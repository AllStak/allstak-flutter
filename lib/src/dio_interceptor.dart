/// Optional Dio interceptor helper — DEPENDENCY-FREE.
///
/// Dio's default adapter (`IOHttpClientAdapter`) runs on `dart:io`'s
/// `HttpClient`, so when `enableHttpOverrides` is on (the default) **Dio calls
/// are already auto-instrumented** by `AllStakHttpOverrides` with zero extra
/// code — this file is only needed when an app:
///   * disabled the global HTTP overrides, or
///   * uses a non-`dart:io` Dio adapter (e.g. a custom/Web adapter), or
///   * wants the capture tied to Dio's own request lifecycle.
///
/// To stay dependency-light this SDK does NOT import `package:dio`. Instead it
/// exposes [allStakDioInterceptor], which builds an `InterceptorsWrapper`-shaped
/// object via a factory the host app supplies — so this file compiles and
/// analyzes cleanly with or without Dio on the classpath.
///
/// Usage (with Dio present):
/// ```dart
/// import 'package:dio/dio.dart';
///
/// final dio = Dio();
/// final i = allStakDioInterceptor(
///   wrapperFactory: ({onRequest, onResponse, onError}) => InterceptorsWrapper(
///     onRequest: onRequest, onResponse: onResponse, onError: onError),
/// );
/// if (i != null) dio.interceptors.add(i as Interceptor);
/// ```
library;

/// Distributed-trace ids the SDK mints for one outbound request.
class DioSpanIds {
  const DioSpanIds({
    required this.traceId,
    required this.requestId,
    required this.spanId,
    this.parentSpanId,
  });
  final String traceId;
  final String requestId;
  final String spanId;
  final String? parentSpanId;
}

/// Minimal seam the interceptor uses to talk to the SDK without importing the
/// top-level library (avoids a cycle). The `AllStak` client implements it.
abstract class DioTelemetrySink {
  /// Mint a fresh outbound span joined to the active trace.
  DioSpanIds beginOutboundSpan();

  /// Record one completed outbound request. Fail-open / fire-and-forget.
  void recordOutbound({
    required String method,
    required String host,
    required String path,
    required int statusCode,
    required int durationMs,
    required DioSpanIds ids,
    String? errorFingerprint,
  });
}

/// Factory the host app supplies that constructs a Dio `InterceptorsWrapper`
/// from the three lifecycle callbacks. Kept as a `Function` so this file never
/// imports `package:dio`. The callbacks use the standard Dio signatures
/// `(options, handler)` / `(response, handler)` / `(err, handler)`.
typedef DioWrapperFactory = Object Function({
  required void Function(dynamic options, dynamic handler) onRequest,
  required void Function(dynamic response, dynamic handler) onResponse,
  required void Function(dynamic err, dynamic handler) onError,
});

/// Builds a Dio interceptor wired to [sink] (an `AllStak` client) that injects
/// trace headers outbound and records an outbound http-request on
/// response/error. Returns `null` when [sink] is null. Duck-typed so it links
/// without `package:dio`.
Object? allStakDioInterceptor({
  required DioWrapperFactory wrapperFactory,
  required DioTelemetrySink? sink,
}) {
  if (sink == null) return null;
  final stopwatches = <Object, Stopwatch>{};

  return wrapperFactory(
    onRequest: (dynamic options, dynamic handler) {
      try {
        final ids = sink.beginOutboundSpan();
        final headers = options.headers as Map?;
        if (headers != null) {
          headers.putIfAbsent(
              'traceparent', () => '00-${ids.traceId}-${ids.spanId}-01');
          headers.putIfAbsent('x-allstak-trace-id', () => ids.traceId);
          headers.putIfAbsent('x-allstak-request-id', () => ids.requestId);
          headers.putIfAbsent('x-allstak-span-id', () => ids.spanId);
        }
        stopwatches[options] = Stopwatch()..start();
        (options.extra as Map)['__allstak_ids'] = ids;
      } catch (_) {}
      handler.next(options);
    },
    onResponse: (dynamic response, dynamic handler) {
      try {
        _record(sink, stopwatches, response.requestOptions,
            statusCode: (response.statusCode as int?) ?? 0);
      } catch (_) {}
      handler.next(response);
    },
    onError: (dynamic err, dynamic handler) {
      try {
        final response = err.response;
        _record(sink, stopwatches, err.requestOptions,
            statusCode:
                response != null ? ((response.statusCode as int?) ?? 0) : 0,
            errorFingerprint: err.type?.toString());
      } catch (_) {}
      handler.next(err);
    },
  );
}

void _record(
  DioTelemetrySink sink,
  Map<Object, Stopwatch> stopwatches,
  dynamic options, {
  required int statusCode,
  String? errorFingerprint,
}) {
  final sw = stopwatches.remove(options);
  sw?.stop();
  final ids = (options.extra as Map)['__allstak_ids'];
  if (ids is! DioSpanIds) return;
  final uri = options.uri as Uri;
  sink.recordOutbound(
    method: (options.method as String?) ?? 'GET',
    host: uri.host + (uri.hasPort ? ':${uri.port}' : ''),
    path: uri.path.isEmpty ? '/' : uri.path,
    statusCode: statusCode,
    durationMs: sw?.elapsedMilliseconds ?? 0,
    ids: ids,
    errorFingerprint: errorFingerprint,
  );
}
