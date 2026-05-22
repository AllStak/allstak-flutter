# allstak_flutter

AllStak SDK for Flutter and Dart apps. Captures Flutter errors, unhandled Dart errors, logs, outbound HTTP requests, route breadcrumbs, and native crashes.

## Install

```bash
flutter pub add allstak_flutter
```

## Setup

```dart
import 'package:allstak_flutter/allstak_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  AllStak.runApp(
    const AllStakConfig(
      apiKey: String.fromEnvironment('ALLSTAK_API_KEY'),
      environment: 'production',
      release: String.fromEnvironment('ALLSTAK_RELEASE'),
      service: 'mobile',
    ),
    () => runApp(const MyApp()),
  );
}
```

Run with:

```bash
flutter run \
  --dart-define=ALLSTAK_API_KEY=ask_live_xxx \
  --dart-define=ALLSTAK_RELEASE=myapp@1.0.0
```

## HTTP client

```dart
final client = AllStak.instance!.httpClient();
final response = await client.get(Uri.parse('https://api.example.com/orders'));
```

## Manual capture

```dart
await AllStak.instance?.captureLog('info', 'checkout opened');
await AllStak.instance?.captureException(
  StateError('checkout failed'),
  stackTrace: StackTrace.current.toString(),
  context: {'screen': 'checkout'},
);
await AllStak.instance?.flush();
```

## Navigation breadcrumbs

```dart
MaterialApp(
  navigatorObservers: [AllStakNavigatorObserver()],
  home: const HomePage(),
);
```

## Configuration

| Option | Description |
| --- | --- |
| `apiKey` | Project API key. |
| `host` | Optional ingest host override for self-hosted AllStak. |
| `environment` | Deployment environment. |
| `release` | App version or commit SHA. |
| `service` | Logical app service name. |
| `tags` | Tags added to telemetry. |
| `transportTimeout` | Per-request timeout. |

## Privacy

The SDK redacts common sensitive headers and fields. Avoid putting secrets in custom metadata.

## Troubleshooting

- No events: confirm `--dart-define=ALLSTAK_API_KEY=...` is present for the target build.
- Native crashes missing: rebuild the native app after installing the package.
- Source maps missing: keep runtime `release` aligned with uploaded build artifacts.

## License

MIT
