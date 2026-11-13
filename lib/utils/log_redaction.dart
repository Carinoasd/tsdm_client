/// Redaction of secrets in log text: the one place every log channel of the app goes through.
///
/// Logs (in-app viewer, log files, exported logs, console) must never carry session cookies, passwords, security
/// answers, captcha answers, `formhash` values, the forum's admin token, the device id of the app API, WebDAV
/// credentials, email addresses or the contents of private forms (replies, messages, notes). Every log line passes
/// through [redactSensitive] before it is stored or written (`RedactingTalker`, `RedactingLogObserver`); a log text
/// written before (an older version of the app, a file of a previous run) goes through [redactLogText] before it is
/// shown or exported.
///
/// The value is replaced, the name stays: a line still tells the method, the path, the action, the status, the timing
/// and which fields were sent. The patterns cover the shapes those values take in this app:
///
/// * HTTP headers, as header lines (`Cookie: …`) or as entries of a printed headers map (`{cookie: [...], …}`);
/// * url query strings and url-encoded form bodies (`formhash=…&password=…`);
/// * Dart map dumps and JSON (`{password: …}`, `"token":"…"`, escaped quotes included);
/// * Discuz! html form inputs (`<input name="formhash" value="…">`, in either attribute order);
/// * credentials in a url (`https://user:pass@host/`), `Basic`/`Bearer` tokens anywhere, email addresses.
///
/// Field names are matched conservatively: besides the known names, any name containing `pass`, `pwd`, `token`,
/// `secret`, `auth` (not `author…`), `cookie`, `hash`, `answer`, `seccode`, `secverify`, `saltkey` or `email` is a
/// secret ([sensitiveNamePattern]).
library;

/// What a redacted value is replaced with.
const redactionMask = '<redacted>';

/// Pieces of a field name that make it a secret, wherever they appear in the name (`newpassword2`, `secanswer`,
/// `answernew`, `x-csrf-token`, `seccodehash`, `emailnew`, …). Words that only look alike are left out: `author…`
/// (`authorid` is in every thread url), `passed`, `answered`.
const _secretNameParts =
    r'pass(?!ed\b|es\b|ing\b)|pwd|token|secret|auth(?!or)|cookie|hash|answer(?!ed\b|s\b)|seccode|secverify|'
    'saltkey|email';

/// Whole field names that are secrets (or identify the account), alone or behind a Discuz! cookie prefix
/// (`Ystv_2132_sid`): the session ids, the account ids, the activity stamp, the security question picked. Not the word
/// `session` alone: log lines say "a previous account or session: GET /forum.php".
const _secretNameWords = r'sid|uid|touid|ulastactivity|questionid\w*|session_?id|phpsessid';

/// A field name that is a secret, see [_secretNameParts] and [_secretNameWords]. Exposed for tests.
const sensitiveNamePattern = '(?:[\\w-]*?(?:$_secretNameParts)[\\w-]*|(?:[\\w-]*_)?(?:$_secretNameWords))';

/// Names of private form fields whose value is user content: replies, messages, notes, signatures.
///
/// Only matched as a form field (`message=`) or a map / JSON entry, never as a word of prose ("chat message: …").
const _contentNames = 'message|pmmessage|subject|description|comment|note|sightml|signature';

/// Form fields whose value is user content only when they are fields of a form (`?data=`, `&text=`, a form body at the
/// start of a line or after a space): the document of the cross-device sync, the text of a draft. As map keys these names are too common to be told apart.
const _formContentNames = 'data|text|content';

/// A JSON / Dart string value, escaped quotes included.
const _quoted =
    r'"(?:[^"\\\r\n]|\\.)*"|'
    r"'(?:[^'\\\r\n]|\\.)*'";

/// Where a map / JSON key begins: the start of a line, after `{`, `[`, `(` or `,`, and the spaces after it (in the
/// match, not in the look-behind: a run of spaces is then scanned once, not from every position).
const _keyContext = r'(?<=^|[\r\n{\[(,])[ \t]*';

