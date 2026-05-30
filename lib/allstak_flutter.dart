/// AllStak SDK for Flutter / Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpOverrides, Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' hide runApp;
import 'package:flutter/widgets.dart' as widgets show runApp;
import 'package:http/http.dart' as http;

import 'sanitizer.dart';
import 'src/dio_interceptor.dart';
import 'src/http_overrides.dart';
import 'src/log_bridge.dart';
import 'src/native_crash.dart';
import 'src/offline_queue.dart';
import 'src/session.dart';

export 'src/dio_interceptor.dart'
    show allStakDioInterceptor, DioWrapperFactory, DioSpanIds, DioTelemetrySink;
export 'src/http_overrides.dart' show AllStakHttpOverrides;
export 'src/log_bridge.dart' show AllStakLogBridge, AllStakLogRecord;
export 'src/native_crash.dart' show NativeCrashRecord;
export 'src/offline_queue.dart' show OfflineQueue, OfflineEntry;
export 'src/session.dart' show Session, SessionStatus;

AllStak? _instance;

String _allstakBaggage(String traceId, String requestId, String? spanId) {
  final parts = <String>['allstak-trace_id=$traceId'];
  if (requestId.isNotEmpty) parts.add('allstak-request_id=$requestId');
  if (spanId != null && spanId.isNotEmpty) parts.add('allstak-span_id=$spanId');
  return parts.join(',');
}

String _mergeBaggage(
    String? existing, String traceId, String requestId, String? spanId) {
  final preserved = (existing ?? '')
      .split(',')
      .map((part) => part.trim())
      .where((part) =>
          part.isNotEmpty && !part.toLowerCase().startsWith('allstak-'))
      .toList();
  preserved.addAll(_allstakBaggage(traceId, requestId, spanId).split(','));
  return preserved.join(',');
}

/// Classifies the result of a single transport POST so the offline queue knows
/// whether to retain an entry for a later retry.
enum _DeliveryOutcome {
  /// 2xx — accepted by the backend; the entry can be discarded.
  delivered,

  /// Network error / timeout / 429 / 5xx — transient; retain for retry.
  retryable,

  /// Non-429 4xx — permanently undeliverable (bad request, auth); discard so
  /// the spool never loops on a poison entry.
  permanent,
}

/// Thin wrapper so the MethodChannel name lives in one place and can be
/// swapped for tests. Kept private to the library.
class _NativeChannel {
  static const MethodChannel channel = MethodChannel(
    'io.allstak.flutter/native',
  );
}

/// SDK identity sent on the wire as `sdk.name` / `sdk.version` in event metadata.
const String kAllStakSdkName = 'allstak-flutter';
const String kAllStakSdkVersion = '1.1.0';

/// Build-time release override. Set with `--dart-define=ALLSTAK_RELEASE=...`
/// (or `--dart-define-from-file`). `String.fromEnvironment` is resolved by the
/// Dart compiler at build time, so this is a compile-time constant — it is the
/// dependency-light automatic release mechanism for Flutter (see
/// [resolveAllStakRelease] and the README "Release identifier" section).
const String _kAllStakReleaseDefine = String.fromEnvironment('ALLSTAK_RELEASE');

/// Resolves the effective `release` stamped on every event.
///
/// ## Honest scope note (mobile reality)
/// A shipped Flutter app (`.ipa` / `.apk` / web bundle) contains no `.git`
/// directory and no `git` binary, so true runtime git detection is impossible
/// in production. Likewise, reading the app's store version at runtime requires
/// a platform plugin (e.g. `package_info_plus`) — which this SDK deliberately
/// does **not** depend on to stay dependency-light. The automatic, build-time
/// release mechanism here is therefore the `ALLSTAK_RELEASE` **dart-define**,
/// with the SDK version as a never-empty fallback.
///
/// Resolution order (highest priority first):
/// 1. Explicit `release` passed to [AllStakConfig] — always wins.
/// 2. `ALLSTAK_RELEASE` build-time dart-define.
/// 3. (Automatic) the SDK version constant as a last resort, so `release` is
///    never empty. (SDK version != app version — last resort only.) Apps that
///    want the real app/store version should pass it explicitly (step 1) or
///    via the dart-define (step 2), e.g. wired from `package_info_plus` in the
///    host app or `1.4.2+$(git rev-parse --short HEAD)` in CI.
///
/// Steps 2–3 are gated by [autoDetect] (default `true` via
/// `AllStakConfig.autoDetectRelease`). With auto-detection off, only an
/// explicit release is used and the result may be empty.
///
/// [define] and [sdkVersion] are seams so tests can assert ordering without a
/// real build environment.
String resolveAllStakRelease({
  required String explicit,
  bool autoDetect = true,
  String define = _kAllStakReleaseDefine,
  String sdkVersion = kAllStakSdkVersion,
}) {
  // 1. Explicit always wins, regardless of autoDetect.
  if (explicit.isNotEmpty) return explicit;
  // Opt-out: respect the caller and send no release rather than inventing one.
  if (!autoDetect) return '';
  // 2. Build-time dart-define.
  if (define.trim().isNotEmpty) return define;
  // 3. Last resort so `release` is never empty.
  return sdkVersion;
}

class AllStakConfig {
  final String apiKey;
  final String host;
  final String environment;
  final String release;
  final String service;
  final Map<String, String> tags;
  final bool debug;
  // Release-tracking metadata (optional). `dist` is especially useful here to
  // disambiguate the same release built for iOS vs Android vs web.
  final String dist;
  final String commitSha;
  final String branch;
  final String platform;
  final String sdkName;
  final String sdkVersion;
  final Duration transportTimeout;
  // When true (default) and no explicit `release` is given, the SDK resolves
  // the release from the `ALLSTAK_RELEASE` dart-define, then the SDK version.
  // See [resolveAllStakRelease]. Set false to opt out of all auto-detection.
  final bool autoDetectRelease;
  final bool autoRegisterRelease;
  // When true (default) the SDK opens a release-health session on init
  // (POST /ingest/v1/sessions/start) and closes it on graceful shutdown
  // (POST /ingest/v1/sessions/end). Sessions are never sampled. Set false to
  // opt out entirely. Automatically skipped under the `flutter test` runtime.
  final bool enableAutoSessionTracking;
  // When true (default) telemetry that cannot be delivered (network error,
  // timeout, app shutting down with events pending) is persisted to a bounded,
  // PII-scrubbed file spool and re-sent on the next SDK init — so events
  // survive an app restart AND a network outage. Session lifecycle calls
  // (/sessions/start, /sessions/end) are NEVER persisted (a replayed stale
  // session would skew release-health durations). Set false to keep the legacy
  // in-memory fire-and-forget behavior. Degrades silently to in-memory when the
  // store is unavailable. See [OfflineQueue].
  final bool enableOfflineQueue;

