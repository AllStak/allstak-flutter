# allstak_flutter

**Crash reporting and logs for Flutter apps. iOS, Android, and web from a single SDK.**

[![pub.dev](https://img.shields.io/pub/v/allstak_flutter.svg)](https://pub.dev/packages/allstak_flutter)
[![CI](https://github.com/AllStak/allstak-flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/AllStak/allstak-flutter/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Official AllStak SDK for Flutter and Dart — captures Flutter framework errors, unhandled Dart zone errors, HTTP requests, and structured logs, with iOS and Android native crash hooks.

## Dashboard

View captured events live at [app.allstak.sa](https://app.allstak.sa).

![AllStak dashboard](https://app.allstak.sa/images/dashboard-preview.png)

## Features

- `FlutterError.onError` + `runZonedGuarded` error capture via `AllStak.runApp`
- `PlatformDispatcher.onError` async error capture
- Native crash hooks on iOS (Obj-C/Swift) and Android (Java/Kotlin)
- `http` client wrapper for outbound request telemetry
- Navigator observer for route breadcrumbs
- User, tag, and breadcrumb context helpers
- Dart SDK 3.0+, Flutter 3.0+

## What You Get

Once integrated, every event flows to your AllStak dashboard:

- **Dart errors** — Flutter framework errors, unhandled zone errors, stack traces
- **Native crashes** — iOS (Obj-C/Swift) and Android (Java/Kotlin) fatals
- **Logs** — structured logs with search and filters
- **HTTP** — outbound `http` client timing, status codes, failed calls
- **Route breadcrumbs** — navigator transitions before each crash
- **Alerts** — email and webhook notifications on regressions

## Installation

```bash
flutter pub add allstak_flutter
```

## Quick Start

> Create a project at [app.allstak.sa](https://app.allstak.sa) to get your API key.

```dart
import 'package:allstak_flutter/allstak_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  AllStak.runApp(
    const AllStakConfig(
      apiKey: 'YOUR_ALLSTAK_API_KEY',
      environment: 'production',
      release: 'myapp@1.0.0',
    ),
    () {
      AllStak.instance?.captureMessage('test: hello from allstak_flutter', level: 'info');
      runApp(const MyApp());
    },
  );
}
```

Run the app — the test event appears in your dashboard within seconds.

## Get Your API Key

1. Sign up at [app.allstak.sa](https://app.allstak.sa)
2. Create a project
3. Copy your API key from **Project Settings → API Keys**
4. Pass it as `apiKey` in `AllStakConfig(...)` (use `--dart-define=ALLSTAK_API_KEY=...` for env-style config)

## Configuration

| Option | Type | Required | Default | Description |
|---|---|---|---|---|
| `apiKey` | `String` | yes | — | Project API key (`ask_live_…`) |
| `host` | `String` | no | `https://api.allstak.sa` | Ingest host override |
| `environment` | `String` | no | `production` | Deployment env |
| `release` | `String` | no | `''` | App version |
| `service` | `String` | no | `flutter` | Logical service identifier |
| `tags` | `Map<String,String>` | no | `{}` | Default tags |
| `debug` | `bool` | no | `false` | Verbose SDK logging |

## Example Usage

Capture an exception:

```dart
try {
  await api.fetchFeed();
} catch (e, st) {
  AllStak.instance?.captureException(e.toString(), stackTrace: st.toString());
}
```

Send a message:

```dart
AllStak.instance?.captureMessage('User opened Settings', level: 'info');
```

Set user and tag:

```dart
AllStak.instance?.setUser(id: 'u_42', email: 'alice@example.com');
AllStak.instance?.setTag('release-channel', 'beta');
```

Wrap an `http.Client` for outbound capture:

```dart
final client = AllStak.instance!.httpClient();
final res = await client.get(Uri.parse('https://example.com/api'));
```

## Production Endpoint

Production endpoint: `https://api.allstak.sa`. Override via `host` for self-hosted deployments:

```dart
const AllStakConfig(
  apiKey: 'YOUR_ALLSTAK_API_KEY',
  host: 'https://allstak.mycorp.com',
)
```

## Links

- Documentation: https://docs.allstak.sa
- Dashboard: https://app.allstak.sa
- Source: https://github.com/AllStak/allstak-flutter

## License

MIT © AllStak
