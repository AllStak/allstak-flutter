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

## Release identifier (automatic)

You can omit `release` entirely and let the SDK resolve it. Order, highest first:

1. **Explicit** `release:` you pass to `AllStakConfig` — always wins.
2. **`ALLSTAK_RELEASE` dart-define** — `--dart-define=ALLSTAK_RELEASE=...`,
   read at build time. This is the automatic mechanism.
3. **SDK version** (`kAllStakSdkVersion`) as a last resort, so `release` is
   never empty. (SDK version is *not* your app version — last resort only.)

Set `autoDetectRelease: false` to opt out of steps 2–3 (only an explicit
release is ever sent).

**Honest note on mobile.** A shipped `.ipa`/`.apk`/web bundle has no `.git`
directory and no `git` binary, so runtime git detection is impossible in
production. Reading the app's *store* version at runtime would require a
platform plugin (e.g. `package_info_plus`), which this SDK deliberately does
**not** depend on to stay dependency-light. So the automatic mechanism is the
build-time `ALLSTAK_RELEASE` dart-define. To get the real app version or a git
SHA into events, pass it explicitly or via the dart-define, e.g.:

```bash
flutter build apk --dart-define=ALLSTAK_RELEASE=1.4.2+$(git rev-parse --short HEAD)
```

If your app already depends on `package_info_plus`, read the version there and
pass it as `release:` (step 1) — the SDK won't add that dependency for you.

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
| `environment` | Deployment environment. |
| `release` | App version or commit SHA. Omit to auto-detect (see "Release identifier"). |
| `autoDetectRelease` | Default `true`. When `release` is empty, resolve from the `ALLSTAK_RELEASE` dart-define, then the SDK version. Set `false` to opt out. |
| `service` | Logical app service name. |
| `tags` | Tags added to telemetry. |
| `transportTimeout` | Per-request timeout. |

## Privacy

The SDK redacts common sensitive headers and fields. Avoid putting secrets in custom metadata.

## Troubleshooting

- No events: confirm `--dart-define=ALLSTAK_API_KEY=...` is present for the target build.
- Native crashes missing: rebuild the native app after installing the package.
- Source maps missing: keep runtime `release` aligned with uploaded build artifacts.

## Contributing and Support

- Report bugs with the GitHub bug report template: https://github.com/AllStak/allstak-flutter/issues/new/choose
- Open pull requests using the checklist in [CONTRIBUTING.md](CONTRIBUTING.md).
- Report security vulnerabilities privately through [SECURITY.md](SECURITY.md).

## License

MIT
