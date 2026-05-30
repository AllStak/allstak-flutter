/// Offline / persistent transport queue.
///
/// A dependency-light file spool that lets buffered telemetry survive an app
/// restart AND a network outage. When the live transport
/// fails to deliver an event (network error, timeout, app shutting down with
/// events still pending) the SDK persists the *already PII-scrubbed* payload
/// here instead of dropping it. On the next SDK init the spool is drained
/// asynchronously and the entries are re-sent through the existing transport.
///
/// ## Invariants
/// * **Scrub-before-persist.** Only the scrubbed wire bytes ever reach disk —
///   the queue stores opaque strings and never inspects/parses payloads.
/// * **Bounded.** Capped by entry count, total bytes, and max age. The OLDEST
///   entries are dropped first when a cap is exceeded.
/// * **Fail-open.** Every disk operation is wrapped: if the store is
///   unavailable / unreadable / unwritable the queue degrades silently to a
///   no-op and the SDK falls back to its in-memory, fire-and-forget behavior.
///   It never throws and never blocks init or capture.
///
/// The spool is a single newline-delimited JSON file. Each line is one entry:
/// `{"p": "<ingest path>", "b": "<scrubbed json body>", "t": <epoch millis>}`.
/// A line-oriented format keeps appends cheap (no full rewrite on enqueue) and
/// keeps a single corrupt line from poisoning the whole spool.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Resolves the absolute directory the spool file lives in. Returns `null` to
/// signal "no persistent store available" (web, or the native channel could
/// not provide a directory) — the queue then degrades to a no-op. This is a
/// seam so tests can inject a temp directory without a real device.
typedef SpoolDirResolver = Future<String?> Function();

/// One persisted telemetry entry: an ingest [path] and the scrubbed wire
/// [body] (a JSON string, already sanitized) plus the enqueue timestamp.
class OfflineEntry {
  OfflineEntry({required this.path, required this.body, required this.epochMs});

  final String path;
  final String body;
  final int epochMs;
}

/// Bounded, fail-open file spool for telemetry that could not be delivered.
class OfflineQueue {
  OfflineQueue({
    required SpoolDirResolver dirResolver,
    this.maxEntries = 100,
    this.maxBytes = 2 * 1024 * 1024,
    this.maxAge = const Duration(hours: 48),
    String fileName = 'allstak_offline_spool.ndjson',
  })  : _dirResolver = dirResolver,
        _fileName = fileName;

  final SpoolDirResolver _dirResolver;
  final String _fileName;

  /// Hard cap on the number of persisted entries.
  final int maxEntries;

  /// Hard cap on the on-disk spool size in bytes.
  final int maxBytes;

  /// Entries older than this are evicted on the next drain/enqueue.
  final Duration maxAge;

  File? _file;
  bool _resolved = false;
  // Serializes file mutations so concurrent enqueues/drains don't interleave
  // partial rewrites. Fail-open: a failure in one op never blocks the next.
  Future<void> _lock = Future<void>.value();

  /// Resolves (once) the spool [File]. Returns `null` when no persistent store
  /// is available, in which case every other method becomes a silent no-op.
  Future<File?> _resolve() async {
    if (_resolved) return _file;
    _resolved = true;
    try {
      final dir = await _dirResolver();
      if (dir == null || dir.isEmpty) return _file = null;
      final d = Directory(dir);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      _file = File('${d.path}${Platform.pathSeparator}$_fileName');
    } catch (_) {
      _file = null;
    }
    return _file;
  }

