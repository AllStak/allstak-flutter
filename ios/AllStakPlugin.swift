// AllStakPlugin.swift — Flutter iOS crash capture plugin.
//
// SCAFFOLDED: targets Flutter 3.x iOS plugin API. Requires a real iOS
// Xcode build + pod install in the host app to verify end-to-end.

import Flutter
import UIKit

private let kPendingCrashKey = "io.allstak.flutter.pending_crash"
private var gRelease: String? = nil
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

public class AllStakPlugin: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "io.allstak.flutter/native",
      binaryMessenger: registrar.messenger()
    )
    let instance = AllStakPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "install":
      let args = call.arguments as? [String: Any]
      gRelease = args?["release"] as? String
      NSSetUncaughtExceptionHandler(allstakHandleException)
      result(true)
    case "drainPendingCrash":
      let json = UserDefaults.standard.string(forKey: kPendingCrashKey)
      UserDefaults.standard.removeObject(forKey: kPendingCrashKey)
      UserDefaults.standard.synchronize()
      result(json as Any?)
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
