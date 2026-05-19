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
      final out =
          scrub({
                'user': {'email': 'a@b', 'password': 'p'},
              })
              as Map;
      expect((out['user'] as Map)['email'], 'a@b');
      expect((out['user'] as Map)['password'], kRedacted);
    });

    test('recurses into list', () {
      final out =
          scrub({
                'items': [
                  {'token': 't'},
                  {'safe': 'v'},
                ],
              })
              as Map;
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

    test('primitive passthrough', () {
      expect(scrub(42), 42);
      expect(scrub('x'), 'x');
      expect(scrub(null), null);
    });
  });
}