  // When false (default) the SDK scrubs free-text PII:
  // email addresses and client IPv4 literals that leak into event values are
  // scrubbed to `[REDACTED]`, and any auto-collected client IP is dropped.
  // High-risk financial/identity data (Luhn-valid credit-card numbers,
  // hyphenated US SSNs) is ALWAYS scrubbed regardless of this flag. Set true
  // to opt into shipping that auto-collected PII — the *explicit* user object
  // set via [setUser] is NEVER affected by this flag (it ships either way).
  // See [scrub] / [ScrubOptions]. Default = false.
  final bool sendDefaultPii;

  // When true (default) the SDK arms async-signal-safe native crash handlers
  // (iOS POSIX `sigaction` for SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP;
  // Android an NDK `sigaction` handler) so hard crashes that NEVER surface as a
  // Dart exception — force-unwrap traps, bad-pointer access, NDK/native signal
  // crashes — are captured. The handler only writes a minimal fixed record to a
  // pre-opened fd; the record is read on the NEXT launch and shipped via the
  // existing transport with `native.crash=true`. Set false to install ONLY the
  // legacy uncaught-exception handlers. Degrades gracefully (no-op) if the
  // native lib fails to build/load — it never breaks existing consumers.
  final bool enableNativeCrashCapture;

  // When true (default) the SDK ARMS the native crash handlers automatically
  // from [AllStak.runApp] / [AllStak.init] (right after the widgets binding is
  // ready), so a host app gets native crash capture with zero extra calls —
  // [installNativeHandlers] stays as an explicit escape hatch. Auto-arming is
  // always skipped under web (`kIsWeb`) and the `flutter test` runtime (the
  // native channel is not available there), and is a silent no-op if the
  // native side is missing. Set false to opt out of auto-arming and call
  // [installNativeHandlers] yourself. This controls *when/whether the handlers
  // are armed*; [enableNativeCrashCapture] controls whether the async-signal
  // handlers are part of that arm vs only the legacy uncaught-exception ones.
  final bool autoInstallNativeHandlers;

  // When true (default) the SDK installs a process-wide `HttpOverrides.global`
  // from [AllStak.runApp] so every `dart:io` `HttpClient` (the transport under
  // `package:http`'s IOClient, Dio's default adapter, `Image.network`, etc.) is
  // auto-instrumented as an outbound http-request — no `allstak.httpClient()`
  // wiring needed per call. Requests to AllStak's own ingest host are skipped
  // to prevent recursion. Always skipped under web (`kIsWeb`) and the
  // `flutter test` runtime. Set false to keep the explicit-client-only model.
  final bool enableHttpOverrides;

  // When true (default) the SDK attaches a `dart:developer` log listener from
  // [AllStak.init] / [AllStak.runApp] so `log()` calls (and anything that
  // funnels through `package:logging`'s `dart:developer` bridge) are shipped to
  // `/ingest/v1/logs`. SEVERE/level>=1000 records, and any record carrying an
  // `error` object, are promoted to [captureException]. Always skipped under
  // the `flutter test` runtime. Set false to opt out of the logging bridge.
  final bool captureLogs;

  const AllStakConfig({
    required this.apiKey,
    this.host = 'https://api.allstak.sa',
    this.environment = 'production',
    this.release = '',
    this.service = 'flutter',
    this.tags = const {},
    this.debug = false,
    this.dist = '',
    this.commitSha = '',
    this.branch = '',
    this.platform = 'flutter',
    this.sdkName = kAllStakSdkName,
    this.sdkVersion = kAllStakSdkVersion,
    this.transportTimeout = const Duration(seconds: 2),
    this.autoDetectRelease = true,
    this.autoRegisterRelease = true,
    this.enableAutoSessionTracking = true,
    this.enableOfflineQueue = true,
    this.sendDefaultPii = false,
    this.enableNativeCrashCapture = true,
    this.autoInstallNativeHandlers = true,
    this.enableHttpOverrides = true,
    this.captureLogs = true,
  });

  /// The release actually stamped on events: explicit > ALLSTAK_RELEASE
  /// dart-define > SDK version (gated by [autoDetectRelease]). Never returns a
  /// non-empty surprise when auto-detection is off and no explicit release is
  /// set — it returns `''` in that case.
  String get effectiveRelease => resolveAllStakRelease(
        explicit: release,
        autoDetect: autoDetectRelease,
        sdkVersion: sdkVersion,
      );

  /// Release-tracking tags merged into every event payload's metadata so the
  /// dashboard can group / filter by SDK / platform / commit / branch.
  Map<String, String> releaseTags() {
    final out = <String, String>{};
    if (sdkName.isNotEmpty) out['sdk.name'] = sdkName;
    if (sdkVersion.isNotEmpty) out['sdk.version'] = sdkVersion;
    if (platform.isNotEmpty) out['platform'] = platform;
    if (dist.isNotEmpty) out['dist'] = dist;
    if (commitSha.isNotEmpty) out['commit.sha'] = commitSha;
    if (branch.isNotEmpty) out['commit.branch'] = branch;
    return out;
  }
}

class AllStak implements DioTelemetrySink {
  final AllStakConfig config;
  final Map<String, String> _tags = {};
  String? _userId;
  String? _userEmail;
  String? _traceId;
  String? _currentSpanId;
  final List<Future<void>> _pendingRequests = [];

  /// Release-health session tracker. Null when auto session tracking is
  /// disabled or skipped under the test runtime. See [SessionTracker].
  SessionTracker? _sessionTracker;
  _SessionLifecycleObserver? _sessionObserver;

  /// Persistent offline spool. Null when the offline queue is disabled. See
  /// [OfflineQueue]. Survives app restarts + network outages.
  OfflineQueue? _offlineQueue;

  /// Automatic logging bridge. Null when `captureLogs` is off or skipped under
  /// the test runtime. Forwards application logs to `/ingest/v1/logs` and
  /// promotes SEVERE / error-bearing records to [captureException].
  AllStakLogBridge? _logBridge;