/// The unquoted value of a map / JSON entry: up to the next `key:`, the end of the map or the end of the line, so a
/// value with spaces or commas in it is redacted whole.
const _mapValue = r'''(?:(?![,;]\s*["']?[\w-]+["']?\s*[:=])[^}\]\r\n])*''';

/// Header names whose whole value is a secret: cookies, authorization, the forum's app API headers (`X-Tsdmapp-Admin`
/// carries the admin token, `X-Tsdmapp-Device` the device id), CSRF and API keys.
final _headerRe = RegExp(
  r'''(?<key>(?<![\w-])["']?(?:cookie|set-cookie|authorization|proxy-authorization|x-csrf-token|x-api-key|x-tsdmapp-[\w-]+)["']?\s*[:=]\s*)'''
  r'''(?<value>\[[^\]\r\n]*\]|(?:(?![,;]\s*["']?[\w-]+["']?\s*:)[^}\r\n])*)''',
  caseSensitive: false,
);

/// Credentials in a url: `https://user:pass@host`. The scheme starts after a character that cannot be part of it, so a
/// long run of letters and digits (base64 in a page) is scanned once, not from every position.
final _urlUserInfoRe = RegExp(
  r'(?<key>(?<![a-z0-9+.-])[a-z][a-z0-9+.-]*://)(?<value>[^\s/@:?#]+:[^\s/@?#]*)@',
  caseSensitive: false,
);

/// `Basic …` / `Bearer …` / `Token …` credentials outside a header line (a printed request, an exception text).
final _schemeTokenRe = RegExp(
  r'(?<key>\b(?:Basic|Bearer|Token)(?:\s+|\+|%20))(?<value>(?=[A-Za-z0-9+/=._~-]*[0-9+/=])[A-Za-z0-9+/=._~-]{8,})',
  caseSensitive: false,
);

/// `Digest username="…", …, response="…"` outside a header line: its `key=value` fields, what follows them stays.
final _digestRe = RegExp(
  r'(?<key>\bDigest\s+)(?<value>\w+=(?:"[^"\r\n]*"|[^\s,]*)(?:[ \t]*,[ \t]*\w+=(?:"[^"\r\n]*"|[^\s,]*))*)',
  caseSensitive: false,
);

/// The patterns of the secret fields named by [namePattern], in the order they are applied: html form inputs, form
/// bodies and url queries, map / JSON entries, then `name: value` after a word of prose. The first two take the names
/// of [formNamePattern] when given: names that are secrets as fields of a form, prose as words of a text.
List<RegExp> _secretFieldPatterns(String namePattern, {String? formNamePattern}) {
  final formNames = formNamePattern ?? namePattern;
  return [
    // Html form inputs of a secret field, the value before or after the name.
    RegExp(
      '(?<key><input\\b(?=[^<>]*\\bname=["\']$formNames["\'])[^<>]*?\\bvalue=["\'])(?<value>[^"\']*)',
      caseSensitive: false,
    ),
    // Secret fields of a form body or url query: `name=value`.
    RegExp('(?<key>(?<![\\w-])$formNames=)(?<value>$_quoted|[^&\\s;,}\\]]*)', caseSensitive: false),
    // Secret fields as map / JSON entries at the start of a key: the whole value, spaces and commas included.
    RegExp(
      '(?<key>$_keyContext["\']?$namePattern["\']?\\s*:\\s*)(?<value>$_quoted|\\[[^\\]\\r\\n]*\\]|$_mapValue)',
      caseSensitive: false,
    ),
    // Secret fields after a word of prose (`saved token: abc`): the next word.
    RegExp(
      '(?<key>(?<![\\w-])["\']?$namePattern["\']?\\s*:\\s*)(?<value>$_quoted|[^&;,\\s{}\\[\\]"\']+)',
      caseSensitive: false,
    ),
  ];
}

/// Secret fields of the logs, see [sensitiveNamePattern].
final List<RegExp> _secretFieldRes = _secretFieldPatterns(sensitiveNamePattern);

