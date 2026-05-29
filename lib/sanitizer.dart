/// AllStak Flutter SDK sanitizer.
///
/// Recursively scrubs sensitive data across the event surface
/// (user, extras, metadata, breadcrumbs.data, contexts, request, response).
///
/// Two layers, applied in one pass:
///   1. KEY-NAME redaction (always): case-insensitive substring match on Map
///      keys against the canonical denylist; the value becomes `[REDACTED]`.
///   2. VALUE-PATTERN redaction (this wave): scans free-text string *values*
///      for high-risk PII patterns and replaces the matched span with
///      `[REDACTED]`. Layered for @sentry data-scrubbing parity:
///        A) ALWAYS — credit-card numbers that pass the Luhn checksum, and
///           US SSNs written with hyphens (`NNN-NN-NNNN`). These are
///           never legitimately wanted in telemetry.
///        B) UNLESS `sendDefaultPii` — email addresses and IPv4 literals.
///
/// Conforms to the canonical AllStak SDK denylist
/// (docs/standards/sdk-platform-standards.md).
///
/// Semantics:
/// - Case-insensitive substring match on Map keys (layer 1).
/// - Value-pattern scrubbing on String values only (layer 2), gated per-key so
///   identifiers that must survive verbatim (stack-frame paths, release/sdk
///   fields, URLs/paths, the SDK's own sessionId, and the *explicit* user
///   object set via setUser) are never corrupted.
/// - Value replacement with the sentinel string `[REDACTED]` (key preserved).
/// - Recursion into Map and Iterable; primitives pass through.
/// - Cycle protection via identityHashCode set.
/// - Pure: returns a sanitized copy; never mutates caller-owned structures.
/// - Mobile-safe: synchronous, no I/O, no blocking calls.
/// - Fail-open: an individual value scrubber that throws leaves that value
///   untouched (still key-redacted) rather than dropping the event.
library;

const String kRedacted = '[REDACTED]';

/// Exact (case-sensitive) AllStak wire field names that are non-secret
/// correlation identifiers and must survive scrubbing. The release-health
/// `sessionId` is the canonical example: the backend's error consumer keys
/// off it to mark a session errored/crashed, so it MUST reach the wire raw.
///
/// This is intentionally an *exact, case-sensitive* match on AllStak's own
/// camelCase field names — it does not loosen the substring denylist for
/// arbitrary user-supplied keys. A user field literally named `sessionid`,
/// `session_id`, or `session_token` is still redacted by the denylist.
const Set<String> kCorrelationAllowlist = <String>{
  'sessionId',
};

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

/// Map keys whose String value is an identifier/locator that must reach the
/// wire VERBATIM — value-pattern scrubbing is skipped for these. They are NOT
/// secret (key-name redaction still applies to anything on the denylist), but
/// running PII regexes over them would corrupt legitimate data:
/// - stack-frame fields (`filename`/`absPath`/`function`) often embed paths
///   that can look like emails/IPs;
/// - release/version/sdk/platform/dist fields are build identifiers;
/// - URLs/paths/hosts have their own redaction story and frequently contain
///   IP-shaped segments;
/// - trace/span/request ids and timestamps are hex/opaque tokens.
///
/// Exact, case-sensitive match on AllStak's own camelCase wire field names.
const Set<String> kValueScrubExemptKeys = <String>{
  // Stack frames (see _parseDartFrames): never corrupt symbolication input.
  'filename',
  'absPath',
  'function',
  'lineno',
  'colno',
  // Release / build / SDK identity.
  'release',
  'version',
  'dist',
  'sdkName',
  'sdkVersion',
  'sdk.name',
  'sdk.version',
  'commitSha',
  'commit.sha',
  'commit.branch',
  'branch',
  'platform',
  'device.platform',
  'environment',
  // URLs / locators (own redactor / IP-shaped segments are legitimate here).
  'url',
  'path',
  'host',
  'href',
  // Trace / span / request correlation ids + timestamps (opaque tokens).
  'traceId',
  'requestId',
  'spanId',
  'parentSpanId',
  'errorFingerprint',
  'timestamp',
  // SDK's own release-health session id (also in kCorrelationAllowlist).
  'sessionId',
};

/// Top-level (exact, case-sensitive) keys whose ENTIRE subtree is exempt from
/// value-pattern scrubbing. The explicit `user` object set via `setUser`
/// (id/email/ip) is intentional identification and ships as-is — matching
/// Sentry, `sendDefaultPii` does NOT strip explicitly-set user data. Key-name
/// redaction still applies inside the subtree (e.g. `user.password`).
const Set<String> kValueScrubExemptSubtrees = <String>{
  'user',
};

/// Hard cap on the length of a single String value scanned by value-pattern
/// scrubbers. Pathological multi-megabyte strings are passed through untouched
/// (still key-redacted) rather than burning CPU on the wire path.
const int _kMaxValueScanLength = 16 * 1024;

// ── Compiled-once value-pattern matchers ────────────────────────────────────
// Compiling RegExp instances at top-level keeps them off the per-event hot path.

/// US SSN with REQUIRED hyphens: `NNN-NN-NNNN`. Bare 9-digit runs are NOT
/// matched (too many false positives: order ids, phone numbers, etc.).
final RegExp _ssnRe = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');

/// Standard-ish email address.
final RegExp _emailRe = RegExp(
  r"[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+",
);

/// IPv4 with each octet validated to 0-255, on word boundaries.
final RegExp _ipv4Re = RegExp(
  r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b',
);