  /// The previous `HttpOverrides.global` we wrapped (if any). Restored on
  /// [close] so the SDK never permanently clobbers an app-set override.
  HttpOverrides? _previousHttpOverrides;
  bool _httpOverridesInstalled = false;

  /// Guards [installNativeHandlers] so arming (and the one-shot previous-launch
  /// crash drain) runs at most once per client, even when both the `init()`
  /// auto-arm and an explicit call (or a `runApp()` re-arm) fire. Draining the
  /// stashed crash twice would double-ship the same event.
  bool _nativeArmed = false;

  /// Completes once the init-time drain finishes (success or fail-open). Tests
  /// await this to assert re-send behavior deterministically; production code
  /// never needs it.
  Future<void>? _drainComplete;

  /// Ingest paths whose payloads must NEVER be persisted offline. A replayed,
  /// stale session start/end would skew release-health durations, so session
  /// lifecycle calls stay strictly fire-and-forget.
  static const Set<String> _nonPersistablePaths = {
    SessionTracker.pathStart,
    SessionTracker.pathEnd,
  };

  AllStak._(this.config,
      {bool forceSessionTracking = false, OfflineQueue? offlineQueue}) {
    _tags.addAll(config.tags);
    // Release-tracking metadata is stamped onto _tags once at init so every
    // outgoing event payload (errors, logs, http, db) picks it up via the
    // existing `metadata` merge — no per-call wiring needed in callers.
    _tags.addAll(config.releaseTags());
    if (!_tags.containsKey('platform')) {
      _tags['platform'] = 'flutter';
    }
    _initOfflineQueue(offlineQueue);
    _registerRuntimeRelease();
    _startSessionTracking(force: forceSessionTracking);
    _startLogBridge(force: forceSessionTracking);
  }

  /// [forceSessionTracking] is a test-only seam: it bypasses the
  /// `flutter test` runtime guard so the session lifecycle can be asserted in
  /// unit tests. [offlineQueue] is a test-only seam to inject a spool backed by
  /// a temp directory; production resolves its own via the native channel.
  /// Production callers never set either.
  static AllStak init(AllStakConfig config,
      {bool forceSessionTracking = false, OfflineQueue? offlineQueue}) {
    final sdk = AllStak._(config,
        forceSessionTracking: forceSessionTracking, offlineQueue: offlineQueue);
    _instance = sdk;
    // Auto-arm native crash handlers right after init (default-on, guarded).
    // Apps that call only `init()` (not `runApp()`) — e.g. when they own their
    // own zone/binding setup — still get native crash capture with no extra
    // call. The arm assumes the widgets binding is (or will shortly be) ready;
    // it is a fire-and-forget that fails open if the channel is not available.
    sdk._maybeAutoArmNativeHandlers();
    return sdk;
  }

  /// Auto-arm the native crash handlers from init/runApp when
  /// `autoInstallNativeHandlers` is on. Skipped on web and under the
  /// `flutter test` runtime (the native channel is mocked/absent there).
  /// Fire-and-forget + fail-open: a missing native side is a silent no-op.
  /// [installNativeHandlers] stays available as an explicit escape hatch.
  void _maybeAutoArmNativeHandlers() {
    try {
      if (!config.autoInstallNativeHandlers) return;
      if (kIsWeb) return;
      if (_isLikelyTestRuntime()) return;
      // Fire-and-forget — never block init on the platform channel.
      // ignore: discarded_futures
      installNativeHandlers();
    } catch (_) {
      // Fail-open: auto-arming must never break init.
    }
  }

  /// Install the process-wide `dart:io` HTTP override when
  /// `enableHttpOverrides` is on, so every `HttpClient` is auto-instrumented.
  /// Skipped on web and under the `flutter test` runtime. Idempotent and
  /// fail-open. We wrap (and remember) any existing `HttpOverrides.global` so
  /// an app-set override keeps working and is restored on [close].
  void _maybeInstallHttpOverrides() {
    try {
      if (!config.enableHttpOverrides) return;
      if (kIsWeb) return;
      if (_isLikelyTestRuntime()) return;
      if (_httpOverridesInstalled) return;
      final previous = HttpOverrides.current;
      _previousHttpOverrides = previous;
      HttpOverrides.global = buildHttpOverrides(inner: previous);
      _httpOverridesInstalled = true;
    } catch (_) {
      // Fail-open: failing to install overrides must never break startup.
    }
  }

  /// Build the [AllStakHttpOverrides] wired to this client's transport. Exposed
  /// for tests and for apps that want to compose the override themselves (e.g.
  /// inside a custom `runZoned(... , zoneValues: ...)`). [inner] is delegated to
  /// for client creation so an existing override is preserved.
  @visibleForTesting
  AllStakHttpOverrides buildHttpOverrides({HttpOverrides? inner}) {
    return AllStakHttpOverrides(
      ingestHost: config.host,
      inner: inner,
      hexId: _hexId,
      traceId: getTraceId,
      currentSpanId: () => _currentSpanId,
      mergeBaggage: _mergeBaggage,
      allstakBaggage: (t, r, s) => _allstakBaggage(t, r, s),
      record: ({
        required String method,
        required String host,
        required String path,
        required int statusCode,
        required int durationMs,
        required String traceId,
        required String requestId,
        required String spanId,
        String? parentSpanId,
        String? errorFingerprint,
      }) {
        // Fire-and-forget — never block the host app's request on ingest.
        captureRequest(
          method: method,
          host: host,
          path: path,
          statusCode: statusCode,
          durationMs: durationMs,
          direction: 'outbound',
          traceId: traceId,
          requestId: requestId,
          spanId: spanId,
          parentSpanId: parentSpanId,
          errorFingerprint: errorFingerprint,
        );
      },
    );
  }

  /// Resolve the spool directory via the native platform channel. Returns null
  /// (queue degrades to a no-op) on web, in tests, or when the channel is
  /// unavailable — fail-open.
  static Future<String?> _resolveSpoolDir() async {
    try {
      if (kIsWeb) return null;
      final dir = await _NativeChannel.channel.invokeMethod<String>('spoolDir');
      return (dir != null && dir.isNotEmpty) ? dir : null;
    } catch (_) {
      return null;
    }
  }

