/// AllStak SDK for Flutter / Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' hide runApp;
import 'package:flutter/widgets.dart' as widgets show runApp;
import 'package:http/http.dart' as http;

import 'sanitizer.dart';

AllStak? _instance;

/// Thin wrapper so the MethodChannel name lives in one place and can be
/// swapped for tests. Kept private to the library.
class _NativeChannel {
  static const MethodChannel channel = MethodChannel(
    'io.allstak.flutter/native',
  );
}

/// SDK identity sent on the wire as `sdk.name` / `sdk.version` in event metadata.
const String kAllStakSdkName = 'allstak-flutter';
const String kAllStakSdkVersion = '1.2.0';

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
  });

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
  final List<Future<void>> _pendingRequests = [];

  AllStak._(this.config) {
    _tags.addAll(config.tags);
    // Release-tracking metadata is stamped onto _tags once at init so every
    // outgoing event payload (errors, logs, http, db) picks it up via the
    // existing `metadata` merge — no per-call wiring needed in callers.
    _tags.addAll(config.releaseTags());
    if (!_tags.containsKey('platform')) {
      _tags['platform'] = 'flutter';
    }
  }

  static AllStak init(AllStakConfig config) {
    final sdk = AllStak._(config);
    _instance = sdk;
    return sdk;
  }

  static AllStak? get instance => _instance;

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
            sdk.captureException(
              details.exceptionAsString(),
              stackTrace: details.stack?.toString() ?? '',
              context: {
                'source': 'FlutterError.onError',
                'library': details.library ?? 'flutter',
              },
            );
          } catch (_) {}
          previousOnError?.call(details);
        };

        PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
          try {
            sdk.captureException(
              error.toString(),
              stackTrace: stack.toString(),
              context: {'source': 'PlatformDispatcher.onError'},
            );
          } catch (_) {}
          return false;
        };

        widgets.runApp(appBuilder());
      },
      (error, stack) {
        try {
          sdk.captureException(
            error.toString(),
            stackTrace: stack.toString(),
            context: {'source': 'runZonedGuarded'},
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

  Future<void> captureException(
    Object error, {
    String? stackTrace,
    Map<String, String>? context,
  }) async {
    final className = error is Error
        ? error.runtimeType.toString()
        : error is Exception
        ? error.runtimeType.toString()
        : 'DartError';
    final message = error is String ? error : error.toString();
    final rawStack =
        stackTrace ??
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
    _sendBestEffort('/ingest/v1/errors', {
      'exceptionClass': className,
      'message': message,
      // Backend expects `stackTrace: List<String>`, not a single `stacktrace` string.
      'stackTrace': stackLines,
      'environment': config.environment,
      'release': config.release,
      'level': 'error',
      // Phase 3 — top-level v2 ingest fields.
      'sdkName': config.sdkName,
      'sdkVersion': config.sdkVersion,
      'platform': config.platform,
      if (config.dist.isNotEmpty) 'dist': config.dist,
      if (structured.isNotEmpty) 'frames': structured,
      'user': {
        if (_userId != null) 'id': _userId,
        if (_userEmail != null) 'email': _userEmail,
      },
      'metadata': {..._tags, if (context != null) ...context},
      if (crumbs != null) 'breadcrumbs': crumbs,
    });
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
    _sendBestEffort('/ingest/v1/errors', {
      'exceptionClass': 'Message',
      'message': message,
      'environment': config.environment,
      'release': config.release,
      'level': level,
      // Phase 3 — top-level v2 ingest fields.
      'sdkName': config.sdkName,
      'sdkVersion': config.sdkVersion,
      'platform': config.platform,
      if (config.dist.isNotEmpty) 'dist': config.dist,
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
  }) async {
    final effectiveTraceId = traceId ?? _hexId(16);
    final effectiveRequestId = requestId ?? effectiveTraceId;
    _sendBestEffort('/ingest/v1/http-requests', {
      'requests': [
        {
          'traceId': effectiveTraceId,
          if (spanId != null) 'spanId': spanId,
          'direction': direction,
          'method': method,
          'host': host,
          'path': path,
          'statusCode': statusCode,
          'durationMs': durationMs,
          'requestSize': 0,
          'responseSize': 0,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'environment': config.environment,
          'release': config.release,
          'metadata': {..._tags, 'requestId': effectiveRequestId},
        },
      ],
    });
  }

  String _hexId(int bytes) {
    final raw = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return raw.padLeft(bytes * 2, '0').substring(0, bytes * 2);
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
      await channel.invokeMethod('install', {'release': config.release});
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
    final url = Uri.parse('${config.host}$path');
    final merged = {
      ...payload,
      'metadata': {
        ...((payload['metadata'] as Map?) ?? const {}),
        'device.platform': _platformTag(),
      },
    };
    // Scrub the full wire payload before serialization. One chokepoint
    // protects every telemetry type (errors, logs, http, native crashes).
    // Pure (no mutation), mobile-safe (synchronous), fail-open.
    Map<String, dynamic> scrubbed;
    try {
      final out = scrub(merged);
      scrubbed = out is Map<String, dynamic>
          ? out
          : (out is Map ? Map<String, dynamic>.from(out) : merged);
    } catch (sanErr) {
      if (config.debug) {
        // ignore: avoid_print
        print('[AllStak] sanitizer failed; sending raw: $sanErr');
      }
      scrubbed = merged;
    }
    final body = jsonEncode(scrubbed);
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'X-AllStak-Key': config.apiKey,
              'User-Agent': 'allstak-flutter/1.0.0',
            },
            body: body,
          )
          .timeout(config.transportTimeout);
      if (config.debug) {
        final trim = res.body.length > 160
            ? res.body.substring(0, 160)
            : res.body;
        // ignore: avoid_print
        print('[AllStak] POST $path -> ${res.statusCode} $trim');
      }
    } catch (e) {
      if (config.debug) {
        // ignore: avoid_print
        print('[AllStak] POST $path failed: $e');
      }
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
    final traceId = _allstak._hexId(16);
    final spanId = _allstak._hexId(8);
    final requestId = traceId;
    if (!isOwnIngest) {
      request.headers.putIfAbsent(
        'traceparent',
        () => '00-$traceId-$spanId-01',
      );
      request.headers.putIfAbsent('x-allstak-trace-id', () => traceId);
      request.headers.putIfAbsent('x-allstak-request-id', () => requestId);
    }
    final sw = Stopwatch()..start();
    try {
      final resp = await _inner.send(request);
      sw.stop();
      if (!isOwnIngest) {
        // fire-and-forget — don't block the caller on ingest
        _allstak.captureRequest(
          method: request.method,
          host:
              request.url.host +
              (request.url.hasPort ? ':${request.url.port}' : ''),
          path: request.url.path.isEmpty ? '/' : request.url.path,
          statusCode: resp.statusCode,
          durationMs: sw.elapsedMilliseconds,
          direction: 'outbound',
          traceId: traceId,
          requestId: requestId,
          spanId: spanId,
        );
      }
      return resp;
    } catch (e) {
      sw.stop();
      if (!isOwnIngest) {
        _allstak.captureRequest(
          method: request.method,
          host:
              request.url.host +
              (request.url.hasPort ? ':${request.url.port}' : ''),
          path: request.url.path.isEmpty ? '/' : request.url.path,
          statusCode: 0,
          durationMs: sw.elapsedMilliseconds,
          direction: 'outbound',
          traceId: traceId,
          requestId: requestId,
          spanId: spanId,
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
