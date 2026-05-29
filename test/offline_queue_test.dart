import 'dart:convert';
import 'dart:io';

import 'package:allstak_flutter/allstak_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-process ingest server (mirrors allstak_flutter_test.dart) with a
/// configurable response code so we can simulate 2xx / 4xx / 5xx / outage.
class _IngestServer {
  late HttpServer _server;
  final List<Map<String, dynamic>> bodies = [];
  late String host;

  /// Status code returned to every request. 200 by default.
  int statusCode = 200;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${_server.port}';
    _server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      if (raw.isNotEmpty) {
        try {
          bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {}
      }
      req.response
        ..statusCode = statusCode
        ..write('{"ok":true}');
      await req.response.close();
    });
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('allstak_spool_test');
  });

  tearDown(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  // A spool backed by [tmpDir]. A stable fileName lets a second queue (or a
  // freshly-init'd SDK) reopen the same on-disk spool, exactly like a restart.
  OfflineQueue makeQueue({
    String fileName = 'spool.ndjson',
    int maxEntries = 100,
    int maxBytes = 2 * 1024 * 1024,
    Duration maxAge = const Duration(hours: 48),
    Future<String?> Function()? dirResolver,
  }) {
    return OfflineQueue(
      dirResolver: dirResolver ?? () async => tmpDir.path,
      fileName: fileName,
      maxEntries: maxEntries,
      maxBytes: maxBytes,
      maxAge: maxAge,
    );
  }

  File spoolFile([String fileName = 'spool.ndjson']) =>
      File('${tmpDir.path}${Platform.pathSeparator}$fileName');

  // ─── OfflineQueue unit behavior ───────────────────────────────────
  group('OfflineQueue', () {
    test('enqueue then drainAll returns entries oldest-first and clears',
        () async {
      final q = makeQueue();
      await q.enqueue('/ingest/v1/errors', '{"n":1}');
      await q.enqueue('/ingest/v1/logs', '{"n":2}');

      expect(await q.count(), 2);

      final drained = await q.drainAll();
      expect(drained.map((e) => e.body).toList(), ['{"n":1}', '{"n":2}']);
      expect(drained.first.path, '/ingest/v1/errors');
      // Drain clears the spool.
      expect(await q.count(), 0);
    });

    test('count cap drops the OLDEST entries', () async {
      final q = makeQueue(maxEntries: 3);
      for (var i = 0; i < 6; i++) {
        await q.enqueue('/ingest/v1/errors', '{"n":$i}');
      }
      final drained = await q.drainAll();
      expect(drained.length, 3);
      // Newest three survive; oldest (0,1,2) evicted.
      expect(drained.map((e) => e.body).toList(),
          ['{"n":3}', '{"n":4}', '{"n":5}']);
    });

    test('byte cap drops the OLDEST entries', () async {
      // Each line is well over 64 bytes; cap forces all-but-newest out.
      final big = 'x' * 200;
      final q = makeQueue(maxBytes: 300);
      await q.enqueue('/ingest/v1/errors', '{"a":"$big"}');
      await q.enqueue('/ingest/v1/errors', '{"b":"$big"}');
      final drained = await q.drainAll();
      expect(drained.length, 1);
      expect(drained.single.body, contains('"b"'));
    });

    test('expired entries are dropped on read', () async {
      final q = makeQueue(maxAge: const Duration(milliseconds: 1));
      await q.enqueue('/ingest/v1/errors', '{"old":true}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await q.count(), 0);
      expect(await q.drainAll(), isEmpty);
    });

    test('corrupt lines are skipped, valid lines survive', () async {
      final q = makeQueue();
      await q.enqueue('/ingest/v1/errors', '{"ok":1}');
      // Inject a garbage line directly into the spool.
      await spoolFile()
          .writeAsString('this is not json\n', mode: FileMode.append);
      final drained = await q.drainAll();
      expect(drained.length, 1);
      expect(drained.single.body, '{"ok":1}');
    });

    test('graceful no-op when the store directory is unavailable', () async {
      final q = makeQueue(dirResolver: () async => null);
      // None of these may throw; all degrade to no-ops.
      await q.enqueue('/ingest/v1/errors', '{"n":1}');
      expect(await q.count(), 0);
      expect(await q.drainAll(), isEmpty);
    });

    test('enqueue never throws when the directory resolver throws', () async {
      final q = makeQueue(dirResolver: () async => throw 'boom');
      await q.enqueue('/ingest/v1/errors', '{"n":1}');
      expect(await q.count(), 0);
    });
  });

  // ─── SDK integration: persist on failure / drain on init ──────────
  group('AllStak offline queue integration', () {
    test('persists telemetry when delivery fails (network outage)', () async {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1', // unreachable
          transportTimeout: Duration(milliseconds: 80),
        ),
        offlineQueue: makeQueue(),
      );
      await sdk.awaitOfflineDrain();

      await sdk.captureException('offline-1');
      await sdk.captureLog('info', 'offline-log');
      await sdk.flush();

      // Both error + log landed on disk (scrubbed).
      final persisted = makeQueue();
      expect(await persisted.count(), 2);
    });

    test('scrubs BEFORE persisting — no secret reaches the spool', () async {
      const canary = 'should_not_leak_flutter';
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 80),
        ),
        offlineQueue: makeQueue(),
      );
      await sdk.awaitOfflineDrain();

      await sdk.captureException(
        'leak test',
        context: {
          'password': canary,
          'authorization': 'Bearer $canary',
          'token': canary,
          'benign': 'keep me',
        },
      );
      await sdk.flush();

      final onDisk = await spoolFile().readAsString();
      expect(onDisk.contains(canary), isFalse,
          reason: 'secret must be scrubbed before it is persisted');
      expect(onDisk.contains('[REDACTED]'), isTrue);
      expect(onDisk.contains('keep me'), isTrue);
    });

    test('drains and re-sends persisted events on next init (restart)',
        () async {
      // Simulate the prior run: persist two events directly into the spool.
      final seed = makeQueue();
      await seed.enqueue(
          '/ingest/v1/errors', '{"exceptionClass":"Boot","n":1}');
      await seed.enqueue('/ingest/v1/logs', '{"level":"info","n":2}');
      expect(await seed.count(), 2);

      // Next launch: a reachable server + a fresh SDK pointed at the same spool.
      final server = _IngestServer();
      await server.start();
      addTearDown(server.stop);

      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
        offlineQueue: makeQueue(),
      );
      await sdk.awaitOfflineDrain();

      // Both persisted events were re-sent and the spool was cleared.
      expect(server.bodies.length, 2);
      expect(await makeQueue().count(), 0);
    });

    test('retryable failures (5xx) are re-persisted, not lost, on drain',
        () async {
      final seed = makeQueue();
      await seed.enqueue('/ingest/v1/errors', '{"n":1}');

      final server = _IngestServer();
      await server.start();
      server.statusCode = 503; // transient -> keep for retry
      addTearDown(server.stop);

      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
        offlineQueue: makeQueue(),
      );
      await sdk.awaitOfflineDrain();

      // Server saw it, returned 503 -> entry stays on disk for a later retry.
      expect(server.bodies.length, 1);
      expect(await makeQueue().count(), 1);
    });

    test('permanent failures (non-429 4xx) are dropped, not retried forever',
        () async {
      final seed = makeQueue();
      await seed.enqueue('/ingest/v1/errors', '{"n":1}');

      final server = _IngestServer();
      await server.start();
      server.statusCode = 400; // permanent -> discard
      addTearDown(server.stop);

      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
        offlineQueue: makeQueue(),
      );
      await sdk.awaitOfflineDrain();

      expect(server.bodies.length, 1);
      // Dropped — no infinite loop on a poison entry.
      expect(await makeQueue().count(), 0);
    });

    test('session lifecycle calls are NEVER persisted', () async {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1', // every send fails
          transportTimeout: Duration(milliseconds: 80),
          release: 'r1',
        ),
        forceSessionTracking: true, // forces /sessions/start + /end attempts
        offlineQueue: makeQueue(),
      );
      await sdk.awaitOfflineDrain();

      // Start was attempted (and failed). End is attempted here.
      sdk.endSession();
      await sdk.flush();

      // Nothing session-shaped reached disk; only persistable telemetry would.
      final drained = await makeQueue().drainAll();
      for (final e in drained) {
        expect(e.path.contains('/sessions/'), isFalse,
            reason: 'session lifecycle must not be persisted');
      }
      // With only session traffic, the spool must be empty.
      expect(drained, isEmpty);
    });

    test('opt-out: enableOfflineQueue=false persists nothing', () async {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 80),
          enableOfflineQueue: false,
        ),
        offlineQueue: makeQueue(), // injected, but flag disables wiring
      );
      await sdk.awaitOfflineDrain();

      await sdk.captureException('should-not-persist');
      await sdk.flush();

      expect(await makeQueue().count(), 0);
      // Spool file should not even exist.
      expect(await spoolFile().exists(), isFalse);
    });

    test('graceful degradation: capture still works when store is unavailable',
        () async {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 80),
        ),
        offlineQueue: makeQueue(dirResolver: () async => null), // no store
      );
      await sdk.awaitOfflineDrain();

      // Must not throw and must return promptly (in-memory fire-and-forget).
      await sdk.captureException('no-store');
      await sdk.flush();

      expect(await makeQueue().count(), 0);
    });
  });
}