  void _initOfflineQueue(OfflineQueue? injected) {
    if (!config.enableOfflineQueue || config.apiKey.isEmpty) return;
    try {
      _offlineQueue = injected ?? OfflineQueue(dirResolver: _resolveSpoolDir);
      // Drain previously-persisted events on the next tick so init never blocks
      // on disk or network. Fail-open throughout.
      _drainComplete = _drainOfflineQueue();
    } catch (_) {
      // Fail-open: an unwritable/unavailable store must never break init.
      _offlineQueue = null;
    }
  }

  /// Load persisted events and re-send them through the existing transport.
  /// An entry is removed (by virtue of [OfflineQueue.drainAll] clearing the
  /// spool) only once it is accepted (2xx) or permanently undeliverable
  /// (non-429 4xx); anything that still fails is re-persisted. Fail-open.
  Future<void> _drainOfflineQueue() async {
    final queue = _offlineQueue;
    if (queue == null) return;
    try {
      final entries = await queue.drainAll();
      for (final entry in entries) {
        final outcome = await _deliverScrubbed(entry.path, entry.body);
        if (outcome == _DeliveryOutcome.retryable) {
          // Still undeliverable — put it back so a later init retries it.
          await queue.enqueue(entry.path, entry.body);
        }
      }
    } catch (_) {
      // Fail-open: draining must never throw.
    }
  }

  /// Test-only: awaits the init-time drain to settle. Returns immediately when
  /// the offline queue is disabled/unavailable.
  @visibleForTesting
  Future<void> awaitOfflineDrain() async => _drainComplete ?? Future.value();

  static AllStak? get instance => _instance;

  /// True when running under `flutter test` (which sets `FLUTTER_TEST=true`).
  /// Mirrors the Java SDK's `isLikelyTestRuntime` classpath guard so unit
  /// tests don't open real release-health sessions. Fail-open: any error
  /// resolving the environment treats the runtime as non-test.
  static bool _isLikelyTestRuntime() {
    try {
      if (kIsWeb) return false;
      final v = Platform.environment['FLUTTER_TEST'];
      return v == 'true' || v == '1';
    } catch (_) {
      return false;
    }
  }

  void _startSessionTracking({bool force = false}) {
    if (!config.enableAutoSessionTracking) return;
    if (!force && _isLikelyTestRuntime()) return;
    if (config.apiKey.isEmpty) return;
    try {
      final tracker = SessionTracker(
        send: _sendBestEffort,
        release: config.effectiveRelease,
        environment: config.environment,
        sdkName: config.sdkName,
        sdkVersion: config.sdkVersion,
        platform: config.platform,
        stateStore: kIsWeb
            ? null
            : FileSessionStateStore.defaultFor(config.effectiveRelease),
      );
      tracker.start(userId: _userId);
      _sessionTracker = tracker;
      // End the session on graceful shutdown (app background -> terminate).
      try {
        final observer = _SessionLifecycleObserver(this);
        WidgetsBinding.instance.addObserver(observer);
        _sessionObserver = observer;
      } catch (_) {
        // WidgetsBinding may be unavailable (pure-Dart / not yet initialized).
        // The session still ends via an explicit close()/endSession() call.
      }
    } catch (_) {
      // Fail-open: session tracking must never break init.
    }
  }

  /// Create the automatic logging bridge (default-on via `captureLogs`).
  /// Skipped under the `flutter test` runtime unless [force] is set (the
  /// test seam) — a bridge that auto-promotes SEVERE logs to captured
  /// exceptions would otherwise fire real network I/O from every test that
  /// logs. The bridge is created here so it is ready immediately; the host app
  /// attaches its logger stream via [attachLogging] (one line) and any record
  /// the SDK feeds via [logBridge] flows to `/ingest/v1/logs`. Fail-open.
  void _startLogBridge({bool force = false}) {
    if (!config.captureLogs) return;
    if (!force && _isLikelyTestRuntime()) return;
    if (config.apiKey.isEmpty) return;
    try {
      _logBridge = AllStakLogBridge(_onLogRecord);
    } catch (_) {
      // Fail-open: the logging bridge must never break init.
    }
  }

  /// Sink the [AllStakLogBridge] calls for every normalized record. Ships the
  /// record to `/ingest/v1/logs`, and — when it is SEVERE+ or carries an error
  /// object — also promotes it to [captureException] so it surfaces as an
  /// error, stamped with the active trace/request ids. Fail-open.
  void _onLogRecord(AllStakLogRecord rec) {
    try {
      final traceId = getTraceId();
      final requestId = _hexId(16);
      final meta = <String, String>{
        if (rec.loggerName != null && rec.loggerName!.isNotEmpty)
          'logger': rec.loggerName!,
        'log.level':
            rec.levelName.isNotEmpty ? rec.levelName : rec.level.toString(),
        'traceId': traceId,
        'requestId': requestId,
      };
      captureLog(rec.wireLevel, rec.message, metadata: meta);
      if (rec.shouldPromote) {
        final err = rec.error ?? rec.message;
        captureException(
          err,
          stackTrace: rec.stackTrace,
          context: {
            'source': 'log-bridge',
            if (rec.loggerName != null && rec.loggerName!.isNotEmpty)
              'logger': rec.loggerName!,
            'log.level':
                rec.levelName.isNotEmpty ? rec.levelName : rec.level.toString(),
            'traceId': traceId,
            'requestId': requestId,
          },
          // A SHOUT / fatal-level log escalates release-health to crashed; a
          // SEVERE / error-bearing one stays a handled error.
          fatal: rec.wireLevel == 'fatal',
        );
      }
    } catch (_) {
      // Fail-open: forwarding a log must never break the app's logging path.
    }
  }

  /// The automatic logging bridge, or null when `captureLogs` is off / skipped
  /// under the test runtime. Use [attachLogging] for the common case.
  AllStakLogBridge? get logBridge => _logBridge;

  /// Forward a `package:logging`-style record stream into AllStak with one
  /// line at app startup:
  ///
  /// ```dart
  /// AllStak.instance?.attachLogging(Logger.root.onRecord);
  /// ```
  ///
  /// Records flow to `/ingest/v1/logs`; SEVERE+ and error-bearing records are
  /// promoted to captured exceptions. No-op when the bridge is unavailable.
  /// Reads record fields via duck typing so it links against whatever
  /// `package:logging` version the host app ships — no SDK dependency on it.
  Object? attachLogging(dynamic onRecordStream) =>
      _logBridge?.attachToLogging(onRecordStream);

  /// The active release-health session id, or null when no session is open.
  /// Attached to every captured error/event payload so the backend's error
  /// consumer can mark the session errored/crashed server-side.
  String? get sessionId => _sessionTracker?.currentSessionId;

