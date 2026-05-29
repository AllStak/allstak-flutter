// AllStakPlugin.swift — Flutter iOS crash capture plugin.
//
// SCAFFOLDED: targets Flutter 3.x iOS plugin API. Requires a real iOS
// Xcode build + pod install in the host app to verify end-to-end.
//
// Two layers of crash capture:
//   1. NSSetUncaughtExceptionHandler — Obj-C NSExceptions (JSON record).
//   2. Async-signal-safe POSIX sigaction handlers (SIGSEGV/SIGABRT/SIGBUS/
//      SIGILL/SIGFPE/SIGTRAP) — the dominant class of real iOS crashes
//      (force-unwrap traps, bad-pointer access) that NEVER raise an
//      NSException. Mirrors the sibling allstak-apple SignalCrashHandler.
//
// THE SIGNAL HANDLER RUNS INSIDE A DYING PROCESS. It is allowed to call ONLY
// async-signal-safe functions (man 2 sigaction). It therefore:
//   * touches NO Swift heap (no String/Array/Dictionary/closure/Foundation/
//     JSONSerialization/malloc);
//   * uses ONLY pre-allocated buffers + a pre-opened file descriptor (set up
//     in install(), in normal context);
//   * formats a tiny fixed ASCII "ASKC1" record into a fixed byte buffer and
//     emits it with a single write(2);
//   * guards re-entrancy with sig_atomic_t, restores the previous disposition,
//     and re-raises so the OS crash reporter (and any chained handler) runs.
// The record is parsed back on the NEXT launch (normal context) on the Dart
// side (see lib/src/native_crash.dart) and shipped as /ingest/v1/errors.

import Flutter
import UIKit

#if canImport(Darwin)
import Darwin
#endif

private let kPendingCrashKey = "io.allstak.flutter.pending_crash"
private var gRelease: String? = nil

// MARK: - Legacy NSException handler (Obj-C exceptions only)

private var gPreviousHandler: (@convention(c) (NSException) -> Void)? = NSGetUncaughtExceptionHandler()

private func allstakHandleException(_ exception: NSException) {
  var stack: [String] = []
  for line in exception.callStackSymbols {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { stack.append(trimmed) }
  }
  let dev = UIDevice.current
  let metadata: [String: Any] = [
    "platform": "flutter",
    "device.os": "ios",
    "device.osVersion": dev.systemVersion,
    "device.model": dev.model,
    "device.name": dev.name,
    "fatal": "true",
    "source": "ios-NSUncaughtExceptionHandler"
  ]
  var payload: [String: Any] = [
    "exceptionClass": exception.name.rawValue,
    "message": exception.reason ?? "(no reason)",
    "stackTrace": stack,
    "level": "fatal",
    "metadata": metadata
  ]
  if let r = gRelease { payload["release"] = r }
  if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
     let str = String(data: data, encoding: .utf8) {
    UserDefaults.standard.set(str, forKey: kPendingCrashKey)
    UserDefaults.standard.synchronize()
  }
  gPreviousHandler?(exception)
}

// MARK: - Async-signal-safe POSIX signal handler

#if canImport(Darwin)

/// The C `struct sigaction` (the bare name `sigaction` resolves to the function).
private typealias SigAction = Darwin.sigaction

/// Signals we intercept. SIGTRAP is what Swift fatal-error / force-unwrap traps
/// deliver; the rest are the classic hard faults. Order is preserved in the
/// parallel previous-action buffers so the handler can restore + re-raise.
private let gAllStakSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

/// Pre-allocated alternate stack — a faulting thread's stack may be exhausted
/// (e.g. SIGSEGV from a stack overflow), so the handler runs on its own stack.
private var gAltStack: UnsafeMutableRawPointer?

/// Pre-allocated scratch buffer the handler formats the ASCII record into. No
/// malloc at crash time — everything is written into this fixed buffer.
private let kRecordCapacity = 8192
private var gRecordBuffer: UnsafeMutablePointer<UInt8>?

/// Pre-allocated frame buffer for backtrace().
private let kMaxFrames = 128
private var gFrameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

/// Pre-opened crash file descriptor. open() is NOT async-signal-safe, so it is
/// opened at install time and only write()-ten in the handler.
private var gSignalFD: Int32 = -1

/// Saved previous dispositions parallel to gSignalNumbers, in install order, in
/// a fixed C buffer (never a Swift Array/Dictionary) so the handler can look up
/// the previous action without hashing or allocating.
private var gPreviousActions: UnsafeMutablePointer<SigAction>?
private var gSignalNumbers: UnsafeMutablePointer<Int32>?
private var gInstalledCount: Int = 0

/// Re-entrancy guard — sig_atomic_t is the only type guaranteed safe to touch
/// from a handler.
private var gInHandler: sig_atomic_t = 0

