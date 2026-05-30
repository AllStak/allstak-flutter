import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:allstak/allstak.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tiny HTTP server that records request bodies + headers so we can assert
/// auto-instrumentation payloads end-to-end over a real loopback socket.
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
        try {
          bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {}
      }
      req.response
        ..statusCode = 200
        ..write('{"ok":true}');
      await req.response.close();
    });
  }

  Future<void> stop() async => _server.close(force: true);

  /// All captured outbound http-request payloads (those with a `requests` key).
  List<Map<String, dynamic>> get httpRequests =>
      bodies.where((b) => b.containsKey('requests')).toList();

  /// All captured /ingest/v1/logs payloads (those with `service` + `level`).
  List<Map<String, dynamic>> get logs => bodies
      .where((b) => b.containsKey('service') && b.containsKey('level'))
      .toList();

  /// All captured error payloads.
  List<Map<String, dynamic>> get errors =>
      bodies.where((b) => b.containsKey('exceptionClass')).toList();
}

void main() {
  // ─── AllStakConfig: new default-on flags ───────────────────────────
  group('auto-instrumentation config defaults', () {
    test('all new auto-instrumentation flags default to true', () {
      const c = AllStakConfig(apiKey: 'ask_test');
      expect(c.autoInstallNativeHandlers, isTrue);
      expect(c.enableHttpOverrides, isTrue);
      expect(c.captureLogs, isTrue);
      // Existing native-capture flag stays on.
      expect(c.enableNativeCrashCapture, isTrue);
    });

    test('each new flag is individually toggleable', () {
      const c = AllStakConfig(
        apiKey: 'ask_test',
        autoInstallNativeHandlers: false,
        enableHttpOverrides: false,
        captureLogs: false,
      );
      expect(c.autoInstallNativeHandlers, isFalse);
      expect(c.enableHttpOverrides, isFalse);
      expect(c.captureLogs, isFalse);
    });
  });

  // ─── HTTP overrides: dart:io HttpClient auto-instrumentation ───────
  group('AllStakHttpOverrides', () {
    late _IngestServer ingest;
    late _IngestServer upstream;

    setUp(() async {
      ingest = _IngestServer();
      upstream = _IngestServer();
      await ingest.start();
      await upstream.start();
    });

    tearDown(() async {
      await ingest.stop();
      await upstream.stop();
    });

    test(
        'a plain dart:io HttpClient is auto-instrumented as an outbound request',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );
      final overrides = sdk.buildHttpOverrides();

      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final req =
            await client.getUrl(Uri.parse('${upstream.host}/widgets/42'));
        final resp = await req.close();
        await resp.drain<void>();
        client.close();
      }, overrides);

      await sdk.flush();

      final reqs = ingest.httpRequests;
      expect(reqs, hasLength(1),
          reason: 'a single outbound GET must be captured once');
      final r = (reqs.first['requests'] as List).first as Map;
      expect(r['method'], 'GET');
      expect(r['path'], '/widgets/42');
      expect(r['statusCode'], 200);
      expect(r['direction'], 'outbound');
      expect(r['traceId'], isA<String>());
      expect(r['requestId'], isA<String>());
    });

    test('injects trace + baggage headers onto the outbound request', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );
      final overrides = sdk.buildHttpOverrides();

      final captured = <String, String>{};
      // Re-point upstream to capture headers for one request.
      final hdrServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      hdrServer.listen((req) async {
        req.headers.forEach((k, v) => captured[k] = v.join(','));
        req.response.statusCode = 200;
        await req.response.close();
      });
      final hdrHost = 'http://127.0.0.1:${hdrServer.port}';

      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse('$hdrHost/orders'));
        req.headers.set('baggage', 'vendor=value');
        final resp = await req.close();
        await resp.drain<void>();
        client.close();
      }, overrides);

      await sdk.flush();

      expect(captured['traceparent'], isNotNull);
      expect(captured['x-allstak-trace-id'], isNotNull);
      expect(captured['x-allstak-request-id'], isNotNull);
      expect(captured['x-allstak-span-id'], isNotNull);
      expect(captured['baggage'], contains('vendor=value'));
      expect(captured['baggage'], contains('allstak-trace_id='));
      expect(captured['allstak-baggage'], contains('allstak-trace_id='));

      await hdrServer.close(force: true);
    });

    test('does NOT instrument requests to the SDK\'s own ingest host',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );
      final overrides = sdk.buildHttpOverrides();

      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        // Hit the ingest host directly — must be skipped (no recursion).
        final req =
            await client.postUrl(Uri.parse('${ingest.host}/ingest/v1/errors'));
        req.write('{}');
        final resp = await req.close();
        await resp.drain<void>();
        client.close();
      }, overrides);

      await sdk.flush();

      // The POST itself reached the server, but it must NOT have produced a
      // secondary http-request ingest capture.
      expect(ingest.httpRequests, isEmpty,
          reason: 'requests to own ingest host must not be re-instrumented');
    });

    test('records status=0 with an error fingerprint on a connection failure',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );
      final overrides = sdk.buildHttpOverrides();

      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(milliseconds: 200);
        try {
          // Port 1 refuses — the request throws and must still be recorded.
          final req = await client.getUrl(Uri.parse('http://127.0.0.1:1/x'));
          final resp = await req.close();
          await resp.drain<void>();
        } catch (_) {}
        client.close();
      }, overrides);

      await sdk.flush();

      final reqs = ingest.httpRequests;
      expect(reqs, hasLength(1));
      final r = (reqs.first['requests'] as List).first as Map;
      expect(r['statusCode'], 0);
      expect(r['errorFingerprint'], isNotNull);
    });

    test('preserves the host\'s own existing HttpOverrides (inner delegate)',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );
      final inner = _CountingHttpOverrides();
      final overrides = sdk.buildHttpOverrides(inner: inner);

      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse('${upstream.host}/x'));
        final resp = await req.close();
        await resp.drain<void>();
        client.close();
      }, overrides);

      expect(inner.created, greaterThanOrEqualTo(1),
          reason:
              'an app-set override must still create the underlying client');
    });
  });

  // ─── Log bridge: package:logging-style stream + promotion ──────────
  group('AllStakLogBridge', () {
    late _IngestServer ingest;

    setUp(() async {
      ingest = _IngestServer();
      await ingest.start();
    });

    tearDown(() async => ingest.stop());

    test('a record below SEVERE ships to /logs only (no exception promotion)',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
        // forceSessionTracking doubles as the log-bridge force seam.
        forceSessionTracking: true,
      );
      expect(sdk.logBridge, isNotNull);

      sdk.logBridge!.record(const AllStakLogRecord(
        level: 800, // WARNING
        levelName: 'WARNING',
        message: 'disk is getting full',
        loggerName: 'storage',
      ));
      await sdk.flush();

      expect(ingest.logs, hasLength(1));
      final log = ingest.logs.first;
      expect(log['level'], 'warning');
      expect(log['message'], 'disk is getting full');
      expect((log['metadata'] as Map)['logger'], 'storage');
      // No exception promotion for a sub-SEVERE record.
      expect(ingest.errors, isEmpty);
    });

    test('a SEVERE record is shipped to /logs AND promoted to an exception',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
        forceSessionTracking: true,
      );

      sdk.logBridge!.record(const AllStakLogRecord(
        level: 1000, // SEVERE
        levelName: 'SEVERE',
        message: 'payment gateway timeout',
        loggerName: 'billing',
      ));
      await sdk.flush();

      expect(ingest.logs, hasLength(1));
      expect(ingest.logs.first['level'], 'error');

      final errs = ingest.errors;
      expect(errs, hasLength(1), reason: 'SEVERE must promote to an exception');
      expect(errs.first['message'], 'payment gateway timeout');
      expect((errs.first['metadata'] as Map)['source'], 'log-bridge');
    });

    test('a record carrying an error object is promoted regardless of level',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
        forceSessionTracking: true,
      );

      sdk.logBridge!.record(AllStakLogRecord(
        level: 800, // WARNING — below SEVERE
        levelName: 'WARNING',
        message: 'caught and logged',
        error: StateError('boom'),
        stackTrace: '#0  main (file:///a.dart:1:1)',
      ));
      await sdk.flush();

      // Below SEVERE but carries an error -> promoted.
      expect(ingest.errors, hasLength(1));
      final err = ingest.errors.first;
      expect(err['exceptionClass'], 'StateError');
      expect((err['stackTrace'] as List), isNotEmpty);
    });

    test('attachToLogging forwards a duck-typed package:logging record stream',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
        forceSessionTracking: true,
      );

      final controller = StreamController<_FakeLogRecord>();
      sdk.attachLogging(controller.stream);

      controller.add(const _FakeLogRecord(
        level: _FakeLevel(1000, 'SEVERE'),
        message: 'from a logging-like stream',
        loggerName: 'app',
      ));
      // Let the stream microtask deliver.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sdk.flush();

      expect(ingest.logs.where((l) => l['level'] == 'error'), isNotEmpty);
      expect(ingest.errors, isNotEmpty);
      await controller.close();
    });

    test('captureLogs=false disables the bridge entirely', () {
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          captureLogs: false,
        ),
        forceSessionTracking: true,
      );
      expect(sdk.logBridge, isNull);
    });

    test('the bridge is skipped under the flutter test runtime without force',
        () {
      final sdk = AllStak.init(
        const AllStakConfig(apiKey: 'ask_test', host: 'http://127.0.0.1:1'),
      );
      expect(sdk.logBridge, isNull,
          reason: 'unforced test runtime must not arm the log bridge');
    });
  });

  // ─── AllStakLogRecord level mapping ────────────────────────────────
  group('AllStakLogRecord.wireLevel', () {
    test('maps package:logging level names to the AllStak vocabulary', () {
      expect(
          const AllStakLogRecord(level: 500, levelName: 'FINE', message: '')
              .wireLevel,
          'debug');
      expect(
          const AllStakLogRecord(level: 800, levelName: 'INFO', message: '')
              .wireLevel,
          'info');
      expect(
          const AllStakLogRecord(level: 900, levelName: 'WARNING', message: '')
              .wireLevel,
          'warning');
      expect(
          const AllStakLogRecord(level: 1000, levelName: 'SEVERE', message: '')
              .wireLevel,
          'error');
      expect(
          const AllStakLogRecord(level: 1200, levelName: 'SHOUT', message: '')
              .wireLevel,
          'fatal');
    });

    test('falls back to numeric mapping for unknown level names', () {
      expect(
          const AllStakLogRecord(level: 1000, levelName: '', message: '')
              .wireLevel,
          'error');
      expect(
          const AllStakLogRecord(level: 850, levelName: '', message: '')
              .wireLevel,
          'warning');
    });

    test('shouldPromote is true at SEVERE+ or when an error is attached', () {
      expect(
          const AllStakLogRecord(level: 800, levelName: 'WARNING', message: '')
              .shouldPromote,
          isFalse);
      expect(
          const AllStakLogRecord(level: 900, levelName: 'SEVERE', message: '')
              .shouldPromote,
          isTrue);
      expect(
          AllStakLogRecord(
                  level: 100,
                  levelName: 'FINEST',
                  message: '',
                  error: Exception('x'))
              .shouldPromote,
          isTrue);
    });
  });

  // ─── Dio interceptor (dependency-free, duck-typed) ─────────────────
  group('dioInterceptor', () {
    late _IngestServer ingest;

    setUp(() async {
      ingest = _IngestServer();
      await ingest.start();
    });

    tearDown(() async => ingest.stop());

    test('records an outbound request through a fake Dio request lifecycle',
        () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );

      // Build the interceptor with a fake wrapper factory that just hands the
      // three callbacks back so the test can drive the Dio lifecycle.
      final fw = sdk.dioInterceptor(
        wrapperFactory: ({
          required onRequest,
          required onResponse,
          required onError,
        }) =>
            _FakeWrapper(onRequest, onResponse, onError),
      ) as _FakeWrapper;

      final options = _FakeRequestOptions(
        method: 'POST',
        uri: Uri.parse('https://api.example.com/checkout'),
      );
      final handler = _FakeHandler();
      fw.onRequest(options, handler);

      // Headers were injected outbound.
      expect(options.headers['traceparent'], isNotNull);
      expect(options.headers['x-allstak-trace-id'], isNotNull);
      expect(handler.proceededWith, same(options));

      final response = _FakeResponse(statusCode: 201, requestOptions: options);
      fw.onResponse(response, _FakeHandler());

      await sdk.flush();

      final reqs = ingest.httpRequests;
      expect(reqs, hasLength(1));
      final r = (reqs.first['requests'] as List).first as Map;
      expect(r['method'], 'POST');
      expect(r['host'], 'api.example.com');
      expect(r['path'], '/checkout');
      expect(r['statusCode'], 201);
    });

    test('records status=0 on a Dio error', () async {
      final sdk = AllStak.init(
        AllStakConfig(apiKey: 'ask_test', host: ingest.host),
      );
      final fw = sdk.dioInterceptor(
        wrapperFactory: ({
          required onRequest,
          required onResponse,
          required onError,
        }) =>
            _FakeWrapper(onRequest, onResponse, onError),
      ) as _FakeWrapper;

      final options = _FakeRequestOptions(
        method: 'GET',
        uri: Uri.parse('https://api.example.com/profile'),
      );
      fw.onRequest(options, _FakeHandler());
      final err = _FakeDioException(requestOptions: options, type: 'timeout');
      fw.onError(err, _FakeHandler());

      await sdk.flush();

      final r = (ingest.httpRequests.first['requests'] as List).first as Map;
      expect(r['statusCode'], 0);
      expect(r['errorFingerprint'], 'timeout');
    });
  });
}