  /// Gracefully end the active release-health session, POSTing
  /// `/ingest/v1/sessions/end` with the accumulated status + duration.
  /// Idempotent and fail-open. Called automatically on app
  /// background -> terminate; also safe to call from app teardown.
  void endSession({SessionStatus? status}) {
    try {
      _sessionTracker?.end(finalStatus: status);
    } catch (_) {}
  }

  /// Flush pending telemetry and end the release-health session. Best-effort.
  Future<void> close() async {
    endSession();
    try {
      final observer = _sessionObserver;
      if (observer != null) {
        WidgetsBinding.instance.removeObserver(observer);
        _sessionObserver = null;
      }
    } catch (_) {}
    // Stop forwarding logs and restore any HTTP override we wrapped so the SDK
    // never permanently mutates global state past its own lifetime.
    try {
      _logBridge?.detach();
    } catch (_) {}
    try {
      if (_httpOverridesInstalled) {
        HttpOverrides.global = _previousHttpOverrides;
        _httpOverridesInstalled = false;
      }
    } catch (_) {}
    await flush();
  }

  void _registerRuntimeRelease() {
    final release = config.effectiveRelease;
    if (!config.autoRegisterRelease ||
        config.apiKey.isEmpty ||
        release.isEmpty) {
      return;
    }
    final ingestHost = Uri.tryParse(config.host)?.host;
    if (ingestHost == '127.0.0.1' || ingestHost == 'localhost') {
      return;
    }
    _sendBestEffort('/ingest/v1/releases', {
      'version': release,
      'environment': config.environment,
      'commitSha': config.commitSha.isNotEmpty ? config.commitSha : null,
      'branch': config.branch.isNotEmpty ? config.branch : null,
      'author': null,
      'message': null,
    });
  }