/// Async-signal-safe: append the lowercase-hex digits of `value` (no "0x") into
/// `buffer` starting at `offset`, bounded by `capacity`. Returns the new offset.
/// Pure pointer arithmetic; no allocation.
private func allstakAppendHex(_ value: UInt64,
                              _ buffer: UnsafeMutablePointer<UInt8>,
                              _ offset: Int,
                              _ capacity: Int) -> Int {
  let digits: StaticString = "0123456789abcdef"
  return digits.withUTF8Buffer { table -> Int in
    if value == 0 {
      if offset >= capacity { return offset }
      buffer[offset] = table[0]
      return offset + 1
    }
    var v = value
    var n = 0
    while v != 0 { n += 1; v >>= 4 }
    if offset + n > capacity { return offset }
    v = value
    var i = offset + n - 1
    while v != 0 {
      buffer[i] = table[Int(v & 0xF)]
      v >>= 4
      i -= 1
    }
    return offset + n
  }
}

/// Async-signal-safe: append the decimal digits of a non-negative `value`.
private func allstakAppendDec(_ value: Int64,
                             _ buffer: UnsafeMutablePointer<UInt8>,
                             _ offset: Int,
                             _ capacity: Int) -> Int {
  let digits: StaticString = "0123456789"
  return digits.withUTF8Buffer { table -> Int in
    if value <= 0 {
      if offset >= capacity { return offset }
      buffer[offset] = table[0]
      return offset + 1
    }
    var v = value
    var n = 0
    while v != 0 { n += 1; v /= 10 }
    if offset + n > capacity { return offset }
    v = value
    var i = offset + n - 1
    while v != 0 {
      buffer[i] = table[Int(v % 10)]
      v /= 10
      i -= 1
    }
    return offset + n
  }
}

/// Async-signal-safe: append a fixed ASCII literal.
private func allstakAppendLiteral(_ s: StaticString,
                                 _ buffer: UnsafeMutablePointer<UInt8>,
                                 _ offset: Int,
                                 _ capacity: Int) -> Int {
  return s.withUTF8Buffer { bytes -> Int in
    var o = offset
    for b in bytes {
      if o >= capacity { return o }
      buffer[o] = b
      o += 1
    }
    return o
  }
}

private func allstakSignalHandler(_ signal: Int32,
                                  _ info: UnsafeMutablePointer<siginfo_t>?,
                                  _ context: UnsafeMutableRawPointer?) {
  // Re-entrancy / double-fault guard: if we crash again while handling, fall
  // straight through to the previous handler.
  if gInHandler != 0 {
    allstakChainPrevious(signal)
    return
  }
  gInHandler = 1

  if let buffer = gRecordBuffer, let frames = gFrameBuffer, gSignalFD >= 0 {
    var off = 0
    // Magic + newline.
    off = allstakAppendLiteral("ASKC1\nplat=ios\nsig=", buffer, off, kRecordCapacity)
    off = allstakAppendDec(Int64(signal), buffer, off, kRecordCapacity)
    // Fault address (si_addr).
    off = allstakAppendLiteral("\naddr=", buffer, off, kRecordCapacity)
    var faultAddress: UInt64 = 0
    if let info = info {
      faultAddress = UInt64(UInt(bitPattern: info.pointee.si_addr))
    }
    off = allstakAppendHex(faultAddress, buffer, off, kRecordCapacity)
    // Timestamp — time(nil) is async-signal-safe.
    off = allstakAppendLiteral("\ntime=", buffer, off, kRecordCapacity)
    off = allstakAppendDec(Int64(time(nil)), buffer, off, kRecordCapacity)
    off = allstakAppendLiteral("\n", buffer, off, kRecordCapacity)
    // Backtrace — documented async-signal-safe; writes into our fixed buffer.
    let frameCount = Int(backtrace(frames, Int32(kMaxFrames)))
    var f = 0
    while f < frameCount {
      let addr = UInt64(UInt(bitPattern: frames[f]))
      off = allstakAppendLiteral("frame=", buffer, off, kRecordCapacity)
      off = allstakAppendHex(addr, buffer, off, kRecordCapacity)
      off = allstakAppendLiteral("\n", buffer, off, kRecordCapacity)
      f += 1
    }
    // Single write of the whole record; write()/fsync() are async-signal-safe.
    _ = write(gSignalFD, buffer, off)
    _ = fsync(gSignalFD)
  }

  // Restore the previous disposition for THIS signal and re-raise so the OS
  // crash reporter (and any chained reporter) still runs.
  allstakChainPrevious(signal)
}

/// Restore the previously-installed action for `signal` (or SIG_DFL) and
/// re-raise. Async-signal-safe: only fixed-buffer reads + sigaction/raise.
private func allstakChainPrevious(_ signal: Int32) {
  var restored = false
  if let numbers = gSignalNumbers, let actions = gPreviousActions {
    var i = 0
    while i < gInstalledCount {
      if numbers[i] == signal {
        _ = sigaction(signal, actions.advanced(by: i), nil)
        restored = true
        break
      }
      i += 1
    }
  }
  if !restored {
    var def = SigAction()
    def.__sigaction_u.__sa_handler = SIG_DFL
    sigemptyset(&def.sa_mask)
    def.sa_flags = 0
    _ = sigaction(signal, &def, nil)
  }
  _ = raise(signal)
}