/// Field names that are secrets in a text the user wrote ([redactUserText]): passwords, tokens, secrets, cookies, the
/// `formhash`, the Discuz! cookie values that log in (`…_auth`, `…_saltkey`) and session ids. Narrower than
/// [sensitiveNamePattern]: the account ids (`uid`), `answer`, `email`, `hash` or `auth` as words of a description are
/// prose.
const _userSecretNamePattern =
    r'(?:[\w-]*?(?:pass(?!ed\b|es\b|ing\b|age|port)|pwd|token|secret|cookie(?!s\b)|formhash|saltkey)[\w-]*|'
    r'[\w-]*_auth|(?:[\w-]*_)?(?:session_?id|phpsessid))';

/// [_userSecretNamePattern] and the names that are secrets only as fields of a form (`answer=…` of a pasted login
/// request, `<input name="seccodeverify">`): the security answer, the captcha, a Discuz! session cookie (`…_sid`), the
/// `auth` of a link (the forum's RSS links carry one).
const _userSecretFormNamePattern =
    '(?:$_userSecretNamePattern|[\\w-]*?(?:answer(?!ed\\b|s\\b)|seccode|secverify)[\\w-]*|[\\w-]*_sid|auth)';

/// Secret fields of a text the user wrote, see [_userSecretNamePattern] and [_userSecretFormNamePattern].
final List<RegExp> _userSecretFieldRes = _secretFieldPatterns(
  _userSecretNamePattern,
  formNamePattern: _userSecretFormNamePattern,
);

/// The device id of the forum's app API (`"device":"<uuid>"`, `tsdmapp_device=<uuid>`, `device <uuid>`): a name with
/// `device` in it and a UUID value, so a device name or a word of prose is left alone.
final _deviceIdRe = RegExp(
  r'''(?<key>(?<![\w-])["']?[\w-]*device[\w-]*["']?(?:\s*[:=]\s*["']?|\s+))(?<value>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})''',
  caseSensitive: false,
);

/// Private content fields of a form body: `message=…`.
final _contentFormRe = RegExp(
  '(?<key>(?<![\\w-])(?:$_contentNames)=)(?<value>[^&\\s]+)|(?<key2>(?<=^|[?&\\s:])(?:$_formContentNames)=)(?<value2>[^&\\s{\\[][^&\\s]*)',
  caseSensitive: false,
);

/// Private content fields as map / JSON entries.
final _contentMapRe = RegExp(
  '(?<key>$_keyContext["\']?(?:$_contentNames)["\']?\\s*:\\s*)(?<value>$_quoted|$_mapValue)',
  caseSensitive: false,
);

/// The same fields as JSON entries of an answer whose value is a string (`"data":"…"` of the sync's `pull`): only quoted
/// keys with a quoted value, an object or a number under these names is left alone.
final _formContentJsonRe = RegExp(
  '(?<key>"(?:$_formContentNames)"\\s*:\\s*)(?<value>"(?:[^"\\\\\\r\\n]|\\\\.)*")',
  caseSensitive: false,
);

/// Email addresses, also url-encoded (`a%40b.com`). A file name such as `avatar@2x.png` is not one.
final _emailRe = RegExp(
  r'(?<![\w.%+-])[\w.+-]+(?:@|%40)[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?!(?:png|jpe?g|gif|webp|avif|bmp|svg|ico)\b)[a-z]{2,}\b',
  caseSensitive: false,
);

/// IPv4 addresses (each part checked to be at most 255 when replacing).
final _ipv4Re = RegExp(r'(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w.]|\.\d)');

String _keep(Match m) => '${(m as RegExpMatch).namedGroup('key')}$redactionMask';

String _keepNonEmpty(Match m) {
  final match = m as RegExpMatch;
  final value = match.namedGroup('value') ?? '';
  if (value.isEmpty || value == "''" || value == '""') {
    return match.group(0)!;
  }
  return '${match.namedGroup('key')}$redactionMask';
}

String _keepContentForm(Match m) {
  final match = m as RegExpMatch;
  final key = match.namedGroup('key') ?? match.namedGroup('key2')!;
  final value = match.namedGroup('value') ?? match.namedGroup('value2') ?? '';
  return value.isEmpty ? match.group(0)! : '$key$redactionMask';
}