// ── Fakes ───────────────────────────────────────────────────────────────

/// Counts how many underlying clients it is asked to create so we can assert
/// the SDK's override delegates to an app-set inner override.
class _CountingHttpOverrides extends HttpOverrides {
  int created = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}

// `package:logging`-shaped fakes (duck-typed by the bridge).
class _FakeLevel {
  const _FakeLevel(this.value, this.name);
  final int value;
  final String name;
}

class _FakeLogRecord {
  const _FakeLogRecord({
    required this.level,
    required this.message,
    this.loggerName,
  });
  final _FakeLevel level;
  final String message;
  final String? loggerName;
  // Present so the bridge's duck-typed `.error` / `.stackTrace` reads resolve
  // to null rather than throwing NoSuchMethod (which the bridge would swallow,
  // but this keeps the fake faithful to a real LogRecord shape).
  final Object? error = null;
  final StackTrace? stackTrace = null;
}

// Dio-shaped fakes (duck-typed by the interceptor).
class _FakeWrapper {
  _FakeWrapper(this.onRequest, this.onResponse, this.onError);
  final void Function(dynamic, dynamic) onRequest;
  final void Function(dynamic, dynamic) onResponse;
  final void Function(dynamic, dynamic) onError;
}

class _FakeRequestOptions {
  _FakeRequestOptions({required this.method, required this.uri});
  final String method;
  final Uri uri;
  final Map<String, dynamic> headers = {};
  final Map<String, dynamic> extra = {};
}

class _FakeResponse {
  _FakeResponse({required this.statusCode, required this.requestOptions});
  final int statusCode;
  final _FakeRequestOptions requestOptions;
}

class _FakeDioException {
  _FakeDioException({required this.requestOptions, required this.type});
  final _FakeRequestOptions requestOptions;
  final String type;
  final Object? response = null;
}

class _FakeHandler {
  Object? proceededWith;
  void next(dynamic value) => proceededWith = value;
}
