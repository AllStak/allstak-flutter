# allstak_flutter Android

Android native crash support is included with `allstak_flutter`.

Most apps only need the Dart setup from the package root README:

```dart
AllStak.runApp(
  const AllStakConfig(apiKey: String.fromEnvironment('ALLSTAK_API_KEY')),
  () => runApp(const MyApp()),
);
```

After installing the package, rebuild the Android app so the native plugin is included:

```bash
flutter clean
flutter run --dart-define=ALLSTAK_API_KEY=ask_live_xxx
```

The native handler stores crash information across process restarts and sends it on the next launch.
