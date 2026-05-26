## 1.0.3 — 2026-05-18

### Fixed — Native plugin registration (Android + iOS)
- `pubspec.yaml` had no `flutter: plugin:` declaration, so the native crash-capture
  plugins (`AllStakPlugin.kt` / `AllStakPlugin.swift`) were never added to the host
  app's plugin registrar. Every `installNativeHandlers()` call hit the `catch (_)`
  no-op and native crash capture was dead code.
- Added `flutter: plugin: platforms:` block declaring `android.package = io.allstak.flutter`,
  `android.pluginClass = AllStakPlugin`, and `ios.pluginClass = AllStakPlugin`.
- Added the platform module scaffolding required for the declaration to build/register:
  `android/build.gradle` (com.android.library, namespace `io.allstak.flutter`),
  `android/src/main/AndroidManifest.xml`, and `ios/allstak_flutter.podspec`.
- The MethodChannel name `io.allstak.flutter/native` already matched on the Dart,
  Kotlin, and Swift sides — no channel rename was needed.
- Verified via a throwaway consuming app: `GeneratedPluginRegistrant` now emits
  `new io.allstak.flutter.AllStakPlugin()` (Android) and
  `[AllStakPlugin registerWithRegistrar:...]` (iOS). End-to-end native crash delivery
  still requires real device/emulator verification.

### Added — Recursive payload sanitizer
- New top-level `scrub(payload, {extraDenylist})` in `lib/sanitizer.dart`. 25-term canonical denylist, recursive over `Map` / `Iterable`, `[REDACTED]` substitution, `identityHashCode` cycle protection. Pure (no caller mutation). Mobile-safe: synchronous, no I/O.
- Wired into `AllStak._send` in `lib/allstak_flutter.dart` — every wire payload is scrubbed before `jsonEncode`. One chokepoint protects errors, logs, http, native crashes.
- Fail-open: sanitizer exceptions are logged in debug mode and the raw payload is sent so telemetry is never blocked.

### Tests
- `test/sanitizer_test.dart` — 10 group tests (denylist, recursion, cycles, mutation, primitive passthrough, extension denylist, canary).
- `test/allstak_flutter_test.dart` — 1 new test asserting the canary `should_not_leak_flutter` is scrubbed in the actual `_send` wire body recorded by the in-test HTTP server.
- 34/34 tests pass.

## 1.0.2

* Fix: update Dart SDK constraint to `>=3.0.0 <4.0.0` for broad compatibility.
* Fix: correct repository URL to `github.com/allstak-io/allstak-flutter`.
* Add: CI workflow with flutter analyze and flutter test.
* Add: Release workflow with pub.dev trusted publishing.

## 1.0.1

* Initial public release of the AllStak Flutter SDK.
* Error tracking, structured logs, HTTP monitoring, distributed tracing, and cron monitoring for Flutter and Dart applications.

## 0.0.1

* Initial development release.
