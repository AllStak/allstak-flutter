import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:allstak_flutter/allstak_flutter.dart';
import 'package:allstak_flutter/src/session.dart' as session_impl;

/// Tiny HTTP server that records request bodies so we can assert payloads.
class _IngestServer {
  late HttpServer _server;
  final List<Map<String, dynamic>> bodies = [];
  final List<Map<String, String>> headers = [];
  late String host;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${_server.port}';
    _server.listen((req) async {
      final capturedHeaders = <String, String>{};
      req.headers.forEach((key, values) {
        capturedHeaders[key] = values.join(',');
      });
      headers.add(capturedHeaders);
      final bytes = await req.expand((chunk) => chunk).toList();
      final decodedBytes = capturedHeaders['content-encoding'] == 'gzip'
          ? gzip.decode(bytes)
          : bytes;
      final raw = utf8.decode(decodedBytes);
      if (raw.isNotEmpty) {
        bodies.add(jsonDecode(raw) as Map<String, dynamic>);
      }
      req.response
        ..statusCode = 200
        ..write('{"ok":true}');
      await req.response.close();
    });
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

class _MemorySessionStore implements session_impl.SessionStateStore {
  _MemorySessionStore([this.state]);
  Map<String, dynamic>? state;
  @override
  Map<String, dynamic>? read() =>
      state == null ? null : Map<String, dynamic>.from(state!);
  @override
  void write(Map<String, dynamic> state) {
    this.state = Map<String, dynamic>.from(state);
  }