/// Arm the signal handlers. Pre-allocates the alt-stack, record + frame
/// buffers, and pre-opens the crash file — none safe inside a handler. Called
/// from normal context at install time. Idempotent enough to be safe to call
/// once per process; a second call re-opens the fd (truncating any unread
/// record, which the next-launch drain already consumed).
private func allstakInstallSignalHandlers(path: String) {
  // 1. Alternate signal stack (a faulting stack may be unusable).
  if gAltStack == nil {
    let stackSize = max(Int(SIGSTKSZ), 64 * 1024)
    let stack = UnsafeMutableRawPointer.allocate(byteCount: stackSize,
                                                 alignment: MemoryLayout<UInt>.alignment)
    gAltStack = stack
    var ss = stack_t()
    ss.ss_sp = stack
    ss.ss_size = stackSize
    ss.ss_flags = 0
    _ = sigaltstack(&ss, nil)
  }

  // 2. Pre-allocate the buffers the handler fills.
  if gRecordBuffer == nil {
    gRecordBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: kRecordCapacity)
  }
  if gFrameBuffer == nil {
    gFrameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: kMaxFrames)
  }

  // 3. Pre-open the crash file (O_CREAT|O_WRONLY|O_TRUNC). open() is not
  //    async-signal-safe, so it happens here, not in the handler.
  if gSignalFD < 0 {
    path.withCString { c in
      gSignalFD = open(c, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    }
  }

  // 4. Pre-allocate the fixed parallel buffers the handler reads.
  if gPreviousActions == nil {
    let n = gAllStakSignals.count
    let actions = UnsafeMutablePointer<SigAction>.allocate(capacity: n)
    actions.initialize(repeating: SigAction(), count: n)
    let numbers = UnsafeMutablePointer<Int32>.allocate(capacity: n)
    numbers.initialize(repeating: 0, count: n)
    gPreviousActions = actions
    gSignalNumbers = numbers

    // 5. Install handlers with SA_SIGINFO | SA_ONSTACK, saving the previous
    //    action so we can chain/restore + re-raise.
    var installed = 0
    for sig in gAllStakSignals {
      var action = SigAction()
      action.__sigaction_u.__sa_sigaction = allstakSignalHandler
      action.sa_flags = SA_SIGINFO | SA_ONSTACK
      sigemptyset(&action.sa_mask)
      var old = SigAction()
      if sigaction(sig, &action, &old) == 0 {
        actions[installed] = old
        numbers[installed] = sig
        installed += 1
      }
    }
    gInstalledCount = installed
  }
}

#endif // canImport(Darwin)

public class AllStakPlugin: NSObject, FlutterPlugin {

  /// Fixed filename of the pending signal-crash record inside the support dir.
  private static let signalRecordFilename = "allstak_signal_crash.bin"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "io.allstak.flutter/native",
      binaryMessenger: registrar.messenger()
    )
    let instance = AllStakPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// Absolute path of the signal-crash record file under Application Support.
  private static func signalCrashPath() -> String? {
    guard let dir = NSSearchPathForDirectoriesInDomains(
      .applicationSupportDirectory, .userDomainMask, true
    ).first else { return nil }
    // Application Support may not exist yet — create it (normal context).
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: nil)
    return (dir as NSString).appendingPathComponent(signalRecordFilename)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "install":
      let args = call.arguments as? [String: Any]
      gRelease = args?["release"] as? String
      NSSetUncaughtExceptionHandler(allstakHandleException)
      let enableSignals = (args?["enableSignalHandlers"] as? Bool) ?? true
      #if canImport(Darwin)
      if enableSignals, let path = AllStakPlugin.signalCrashPath() {
        allstakInstallSignalHandlers(path: path)
      }
      #endif
      result(true)
    case "drainPendingCrash":
      let json = UserDefaults.standard.string(forKey: kPendingCrashKey)
      UserDefaults.standard.removeObject(forKey: kPendingCrashKey)
      UserDefaults.standard.synchronize()
      result(json as Any?)
    case "drainPendingSignalCrash":
      // Read + remove the async-signal-safe record from the previous launch.
      guard let path = AllStakPlugin.signalCrashPath() else {
        result(nil)
        return
      }
      let fm = FileManager.default
      let contents = try? String(contentsOfFile: path, encoding: .utf8)
      try? fm.removeItem(atPath: path)
      result(contents as Any?)
    case "spoolDir":
      // Persistent, sandboxed directory for the offline telemetry spool.
      // Application Support is the conventional home for app-managed,
      // non-user-facing data that should survive app restarts.
      let dir = NSSearchPathForDirectoriesInDomains(
        .applicationSupportDirectory, .userDomainMask, true
      ).first
      result(dir as Any?)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
