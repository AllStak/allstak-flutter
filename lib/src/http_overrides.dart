/// Process-wide `dart:io` HTTP auto-instrumentation.
///
/// Installing [AllStakHttpOverrides] as `HttpOverrides.global` makes EVERY
/// `dart:io` [HttpClient] created afterwards record an outbound http-request to
/// AllStak — with the real method/host/path/status/duration — and propagate the
/// SDK's distributed-trace headers (`traceparent`, `x-allstak-*`, `baggage`).
/// This covers the vast majority of real Flutter networking: `package:http`'s
/// `IOClient`, Dio's default `IOHttpClientAdapter`, `Image.network`, and any
/// hand-rolled `HttpClient` — with zero per-call wiring.
///
/// Requests to AllStak's own ingest host are skipped to prevent recursion (the
/// SDK transport itself uses `package:http`, which uses `dart:io` under the
/// hood). Capture is strictly fire-and-forget and fail-open: an instrumentation
/// error never affects the host app's request or response.
///
/// This complements (does not replace) `allstak.httpClient()` — apps that
/// prefer an explicit instrumented client can keep using it; with overrides
/// installed they simply both work.
library;

import 'dart:convert' show Encoding;
import 'dart:io';

/// Callback the override fires once an outbound request settles. Mirrors the
/// public `captureRequest` contract so the SDK can forward it without exposing
/// internals. Implementations must be fail-open (never throw).
typedef HttpRecordCallback = void Function({
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
});

/// Generates a fresh hex correlation id of [byteLength] bytes. Supplied by the
/// SDK so override-side ids share the same generator as the rest of the SDK.
typedef HexIdFactory = String Function(int byteLength);

/// Reads the SDK's current trace id (creating one lazily if needed) so spans
/// emitted by the override join the active trace.
typedef TraceIdProvider = String Function();

/// Builds the `baggage` header value, merging any existing baggage with the
/// AllStak correlation entries. Supplied by the SDK so the wire format stays in
/// one place.
typedef BaggageBuilder = String Function(
    String? existing, String traceId, String requestId, String? spanId);

/// Builds the `allstak-baggage` header value.
typedef AllStakBaggageBuilder = String Function(
    String traceId, String requestId, String? spanId);

/// An [HttpOverrides] that instruments every [HttpClient] it creates.
class AllStakHttpOverrides extends HttpOverrides {
  AllStakHttpOverrides({
    required this.ingestHost,
    required this.record,
    required this.hexId,
    required this.traceId,
    required this.currentSpanId,
    required this.mergeBaggage,
    required this.allstakBaggage,
    this.inner,
  });

  /// The SDK's configured ingest host (`config.host`). Requests whose absolute
  /// URL starts with this are NOT instrumented, preventing recursion.
  final String ingestHost;

  final HttpRecordCallback record;
  final HexIdFactory hexId;
  final TraceIdProvider traceId;

  /// Returns the SDK's current span id (parent for the new span), or null.
  final String? Function() currentSpanId;

  final BaggageBuilder mergeBaggage;
  final AllStakBaggageBuilder allstakBaggage;

  /// An optional previous [HttpOverrides] to delegate client creation to, so
  /// installing AllStak does not clobber an override the host app already set.
  final HttpOverrides? inner;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client =
        inner?.createHttpClient(context) ?? super.createHttpClient(context);
    return _AllStakHttpClient(client, this);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    if (inner != null) {
      return inner!.findProxyFromEnvironment(url, environment);
    }
    return super.findProxyFromEnvironment(url, environment);
  }
}

/// True when [url] targets the SDK's own ingest host — those must never be
/// re-instrumented (infinite recursion).
bool _isOwnIngest(String ingestHost, Uri url) {
  if (ingestHost.isEmpty) return false;
  return url.toString().startsWith(ingestHost);
}

/// Delegating [HttpClient] that records each opened request. Only `openUrl`
/// (the funnel every other open* method routes through) is overridden; all
/// other members forward to [_inner] so behavior is otherwise identical.
class _AllStakHttpClient implements HttpClient {
  _AllStakHttpClient(this._inner, this._overrides);

