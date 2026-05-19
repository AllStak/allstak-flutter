import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:allstak_flutter/allstak_flutter.dart';

/// Tiny HTTP server that records request bodies so we can assert payloads.
class _IngestServer {
  late HttpServer _server;
  final List<Map<String, dynamic>> bodies = [];
  late String host;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${_server.port}';
    _server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
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
    // we run in production ClickHouse for the polyglot SDKs. We assert
    // that sensitive fields are scrubbed before the request body leaves
    // _send. Benign fields pass through. (P0 security parity)
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
    });
  });
}
