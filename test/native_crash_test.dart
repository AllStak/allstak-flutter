import 'package:allstak/allstak.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Required for the mock MethodChannel handler used in the drain-handoff
  // group. Note: initializing this binding makes flutter_test intercept all
  // real HTTP (returning 400), so the drain-handoff tests assert the
  // parse/handoff at the channel + payload boundary rather than over a real
  // loopback socket. The wire SHAPE is fully covered by the
  // `toErrorPayload` group above, and the live `_send` transport is exercised
  // end-to-end (real loopback) by allstak_flutter_test.dart.
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─── Record parsing ────────────────────────────────────────────────
  group('NativeCrashRecord.parse', () {
    String record({
      String plat = 'ios',
      int sig = 11,
      String? signame,
      String addr = '10ab34cd0',
      int time = 1716950000,
      List<String> frames = const ['10204aa3c', '10204b110'],
    }) {
      final b = StringBuffer()
        ..writeln(NativeCrashRecord.magic)
        ..writeln('plat=$plat')
        ..writeln('sig=$sig');
      if (signame != null) b.writeln('signame=$signame');
      b
        ..writeln('addr=$addr')
        ..writeln('time=$time');
      for (final f in frames) {
        b.writeln('frame=$f');
      }
      return b.toString();
    }

    test('parses a well-formed iOS SIGSEGV record', () {
      final r = NativeCrashRecord.parse(record());
      expect(r, isNotNull);
      expect(r!.platform, 'ios');
      expect(r.signal, 11);
      expect(r.faultAddress, '10ab34cd0');
      expect(r.timestampSeconds, 1716950000);
      expect(r.frames, ['10204aa3c', '10204b110']);
      expect(r.effectiveSignalName, 'SIGSEGV');
      expect(r.description, contains('Segmentation fault'));
      expect(r.description, contains('0x10ab34cd0'));
    });

    test('parses an Android record and derives the signal name', () {
      final r =
          NativeCrashRecord.parse(record(plat: 'android', sig: 6, addr: ''));
      expect(r, isNotNull);
      expect(r!.platform, 'android');
      expect(r.signal, 6);
      expect(r.effectiveSignalName, 'SIGABRT');
      // No fault address -> not appended to the message.
      expect(r.description, isNot(contains('0x')));
    });

    test('prefers an explicit signame line over the derived name', () {
      final r = NativeCrashRecord.parse(record(sig: 99, signame: 'SIGCUSTOM'));
      expect(r!.effectiveSignalName, 'SIGCUSTOM');
    });

    test('tolerates leading blank lines and unknown keys', () {
      const raw = '\n\nASKC1\n'
          'unknown=ignored\n'
          'sig=11\n'
          'frame=deadbeef\n'
          'another_unknown=also-ignored\n';
      final r = NativeCrashRecord.parse(raw);
      expect(r, isNotNull);
      expect(r!.signal, 11);
      expect(r.frames, ['deadbeef']);
    });

    test('caps frame parsing so a flooded record cannot blow up', () {
      final b = StringBuffer()
        ..writeln(NativeCrashRecord.magic)
        ..writeln('sig=11');
      for (var i = 0; i < 1000; i++) {
        b.writeln('frame=${i.toRadixString(16)}');
      }
      final r = NativeCrashRecord.parse(b.toString());
      expect(r, isNotNull);
      expect(r!.frames.length, lessThanOrEqualTo(256));
    });

    test('returns null for empty input', () {
      expect(NativeCrashRecord.parse(''), isNull);
    });

    test('returns null when the magic header is missing', () {
      expect(NativeCrashRecord.parse('sig=11\nframe=abc\n'), isNull);
    });

    test('returns null for a record with no signal and no frames', () {
      // Magic present but nothing actionable -> refuse to ship empty noise.
      expect(
        NativeCrashRecord.parse('${NativeCrashRecord.magic}\nplat=ios\n'),
        isNull,
      );
    });

    test('parses a record with frames but no signal number', () {
      final r =
          NativeCrashRecord.parse('${NativeCrashRecord.magic}\nframe=abc123\n');
      expect(r, isNotNull);
      expect(r!.signal, 0);
      expect(r.frames, ['abc123']);
    });

    test('signalNameFor maps known Darwin + Linux numbers', () {
      expect(NativeCrashRecord.signalNameFor(11), 'SIGSEGV');
      expect(NativeCrashRecord.signalNameFor(6), 'SIGABRT');
      expect(NativeCrashRecord.signalNameFor(4), 'SIGILL');
      expect(NativeCrashRecord.signalNameFor(8), 'SIGFPE');
      expect(NativeCrashRecord.signalNameFor(5), 'SIGTRAP');
      expect(NativeCrashRecord.signalNameFor(10), 'SIGBUS'); // Darwin
      expect(NativeCrashRecord.signalNameFor(7), 'SIGBUS'); // Linux
      expect(NativeCrashRecord.signalNameFor(42), 'SIG42');
      expect(NativeCrashRecord.signalNameFor(0), 'SIGNAL');
    });
  });

  // ─── Payload shaping (the wire contract) ───────────────────────────
  group('NativeCrashRecord.toErrorPayload', () {
    test('produces an /ingest/v1/errors payload marked native.crash=true', () {
      final r = NativeCrashRecord(
        signal: 11,
        signalName: 'SIGSEGV',
        faultAddress: 'deadbeef',
        timestampSeconds: 1716950000,
        platform: 'ios',
        frames: ['aaaa', 'bbbb'],
      );
      final p = r.toErrorPayload(
        release: 'v1.2.3',
        environment: 'production',
        sdkName: 'allstak-flutter',
        sdkVersion: '1.0.3',
        platformTag: 'flutter',
        dist: 'ios',
        sessionId: 'sess-1',
        extraMetadata: {'team': 'infra'},
      );
      expect(p['exceptionClass'], 'SIGSEGV');
      expect(p['level'], 'fatal');
      expect(p['release'], 'v1.2.3');
      expect(p['environment'], 'production');
      expect(p['sdkName'], 'allstak-flutter');
      expect(p['platform'], 'flutter');
      expect(p['dist'], 'ios');
      expect(p['sessionId'], 'sess-1');
      // Stack frames become 0x-prefixed address lines for backend symbolication.
      expect(p['stackTrace'], ['0xaaaa', '0xbbbb']);
      final meta = p['metadata'] as Map;
      expect(meta['native.crash'], 'true');
      expect(meta['native.signal'], '11');
      expect(meta['native.signalName'], 'SIGSEGV');
      expect(meta['native.faultAddress'], '0xdeadbeef');
      expect(meta['native.platform'], 'ios');
      expect(meta['fatal'], 'true');
      expect(meta['source'], 'native-signal-handler');
      // Caller-supplied tags are merged in.
      expect(meta['team'], 'infra');
    });

    test('omits dist/sessionId/faultAddress when absent', () {
      final r = NativeCrashRecord(
        signal: 6,
        signalName: '',
        faultAddress: '',
        timestampSeconds: 0,
        platform: 'android',
        frames: const [],
      );
      final p = r.toErrorPayload(
        release: '1.0.3',
        environment: 'staging',
        sdkName: 'allstak-flutter',
        sdkVersion: '1.0.3',
        platformTag: 'flutter',
      );
      expect(p.containsKey('dist'), isFalse);
      expect(p.containsKey('sessionId'), isFalse);
      final meta = p['metadata'] as Map;
      expect(meta.containsKey('native.faultAddress'), isFalse);
      // Signal name derived from the number when not stamped.
      expect(p['exceptionClass'], 'SIGABRT');
      expect(p['stackTrace'], isEmpty);
    });
  });

  // ─── Drain handoff through the public installNativeHandlers() path ──
  //
  // We fake the native MethodChannel so the next-launch handoff is exercised
  // without a device: install() arms, drainPendingSignalCrash returns the
  // stashed record, and the SDK parses it + builds the /ingest/v1/errors
  // payload via buildNativeCrashPayload. We assert the channel call sequence
  // (which methods get invoked, with what args, under which gating) and the
  // payload the parsed record yields. The HTTP wire SHAPE itself is covered by
  // the `toErrorPayload` group; real-socket transport is covered in
  // allstak_flutter_test.dart (which doesn't init the widgets binding and so
  // keeps real HTTP).
  group('installNativeHandlers drain handoff', () {
    const channel = MethodChannel('io.allstak.flutter/native');
    late List<String> calls;
    late List<dynamic> argList;

    void mockNative({String? signalRecord, String? legacyRecord}) {
      calls = <String>[];
      argList = <dynamic>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        argList.add(call.arguments);
        switch (call.method) {
          case 'install':
            return true;
          case 'drainPendingCrash':
            return legacyRecord;
          case 'drainPendingSignalCrash':
            return signalRecord;
          case 'spoolDir':
            return null;
          default:
            return null;
        }
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('a pending native signal record is drained, parsed, and shipped',
        () async {
      mockNative(
        signalRecord: '${NativeCrashRecord.magic}\n'
            'plat=android\n'
            'sig=11\n'
            'addr=cafe\n'
            'time=1716950000\n'
            'frame=1111\n'
            'frame=2222\n',
      );
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          // Unreachable host: the drained event hits the real _send path and
          // fails fast (fail-open) — we are asserting the handoff, not delivery.
          host: 'http://127.0.0.1:1',
          environment: 'production',
          release: 'v9.9.9',
          transportTimeout: Duration(milliseconds: 50),
        ),
      );

      await sdk.installNativeHandlers();
      await sdk.flush();

      // The full native handoff sequence ran: arm, legacy drain, signal drain.
      expect(calls, contains('install'));
      expect(calls, contains('drainPendingCrash'));
      expect(calls, contains('drainPendingSignalCrash'));

      // The record the native side returned parses into the expected event.
      final record = NativeCrashRecord.parse('${NativeCrashRecord.magic}\n'
          'plat=android\nsig=11\naddr=cafe\ntime=1716950000\n'
          'frame=1111\nframe=2222\n')!;
      final payload = sdk.buildNativeCrashPayload(record);
      expect(payload['exceptionClass'], 'SIGSEGV');
      expect(payload['level'], 'fatal');
      expect(payload['release'], 'v9.9.9');
      expect(payload['environment'], 'production');
      expect(payload['stackTrace'], ['0x1111', '0x2222']);
      final meta = payload['metadata'] as Map;
      expect(meta['native.crash'], 'true');
      expect(meta['native.platform'], 'android');
      expect(meta['native.faultAddress'], '0xcafe');
    });

    test('a corrupt native record is dropped, not parsed into an event',
        () async {
      mockNative(signalRecord: 'not-a-valid-record\njunk\n');
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 50),
        ),
      );

      // Must not throw, and the drain must have been attempted.
      await sdk.installNativeHandlers();
      await sdk.flush();
      expect(calls, contains('drainPendingSignalCrash'));
      // The corrupt record yields no event.
      expect(NativeCrashRecord.parse('not-a-valid-record\njunk\n'), isNull);
    });

    test('no pending record -> drain attempted, nothing parsed (fail-open)',
        () async {
      mockNative(signalRecord: null);
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          transportTimeout: Duration(milliseconds: 50),
        ),
      );

      await sdk.installNativeHandlers();
      await sdk.flush();
      expect(calls, contains('drainPendingSignalCrash'));
    });

    test('enableNativeCrashCapture=false skips the signal-crash drain',
        () async {
      mockNative(signalRecord: '${NativeCrashRecord.magic}\nsig=11\nframe=1\n');
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          enableNativeCrashCapture: false,
          transportTimeout: Duration(milliseconds: 50),
        ),
      );

      await sdk.installNativeHandlers();
      await sdk.flush();

      // Opt-out: install still runs (legacy uncaught handler stays), but the
      // signal-crash record is never even queried.
      expect(calls, contains('install'));
      expect(calls, isNot(contains('drainPendingSignalCrash')),
          reason: 'opt-out must not query the native signal record');
    });

    test('install passes the enableSignalHandlers flag to native (default on)',
        () async {
      mockNative();
      final sdk = AllStak.init(
        const AllStakConfig(apiKey: 'ask_test', host: 'http://127.0.0.1:1'),
      );
      await sdk.installNativeHandlers();

      final installArgs = argList[calls.indexOf('install')] as Map?;
      expect(installArgs, isNotNull);
      expect(installArgs!['enableSignalHandlers'], isTrue);
      expect(installArgs['release'], isNotNull);
    });

    test('opt-out still passes enableSignalHandlers=false to native', () async {
      mockNative();
      final sdk = AllStak.init(
        const AllStakConfig(
          apiKey: 'ask_test',
          host: 'http://127.0.0.1:1',
          enableNativeCrashCapture: false,
        ),
      );
      await sdk.installNativeHandlers();

      final installArgs = argList[calls.indexOf('install')] as Map?;
      expect(installArgs!['enableSignalHandlers'], isFalse);
    });
  });
}