/// Candidate credit-card run: 13-19 digits with optional single space/hyphen
/// separators between groups. Luhn-validated before redaction so digit runs
/// that fail the checksum (order ids, timestamps) are preserved.
final RegExp _ccCandidateRe = RegExp(r'\b(?:\d[ -]?){12,18}\d\b');

/// Options controlling which value-pattern scrubbers run.
class ScrubOptions {
  /// When true, the (B) auto-PII scrubbers (email + IPv4) are DISABLED because
  /// the user explicitly opted into shipping PII. The (A) financial/identity
  /// scrubbers (Luhn-valid CC, hyphenated SSN) ALWAYS run regardless. Default
  /// false = Sentry parity (auto-PII is scrubbed).
  final bool sendDefaultPii;

  const ScrubOptions({this.sendDefaultPii = false});
}

/// Returns a sanitized deep copy of [payload]. [extraDenylist] may add key
/// terms; it must not narrow the canonical list. [options] gates the value
/// scrubbers ([ScrubOptions.sendDefaultPii]). Fail-open at the value level.
Object? scrub(
  Object? payload, {
  List<String>? extraDenylist,
  ScrubOptions options = const ScrubOptions(),
}) {
  final denylist = <String>[...kDefaultDenylist];
  if (extraDenylist != null) {
    for (final t in extraDenylist) {
      final lower = t.toLowerCase();
      if (!denylist.contains(lower)) denylist.add(lower);
    }
  }
  final seen = <int>{};
  // scrubValues starts true at the root; entering an exempt subtree flips it.
  return _walk(payload, denylist, seen, options, true);
}

bool _isSensitive(String key, List<String> denylist) {
  final k = key.toLowerCase();
  for (final term in denylist) {
    if (k.contains(term)) return true;
  }
  return false;
}

Object? _walk(
  Object? value,
  List<String> denylist,
  Set<int> seen,
  ScrubOptions options,
  bool scrubValues,
) {
  if (value == null) return null;
  if (value is Map) {
    final hash = identityHashCode(value);
    if (seen.contains(hash)) return kRedacted;
    seen.add(hash);
    final out = <String, Object?>{};
    value.forEach((k, v) {
      final key = k.toString();
      // Exact-match allowlist wins: non-secret AllStak correlation ids
      // (e.g. sessionId) must reach the wire raw for server-side correlation.
      if (kCorrelationAllowlist.contains(key)) {
        out[key] = _walk(v, denylist, seen, options, false);
      } else if (_isSensitive(key, denylist)) {
        out[key] = kRedacted;
      } else {
        // Value scrubbing is disabled for this child when either the whole
        // subtree is exempt (e.g. the explicit `user` object) or this exact
        // key holds an identifier/locator that must survive verbatim.
        final childScrubValues = scrubValues &&
            !kValueScrubExemptSubtrees.contains(key) &&
            !kValueScrubExemptKeys.contains(key);
        out[key] = _walk(v, denylist, seen, options, childScrubValues);
      }
    });
    return out;
  }
  if (value is List) {
    final hash = identityHashCode(value);
    if (seen.contains(hash)) return kRedacted;
    seen.add(hash);
    return value
        .map((v) => _walk(v, denylist, seen, options, scrubValues))
        .toList();
  }
  if (value is Set) {
    final hash = identityHashCode(value);
    if (seen.contains(hash)) return kRedacted;
    seen.add(hash);
    return value
        .map((v) => _walk(v, denylist, seen, options, scrubValues))
        .toList();
  }
  if (value is String && scrubValues) {
    return _scrubValue(value, options);
  }
  // Primitives (String in an exempt context, num, bool) pass through.
  return value;
}

/// Apply the value-pattern scrubbers to a single free-text String. Fail-open:
/// any error returns the original string (still key-redacted upstream) so a
/// scrubber bug can never drop or break an event.
String _scrubValue(String input, ScrubOptions options) {
  // Cheap pre-checks: empty / oversized strings skip the regex work entirely.
  if (input.isEmpty) return input;
  if (input.length > _kMaxValueScanLength) return input;
  try {
    var out = input;
    // (A) ALWAYS — credit cards (Luhn-valid only) and hyphenated SSNs.
    out = _scrubCreditCards(out);
    out = out.replaceAll(_ssnRe, kRedacted);
    // (B) UNLESS the user opted into PII — email + IPv4.
    if (!options.sendDefaultPii) {
      out = out.replaceAll(_emailRe, kRedacted);
      out = out.replaceAll(_ipv4Re, kRedacted);
    }
    return out;
  } catch (_) {
    // Fail-open: never let a scrubber error drop the value.
    return input;
  }
}

/// Replace only those 13-19 digit runs that pass the Luhn checksum. Runs that
/// fail Luhn (order ids, timestamps, arbitrary numbers) are preserved to avoid
/// corrupting legitimate data.
String _scrubCreditCards(String input) {
  return input.replaceAllMapped(_ccCandidateRe, (m) {
    final match = m.group(0)!;
    final digits = match.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length < 13 || digits.length > 19) return match;
    return _luhnValid(digits) ? kRedacted : match;
  });
}

/// Luhn (mod-10) checksum over a pure-digit string.
bool _luhnValid(String digits) {
  var sum = 0;
  var alt = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = digits.codeUnitAt(i) - 0x30; // '0' == 0x30
    if (d < 0 || d > 9) return false;
    if (alt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alt = !alt;
  }
  return sum % 10 == 0;
}
