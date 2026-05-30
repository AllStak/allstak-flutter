import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:allstak_flutter/sanitizer.dart';

void main() {
  group('Sanitizer', () {
    test('redacts top-level sensitive key', () {
      final out = scrub({'Authorization': 'Bearer abc'}) as Map;
      expect(out['Authorization'], kRedacted);
    });

    test('case-insensitive key match', () {
      final out =
          scrub({'X-Api-Key': 'k', 'PASSWORD': 'p', 'safe': 'v'}) as Map;
      expect(out['X-Api-Key'], kRedacted);
      expect(out['PASSWORD'], kRedacted);
      expect(out['safe'], 'v');
    });

    test('recurses into nested map', () {
      final out = scrub({
        'user': {'email': 'a@b', 'password': 'p'},
      }) as Map;
      expect((out['user'] as Map)['email'], 'a@b');
      expect((out['user'] as Map)['password'], kRedacted);
    });

    test('recurses into list', () {
      final out = scrub({
        'items': [
          {'token': 't'},
          {'safe': 'v'},
        ],
      }) as Map;
      final items = out['items'] as List;
      expect((items[0] as Map)['token'], kRedacted);
      expect((items[1] as Map)['safe'], 'v');
    });

    test('does not mutate caller', () {
      final input = {'Authorization': 'v'};
      scrub(input);
      expect(input['Authorization'], 'v');
    });

    test('cycle protection', () {
      final d = <String, Object?>{'a': 1};
      d['self'] = d;
      final out = scrub(d) as Map;
      expect(out['a'], 1);
      expect(out['self'], kRedacted);
    });

    test('covers canonical denylist', () {
      final input = <String, Object?>{};
      for (final term in kDefaultDenylist) {
        input[term] = 'leaky';
      }
      final out = scrub(input) as Map;
      for (final term in kDefaultDenylist) {
        expect(out[term], kRedacted, reason: 'term $term not redacted');
      }
    });

    test('canary should_not_leak_flutter', () {
      final input = {
        'metadata': {'api_key': 'should_not_leak_flutter'},
        'user': {'password': 'should_not_leak_flutter'},
      };
      final out = scrub(input);
      final serialized = jsonEncode(out);
      expect(serialized.contains('should_not_leak_flutter'), false);
    });

    test('extension denylist adds terms', () {
      final out =
          scrub({'custom_pii': 'v'}, extraDenylist: ['custom_pii']) as Map;
      expect(out['custom_pii'], kRedacted);
    });

    test('preserves AllStak sessionId correlation id (allowlist)', () {
      // The release-health sessionId must survive scrubbing so the backend
      // can mark the session errored/crashed. Exact camelCase match only.
      final out =
          scrub({'sessionId': 'ad72fed7c91318c49621a0e3a7201a64'}) as Map;
      expect(out['sessionId'], 'ad72fed7c91318c49621a0e3a7201a64');
    });

    test('lowercase sessionid / session_id are still redacted', () {
      // The allowlist is exact + case-sensitive, so denylisted lookalike keys
      // a host app might supply are still scrubbed.
      final out = scrub({
        'sessionid': 'leaky',
        'session_id': 'leaky',
        'session_token': 'leaky',
      }) as Map;
      expect(out['sessionid'], kRedacted);
      expect(out['session_id'], kRedacted);
      expect(out['session_token'], kRedacted);
    });

    test('primitive passthrough', () {
      expect(scrub(42), 42);
      expect(scrub('x'), 'x');
      expect(scrub(null), null);
    });
  });

  // ── Value-pattern scrubbing (value-pattern data scrubbing) ────────────────
  group('Value-pattern scrubbing', () {
    // Layer A — ALWAYS scrubbed (regardless of sendDefaultPii).

    test('credit card is redacted ONLY when it passes Luhn', () {
      // 4111111111111111 is the canonical Luhn-valid Visa test number.
      final out = scrub({'msg': 'card 4111111111111111 charged'}) as Map;
      expect(out['msg'], 'card $kRedacted charged');
    });

    test('credit card with space/hyphen separators is redacted (Luhn-valid)',
        () {
      final spaced = scrub({'m': 'pan 4111 1111 1111 1111 ok'}) as Map;
      expect(spaced['m'], 'pan $kRedacted ok');
      final hyphen = scrub({'m': 'pan 4111-1111-1111-1111 ok'}) as Map;
      expect(hyphen['m'], 'pan $kRedacted ok');
    });

    test('Luhn-INVALID digit run is PRESERVED (no order-id / timestamp nuking)',
        () {
      // 4111111111111112 fails Luhn -> must survive untouched.
      final out = scrub({'m': 'order 4111111111111112 placed'}) as Map;
      expect(out['m'], 'order 4111111111111112 placed');
      // 16-digit timestamp-ish / id run that fails Luhn is preserved.
      final id = scrub({'m': 'id 1234567890123456 done'}) as Map;
      expect(id['m'], 'id 1234567890123456 done');
    });

    test('short / long digit runs outside 13-19 are never CC-redacted', () {
      // 12 digits — too short.
      final short = scrub({'m': '123456789012'}) as Map;
      expect(short['m'], '123456789012');
      // 20 digits — too long.
      final long = scrub({'m': '12345678901234567890'}) as Map;
      expect(long['m'], '12345678901234567890');
    });

    test('US SSN WITH hyphens is redacted', () {
      final out = scrub({'note': 'ssn 123-45-6789 on file'}) as Map;
      expect(out['note'], 'ssn $kRedacted on file');
    });

    test('bare 9-digit number is NOT treated as an SSN', () {
      final out = scrub({'note': 'ref 123456789 ok'}) as Map;
      expect(out['note'], 'ref 123456789 ok');
    });

    test('CC + SSN are scrubbed even when sendDefaultPii is true', () {
      final out = scrub(
        {'m': 'pan 4111111111111111 ssn 123-45-6789'},
        options: const ScrubOptions(sendDefaultPii: true),
      ) as Map;
      expect(out['m'], 'pan $kRedacted ssn $kRedacted');
    });

    // Layer B — scrubbed UNLESS sendDefaultPii == true.

    test('email is redacted when sendDefaultPii is false (default)', () {
      final out = scrub({'msg': 'contact alice@example.com please'}) as Map;
      expect(out['msg'], 'contact $kRedacted please');
    });

    test('IPv4 is redacted when sendDefaultPii is false (default)', () {
      final out = scrub({'msg': 'from 192.168.1.42 ok'}) as Map;
      expect(out['msg'], 'from $kRedacted ok');
    });

    test('invalid-octet IPv4 is NOT redacted (precise validation)', () {
      // 999 is not a valid octet -> not an IP; must survive.
      final out = scrub({'msg': 'version 1.2.3.999 build'}) as Map;
      expect(out['msg'], 'version 1.2.3.999 build');
    });

    test('email is PRESERVED when sendDefaultPii is true', () {
      final out = scrub(
        {'msg': 'contact alice@example.com please'},
        options: const ScrubOptions(sendDefaultPii: true),
      ) as Map;
      expect(out['msg'], 'contact alice@example.com please');
    });

    test('IPv4 is PRESERVED when sendDefaultPii is true', () {
      final out = scrub(
        {'msg': 'from 192.168.1.42 ok'},
        options: const ScrubOptions(sendDefaultPii: true),
      ) as Map;
      expect(out['msg'], 'from 192.168.1.42 ok');
    });

    test('value scrubbing reaches nested metadata + breadcrumb data', () {
      final out = scrub({
        'metadata': {'note': 'reach me at bob@corp.io'},
        'breadcrumbs': [
          {
            'message': 'login from 10.0.0.5',
            'data': {'detail': 'card 4111111111111111'},
          },
        ],
      }) as Map;
      expect((out['metadata'] as Map)['note'], 'reach me at $kRedacted');
      final crumb = (out['breadcrumbs'] as List).first as Map;
      expect(crumb['message'], 'login from $kRedacted');
      expect((crumb['data'] as Map)['detail'], 'card $kRedacted');
    });

    // Exemptions — fields that must reach the wire VERBATIM.

    test('explicit setUser object is NOT value-scrubbed', () {
      // The whole `user` subtree is intentional identification: email + ip ship
      // as-is even with sendDefaultPii=false.
      final out = scrub({
        'user': {
          'id': 'u1',
          'email': 'real.user@example.com',
          'ip': '203.0.113.7',
        },
      }) as Map;
      final user = out['user'] as Map;
      expect(user['email'], 'real.user@example.com');
      expect(user['ip'], '203.0.113.7');
    });

    test('a denylisted key INSIDE the user subtree is still key-redacted', () {
      final out = scrub({
        'user': {'email': 'real@example.com', 'password': 'hunter2'},
      }) as Map;
      final user = out['user'] as Map;
      expect(user['email'], 'real@example.com'); // value not scrubbed
      expect(user['password'], kRedacted); // key-name redaction still wins
    });

    test('stack-frame paths/functions are NOT corrupted by value scrubbing',
        () {
      // A frame whose function/filename embeds IP-shaped or email-shaped text
      // must survive verbatim so symbolication still works.
      final out = scrub({
        'frames': [
          {
            'filename': 'package:app/net/192.168.1.1_client.dart',
            'absPath': 'package:app/net/192.168.1.1_client.dart',
            'function': 'connectTo(192.168.1.1)',
            'lineno': 42,
          },
        ],
      }) as Map;
      final frame = (out['frames'] as List).first as Map;
      expect(frame['filename'], 'package:app/net/192.168.1.1_client.dart');
      expect(frame['absPath'], 'package:app/net/192.168.1.1_client.dart');
      expect(frame['function'], 'connectTo(192.168.1.1)');
      expect(frame['lineno'], 42);
    });

    test('release / sdk / url identifier fields are NOT value-scrubbed', () {
      final out = scrub({
        'release': '1.2.3.4', // IP-shaped but a legitimate build id
        'sdkVersion': '1.0.3',
        'host': '10.0.0.1',
        'path': '/users/192.168.0.1',
        'url': 'https://192.168.0.1/cb?to=a@b.com',
      }) as Map;
      expect(out['release'], '1.2.3.4');
      expect(out['sdkVersion'], '1.0.3');
      expect(out['host'], '10.0.0.1');
      expect(out['path'], '/users/192.168.0.1');
      expect(out['url'], 'https://192.168.0.1/cb?to=a@b.com');
    });

    test('sessionId correlation id is not value-scrubbed', () {
      // Hex session id can never match the PII patterns, but assert the
      // allowlist path keeps it raw regardless.
      final out =
          scrub({'sessionId': 'ad72fed7c91318c49621a0e3a7201a64'}) as Map;
      expect(out['sessionId'], 'ad72fed7c91318c49621a0e3a7201a64');
    });

    // Robustness / performance guards.

    test('fail-open: a pathological huge string is passed through untouched',
        () {
      // Larger than the scan cap -> skipped gracefully (no hang, no throw).
      final huge = 'a@b.com ' * 5000; // well over 16KB
      final out = scrub({'msg': huge}) as Map;
      expect(out['msg'], huge);
    });

    test('benign free text with no PII is unchanged', () {
      const text = 'The quick brown fox jumped over 7 lazy dogs.';
      final out = scrub({'msg': text}) as Map;
      expect(out['msg'], text);
    });

    test('key-based redaction still works alongside value scrubbing', () {
      final out = scrub({
        'password': 'p',
        'msg': 'mail a@b.com',
        'safe': 'value',
      }) as Map;
      expect(out['password'], kRedacted);
      expect(out['msg'], 'mail $kRedacted');
      expect(out['safe'], 'value');
    });
  });
}
