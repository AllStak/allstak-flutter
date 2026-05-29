## Unreleased — 2026-05-29

### Added — Release-health session tracking (start/end + crash-free)
- Automatic session lifecycle tied to the Flutter app lifecycle. On init the SDK
  opens a session and POSTs `/ingest/v1/sessions/start`; on graceful shutdown (or
  an explicit `close()` / `endSession()`) it POSTs `/ingest/v1/sessions/end` with
  the final status and accumulated duration. Sessions are **never sampled** so
  crash-free rates stay accurate.
- `SessionStatus` vocabulary (`ok` / `exited` / `errored` / `crashed` / `abnormal`)
  matches the backend `/sessions/end` contract; an unhandled/fatal exception marks
  the session `crashed`, feeding crash-free-sessions / crash-free-users release
  health on the server.
- New `AllStakConfig.enableAutoSessionTracking` (**default on**); a
  `_SessionLifecycleObserver` (`WidgetsBindingObserver`) drives end-on-detach.
  `AllStak.sessionId` exposes the current session id, also stamped onto error /
  log / http payloads for correlation. See `lib/src/session.dart`.

### Added — Offline / persistent transport queue (survive restart + outage)
- When the live transport cannot deliver an event (network outage, or events
  still pending), the SDK persists the **already PII-scrubbed** wire bytes to a
  line-oriented on-disk spool instead of dropping them, and drains the spool on
  the next SDK init (sentry-dart parity). See `lib/src/offline_queue.dart`
  (`OfflineQueue`, `OfflineEntry`, now exported from the package root).
- Scrub-before-persist: only sanitized bytes ever touch disk. The spool is
  bounded (max-entry cap + age-based eviction) and degrades to a silent no-op
  when no persistent store is available (web / tests). Session lifecycle calls
  (`/sessions/start`, `/sessions/end`) are intentionally **never persisted** so a
  replayed stale session can't corrupt release-health math.
- New `AllStakConfig.enableOfflineQueue` (**default on**).

### Added — Value-pattern PII scrubbing + `sendDefaultPii`
- Extended the single sanitizer chokepoint (`lib/sanitizer.dart`) with free-text
  VALUE scrubbing on top of the existing key-name redaction, reaching Sentry
  data-scrubbing parity:
  - **Always** (regardless of `sendDefaultPii`): Luhn-valid credit-card numbers
    (13–19 digits, space/hyphen separators; Luhn-invalid digit runs such as order
    ids / timestamps are preserved) and hyphenated US SSNs.
  - **Unless `sendDefaultPii=true`** (default `false` = Sentry parity): email
    addresses and validated-octet IPv4 literals.
- Value scrubbing skips identifiers that must reach the wire verbatim (stack-frame
  filename/function/absPath, release/sdk/version/dist, URLs/paths/hosts,
  trace/span/request ids, timestamps, the SDK's own `sessionId`) and the explicit
  `setUser` subtree (intentional identity; not stripped by `sendDefaultPii`,
  matching Sentry). Regexes compile once; strings >16 KB are skipped; per-value
  scrubbing is fail-open so it can never drop an event.
- New `ScrubOptions` + `AllStakConfig.sendDefaultPii` (**default false**) wire
  through the existing `scrub()` call in `_send`.

### Added — Native signal / NDK crash capture (async-signal-safe)
- Broadened native crash capture beyond uncaught-exception handlers, which miss
  the dominant class of real mobile crashes:
  - **iOS** (`ios/AllStakPlugin.swift`): async-signal-safe POSIX `sigaction`
    handlers for SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP — the force-unwrap
    traps, bad-pointer accesses, and Mach-derived faults that never raise an
    `NSException`. Mirrors the sibling `allstak-apple` `SignalCrashHandler`:
    pre-allocated buffers + a pre-opened fd, single `write()`, restore the
    previous disposition, re-raise. (Mach exception ports remain a future bonus;
    signal handlers are the priority and match the apple SDK.)
  - **Android** (`android/src/main/cpp/allstak_crash.c` + `CMakeLists.txt`): an
    NDK `sigaction` handler for the same signals, capturing NDK/native signal
    crashes the JVM `Thread.setDefaultUncaughtExceptionHandler` misses. Stack
    unwound via `_Unwind_Backtrace`; JNI install bridge passes the crash-file
    path. The handler makes NO JNI/heap calls — only async-signal-safe writes.
- The signal handler writes a minimal, fixed `ASKC1` text record to a pre-opened
  fd under the app-support / files dir. On the **next launch** (normal context)
  the record is read, parsed (`lib/src/native_crash.dart`), and shipped through
  the existing `_send` transport as `/ingest/v1/errors` marked
  `native.crash=true`. Stack frames ship as raw `0x…` return addresses for
  backend symbolication against uploaded debug images.
- New `drainPendingSignalCrash` MethodChannel method (iOS + Android) feeding the
  existing next-launch drain in `installNativeHandlers()`.
- Gated behind `AllStakConfig.enableNativeCrashCapture` (**default on**).
  Degrades gracefully: if the native lib is unavailable (web, tests, or an app
  that did not opt into the Android NDK build via
  `allstak.enableNdkCrashCapture=true`), signal capture is a silent no-op and
  the SDK keeps working — adding the SDK never forces an NDK toolchain on apps.

### Tests
- `test/allstak_flutter_test.dart` — session lifecycle (start/end POST contract,
  status transitions, `sessionId` stamping, lifecycle-observer end-on-detach),
  release auto-detection ordering, and offline-queue integration via injected
  seams.
- `test/offline_queue_test.dart` — enqueue/drain round-trip, bounded cap + age
  eviction, scrub-before-persist invariant, no-store no-op, and corrupt-line
  tolerance.
- `test/sanitizer_test.dart` — value-pattern scrubbing (Luhn-valid CC vs.
  Luhn-invalid passthrough, hyphenated SSN, email + IPv4 gated by
  `sendDefaultPii`, verbatim-identifier skip list, `setUser` subtree preserved)
  on top of the existing key-name denylist coverage.
- `test/native_crash_test.dart` — record parsing (well-formed iOS/Android,
  unknown-key tolerance, frame cap, corrupt/empty rejection, signal-name
  mapping), payload shaping (`native.crash=true` wire contract), and the
  next-launch drain handoff via a mocked native channel (install gating, drain
  sequence, opt-out, corrupt-drop).
- Full suite **113/113 green** at HEAD.

### Verification (honest scope)
- Dart: `flutter pub get` + `flutter analyze` (no issues) + `flutter test`
  (113/113) all pass; `dart format` applied.
- Native syntax/type checks (no device/emulator here):
  - iOS Swift: `swiftc -parse` of the full plugin against the iphoneos SDK, and
    `swiftc -typecheck` of the extracted signal-handler logic against Darwin —
    both clean (validates the `sigaction`/`backtrace`/`si_addr` API usage).
  - Android C: `clang -fsyntax-only -std=c11 -Wall -Wextra` (with JNI +
    `android/log.h`/`unwind.h` stubs, and against the host's real `signal.h`) —
    clean. A real NDK/CMake/Gradle build was NOT run (no NDK installed here).
- **On-device E2E delivery of native signal/NDK crashes remains PENDING** real
  device/emulator verification, consistent with the 1.0.3 note below.

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
