/// AllStak Flutter SDK sanitizer.
///
/// Recursively scrubs sensitive keys across the event surface
/// (user, extras, metadata, breadcrumbs.data, contexts, request, response).
///
/// Conforms to the canonical AllStak SDK denylist
/// (docs/standards/sdk-platform-standards.md).
///
/// Semantics:
/// - Case-insensitive substring match on Map keys.
/// - Value replacement with the sentinel string `[REDACTED]` (key preserved).
/// - Recursion into Map and Iterable; primitives pass through.
/// - Cycle protection via identityHashCode set.
/// - Pure: returns a sanitized copy; never mutates caller-owned structures.
/// - Mobile-safe: synchronous, no I/O, no blocking calls.
library;


const String kRedacted = '[REDACTED]';

const List<String> kDefaultDenylist = <String>[
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'password',
  'passwd',
  'pwd',
  'api_key',
  'apikey',
  'x-api-key',
  'x-allstak-key',
  'x-auth-token',
  'x-access-token',
  'token',
  'bearer',
  'jwt',
  'session',
  'sessionid',
  'session_id',
  'secret',
  'credit_card',
  'card_number',
  'cvv',
  'ssn',
  'csrf',
];

/// Returns a sanitized deep copy of [payload]. [extraDenylist] may add terms;
/// it must not narrow the canonical list.
Object? scrub(Object? payload, {List<String>? extraDenylist}) {
  final denylist = <String>[...kDefaultDenylist];
  if (extraDenylist != null) {
    for (final t in extraDenylist) {
      final lower = t.toLowerCase();
      if (!denylist.contains(lower)) denylist.add(lower);
    }
  }
  final seen = <int>{};
  return _walk(payload, denylist, seen);
}

bool _isSensitive(String key, List<String> denylist) {
  final k = key.toLowerCase();
  for (final term in denylist) {
    if (k.contains(term)) return true;
  }
  return false;
}

Object? _walk(Object? value, List<String> denylist, Set<int> seen) {
  if (value == null) return null;
  if (value is Map) {
    final hash = identityHashCode(value);
    if (seen.contains(hash)) return kRedacted;
    seen.add(hash);
    final out = <String, Object?>{};
    value.forEach((k, v) {
      final key = k.toString();
      if (_isSensitive(key, denylist)) {
        out[key] = kRedacted;
      } else {
        out[key] = _walk(v, denylist, seen);
      }
    });
    return out;
  }
  if (value is List) {
    final hash = identityHashCode(value);
    if (seen.contains(hash)) return kRedacted;
    seen.add(hash);
    return value.map((v) => _walk(v, denylist, seen)).toList();
  }
  if (value is Set) {
    final hash = identityHashCode(value);
    if (seen.contains(hash)) return kRedacted;
    seen.add(hash);
    return value.map((v) => _walk(v, denylist, seen)).toList();
  }
  // Primitives (String, num, bool) pass through.
  return value;
}
