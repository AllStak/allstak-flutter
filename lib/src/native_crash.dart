/// Native (signal / NDK) crash record parsing + drain handoff.
///
/// The platform sides (iOS `sigaction`, Android NDK `sigaction`) cannot build
/// JSON inside a signal handler — only async-signal-safe calls are allowed
/// there (no malloc, no Obj-C, no JNI). So the handler writes a tiny, fixed,
/// line-oriented ASCII record to a pre-opened file descriptor using a single
/// `write()`. On the NEXT launch — in normal context, where allocation and a
/// full JSON encoder are fine — Dart reads that record back, parses it here,
/// and ships it through the existing `_send` transport as an `/ingest/v1/errors`
/// event marked `native.crash=true`.
///
/// ## Record format (`ASKC1`)
///
/// A newline-delimited key/value text blob. The first line is the magic
/// `ASKC1`. Subsequent lines are `key=value`. `frame=` lines repeat, one per
/// stack return address (hex, no `0x`). Unknown keys are ignored so the format
/// can grow without breaking older parsers. Example:
///
/// ```text
/// ASKC1
/// plat=ios
/// sig=11
/// signame=SIGSEGV
/// addr=10ab34cd0
/// time=1716950000
/// frame=10204aa3c
/// frame=10204b110
/// ```
///
/// This ASCII shape is deliberately trivial for an async-signal-safe writer to
/// emit (fixed digits/hex, no length-prefixing) and trivial to host-test on the
/// Dart side without a device.
library;

/// One parsed native crash record. Pure data; no I/O.
class NativeCrashRecord {
  NativeCrashRecord({
    required this.signal,
    required this.signalName,
    required this.faultAddress,
    required this.timestampSeconds,
    required this.platform,
    required this.frames,
  });

  /// POSIX signal number (e.g. 11 for SIGSEGV). 0 when unknown.
  final int signal;

  /// Human-readable signal name (e.g. `SIGSEGV`). Empty when unknown.
  final String signalName;

  /// Faulting address as written by the handler (hex string, no `0x`). Empty
  /// when unknown / not applicable.
  final String faultAddress;

  /// Whole seconds since epoch when the crash was captured. 0 when unknown.
  final int timestampSeconds;

  /// `ios` or `android` (whatever the native side stamped). Empty when unknown.
  final String platform;

  /// Raw stack return addresses (hex strings, no `0x`), top frame first.
  final List<String> frames;

  /// Magic header that prefixes every record. Kept short + fixed so the
  /// async-signal-safe writer can emit it with a single `write()`.
  static const String magic = 'ASKC1';

  static const int _maxFrames = 256;

  /// Parse a raw record blob. Returns `null` for empty / non-matching / garbage
  /// input so a corrupt file is dropped rather than shipped as half-parsed
  /// noise. Tolerant of trailing data and unknown keys.
  static NativeCrashRecord? parse(String raw) {
    if (raw.isEmpty) return null;
    final lines = raw.split('\n');
    if (lines.isEmpty) return null;
    // The first non-empty line must be the magic.
    var i = 0;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length || lines[i].trim() != magic) return null;
    i++;

    var signal = 0;
    var signalName = '';
    var faultAddress = '';
    var timestamp = 0;
    var platform = '';
    final frames = <String>[];

    for (; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq);
      final value = line.substring(eq + 1).trim();
      switch (key) {
        case 'sig':
          signal = int.tryParse(value) ?? 0;
          break;
        case 'signame':
          signalName = value;
          break;
        case 'addr':
          faultAddress = value;
          break;
        case 'time':
          timestamp = int.tryParse(value) ?? 0;
          break;
        case 'plat':
          platform = value;
          break;
        case 'frame':
          if (value.isNotEmpty && frames.length < _maxFrames) {
            frames.add(value);
          }
          break;
        default:
          // Unknown key — ignore so the format can grow compatibly.
          break;
      }
    }

    // A record with neither a signal nor any frames is indistinguishable from
    // noise — refuse it so we never emit an empty "native crash".
    if (signal == 0 && frames.isEmpty) return null;

    return NativeCrashRecord(
      signal: signal,
      signalName: signalName,
      faultAddress: faultAddress,
      timestampSeconds: timestamp,
      platform: platform,
      frames: frames,
    );
  }

  /// Best-effort human signal name from the number, used when the native side
  /// did not stamp one (older record, or a signal we did not special-case).
  static String signalNameFor(int signal) {
    switch (signal) {
      case 4:
        return 'SIGILL';
      case 6:
        return 'SIGABRT';
      case 8:
        return 'SIGFPE';
      case 10:
        return 'SIGBUS'; // Darwin numbering (Linux SIGBUS = 7)
      case 11:
        return 'SIGSEGV';
      case 5:
        return 'SIGTRAP';
      case 7:
        return 'SIGBUS'; // Linux numbering
      default:
        return signal > 0 ? 'SIG$signal' : 'SIGNAL';
    }
  }

  /// The resolved signal name: the one the native side stamped, else derived
  /// from the number.
  String get effectiveSignalName =>
      signalName.isNotEmpty ? signalName : signalNameFor(signal);

  /// A short human description of the fault for the error message line.
  String get description {
    final name = effectiveSignalName;
    final base = switch (name) {
      'SIGSEGV' => 'Segmentation fault',
      'SIGABRT' => 'Abnormal termination (abort)',
      'SIGBUS' => 'Bus error',
      'SIGILL' => 'Illegal instruction',
      'SIGFPE' => 'Floating-point exception',
      'SIGTRAP' => 'Trace/breakpoint trap',
      _ => 'Fatal native signal',
    };
    final at = faultAddress.isNotEmpty ? ' at 0x$faultAddress' : '';
    return 'Native crash: $name ($base)$at';
  }

  /// Convert this record into the `/ingest/v1/errors` payload shape used by the
  /// existing Dart `_send` path. [release], [environment], and SDK metadata are
  /// supplied by the caller so the payload matches every other event the SDK
  /// emits. Marks `native.crash=true` so the dashboard can distinguish a native
  /// signal/NDK crash from a Dart-side exception.
  ///
  /// Stack frames are raw return addresses (the device has no symbol table at
  /// runtime); they are emitted as `stackTrace` lines so the backend can
  /// symbolicate them against the uploaded debug images, mirroring how the
  /// apple SDK ships address-only crash reports.
  Map<String, dynamic> toErrorPayload({
    required String release,
    required String environment,
    required String sdkName,
    required String sdkVersion,
    required String platformTag,
    String? dist,
    String? sessionId,
    Map<String, String>? extraMetadata,
  }) {
    final name = effectiveSignalName;
    final stackLines = <String>[
      for (final f in frames) '0x$f',
    ];
    final metadata = <String, String>{
      'platform': 'flutter',
      'native.crash': 'true',
      'native.signal': signal.toString(),
      'native.signalName': name,
      if (faultAddress.isNotEmpty) 'native.faultAddress': '0x$faultAddress',
      if (platform.isNotEmpty) 'native.platform': platform,
      'fatal': 'true',
      'source': 'native-signal-handler',
      if (extraMetadata != null) ...extraMetadata,
    };
    return <String, dynamic>{
      'exceptionClass': name,
      'message': description,
      'stackTrace': stackLines,
      'environment': environment,
      'release': release,
      'level': 'fatal',
      'sdkName': sdkName,
      'sdkVersion': sdkVersion,
      'platform': platformTag,
      if (dist != null && dist.isNotEmpty) 'dist': dist,
      if (sessionId != null) 'sessionId': sessionId,
      'metadata': metadata,
    };
  }
}