/// The credentials in [text]: headers, credentials in a url, `Basic` / `Bearer` / `Digest` tokens, the device id of
/// the app API, and the secret fields of [fieldRes] ([_secretFieldPatterns]).
String _redactCredentials(String text, List<RegExp> fieldRes) {
  var out = text;
  out = out.replaceAllMapped(_headerRe, _keepNonEmpty);
  out = out.replaceAllMapped(_urlUserInfoRe, (m) => '${(m as RegExpMatch).namedGroup('key')}$redactionMask@');
  out = out.replaceAllMapped(_schemeTokenRe, _keep);
  out = out.replaceAllMapped(_digestRe, _keep);
  out = out.replaceAllMapped(fieldRes[0], _keep);
  out = out.replaceAllMapped(_deviceIdRe, _keep);
  for (final re in fieldRes.skip(1)) {
    out = out.replaceAllMapped(re, _keepNonEmpty);
  }
  return out;
}

/// Redact a text the user wrote themselves (the description of a problem on the feedback page), for the diagnostics
/// bundle and the reply to the feedback thread alike: only what is surely a secret, the credentials of
/// [redactSensitive] (cookies, `formhash`, password and token fields, `Basic` / `Bearer` tokens, credentials in a url)
/// and email addresses.
///
/// Not the rest of [redactLogText], made for log lines: their content fields would take a line of the description
/// that starts with `message:` or `note:`, their IPv4 addresses a version number such as `1.57.1.173`. Idempotent.
String redactUserText(String text) {
  if (text.isEmpty) {
    return text;
  }
  return _redactCredentials(text, _userSecretFieldRes).replaceAllMapped(_emailRe, (_) => redactionMask);
}

/// Replace every secret in [text] with [redactionMask]; the names, methods, paths, statuses and timings stay.
///
/// Applied to every log line as it is made. Idempotent: redacting a redacted text changes nothing.
String redactSensitive(String text) {
  if (text.isEmpty) {
    return text;
  }
  var out = _redactCredentials(text, _secretFieldRes);
  out = out.replaceAllMapped(_contentFormRe, _keepContentForm);
  out = out.replaceAllMapped(_contentMapRe, _keepNonEmpty);
  out = out.replaceAllMapped(_formContentJsonRe, _keepNonEmpty);
  out = out.replaceAllMapped(_emailRe, (_) => redactionMask);
  return out;
}

/// What [redactLogText] does with IPv4 addresses.
enum IpRedaction {
  /// Left as they are.
  keep,

  /// The first two parts kept (`192.168.x.x`): the network is still told apart (a LAN proxy, a loopback address).
  keepFirstTwo,

  /// Replaced whole.
  mask,
}

/// Redact a log text written before, for showing or exporting it: a log file of an older version of the app (which
/// may predate redaction, or a field added since), the logs packed into a diagnostics export.
///
/// Everything [redactSensitive] redacts; email addresses unless [maskEmail] is false; IPv4 addresses as [ip] says.
/// A pure function of its arguments, for `compute`; idempotent.
String redactLogText(String text, {bool maskEmail = true, IpRedaction ip = IpRedaction.keepFirstTwo}) {
  if (text.isEmpty) {
    return text;
  }
  var out = text;
  if (!maskEmail) {
    // Kept out of the way of the field patterns, put back after them.
    final emails = <String>[];
    out = out.replaceAllMapped(_emailRe, (m) {
      emails.add(m.group(0)!);
      return '\u0000email${emails.length - 1}\u0000';
    });
    out = redactSensitive(out);
    out = out.replaceAllMapped(RegExp('\u0000email(\\d+)\u0000'), (m) {
      final i = int.parse(m.group(1)!);
      return i < emails.length ? emails[i] : m.group(0)!;
    });
  } else {
    out = redactSensitive(out);
  }
  if (ip != IpRedaction.keep) {
    out = out.replaceAllMapped(_ipv4Re, (m) {
      final parts = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
      if (parts.any((p) => p > 255)) {
        return m.group(0)!;
      }
      return ip == IpRedaction.mask ? redactionMask : '${parts[0]}.${parts[1]}.x.x';
    });
  }
  return out;
}

/// Whether [text] still contains something [redactSensitive] would change.
bool containsSensitive(String text) => redactSensitive(text) != text;