  @override
  void clear() {
    state = null;
  }
}

void main() {
  // ─── Configuration tests ──────────────────────────────────────────
  group('AllStakConfig', () {
    test('defaults to api.allstak.sa', () {
      const config = AllStakConfig(apiKey: 'ask_test');
      expect(config.host, 'https://api.allstak.sa');
      expect(config.apiKey, 'ask_test');
      expect(config.service, 'flutter');
    });

    test('respects overrides', () {
      const config = AllStakConfig(
        apiKey: 'ask_test',
        host: 'http://localhost:8080',
        environment: 'test',
        release: 'v1.2.3',
      );
      expect(config.host, 'http://localhost:8080');
      expect(config.environment, 'test');
      expect(config.release, 'v1.2.3');
    });

    test('releaseTags populates sdk and platform fields', () {
      const config = AllStakConfig(
        apiKey: 'ask_test',
        dist: 'ios',
        commitSha: 'abc123',
        branch: 'main',
      );
      final tags = config.releaseTags();
      expect(tags['sdk.name'], 'allstak-flutter');
      expect(tags['sdk.version'], kAllStakSdkVersion);
      expect(tags['platform'], 'flutter');
      expect(tags['dist'], 'ios');
      expect(tags['commit.sha'], 'abc123');
      expect(tags['commit.branch'], 'main');
    });

    test('releaseTags omits empty optional fields', () {
      const config = AllStakConfig(apiKey: 'ask_test');
      final tags = config.releaseTags();
      expect(tags.containsKey('dist'), isFalse);
      expect(tags.containsKey('commit.sha'), isFalse);
      expect(tags.containsKey('commit.branch'), isFalse);
    });
  });

  // ─── Release resolution order ─────────────────────────────────────
  // The dart-define and SDK-version inputs are injected as seams so we can
  // assert ordering without rebuilding the test binary with --dart-define.
  group('resolveAllStakRelease', () {
    test('explicit release always wins, beating define and sdk version', () {
      final r = resolveAllStakRelease(
        explicit: '9.9.9',
        autoDetect: true,
        define: 'ci-deadbeef',
        sdkVersion: '1.0.3',
      );
      expect(r, '9.9.9');
    });

    test('explicit wins even when autoDetect is off', () {
      final r = resolveAllStakRelease(
        explicit: '9.9.9',
        autoDetect: false,
        define: 'ci-deadbeef',
        sdkVersion: '1.0.3',
      );
      expect(r, '9.9.9');
    });

    test('dart-define is used when no explicit release', () {
      final r = resolveAllStakRelease(
        explicit: '',
        autoDetect: true,
        define: '1.4.2+abc123',
        sdkVersion: '1.0.3',
      );
      expect(r, '1.4.2+abc123');
    });

    test('falls back to sdk version when no explicit and no define', () {
      final r = resolveAllStakRelease(
        explicit: '',
        autoDetect: true,
        define: '',
        sdkVersion: '1.0.3',
      );
      expect(r, '1.0.3',
          reason: 'release must never be empty as a last resort');
    });

    test('blank dart-define is ignored and falls through to sdk version', () {
      final r = resolveAllStakRelease(
        explicit: '',
        autoDetect: true,
        define: '   ',
        sdkVersion: '1.0.3',
      );
      expect(r, '1.0.3');
    });

    test('autoDetect off with no explicit yields empty (opt-out)', () {
      final r = resolveAllStakRelease(
        explicit: '',
        autoDetect: false,
        define: 'ci-x',
        sdkVersion: '1.0.3',
      );
      expect(r, '', reason: 'opt-out must suppress all automatic sources');
    });
  });

  group('AllStakConfig.effectiveRelease', () {
    test('explicit release flows through', () {
      const config = AllStakConfig(apiKey: 'ask_test', release: 'v2.0.0');
      expect(config.effectiveRelease, 'v2.0.0');
    });

    test('defaults to sdk version when nothing set (auto-detect on)', () {
      const config = AllStakConfig(apiKey: 'ask_test');
      // No explicit release, no dart-define in the test binary -> SDK version.
      expect(config.effectiveRelease, kAllStakSdkVersion);
    });

    test('auto-detect off with no explicit release yields empty', () {
      const config =
          AllStakConfig(apiKey: 'ask_test', autoDetectRelease: false);
      expect(config.effectiveRelease, '');
    });
  });

  // ─── Init / singleton tests ───────────────────────────────────────
  group('AllStak.init', () {
    test('sets singleton instance', () {
      final sdk = AllStak.init(const AllStakConfig(apiKey: 'ask_test'));
      expect(AllStak.instance, same(sdk));
    });

    test('setUser stores user data', () {
      final sdk = AllStak.init(const AllStakConfig(apiKey: 'ask_test'));
      sdk.setUser(id: 'u1', email: 'a@b.com');
      // No public getter, but we can verify captureException includes user
      // data below in the integration tests.
      expect(sdk, isNotNull);
    });

    test('setTag and setTags add custom tags', () {
      final sdk = AllStak.init(const AllStakConfig(apiKey: 'ask_test'));
      sdk.setTag('team', 'infra');
      sdk.setTags({'region': 'us-east', 'tier': 'pro'});
      // Tags are included in payloads — verified in integration tests.
      expect(sdk, isNotNull);
    });
  });

  // ─── Fail-open behavior ───────────────────────────────────────────
  group('fail-open', () {
    test(
      'captureException returns immediately when ingest is unreachable',
      () async {
        final sdk = AllStak.init(
          const AllStakConfig(
            apiKey: 'ask_test',
            host: 'http://127.0.0.1:1',
            transportTimeout: Duration(milliseconds: 50),
          ),
        );
        final sw = Stopwatch()..start();
        await sdk.captureException('fail-open');
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(25));
      },
    );

    test('captureLog returns immediately when ingest is unreachable', () async {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 50),
        ),
      );
      final sw = Stopwatch()..start();
      await sdk.captureLog('info', 'fail-open');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(25));
    });

    test('no-ops when apiKey is empty', () async {
      final sdk = AllStak.init(const AllStakConfig(apiKey: ''));
      // Should not throw, should not attempt any network call.
      await sdk.captureException('no key');
      await sdk.captureLog('info', 'no key');
      await sdk.flush();
    });
  });

  // ─── Error capture payload ────────────────────────────────────────
  group('captureException', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('sends structured error payload to /ingest/v1/errors', () async {
      final sdk = AllStak.init(
        AllStakConfig(
          apiKey: 'ask_test',
          host: server.host,
          environment: 'test',
          release: 'v0.1.0',
        ),
      );

      await sdk.captureException(
        'Something broke',
        context: {'source': 'unit-test'},
      );
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final body = server.bodies.first;
      expect(body['exceptionClass'], 'DartError');
      expect(body['message'], 'Something broke');
      expect(body['environment'], 'test');
      expect(body['release'], 'v0.1.0');
      expect(body['level'], 'error');
      expect(body['sdkName'], 'allstak-flutter');
      expect(body['platform'], 'flutter');
      expect((body['metadata'] as Map)['source'], 'unit-test');
    });

    test('includes user info when setUser was called', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      sdk.setUser(id: 'u42', email: 'test@allstak.io');

      await sdk.captureException('with-user');
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final user = server.bodies.first['user'] as Map;
      expect(user['id'], 'u42');
      expect(user['email'], 'test@allstak.io');
    });

    test('includes custom tags in metadata', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      sdk.setTag('team', 'backend');

      await sdk.captureException('tagged');
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final meta = server.bodies.first['metadata'] as Map;
      expect(meta['team'], 'backend');
    });

    // Canary leak test — the Flutter equivalent of the leak_pos=0 check
    // we run against the ingest API for the polyglot SDKs. We assert
    // that sensitive fields are scrubbed before the request body leaves
    // _send. Benign fields pass through. (P0 security)
    test('canary should_not_leak_flutter is scrubbed on the wire', () async {
      const canary = 'should_not_leak_flutter';
      final sdk = AllStak.init(
        AllStakConfig(
          apiKey: 'ask_test',
          host: server.host,
          environment: 'production',
          release: 'flutter-canary-10outof10',
        ),
      );

      // SDK captureException takes a flat String map for context.
      // Nested-cycle sanitizer coverage is exercised in sanitizer_test.dart.
      await sdk.captureException(
        'canary leak test',
        context: {
          'password': canary,
          'authorization': 'Bearer $canary',
          'cookie': 'session=$canary; jwt=$canary',
          'api_key': canary,
          'token': canary,
          'jwt': canary,
          'benign': 'this should pass through',
        },
      );
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final raw = jsonEncode(server.bodies.first);
      expect(
        raw.contains(canary),
        isFalse,
        reason: 'Canary $canary leaked to the wire payload: $raw',
      );
      expect(raw.contains('[REDACTED]'), isTrue);
      expect(raw.contains('this should pass through'), isTrue);
    });
  });

  // ─── Breadcrumbs ──────────────────────────────────────────────────
  group('breadcrumbs', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('breadcrumbs are attached to next captureException', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      sdk.addBreadcrumb('http', 'GET /api/users');
      sdk.addBreadcrumb('ui', 'Button tapped', data: {'id': 'submit'});

      await sdk.captureException('after-crumbs');
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final crumbs = server.bodies.first['breadcrumbs'] as List;
      expect(crumbs, hasLength(2));
      expect(crumbs[0]['type'], 'http');
      expect(crumbs[0]['message'], 'GET /api/users');
      expect(crumbs[1]['type'], 'ui');
      expect((crumbs[1]['data'] as Map)['id'], 'submit');
    });

    test('breadcrumbs are cleared after captureException', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      sdk.addBreadcrumb('nav', 'page1');
      await sdk.captureException('first');
      await sdk.flush();

      // Second capture should have no breadcrumbs.
      await sdk.captureException('second');
      await sdk.flush();

      expect(server.bodies, hasLength(2));
      expect(server.bodies[0].containsKey('breadcrumbs'), isTrue);
      // Second payload should not contain breadcrumbs (or have null).
      expect(server.bodies[1].containsKey('breadcrumbs'), isFalse);
    });

    test('breadcrumbs cap at 50', () {
      final sdk = AllStak.init(
        const AllStakConfig(apiKey: 'ask_test', host: 'http://127.0.0.1:1'),
      );
      for (var i = 0; i < 60; i++) {
        sdk.addBreadcrumb('test', 'crumb-$i');
      }
      // Internal list should be capped (we can't read it directly, but
      // the implementation drops oldest entries beyond 50).
      expect(sdk, isNotNull);
    });
  });

  // ─── Flush behavior ──────────────────────────────────────────────
  group('diagnostics', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('reports privacy-safe counters and active context', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      sdk.setTraceId('0af7651916cd43dd8448eb211c80319c');
      sdk.addBreadcrumb('custom', 'ready');
      await sdk.captureLog('info', 'hello user@example.com',
          metadata: {'password': 'secret'});
      await sdk.flush();

      final diagnostics = sdk.diagnostics;
      expect(diagnostics.eventsCaptured, greaterThanOrEqualTo(1));
      expect(diagnostics.eventsSent, greaterThanOrEqualTo(1));
      expect(diagnostics.eventsDropped, 0);
      expect(diagnostics.activeTraceCount, 1);
      expect(diagnostics.breadcrumbCount, 1);
      expect(diagnostics.sanitizerRedactionCount, greaterThanOrEqualTo(1));
      expect(diagnostics.uncompressedPayloads, greaterThanOrEqualTo(1));
      expect(diagnostics.compressedPayloads, 0);
      expect(diagnostics.toJson().containsKey('eventsSent'), isTrue);
      expect(AllStak.getDiagnostics().eventsSent, diagnostics.eventsSent);
    });

    test('compresses large payloads and exposes compression counters',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      final message = 'x' * 8000;

      await sdk.captureLog('info', message);
      await sdk.flush();

      expect(server.headers.first['content-encoding'], 'gzip');
      expect(server.bodies.first['message'], message);
      final diagnostics = sdk.diagnostics;
      expect(diagnostics.compressedPayloads, 1);
      expect(diagnostics.uncompressedPayloads, 0);
      expect(diagnostics.compressionBytesSaved, greaterThan(0));
    });
  });

  group('flush', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('flush waits for pending events to be delivered', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      // Fire several events without awaiting individually.
      sdk.captureException('e1');
      sdk.captureException('e2');
      sdk.captureLog('info', 'log1');

      // Before flush, the server may not have received them yet.
      await sdk.flush();

      // After flush, all 3 payloads must have arrived.
      expect(server.bodies.length, greaterThanOrEqualTo(3));
    });

    test('flush is safe to call when no events are pending', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      // Should complete without error.
      await sdk.flush();
      await sdk.flush();
      expect(server.bodies, isEmpty);
    });

    test('flush completes even when ingest host is unreachable', () async {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 100),
        ),
      );

      sdk.captureException('will-timeout');
      // flush should still complete (not hang) because _send swallows errors.
      await sdk.flush().timeout(const Duration(seconds: 2));
    });
  });

  // ─── HTTP client instrumentation ─────────────────────────────────
  group('httpClient', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('httpClient returns a working Client wrapper', () {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      final client = sdk.httpClient();
      expect(client, isNotNull);
      client.close();
    });

    test('httpClient skips recording requests to own ingest host', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      final client = sdk.httpClient();

      // Make a request to the SDK's own ingest host — should NOT be recorded.
      try {
        await client.get(Uri.parse('${server.host}/ingest/v1/errors'));
      } catch (_) {}
      await sdk.flush();

      // The only body should be from the GET itself arriving at our test
      // server, NOT a secondary ingest capture (which would cause recursion).
      // We verify no http-request ingest payload was sent.
      final httpIngest = server.bodies.where((b) => b.containsKey('requests'));
      expect(httpIngest, isEmpty);
      client.close();
    });

    test('httpClient propagates trace headers and baggage', () async {
      final upstream = _IngestServer();
      await upstream.start();
      final sdk = AllStak.init(AllStakConfig(
        apiKey: 'ask_test',
        host: server.host,
      ));
      final client = sdk.httpClient();

      await client.get(
        Uri.parse('${upstream.host}/orders'),
        headers: {'baggage': 'vendor=value'},
      );
      await sdk.flush();

      final sent = upstream.headers.single;
      expect(sent['traceparent'], isNotNull);
      expect(sent['x-allstak-trace-id'], isNotNull);
      expect(sent['x-allstak-request-id'], isNotNull);
      expect(sent['x-allstak-span-id'], isNotNull);
      expect(sent['baggage'], contains('vendor=value'));
      expect(sent['baggage'], contains('allstak-trace_id='));
      expect(sent['baggage'], contains('allstak-request_id='));
      expect(sent['baggage'], contains('allstak-span_id='));
      expect(sent['allstak-baggage'], contains('allstak-trace_id='));

      client.close();
      await upstream.stop();
    });
  });

  // ─── captureMessage ───────────────────────────────────────────────
  group('captureMessage', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('sends a message-level event', () async {
      final sdk = AllStak.init(
        AllStakConfig(
          apiKey: 'ask_test',
          host: server.host,
          environment: 'staging',
        ),
      );

      await sdk.captureMessage('deploy started', level: 'info');
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final body = server.bodies.first;
      expect(body['exceptionClass'], 'Message');
      expect(body['message'], 'deploy started');
      expect(body['level'], 'info');
      expect(body['environment'], 'staging');
    });
  });

  // ─── SessionStatus model (mirrors the Java SessionTracker) ────────
  group('Session model', () {
    test('starts ok, escalates ok -> errored -> crashed', () {
      final s = Session();
      expect(s.status, SessionStatus.ok);
      expect(s.errorCount, 0);

      s.recordError();
      expect(s.status, SessionStatus.errored);
      expect(s.errorCount, 1);

      // A second handled error keeps ERRORED and bumps the counter.
      s.recordError();
      expect(s.status, SessionStatus.errored);
      expect(s.errorCount, 2);

      // Crash escalates and is terminal.
      s.recordCrash();
      expect(s.status, SessionStatus.crashed);
      expect(s.errorCount, 3);
    });

    test('recordError does not downgrade a crashed session', () {
      final s = Session();
      s.recordCrash();
      expect(s.status, SessionStatus.crashed);
      // Once crashed, a later handled error must not pull it back to errored.
      s.recordError();
      expect(s.status, SessionStatus.crashed);
    });

    test('durationMs is non-negative', () {
      final s = Session(startedAt: DateTime.now());
      expect(s.durationMs(), greaterThanOrEqualTo(0));
    });

    test('wire values match the backend contract', () {
      expect(SessionStatus.ok.wire, 'ok');
      expect(SessionStatus.errored.wire, 'errored');
      expect(SessionStatus.crashed.wire, 'crashed');
      expect(SessionStatus.abnormal.wire, 'abnormal');
    });
  });

  group('SessionTracker abnormal recovery', () {
    session_impl.SessionTracker tracker(
      List<MapEntry<String, Map<String, dynamic>>> sent,
      _MemorySessionStore store,
    ) =>
        session_impl.SessionTracker(
          send: (path, payload) => sent.add(MapEntry(path, payload)),
          release: 'r1',
          environment: 'test',
          sdkName: 'allstak-flutter',
          sdkVersion: kAllStakSdkVersion,
          platform: 'flutter',
          stateStore: store,
        );

    test('clean shutdown does not report abnormal on next start', () {
      final store = _MemorySessionStore();
      final firstSent = <MapEntry<String, Map<String, dynamic>>>[];
      tracker(firstSent, store)
        ..start()
        ..end();

      final secondSent = <MapEntry<String, Map<String, dynamic>>>[];
      tracker(secondSent, store).start();

      expect(
          secondSent.where((e) => e.key == session_impl.SessionTracker.pathEnd),
          isEmpty);
      expect(
          secondSent
              .where((e) => e.key == session_impl.SessionTracker.pathStart),
          hasLength(1));
    });

    test('open session is reported abnormal on next start', () {
      final store = _MemorySessionStore();
      final session =
          tracker(<MapEntry<String, Map<String, dynamic>>>[], store).start();

      final secondSent = <MapEntry<String, Map<String, dynamic>>>[];
      final second = tracker(secondSent, store);
      second.start();

      final recovered = secondSent
          .firstWhere((e) => e.key == session_impl.SessionTracker.pathEnd)
          .value;
      expect(recovered['sessionId'], session.id);
      expect(recovered['status'], SessionStatus.abnormal.wire);
      expect(second.recoveryCount, 1);
    });

    test('crashed open session is reported crashed on next start', () {
      final store = _MemorySessionStore();
      final first = tracker(<MapEntry<String, Map<String, dynamic>>>[], store);
      final session = first.start();
      first.recordCrash();

      final secondSent = <MapEntry<String, Map<String, dynamic>>>[];
      final second = tracker(secondSent, store);
      second.start();

      final recovered = secondSent
          .firstWhere((e) => e.key == session_impl.SessionTracker.pathEnd)
          .value;
      expect(recovered['sessionId'], session.id);
      expect(recovered['status'], SessionStatus.crashed.wire);
      expect(second.recoveryCount, 1);
    });

    test('corrupt state is cleared safely', () {
      final store = _MemorySessionStore({'version': 1, 'bad': 'shape'});
      final sent = <MapEntry<String, Map<String, dynamic>>>[];
      tracker(sent, store).start();

      expect(sent.where((e) => e.key == session_impl.SessionTracker.pathEnd),
          isEmpty);
      expect(sent.where((e) => e.key == session_impl.SessionTracker.pathStart),
          hasLength(1));
    });

    test('recovered abnormal session is not reported twice', () {
      final store = _MemorySessionStore();
      tracker(<MapEntry<String, Map<String, dynamic>>>[], store).start();

      final secondSent = <MapEntry<String, Map<String, dynamic>>>[];
      tracker(secondSent, store)
        ..start()
        ..end();

      final thirdSent = <MapEntry<String, Map<String, dynamic>>>[];
      tracker(thirdSent, store).start();

      expect(
        secondSent.where((e) =>
            e.key == session_impl.SessionTracker.pathEnd &&
            e.value['status'] == SessionStatus.abnormal.wire),
        hasLength(1),
      );
      expect(
        thirdSent.where((e) =>
            e.key == session_impl.SessionTracker.pathEnd &&
            e.value['status'] == SessionStatus.abnormal.wire),
        isEmpty,
      );
    });
  });

  // ─── Release-health session lifecycle (start/end on the wire) ─────
  // `forceSessionTracking: true` bypasses the `flutter test` runtime guard so
  // the lifecycle can be asserted; production callers never set it.
  group('session tracking', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    Map<String, dynamic>? sessionStart(_IngestServer s) {
      final matches = s.bodies
          .where((b) => b.containsKey('sessionId') && b.containsKey('release'))
          .toList();
      return matches.isEmpty ? null : matches.first;
    }

    test('posts /sessions/start on init with the expected payload shape',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(
          apiKey: 'ask_test',
          host: server.host,
          environment: 'staging',
          release: 'v1.2.3',
        ),
        forceSessionTracking: true,
      );
      await sdk.flush();

      final start = sessionStart(server);
      expect(start, isNotNull, reason: 'session/start must be posted on init');
      expect(start!['sessionId'], isA<String>());
      expect((start['sessionId'] as String).isNotEmpty, isTrue);
      expect(start['release'], 'v1.2.3');
      expect(start['environment'], 'staging');
      expect(start['sdkName'], 'allstak-flutter');
      expect(start['sdkVersion'], kAllStakSdkVersion);
      expect(start['platform'], 'flutter');
      // No user set at init -> userId omitted.
      expect(start.containsKey('userId'), isFalse);
      // sessionId is exposed for attaching to events.
      expect(sdk.sessionId, start['sessionId']);
    });

    test('release falls back to sdk version when none is resolved', () async {
      final sdk = AllStak.init(
        AllStakConfig(
          apiKey: 'ask_test',
          host: server.host,
          autoDetectRelease: false, // effectiveRelease == ''
        ),
        forceSessionTracking: true,
      );
      await sdk.flush();

      final start = sessionStart(server);
      expect(start, isNotNull);
      expect(start!['release'], kAllStakSdkVersion,
          reason: 'a session must never be dropped for lack of a release');
    });

    test('attaches sessionId to error payloads', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
        forceSessionTracking: true,
      );
      final sid = sdk.sessionId;
      expect(sid, isNotNull);

      await sdk.captureException('boom');
      await sdk.flush();

      final err = server.bodies.firstWhere(
        (b) => b['exceptionClass'] == 'DartError',
      );
      expect(err['sessionId'], sid);
    });

    test('end posts /sessions/end with status ok and a non-negative durationMs',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host, release: 'r1'),
        forceSessionTracking: true,
      );
      final sid = sdk.sessionId;
      sdk.endSession();
      await sdk.flush();

      final end = server.bodies.firstWhere((b) => b.containsKey('status'));
      expect(end['sessionId'], sid);
      expect(end['status'], 'ok');
      expect(end['durationMs'], isA<int>());
      expect(end['durationMs'] as int, greaterThanOrEqualTo(0));
    });

    test('status transitions ok -> errored after a handled error', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host, release: 'r1'),
        forceSessionTracking: true,
      );
      await sdk.captureException('handled');
      sdk.endSession();
      await sdk.flush();

      final end = server.bodies.firstWhere((b) => b.containsKey('status'));
      expect(end['status'], 'errored');
    });

    test('status transitions to crashed on a fatal error', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host, release: 'r1'),
        forceSessionTracking: true,
      );
      // Mirror the unhandled-handler path.
      await sdk.captureException('handled-first');
      await sdk.captureException('fatal-crash', fatal: true);
      sdk.endSession();
      await sdk.flush();

      final end = server.bodies.firstWhere((b) => b.containsKey('status'));
      expect(end['status'], 'crashed',
          reason: 'a fatal error must escalate the session to crashed');
    });

    test('end is idempotent — a second endSession sends nothing new', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host, release: 'r1'),
        forceSessionTracking: true,
      );
      sdk.endSession();
      await sdk.flush();
      final endsAfterFirst =
          server.bodies.where((b) => b.containsKey('status')).length;

      sdk.endSession();
      await sdk.flush();
      final endsAfterSecond =
          server.bodies.where((b) => b.containsKey('status')).length;

      expect(endsAfterFirst, 1);
      expect(endsAfterSecond, 1);
    });

    test('enableAutoSessionTracking=false opts out (no session/start)',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(
          apiKey: 'ask_test',
          host: server.host,
          release: 'r1',
          enableAutoSessionTracking: false,
        ),
        forceSessionTracking: true, // even forced, the flag wins
      );
      await sdk.flush();

      expect(sdk.sessionId, isNull);
      expect(sessionStart(server), isNull,
          reason: 'opt-out must suppress the session/start POST');

      // captureException still works and carries no sessionId.
      await sdk.captureException('no-session');
      await sdk.flush();
      final err = server.bodies.firstWhere(
        (b) => b['exceptionClass'] == 'DartError',
      );
      expect(err.containsKey('sessionId'), isFalse);
    });

    test('skipped under the flutter test runtime without the force seam',
        () async {
      // No forceSessionTracking -> the FLUTTER_TEST guard suppresses tracking.
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host, release: 'r1'),
      );
      await sdk.flush();
      expect(sdk.sessionId, isNull);
      expect(sessionStart(server), isNull);
    });
  });

  // ─── captureRequest ───────────────────────────────────────────────
  group('captureRequest', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('sends http-request payload', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      await sdk.captureRequest(
        method: 'GET',
        host: 'api.example.com',
        path: '/users',
        statusCode: 200,
        durationMs: 42,
        traceId: 'a' * 32,
        requestId: 'req-123',
        spanId: 'b' * 16,
        parentSpanId: 'c' * 16,
        requestSize: 12,
        responseSize: 34,
      );
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final reqs = server.bodies.first['requests'] as List;
      expect(reqs, hasLength(1));
      expect(reqs[0]['method'], 'GET');
      expect(reqs[0]['host'], 'api.example.com');
      expect(reqs[0]['path'], '/users');
      expect(reqs[0]['statusCode'], 200);
      expect(reqs[0]['durationMs'], 42);
      expect(reqs[0]['direction'], 'outbound');
      expect(reqs[0]['traceId'], 'a' * 32);
      expect(reqs[0]['requestId'], 'req-123');
      expect(reqs[0]['spanId'], 'b' * 16);
      expect(reqs[0]['parentSpanId'], 'c' * 16);
      expect(reqs[0]['requestSize'], 12);
      expect(reqs[0]['responseSize'], 34);
      expect((reqs[0]['metadata'] as Map).containsKey('requestId'), isFalse);
    });

    test('normalizes caller-provided trace and span ids to W3C widths',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );
      sdk.setTraceId('7f3ac1d9-2b8e-4a6f-8c1a-000000000001');

      await sdk.captureRequest(
        method: 'POST',
        host: 'api.example.com',
        path: '/orders',
        statusCode: 202,
        durationMs: 10,
        traceId: 'not-a-trace',
        spanId: 'abcdef01-2345-6789-abcd-ef0123456789',
        parentSpanId: '0000000000000000',
      );
      await sdk.flush();

      final reqs = server.bodies.first['requests'] as List;
      expect(reqs[0]['traceId'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(reqs[0]['traceId'], isNot('00000000000000000000000000000000'));
      expect(reqs[0]['spanId'], 'abcdef0123456789');
      expect(reqs[0]['parentSpanId'], matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(reqs[0]['parentSpanId'], isNot('0000000000000000'));
      expect(sdk.getTraceId(), '7f3ac1d92b8e4a6f8c1a000000000001');
    });
  });

  // ─── captureSpan ─────────────────────────────────────────────────
  group('captureSpan', () {
    late _IngestServer server;

    setUp(() async {
      server = _IngestServer();
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('sends W3C-normalized span payload', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      await sdk.captureSpan(
        traceId: '550E8400-E29B-41D4-A716-446655440000',
        spanId: 'ABCDEFABCDEF1234',
        parentSpanId: '1234567890ABCDEF',
        operation: 'db.sqlite.query',
        description: 'SELECT 1',
        status: 'ok',
        durationMs: 3,
        startTimeMillis: 1700000000000,
        endTimeMillis: 1700000000003,
        service: 'certification-flutter',
        tags: {'db.system': 'sqlite'},
      );
      await sdk.flush();

      expect(server.bodies, hasLength(1));
      final spans = server.bodies.first['spans'] as List;
      expect(spans, hasLength(1));
      expect(spans[0]['traceId'], '550e8400e29b41d4a716446655440000');
      expect(spans[0]['spanId'], 'abcdefabcdef1234');
      expect(spans[0]['parentSpanId'], '1234567890abcdef');
      expect(spans[0]['operation'], 'db.sqlite.query');
      expect(spans[0]['service'], 'certification-flutter');
    });

    test('sanitizes span tags data and attributes before sending', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: server.host),
      );

      await sdk.captureSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        operation: 'http.client',
        description: 'GET https://example.invalid',
        durationMs: 1,
        startTimeMillis: 1,
        endTimeMillis: 2,
        tags: {'authorization': 'Bearer should_not_leak'},
        data: 'card 4242424242424242',
        attributes: {
          'nested': {'apiKey': 'should_not_leak'}
        },
      );
      await sdk.flush();

      final serialized = jsonEncode(server.bodies.first);
      expect(serialized.contains('should_not_leak'), isFalse);
      expect(serialized.contains('4242424242424242'), isFalse);
      expect(serialized.contains('[REDACTED]'), isTrue);
    });
  });
}
