/// Automatic logging bridge.
///
/// Wires application logs into AllStak with no per-call code: once the bridge
/// is attached (done automatically from `AllStak.init` / `AllStak.runApp` when
/// `captureLogs` is on), records flow to `/ingest/v1/logs`, and the high-severity
/// ones — level >= [kSevereThreshold] (i.e. `package:logging`'s `SEVERE`/
/// `SHOUT`) OR any record that carries an `error` object — are additionally
/// promoted to a captured exception so they surface as errors, not just logs.
///
/// ## Why a normalized record (no hard `package:logging` dependency)
/// This SDK is intentionally dependency-light, so it does NOT take a compile
/// dependency on `package:logging`. Instead the bridge exposes a tiny
/// normalized [AllStakLogRecord] plus two attach helpers:
///
///  * [attachToLogging] — call once from app startup to forward
///    `package:logging` records. Pass `Logger.root.onRecord` (a
///    `Stream<LogRecord>`); the bridge reads the fields it needs via duck-typed
///    accessors so it links against whatever `logging` version the app uses.
///  * [record] — the low-level sink the SDK calls for `dart:developer.log`
///    interception and that tests drive directly.
///
/// All sinks are fire-and-forget and fail-open: a logging error never breaks
/// the app's own logging path.
library;

/// Level at/above which a log record is ALSO promoted to a captured exception.
/// Mirrors `package:logging`'s `Level.SEVERE.value` (900) — but we promote at
/// SEVERE and above (>= 900) so both `SEVERE` (900) and `SHOUT` (1200) escalate.
const int kSevereThreshold = 900;

/// A normalized log record decoupled from any concrete logging package.
class AllStakLogRecord {
  const AllStakLogRecord({
    required this.level,
    required this.levelName,
    required this.message,
    this.loggerName,
    this.error,
    this.stackTrace,
  });

  /// Numeric severity (e.g. `package:logging` `Level.value`, or a
  /// `dart:developer.log` `level`). Used for the SEVERE promotion threshold.
  final int level;

  /// Human-readable level (e.g. `INFO`, `WARNING`, `SEVERE`). Mapped to the
  /// AllStak wire `level` string.
  final String levelName;

  final String message;
  final String? loggerName;

  /// Optional error object attached to the record. When present the record is
  /// promoted to a captured exception regardless of [level].
  final Object? error;

  /// Optional stack trace string for the [error].
  final String? stackTrace;

  /// True when this record should be promoted to a captured exception:
  /// either it carries an [error] object, or its [level] is SEVERE+.
  bool get shouldPromote => error != null || level >= kSevereThreshold;

  /// The AllStak wire `level` string. `package:logging` level names are mapped
  /// onto the SDK's vocabulary; unknown names fall back to a numeric mapping.
  String get wireLevel {
    switch (levelName.toUpperCase()) {
      case 'FINEST':
      case 'FINER':
      case 'FINE':
        return 'debug';
      case 'CONFIG':
      case 'INFO':
        return 'info';
      case 'WARNING':
        return 'warning';
      case 'SEVERE':
        return 'error';
      case 'SHOUT':
        return 'fatal';
    }
    // Fall back to a numeric mapping for non-`logging` sources (dart:developer).
    if (level >= 1200) return 'fatal';
    if (level >= 900) return 'error';
    if (level >= 800) return 'warning';
    if (level >= 700) return 'info';
    return 'debug';
  }
}

/// Sink for normalized log records. Implemented by the SDK to forward to
/// `/ingest/v1/logs` (and to `captureException` for promoted records).
typedef LogSink = void Function(AllStakLogRecord record);

/// Bridges application logs into the AllStak [LogSink]. One per SDK client;
/// stateless apart from its sink and an installed flag for idempotency.
class AllStakLogBridge {
  AllStakLogBridge(this._sink);

  final LogSink _sink;

  /// Subscriptions opened by [attachToLogging] / [attachStream] so the bridge
  /// can be detached cleanly (e.g. on SDK close in long-lived isolates/tests).
  final List<dynamic> _subscriptions = <dynamic>[];

  bool _detached = false;

  /// Feed one already-normalized record into the bridge. Fail-open.
  void record(AllStakLogRecord rec) {
    if (_detached) return;
    try {
      _sink(rec);
    } catch (_) {
      // Fail-open: a sink error must never break the app's logging path.
    }
  }

  /// Attach to a `package:logging`-style record stream WITHOUT a compile
  /// dependency on that package. Pass `Logger.root.onRecord`. Each emitted
  /// record is read via duck-typed dynamic access (`.level.value`,
  /// `.level.name`, `.message`, `.loggerName`, `.error`, `.stackTrace`) so the
  /// bridge links against whatever `logging` version the host app ships.
  /// Returns the subscription so the caller can cancel it; the bridge also
  /// tracks it for [detach]. Fail-open: a malformed record is skipped.
  Object? attachToLogging(dynamic onRecordStream) {
    try {
      final sub = (onRecordStream as dynamic).listen((dynamic r) {
        try {
          record(_normalizeLoggingRecord(r));
        } catch (_) {}
      });
      _subscriptions.add(sub);
      return sub;
    } catch (_) {
      return null;
    }
  }

  /// Normalize a duck-typed `package:logging` `LogRecord` into an
  /// [AllStakLogRecord]. Each field access is individually guarded so a record
  /// missing an expected getter still produces a usable record.
  static AllStakLogRecord _normalizeLoggingRecord(dynamic r) {
    int level = 0;
    String levelName = '';
    String message = '';
    String? loggerName;
    Object? error;
    String? stackTrace;
    try {
      final lvl = r.level;
      level = (lvl.value as int?) ?? 0;
      levelName = (lvl.name as String?) ?? '';
    } catch (_) {}
    try {
      message = (r.message as Object?)?.toString() ?? '';
    } catch (_) {}
    try {
      loggerName = r.loggerName as String?;
    } catch (_) {}
    try {
      error = r.error as Object?;
    } catch (_) {}
    try {
      final st = r.stackTrace;
      stackTrace = st?.toString();
    } catch (_) {}
    return AllStakLogRecord(
      level: level,
      levelName: levelName,
      message: message,
      loggerName: loggerName,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Cancel all tracked subscriptions and stop forwarding. Idempotent,
  /// fail-open.
  void detach() {
    _detached = true;
    for (final sub in _subscriptions) {
      try {
        (sub as dynamic).cancel();
      } catch (_) {}
    }
    _subscriptions.clear();
  }
}
