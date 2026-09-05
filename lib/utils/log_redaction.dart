/// Redaction of secrets in log text.
///
/// Logs (in-app viewer, log files, exported logs) must never carry session cookies, passwords, `formhash` values
/// or the contents of private forms (replies, messages, notes). Every log line passes through [redactSensitive]
/// before it is stored or written; the patterns below cover the shapes those values take in this app: HTTP headers,
/// cookie strings, url query strings, url-encoded form bodies, Dart map / JSON dumps and Discuz! html form inputs.
library;

const _mask = '<redacted>';

/// Header names whose whole value is a secret, as header lines or as entries of a printed headers map.
final _headerRe = RegExp(
  r"""(?<key>\b(?:cookie|set-cookie|authorization|proxy-authorization|x-csrf-token)\b["']?\s*[:=]\s*)(?<value>[^\r\n,}]*)""",
  caseSensitive: false,
);

/// Discuz! session cookies (`Ystv_2132_auth=...`), also when printed as map entries (`Ystv_2132_auth: ...`), form
/// hashes, passwords and generic token names.
final _tokenRe = RegExp(
  r"""(?<key>\b(?:\w+_)?(?:auth|saltkey|sid|token|session|password|passwd|pwd|formhash)\b["']?\s*[:=]\s*)(?<value>"[^"]*"|'[^']*'|[^&;,\s}\]]+)""",
  caseSensitive: false,
);

/// Discuz! html form inputs: `<input name="formhash" value="…">`.
final _formHashInputRe = RegExp(
  """(?<key>name=["']formhash["'][^>]*?value=["'])(?<value>[^"']*)""",
  caseSensitive: false,
);

/// Names of private form fields: replies, messages, notes, security answers.
const _privateFields =
    'message|pmmessage|subject|description|answer|questionid|email|oldpassword|newpassword|newpassword2|password2|'
    'seccodeverify|comment|note';

/// Private form fields as url-encoded body parts (`message=...`, wherever they appear).
final _privateFormRe = RegExp('(?<key>\\b(?:$_privateFields)=)(?<value>[^&\\s]*)', caseSensitive: false);

/// Private form fields as map entries (`{message: ..., ` / `, message: ...`) or quoted JSON keys (`"message": ...`).
///
/// A bare word in prose ("chat message: author not found") is deliberately not matched: the key must open the string,
/// follow a `{` or `,`, or be quoted.
final _privateMapRe = RegExp(
  """(?<key>(?:^|[{,]\\s*|["'])(?:$_privateFields)["']?\\s*:\\s*)(?<value>"[^"]*"|'[^']*'|[^,}\\]\\r\\n]*)""",
  caseSensitive: false,
);

/// Replace every secret in [text] with a placeholder.
String redactSensitive(String text) {
  if (text.isEmpty) {
    return text;
  }
  String keep(Match m) => '${(m as RegExpMatch).namedGroup('key')}$_mask';
  var out = text;
  out = out.replaceAllMapped(_headerRe, keep);
  out = out.replaceAllMapped(_formHashInputRe, keep);
  out = out.replaceAllMapped(_tokenRe, keep);
  String keepNonEmpty(Match m) {
    final match = m as RegExpMatch;
    final value = match.namedGroup('value') ?? '';
    return value.isEmpty ? match.group(0)! : '${match.namedGroup('key')}$_mask';
  }
  out = out.replaceAllMapped(_privateFormRe, keepNonEmpty);
  out = out.replaceAllMapped(_privateMapRe, keepNonEmpty);
  return out;
}

/// Whether [text] still contains something [redactSensitive] would change.
bool containsSensitive(String text) => redactSensitive(text) != text;