  /// Install Flutter/Dart error handlers and run the app inside a guarded zone.
  static Future<void> runApp(
    AllStakConfig config,
    Widget Function() appBuilder,
  ) async {
    final sdk = init(config);

    await runZonedGuarded<Future<void>>(
      () async {
        // Bindings MUST be initialized inside the zone so framework callbacks
        // run in the guarded zone, otherwise Flutter throws "Zone mismatch".
        WidgetsFlutterBinding.ensureInitialized();

        // Auto-arm native crash handlers now that the binding (and therefore
        // the platform channel) is ready. Idempotent with the `init()` arm.
        sdk._maybeAutoArmNativeHandlers();
        // Install the process-wide dart:io HTTP override so every HttpClient
        // (package:http IOClient, Dio's default adapter, Image.network, …) is
        // auto-instrumented as an outbound http-request with zero per-call
        // wiring. Default-on, guarded, restored on close(). `allstak.httpClient()`
        // keeps working unchanged.
        sdk._maybeInstallHttpOverrides();

        final previousOnError = FlutterError.onError;
        FlutterError.onError = (FlutterErrorDetails details) {
          try {
            // Unhandled framework error -> release-health CRASHED.
            sdk.captureException(
              details.exceptionAsString(),
              stackTrace: details.stack?.toString() ?? '',
              context: {
                'source': 'FlutterError.onError',
                'library': details.library ?? 'flutter',
              },
              fatal: true,
            );
          } catch (_) {}
          previousOnError?.call(details);
        };

        PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
          try {
            // Unhandled platform error -> release-health CRASHED.
            sdk.captureException(
              error.toString(),
              stackTrace: stack.toString(),
              context: {'source': 'PlatformDispatcher.onError'},
              fatal: true,
            );
          } catch (_) {}
          return false;
        };

        widgets.runApp(appBuilder());
      },
      (error, stack) {
        try {
          // Uncaught zone error -> release-health CRASHED.
          sdk.captureException(
            error.toString(),
            stackTrace: stack.toString(),
            context: {'source': 'runZonedGuarded'},
            fatal: true,
          );
        } catch (_) {}
      },
    );
  }

  void setUser({String? id, String? email}) {
    _userId = id;
    _userEmail = email;
  }

  void setTag(String key, String value) {
    _tags[key] = value;
  }

  void setTags(Map<String, String> tags) {
    _tags.addAll(tags);
  }

  String getTraceId() {
    return _traceId ??= _hexId(16);
  }

  void setTraceId(String traceId) {
    _traceId = traceId;
  }

  void resetTrace() {
    _traceId = null;
    _currentSpanId = null;
  }

  Future<void> captureException(
    Object error, {
    String? stackTrace,
    Map<String, String>? context,
    bool fatal = false,
  }) async {
    final className = error is Error
        ? error.runtimeType.toString()
        : error is Exception
            ? error.runtimeType.toString()
            : 'DartError';
    final message = error is String ? error : error.toString();
    final rawStack = stackTrace ??
        (error is Error ? error.stackTrace?.toString() ?? '' : '');
    final stackLines = rawStack
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // Drain breadcrumbs
    final crumbs = _breadcrumbs.isNotEmpty
        ? List<Map<String, dynamic>>.from(_breadcrumbs)
        : null;
    _breadcrumbs.clear();
    // Phase 3 — structured frames from Dart stack lines. Dart prints
    // them as e.g. `#0  MyClass.method (package:foo/foo.dart:42:5)` —
    // parse into the v2 ErrorIngestRequest.Frame shape.
    final structured = _parseDartFrames(stackLines);
    // Release-health: attach the active session id so the backend's error
    // consumer can mark this session errored/crashed server-side. Null when
    // auto session tracking is disabled or no session is open.
    final sid = _sessionTracker?.currentSessionId;
    _sendBestEffort('/ingest/v1/errors', {
      'exceptionClass': className,
      'message': message,
      // Backend expects `stackTrace: List<String>`, not a single `stacktrace` string.
      'stackTrace': stackLines,
      'environment': config.environment,
      'release': config.effectiveRelease,
      'level': fatal ? 'fatal' : 'error',
      // Phase 3 — top-level v2 ingest fields.
      'sdkName': config.sdkName,
      'sdkVersion': config.sdkVersion,
      'platform': config.platform,
      if (config.dist.isNotEmpty) 'dist': config.dist,
      if (sid != null) 'sessionId': sid,
      if (structured.isNotEmpty) 'frames': structured,
      'user': {
        if (_userId != null) 'id': _userId,
        if (_userEmail != null) 'email': _userEmail,
      },
      'metadata': {..._tags, if (context != null) ...context},
      if (crumbs != null) 'breadcrumbs': crumbs,
    });
    // Release-health: bump the local session status. A fatal (unhandled /
    // crash) escalates to CRASHED; a handled error -> ERRORED.
    if (fatal) {
      _sessionTracker?.recordCrash();
    } else {
      _sessionTracker?.recordError();
    }
  }

  /// Phase 3 — parse Dart stack-trace lines into v2 Frame[] dicts.
  ///
  /// Dart format examples handled:
  ///   `#0      MyWidget.build (package:my_app/widget.dart:42:7)`
  ///   `#1      _UserState.handle (file:///path/to/x.dart:13:5)`
  /// Lines that don't match are skipped so the dashboard never sees
  /// half-parsed garbage.
  List<Map<String, dynamic>> _parseDartFrames(List<String> lines) {
    final out = <Map<String, dynamic>>[];
    final re = RegExp(r'^#\d+\s+(.+?)\s+\((.+?):(\d+)(?::(\d+))?\)\s*$');
    for (final line in lines) {
      final m = re.firstMatch(line);
      if (m == null) continue;
      final fn = m.group(1) ?? '';
      final file = m.group(2) ?? '';
      final lineno = int.tryParse(m.group(3) ?? '') ?? 0;
      final colno = int.tryParse(m.group(4) ?? '');
      final inApp =
          !file.startsWith('dart:') && !file.startsWith('package:flutter/');
      out.add({
        'filename': file,
        'absPath': file,
        'function': fn,
        'lineno': lineno,
        if (colno != null) 'colno': colno,
        'inApp': inApp,
        'platform': 'flutter',
      });
      if (out.length >= 50) break;
    }
    return out;
  }

  Future<void> captureMessage(String message, {String level = 'info'}) async {
    final sid = _sessionTracker?.currentSessionId;
    _sendBestEffort('/ingest/v1/errors', {
      'exceptionClass': 'Message',
      'message': message,
      'environment': config.environment,
      'release': config.effectiveRelease,
      'level': level,
      // Phase 3 — top-level v2 ingest fields.
      'sdkName': config.sdkName,
      'sdkVersion': config.sdkVersion,
      'platform': config.platform,
      if (config.dist.isNotEmpty) 'dist': config.dist,
      if (sid != null) 'sessionId': sid,
      'user': {
        if (_userId != null) 'id': _userId,
        if (_userEmail != null) 'email': _userEmail,
      },
      'metadata': Map<String, String>.from(_tags),
    });
  }

  Future<void> captureLog(
    String level,
    String message, {
    Map<String, String>? metadata,
  }) async {
    _sendBestEffort('/ingest/v1/logs', {
      'level': level,
      'message': message,
      'service': config.service,
      'environment': config.environment,
      'metadata': {..._tags, if (metadata != null) ...metadata},
    });
  }

  // ─── Breadcrumbs ────────────────────────────────────────────────
  final List<Map<String, dynamic>> _breadcrumbs = [];
  static const int _maxBreadcrumbs = 50;

  void addBreadcrumb(
    String type,
    String message, {
    String level = 'info',
    Map<String, dynamic>? data,
  }) {
    _breadcrumbs.add({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': type,
      'message': message,
      'level': level,
      if (data != null) 'data': data,
    });
    if (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeAt(0);
    }
  }

  // ─── HTTP request capture ────────────────────────────────────────
  Future<void> captureRequest({
    required String method,
    required String host,
    required String path,
    required int statusCode,
    required int durationMs,
    String direction = 'outbound',
    String? traceId,
    String? requestId,
    String? spanId,
    String? parentSpanId,
    String? errorFingerprint,
    int requestSize = 0,
    int responseSize = 0,
  }) async {
    final effectiveTraceId = traceId ?? getTraceId();
    final effectiveRequestId = requestId ?? _hexId(16);
    _sendBestEffort('/ingest/v1/http-requests', {
      'requests': [
        {
          'traceId': effectiveTraceId,
          'requestId': effectiveRequestId,
          if (spanId != null) 'spanId': spanId,
          if (parentSpanId != null) 'parentSpanId': parentSpanId,
          'direction': direction,
          'method': method,
          'host': host,
          'path': path,
          'statusCode': statusCode,
          'durationMs': durationMs,
          'requestSize': requestSize,
          'responseSize': responseSize,
          if (errorFingerprint != null) 'errorFingerprint': errorFingerprint,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'environment': config.environment,
          'release': config.effectiveRelease,
          'metadata': Map<String, String>.from(_tags),
        },
      ],
    });
  }

  String _hexId(int bytes) {
    final random = Random.secure();
    final values = List<int>.generate(bytes, (_) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Installs platform-side crash handlers and drains any crash stashed by the
  /// previous app launch, shipping it to `/ingest/v1/errors`.
  ///
  /// Two classes of handler are armed natively (the second gated by
  /// [AllStakConfig.enableNativeCrashCapture], default on):
  ///
  /// 1. **Uncaught-exception handlers** (iOS `NSSetUncaughtExceptionHandler`,
  ///    Android `Thread.setDefaultUncaughtExceptionHandler`). These catch
  ///    Obj-C `NSException`s and uncaught JVM `Throwable`s and stash a
  ///    DTO-compatible JSON crash record.
  /// 2. **Async-signal-safe POSIX signal handlers** (iOS `sigaction`, Android
  ///    NDK `sigaction`) for SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP —
  ///    the dominant class of REAL mobile crashes (force-unwrap traps,
  ///    bad-pointer access, NDK/native signal crashes) that never surface as
  ///    an exception. The handler is run inside a dying process, so it only
  ///    writes a minimal fixed [NativeCrashRecord] to a pre-opened fd, then
  ///    chains to the previous handler and re-raises. The record is read here
  ///    on the NEXT launch (normal context) and shipped marked
  ///    `native.crash=true`.
  ///
  /// Requires the companion Android `AllStakPlugin.kt` (+ NDK lib) and iOS
  /// `AllStakPlugin.swift` to be present in the host app's plugin registry,
  /// which is wired automatically when this package is listed in
  /// `pubspec.yaml`. Fail-open: if the native channel or the native lib is
  /// unavailable (web, tests, a build where the NDK lib failed to compile)
  /// this is a silent no-op and the SDK keeps working. On-device E2E delivery
  /// still requires real device/emulator verification.
  Future<void> installNativeHandlers() async {
    // Idempotent: arming + the one-shot previous-launch crash drain happen at
    // most once per client. The auto-arm from `init()`/`runApp()` and an
    // explicit escape-hatch call therefore never double-drain a stashed crash.
    if (_nativeArmed) return;
    _nativeArmed = true;
    try {
      const channel = _NativeChannel.channel;
      await channel.invokeMethod('install', {
        'release': config.effectiveRelease,
        'enableSignalHandlers': config.enableNativeCrashCapture,
      });
      // 1. Legacy uncaught-exception record (already DTO-compatible JSON).
      await _drainLegacyNativeCrash(channel);
      // 2. Async-signal-safe native (signal / NDK) crash record.
      if (config.enableNativeCrashCapture) {
        await _drainNativeSignalCrash(channel);
      }
    } catch (_) {
      // channel not available on web or in tests — no-op.
    }
  }

  /// Drain the legacy uncaught-exception JSON crash record. The native side
  /// already produced a DTO-compatible payload, so it ships as-is.
  Future<void> _drainLegacyNativeCrash(MethodChannel channel) async {
    try {
      final Object? raw = await channel.invokeMethod('drainPendingCrash');
      if (raw is String && raw.isNotEmpty) {
        _sendBestEffort('/ingest/v1/errors', _decodeNativeCrash(raw));
      }
    } catch (_) {
      // Fail-open: a missing/garbage legacy record never blocks startup.
    }
  }

  /// Drain the async-signal-safe native crash record written by the signal/NDK
  /// handler on the previous launch. The handler can't build JSON safely, so
  /// it wrote a tiny [NativeCrashRecord.magic] text record; parse it here (in
  /// normal context) into the standard `/ingest/v1/errors` shape and ship it
  /// marked `native.crash=true`. Fail-open throughout.
  Future<void> _drainNativeSignalCrash(MethodChannel channel) async {
    try {
      final Object? raw = await channel.invokeMethod('drainPendingSignalCrash');
      if (raw is! String || raw.isEmpty) return;
      final record = NativeCrashRecord.parse(raw);
      if (record == null) return; // corrupt / empty — drop, never ship noise.
      final payload = buildNativeCrashPayload(record);
      _sendBestEffort('/ingest/v1/errors', payload);
    } catch (_) {
      // Fail-open: native crash drain must never break startup.
    }
  }

  /// Build the `/ingest/v1/errors` payload for a parsed native crash [record],
  /// stamping the SDK's release/environment/session metadata so it matches
  /// every other event the SDK emits. Exposed for unit testing the drain
  /// handoff without a device.
  @visibleForTesting
  Map<String, dynamic> buildNativeCrashPayload(NativeCrashRecord record) {
    return record.toErrorPayload(
      release: config.effectiveRelease,
      environment: config.environment,
      sdkName: config.sdkName,
      sdkVersion: config.sdkVersion,
      platformTag: config.platform,
      dist: config.dist,
      sessionId: _sessionTracker?.currentSessionId,
      extraMetadata: Map<String, String>.from(_tags),
    );
  }

  Map<String, dynamic> _decodeNativeCrash(String json) {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  /// Force-send all queued/buffered events immediately and wait for every
  /// pending HTTP request to complete (or time out).  Safe to call before
  /// the app is paused or terminated so no telemetry is lost.
  Future<void> flush() async {
    // Snapshot the list so new sends that arrive while we await don't
    // cause a concurrent-modification issue.
    final pending = List<Future<void>>.from(_pendingRequests);
    _pendingRequests.clear();
    if (pending.isEmpty) return;
    // Wait for all in-flight requests.  Individual _send calls already
    // swallow their own exceptions so this won't throw.
    await Future.wait(pending, eagerError: false);
  }

  String _platformTag() {
    try {
      if (kIsWeb) return 'web';
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isLinux) return 'linux';
      if (Platform.isWindows) return 'windows';
    } catch (_) {}
    return 'flutter';
  }

  void _sendBestEffort(String path, Map<String, dynamic> payload) {
    if (config.apiKey.isEmpty) return;
    final future = _send(path, payload);
    _pendingRequests.add(future);
    // Auto-remove from the list when it completes so we don't leak memory.
    future.whenComplete(() => _pendingRequests.remove(future));
  }

  Future<void> _send(String path, Map<String, dynamic> payload) async {
    final merged = {
      ...payload,
      'metadata': {
        ...((payload['metadata'] as Map?) ?? const {}),
        'device.platform': _platformTag(),
      },
    };
    // Scrub the full wire payload before serialization. One chokepoint
    // protects every telemetry type (errors, logs, http, native crashes).
    // Pure (no mutation), mobile-safe (synchronous), fail-closed for this event.
    Map<String, dynamic> scrubbed;
    try {
      final out = scrub(
        merged,
        options: ScrubOptions(sendDefaultPii: config.sendDefaultPii),
      );
      scrubbed = out is Map<String, dynamic>
          ? out
          : (out is Map ? Map<String, dynamic>.from(out) : merged);
    } catch (sanErr) {
      if (config.debug) {
        // ignore: avoid_print
        print('[AllStak] sanitizer failed; dropping event: $sanErr');
      }
      return;
    }
    // From here on we operate on the SCRUBBED bytes only — the same bytes that
    // would be persisted offline. Nothing unredacted ever reaches disk.
    final body = jsonEncode(scrubbed);
    final outcome = await _deliverScrubbed(path, body);
    // Persist on a retryable failure (offline / timeout / 5xx / 429) so the
    // event survives a network outage and an app restart. Session lifecycle
    // calls are excluded — a replayed stale session would skew durations.
    if (outcome == _DeliveryOutcome.retryable && _isPersistable(path)) {
      try {
        await _offlineQueue?.enqueue(path, body);
      } catch (_) {
        // Fail-open: persistence must never break capture.
      }
    }
  }

  bool _isPersistable(String path) =>
      _offlineQueue != null && !_nonPersistablePaths.contains(path);

  /// POST an already-scrubbed JSON [body] to [path]. Classifies the result so
  /// the offline queue knows whether to retain (retryable) or discard
  /// (delivered / permanently undeliverable) the entry. Never throws.
  Future<_DeliveryOutcome> _deliverScrubbed(String path, String body) async {
    final url = Uri.parse('${config.host}$path');
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'X-AllStak-Key': config.apiKey,
              'User-Agent': 'allstak-flutter/$kAllStakSdkVersion',
            },
            body: body,
          )
          .timeout(config.transportTimeout);
      if (config.debug) {
        final trim =
            res.body.length > 160 ? res.body.substring(0, 160) : res.body;
        // ignore: avoid_print
        print('[AllStak] POST $path -> ${res.statusCode} $trim');
      }
      final code = res.statusCode;
      if (code >= 200 && code < 300) return _DeliveryOutcome.delivered;
      // 429 (rate limited) and 5xx are transient -> keep for retry. Other 4xx
      // (bad request, auth, etc.) are permanent -> drop, don't loop forever.
      if (code == 429 || code >= 500) return _DeliveryOutcome.retryable;
      return _DeliveryOutcome.permanent;
    } catch (e) {
      if (config.debug) {
        // ignore: avoid_print
        print('[AllStak] POST $path failed: $e');
      }
      // Network error / timeout / app offline -> retryable.
      return _DeliveryOutcome.retryable;
    }
  }

  /// Returns a [http.Client] that automatically records every outbound
  /// request to AllStak's /ingest/v1/http-requests with direction=outbound.
  ///
  /// Usage:
  /// ```dart
  /// final client = allstak.httpClient();
  /// final resp = await client.get(Uri.parse('https://api.example.com/users'));
  /// // auto-recorded, no extra code needed
  /// ```
  ///
  /// Skips requests to AllStak's own ingest host to prevent recursion.
  http.Client httpClient({http.Client? inner}) {
    return _AllStakHttpClient(this, inner ?? http.Client());
  }

  // ─── Dio interceptor wiring (DioTelemetrySink) ───────────────────────
  //
  // Dio's default adapter already runs through the global HttpOverrides when
  // `enableHttpOverrides` is on, so these are only needed for the explicit
  // Dio-interceptor path (custom adapter / overrides disabled). See
  // [dioInterceptor].

  @override
  DioSpanIds beginOutboundSpan() {
    return DioSpanIds(
      traceId: getTraceId(),
      requestId: _hexId(16),
      spanId: _hexId(8),
      parentSpanId: _currentSpanId,
    );
  }

  @override
  void recordOutbound({
    required String method,
    required String host,
    required String path,
    required int statusCode,
    required int durationMs,
    required DioSpanIds ids,
    String? errorFingerprint,
  }) {
    // Fire-and-forget — never block the host app's request on ingest.
    captureRequest(
      method: method,
      host: host,
      path: path,
      statusCode: statusCode,
      durationMs: durationMs,
      direction: 'outbound',
      traceId: ids.traceId,
      requestId: ids.requestId,
      spanId: ids.spanId,
      parentSpanId: ids.parentSpanId,
      errorFingerprint: errorFingerprint,
    );
  }

  /// Builds a Dio interceptor wired to this client. Pass a [wrapperFactory]
  /// that constructs Dio's `InterceptorsWrapper` (so the SDK never depends on
  /// `package:dio`):
  ///
  /// ```dart
  /// final i = AllStak.instance!.dioInterceptor(
  ///   wrapperFactory: ({onRequest, onResponse, onError}) => InterceptorsWrapper(
  ///     onRequest: onRequest, onResponse: onResponse, onError: onError),
  /// );
  /// dio.interceptors.add(i as Interceptor);
  /// ```
  Object? dioInterceptor({required DioWrapperFactory wrapperFactory}) =>
      allStakDioInterceptor(wrapperFactory: wrapperFactory, sink: this);
}

