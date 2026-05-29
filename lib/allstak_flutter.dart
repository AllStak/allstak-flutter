/// AllStak SDK for Flutter / Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' hide runApp;
import 'package:flutter/widgets.dart' as widgets show runApp;
import 'package:http/http.dart' as http;

import 'sanitizer.dart';
import 'src/offline_queue.dart';
import 'src/session.dart';

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
const String kAllStakSdkVersion = '1.0.3';

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

class AllStak {
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
    return sdk;
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

  /// Installs platform-side uncaught exception handlers (Android Kotlin /
  /// iOS Obj-C) and drains any crash stashed by the previous app launch,
  /// shipping it to /ingest/v1/errors.
  ///
  /// SCAFFOLDED: requires the companion Android AllStakPlugin.kt and iOS
  /// AllStakPlugin.swift to be present in the host app's plugin registry,
  /// which is wired up automatically when this package is listed in
  /// pubspec.yaml. Verify on a real Android/iOS device build.
  Future<void> installNativeHandlers() async {
    try {
      const channel = _NativeChannel.channel;
      await channel
          .invokeMethod('install', {'release': config.effectiveRelease});
      final Object? raw = await channel.invokeMethod('drainPendingCrash');
      if (raw is String && raw.isNotEmpty) {
        try {
          // Payload from native side is already DTO-compatible — ship as-is
          // under the customer's api key.
          _sendBestEffort('/ingest/v1/errors', _decodeNativeCrash(raw));
        } catch (_) {}
      }
    } catch (_) {
      // channel not available on web or in tests — no-op.
    }
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
      final out = scrub(merged);
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