  final HttpClient _inner;
  final AllStakHttpOverrides _overrides;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final HttpClientRequest request;
    try {
      request = await _inner.openUrl(method, url);
    } catch (e) {
      // Some failures (e.g. connection refused with eager connect) surface at
      // openUrl rather than close(). Record the failed outbound attempt before
      // rethrowing so the dashboard still sees a status=0 row — unless it
      // targets our own ingest host (no recursion).
      if (!_isOwnIngest(_overrides.ingestHost, url)) {
        try {
          _overrides.record(
            method: method,
            host: url.host + (url.hasPort ? ':${url.port}' : ''),
            path: url.path.isEmpty ? '/' : url.path,
            statusCode: 0,
            durationMs: 0,
            traceId: _overrides.traceId(),
            requestId: _overrides.hexId(16),
            spanId: _overrides.hexId(8),
            parentSpanId: _overrides.currentSpanId(),
            errorFingerprint: e.runtimeType.toString(),
          );
        } catch (_) {}
      }
      rethrow;
    }
    if (_isOwnIngest(_overrides.ingestHost, url)) {
      return request;
    }
    return _wrap(request, method, url);
  }

  HttpClientRequest _wrap(HttpClientRequest request, String method, Uri url) {
    try {
      final traceId = _overrides.traceId();
      final spanId = _overrides.hexId(8);
      final requestId = _overrides.hexId(16);
      final parentSpanId = _overrides.currentSpanId();
      // Header injection + stopwatch start are deferred to `close()` (just
      // before the request is sent) so headers the caller sets AFTER `openUrl`
      // returns — the normal pattern: `final req = await client.getUrl(...);
      // req.headers.set(...)` — are not clobbered, and the merged `baggage`
      // reflects whatever the caller added.
      return _AllStakHttpClientRequest(
        request,
        _overrides,
        method: method,
        url: url,
        traceId: traceId,
        requestId: requestId,
        spanId: spanId,
        parentSpanId: parentSpanId,
      );
    } catch (_) {
      // Fail-open: any instrumentation error returns the untouched request.
      return request;
    }
  }

  // ── Everything below simply forwards to the inner client ────────────────

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Delegating [HttpClientRequest] that records the outcome when `close()`
/// resolves the response (or fails). Forwards all other members to [_inner].
class _AllStakHttpClientRequest implements HttpClientRequest {
  _AllStakHttpClientRequest(
    this._inner,
    this._overrides, {
    required this.method,
    required this.url,
    required this.traceId,
    required this.requestId,
    required this.spanId,
    required this.parentSpanId,
  });

  final HttpClientRequest _inner;
  final AllStakHttpOverrides _overrides;
  @override
  final String method;
  final Uri url;
  final String traceId;
  final String requestId;
  final String spanId;
  final String? parentSpanId;
  final Stopwatch _stopwatch = Stopwatch();

  String get _host => url.host + (url.hasPort ? ':${url.port}' : '');
  String get _path => url.path.isEmpty ? '/' : url.path;

  /// Inject the distributed-trace headers just before the request is sent so a
  /// caller's post-`openUrl` `headers.set('baggage', ...)` is merged, not lost.
  void _injectHeaders() {
    try {
      final headers = _inner.headers;
      if (headers.value('traceparent') == null) {
        headers.set('traceparent', '00-$traceId-$spanId-01');
      }
      if (headers.value('x-allstak-trace-id') == null) {
        headers.set('x-allstak-trace-id', traceId);
      }
      if (headers.value('x-allstak-request-id') == null) {
        headers.set('x-allstak-request-id', requestId);
      }
      if (headers.value('x-allstak-span-id') == null) {
        headers.set('x-allstak-span-id', spanId);
      }
      headers.set(
          'baggage',
          _overrides.mergeBaggage(
              headers.value('baggage'), traceId, requestId, spanId));
      headers.set('allstak-baggage',
          _overrides.allstakBaggage(traceId, requestId, spanId));
    } catch (_) {
      // Fail-open: header injection must never break the request.
    }
  }

  void _emit(int statusCode, {String? errorFingerprint}) {
    try {
      _stopwatch.stop();
      _overrides.record(
        method: method,
        host: _host,
        path: _path,
        statusCode: statusCode,
        durationMs: _stopwatch.elapsedMilliseconds,
        traceId: traceId,
        requestId: requestId,
        spanId: spanId,
        parentSpanId: parentSpanId,
        errorFingerprint: errorFingerprint,
      );
    } catch (_) {
      // Fail-open: capture must never break the request.
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    _injectHeaders();
    _stopwatch.start();
    try {
      final response = await _inner.close();
      _emit(response.statusCode);
      return response;
    } catch (e) {
      _emit(0, errorFingerprint: e.runtimeType.toString());
      rethrow;
    }
  }

  @override
  Future<HttpClientResponse> get done => _inner.done;

  // ── Forward the streaming/IOSink surface to the inner request ───────────

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Uri get uri => _inner.uri;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}