/// Wraps any [http.Client] (by default `http.Client()`) so that every outbound
/// HTTP call is captured as an AllStak http-request row, with the real method,
/// host, path, status code, and duration. Errors are captured too with
/// status=0.
class _AllStakHttpClient extends http.BaseClient {
  final AllStak _allstak;
  final http.Client _inner;
  _AllStakHttpClient(this._allstak, this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    final isOwnIngest = url.startsWith(_allstak.config.host);
    final traceId = _allstak.getTraceId();
    final spanId = _allstak._hexId(8);
    final parentSpanId = _allstak._currentSpanId;
    final requestId = _allstak._hexId(16);
    if (!isOwnIngest) {
      request.headers.putIfAbsent(
        'traceparent',
        () => '00-$traceId-$spanId-01',
      );
      request.headers.putIfAbsent('x-allstak-trace-id', () => traceId);
      request.headers.putIfAbsent('x-allstak-request-id', () => requestId);
      request.headers.putIfAbsent('x-allstak-span-id', () => spanId);
      request.headers['baggage'] =
          _mergeBaggage(request.headers['baggage'], traceId, requestId, spanId);
      request.headers['allstak-baggage'] =
          _allstakBaggage(traceId, requestId, spanId);
    }
    final sw = Stopwatch()..start();
    try {
      final resp = await _inner.send(request);
      sw.stop();
      if (!isOwnIngest) {
        // fire-and-forget — don't block the caller on ingest
        _allstak.captureRequest(
          method: request.method,
          host: request.url.host +
              (request.url.hasPort ? ':${request.url.port}' : ''),
          path: request.url.path.isEmpty ? '/' : request.url.path,
          statusCode: resp.statusCode,
          durationMs: sw.elapsedMilliseconds,
          direction: 'outbound',
          traceId: traceId,
          requestId: requestId,
          spanId: spanId,
          parentSpanId: parentSpanId,
        );
      }
      return resp;
    } catch (e) {
      sw.stop();
      if (!isOwnIngest) {
        _allstak.captureRequest(
          method: request.method,
          host: request.url.host +
              (request.url.hasPort ? ':${request.url.port}' : ''),
          path: request.url.path.isEmpty ? '/' : request.url.path,
          statusCode: 0,
          durationMs: sw.elapsedMilliseconds,
          direction: 'outbound',
          traceId: traceId,
          requestId: requestId,
          spanId: spanId,
          parentSpanId: parentSpanId,
          errorFingerprint: e.runtimeType.toString(),
        );
      }
      rethrow;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

/// Ends the release-health session on graceful shutdown — i.e. when the app
/// transitions to `detached` (process about to terminate). Best-effort and
/// fail-open; never blocks the lifecycle callback.
class _SessionLifecycleObserver extends WidgetsBindingObserver {
  _SessionLifecycleObserver(this._allstak);
  final AllStak _allstak;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // The process is terminating — close the session with its accumulated
      // status (ok / errored / crashed).
      _allstak.endSession();
    }
  }
}
