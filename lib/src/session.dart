/// Release-health "one session per app launch" tracking.
///
/// Mirrors the AllStak Java SDK's `dev.allstak.session` package
/// (`Session` / `SessionStatus` / `SessionTracker`) idiomatically for
/// Dart/Flutter. One [SessionTracker] per [AllStak] client. On
/// [SessionTracker.start] the SDK POSTs `/ingest/v1/sessions/start`; on
/// [SessionTracker.end] it POSTs `/ingest/v1/sessions/end` with the final
/// status + total duration. ERRORED / CRASHED transitions are recorded in
/// memory only — just the terminal `end` call performs network I/O.
///
/// Sessions are NEVER sampled: the start POST is always attempted (subject
/// only to the transport being enabled / an api key being present), and a
/// missing release falls back to the SDK version so a session is never
/// dropped for lack of a release.
library;

import 'dart:math';

/// Lifecycle status of a release-health session.
///
/// Vocabulary matches the backend `/ingest/v1/sessions/end` contract and
/// Sentry's release-health conventions:
///
/// * [ok] — session ended normally with at most non-fatal logs.
/// * [errored] — at least one captured event of level `error` (handled)
///   landed during the session, but the app kept running.
/// * [crashed] — an unhandled / fatal exception ended the session (the SDK
///   only reports this when it observes the uncaught exception itself).
/// * [abnormal] — app ended without a normal flush. Reserved for future
///   shutdown telemetry.
enum SessionStatus {
  ok('ok'),
  errored('errored'),
  crashed('crashed'),
  abnormal('abnormal');

  const SessionStatus(this.wire);

  /// Backend wire value — the lower-case string `/sessions/end` expects.
  final String wire;
}

/// A single release-health session. One-per-app-launch in the default
/// deployment. Status escalates monotonically OK -> ERRORED -> CRASHED.
class Session {
  Session({String? id, DateTime? startedAt})
      : id = id ?? _newId(),
        startedAt = startedAt ?? DateTime.now();

  final String id;
  final DateTime startedAt;

  SessionStatus _status = SessionStatus.ok;
  int _errorCount = 0;

  SessionStatus get status => _status;
  int get errorCount => _errorCount;

  /// Increment the error counter and bump status to [SessionStatus.errored]
  /// unless the session has already escalated to a terminal status.
  void recordError() {
    _errorCount++;
    if (_status == SessionStatus.ok) {
      _status = SessionStatus.errored;
    }
  }

  /// Mark a terminal crashed status (overrides ERRORED). Used by the
  /// uncaught / fatal error handlers.
  void recordCrash() {
    _status = SessionStatus.crashed;
    _errorCount++;
  }

  /// Promote to [SessionStatus.abnormal] only if still OK or ERRORED.
  void recordAbnormalExit() {
    if (_status == SessionStatus.ok || _status == SessionStatus.errored) {
      _status = SessionStatus.abnormal;
    }
  }

  /// Duration from start to now, floored at 0.
  int durationMs() {
    final d = DateTime.now().difference(startedAt).inMilliseconds;
    return d < 0 ? 0 : d;
  }

  static String _newId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Sends a best-effort POST to an ingest path with a JSON body. Reuses the
/// SDK's existing transport/HTTP path. Must be fail-open (never throw).
typedef SessionSend = void Function(String path, Map<String, dynamic> payload);

/// Single-session tracker. Re-entrancy safe: once started a second [start] is
/// a no-op; once ended the tracker does not re-arm. All session network I/O
/// is fail-open — failures never block or break app init/shutdown.
class SessionTracker {
  SessionTracker({
    required SessionSend send,
    required String release,
    String? environment,
    String? sdkName,
    String? sdkVersion,
    String? platform,
  })  : _send = send,
        _release = release,
        _environment = environment,
        _sdkName = sdkName,
        _sdkVersion = sdkVersion,
        _platform = platform;

  static const String pathStart = '/ingest/v1/sessions/start';
  static const String pathEnd = '/ingest/v1/sessions/end';

  final SessionSend _send;
  final String _release;
  final String? _environment;
  final String? _sdkName;
  final String? _sdkVersion;
  final String? _platform;

  Session? _active;
  bool _ended = false;

  /// Idempotent. Generates the session, records its start, sets in-memory
  /// status = ok, and POSTs `/sessions/start`. Sessions are never sampled.
  /// [userId] is attached when a user is set at init time.
  Session start({String? userId}) {
    final existing = _active;
    if (existing != null) return existing;
    final candidate = Session();
    _active = candidate;

    _send(pathStart, <String, dynamic>{
      'sessionId': candidate.id,
      'release': _resolveRelease(),
      if (_environment != null) 'environment': _environment,
      if (userId != null && userId.isNotEmpty) 'userId': userId,
      if (_sdkName != null) 'sdkName': _sdkName,
      if (_sdkVersion != null) 'sdkVersion': _sdkVersion,
      if (_platform != null) 'platform': _platform,
    });
    return candidate;
  }

  /// The active session, or `null` when not started or already ended.
  Session? get current => _ended ? null : _active;

  /// Id of the active session, or `null` when no session is open. Attached to
  /// every captured error/event payload so the backend's error consumer can
  /// mark the session errored/crashed server-side.
  String? get currentSessionId => current?.id;

  /// Record a handled error-level event against the active session. No I/O.
  void recordError() => current?.recordError();

  /// Record an unhandled / fatal crash. No I/O — the `end` POST carries it.
  void recordCrash() => current?.recordCrash();

  /// Terminate the session and POST `/sessions/end`. Idempotent. When
  /// [finalStatus] is null the session's own accumulated status is used.
  void end({SessionStatus? finalStatus}) {
    if (_ended) return;
    final s = _active;
    if (s == null) return;
    _active = null;
    _ended = true;

    final status = finalStatus ?? s.status;
    _send(pathEnd, <String, dynamic>{
      'sessionId': s.id,
      'durationMs': s.durationMs(),
      'status': status.wire,
    });
  }

  /// The release identifier carried on the session envelope. Falls back to the
  /// SDK version when no release was resolved so a release-health session is
  /// never dropped for lack of a release (the `/sessions/start` contract
  /// requires a non-null release).
  String _resolveRelease() {
    if (_release.isNotEmpty) return _release;
    return _sdkVersion ?? '';
  }
}