  Future<T> _synchronized<T>(Future<T> Function() action, T fallback) {
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (_) {
        completer.complete(fallback);
      }
    });
    return completer.future;
  }

  /// Append one scrubbed payload to the spool, then enforce the bounds
  /// (dropping the OLDEST entries first). Fail-open: returns silently on any
  /// error. [body] MUST already be the scrubbed wire JSON — the queue never
  /// scrubs and never persists raw data.
  Future<void> enqueue(String path, String body) async {
    await tryEnqueue(path, body);
  }

  /// Same as [enqueue], but returns whether the entry was actually persisted.
  /// Counter-only diagnostics use this so an unavailable store is counted as a
  /// dropped retryable event rather than a persisted one.
  Future<bool> tryEnqueue(String path, String body) async {
    final file = await _resolve();
    if (file == null) return false;
    return _synchronized<bool>(() async {
      final line = jsonEncode({
        'p': path,
        'b': body,
        't': DateTime.now().millisecondsSinceEpoch,
      });
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      await _enforceBounds(file);
      return true;
    }, false);
  }

  /// Atomically read every valid (non-expired) entry, clear the spool, and
  /// return the entries oldest-first. The caller re-sends them and is
  /// responsible for re-persisting any that still fail (via [enqueue]).
  ///
  /// Draining by take-all-then-clear keeps the disk format dead simple and
  /// avoids tracking per-entry offsets; the small re-persist cost on a still
  /// offline network is acceptable for a bounded spool.
  Future<List<OfflineEntry>> drainAll() async {
    final file = await _resolve();
    if (file == null) return const [];
    return _synchronized<List<OfflineEntry>>(() async {
      if (!await file.exists()) return const [];
      final entries = await _readValid(file);
      try {
        await file.delete();
      } catch (_) {}
      return entries;
    }, const []);
  }

  /// Reads the spool, dropping malformed and expired lines. Oldest-first.
  Future<List<OfflineEntry>> _readValid(File file) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds;
    final out = <OfflineEntry>[];
    final raw = await file.readAsString();
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) continue;
        final p = decoded['p'];
        final b = decoded['b'];
        final t = decoded['t'];
        if (p is! String || b is! String || t is! int) continue;
        if (t < cutoff) continue; // expired
        out.add(OfflineEntry(path: p, body: b, epochMs: t));
      } catch (_) {
        // Skip a single corrupt line; the rest of the spool is still usable.
      }
    }
    return out;
  }

  String _encodeLine(OfflineEntry e) =>
      jsonEncode({'p': e.path, 'b': e.body, 't': e.epochMs});

  /// Trim the spool to satisfy the count / byte / age caps, dropping the
  /// OLDEST entries first. Rewrites the file only when something was evicted.
  Future<void> _enforceBounds(File file) async {
    // Lines physically on disk (before age/corruption filtering).
    final onDisk = _countLines(await _safeRead(file));
    // Valid, non-expired entries (age cap already applied here).
    final entries = await _readValid(file);
    var kept = entries;
    var changed = entries.length != onDisk;

    // Count cap: keep the newest [maxEntries].
    if (kept.length > maxEntries) {
      kept = kept.sublist(kept.length - maxEntries);
      changed = true;
    }
    // Byte cap: keep dropping the oldest until under budget.
    int bytesOf(List<OfflineEntry> es) =>
        es.fold(0, (sum, e) => sum + utf8.encode('${_encodeLine(e)}\n').length);
    while (kept.length > 1 && bytesOf(kept) > maxBytes) {
      kept = kept.sublist(1);
      changed = true;
    }
    if (!changed) return;
    final buffer = StringBuffer();
    for (final e in kept) {
      buffer.writeln(_encodeLine(e));
    }
    await file.writeAsString(buffer.toString(), flush: true);
  }

  int _countLines(String s) =>
      s.split('\n').where((l) => l.trim().isNotEmpty).length;

  Future<String> _safeRead(File file) async {
    try {
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// Test/diagnostic helper: number of currently persisted, non-expired
  /// entries. Fail-open: returns 0 when the store is unavailable.
  Future<int> count() async {
    final file = await _resolve();
    if (file == null) return 0;
    return _synchronized<int>(() async {
      if (!await file.exists()) return 0;
      return (await _readValid(file)).length;
    }, 0);
  }
}
