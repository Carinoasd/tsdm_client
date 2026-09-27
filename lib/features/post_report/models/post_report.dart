import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart'
    show isCloudflareChallengePage, unwrapAjax;
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Length limit of a report reason on the forum: `cutstr(message, 200)`.
const postReportReasonLimit = 200;

/// Length of [text] as the forum's utf-8 `cutstr` counts it: 1 for every ASCII character (tab and newline included),
/// 2 for every other unicode scalar, emoji included. Not the Dart (UTF-16) length.
int postReportReasonWeight(String text) {
  var n = 0;
  for (final rune in text.runes) {
    n += rune < 0x80 ? 1 : 2;
  }
  return n;
}

/// The forum's `dhtmlspecialchars` of a report reason: the four special characters escaped.
String _forumEscape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

const _cutEntities = {'&amp;': '&', '&quot;': '"', '&lt;': '<', '&gt;': '>'};

/// Whether the forum's `cutstr(escaped, 200, '')` returns [escaped] unchanged, following its source step by step:
/// the four entities are wrapped in chr(1) sentinels, utf-8 bytes are counted (printable ASCII, tab and newline 1,
/// multibyte scalars 2, anything else 0) until the count reaches the limit, and an entity whose closing sentinel was
/// cut off is dropped. So a reason of exactly the limit ending in `&`, `"`, `<` or `>` loses that character.
/// Only this supported edge is modelled; `censor` is not.
bool _cutstrKeeps(String escaped) {
  final plain = utf8.encode(escaped);
  if (plain.length <= postReportReasonLimit) {
    return true;
  }
  var wrapped = escaped;
  for (final MapEntry(key: entity, value: char) in _cutEntities.entries) {
    wrapped = wrapped.replaceAll(entity, '\u0001$char\u0001');
  }
  final bytes = utf8.encode(wrapped);
  var n = 0;
  var tn = 0;
  var noc = 0;
  while (n < bytes.length) {
    final t = bytes[n];
    if (t == 9 || t == 10 || (t >= 32 && t <= 126)) {
      tn = 1;
      n++;
      noc++;
    } else if (t >= 194 && t <= 223) {
      tn = 2;
      n += 2;
      noc += 2;
    } else if (t >= 224 && t <= 239) {
      tn = 3;
      n += 3;
      noc += 2;
    } else if (t >= 240 && t <= 247) {
      tn = 4;
      n += 4;
      noc += 2;
    } else {
      n++;
    }
    if (noc >= postReportReasonLimit) {
      break;
    }
  }
  if (noc > postReportReasonLimit) {
    n -= tn;
  }
  if (n < bytes.length) {
    return false;
  }
  // Nothing cut and every sentinel restored; a chr(1) typed by the user would still make the forum cut at it.
  return !escaped.contains('\u0001');
}

/// Whether the forum stores the normalized reason [text] exactly as typed: within [postReportReasonLimit] by
/// [postReportReasonWeight] and not shortened by `cutstr` or the handler's trailing-backslash removal.
bool postReportReasonFits(String text) =>
    !text.endsWith(r'\') && postReportReasonWeight(text) <= postReportReasonLimit && _cutstrKeeps(_forumEscape(text));

const _phpTrimChars = {0x20, 0x09, 0x0A, 0x0D, 0x00, 0x0B};

/// [raw] as the forum stores it before counting: line breaks as `\n`, trimmed like PHP `trim`.
String normalizePostReportReason(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var start = 0;
  var end = text.length;
  while (start < end && _phpTrimChars.contains(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _phpTrimChars.contains(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

/// Why the report can not be done in the app now. Nothing was sent in any of these cases.
enum PostReportProblem {
  /// Another account is current, or the page was served to another account.
  accountChanged,

  /// The forum answered as to a guest.
  notLoggedIn,

  /// The fresh thread page does not offer this report (own post, deleted floor, no permission).
  noPermission,

  /// The forum asks for a verification (captcha, question) the app does not support.
  verificationRequired,

  /// A site protection page answered instead of the forum.
  challenge,

  /// Network error before anything was sent.
  network,

  /// The forum answered with a message instead of the form.
  forumMessage,

  /// The form is not the one the app understands.
  unsupported,
}

/// A failure before sending, with the forum's plain message when there is one.
final class PostReportFailure implements Exception {
  /// Constructor.
  const PostReportFailure(this.problem, {this.message});

  /// Kind.
  final PostReportProblem problem;

  /// Plain text from the forum, never html or tokens.
  final String? message;

  @override
  String toString() => 'PostReportFailure($problem)';
}

/// Result of the one report request.
sealed class PostReportOutcome {
  const PostReportOutcome();
}

/// The forum explicitly answered the report succeeded (`report_succeed`).
final class PostReportSucceeded extends PostReportOutcome {
  /// Constructor.
  const PostReportSucceeded(this.message);

  /// Plain success text of the forum.
  final String message;
}

/// The forum explicitly refused the report.
final class PostReportRejected extends PostReportOutcome {
  /// Constructor.
  const PostReportRejected(this.message, {this.notLoggedIn = false});

  /// Plain text of the forum, may be empty.
  final String message;

  /// The forum asks to log in.
  final bool notLoggedIn;
}

/// The request may or may not have reached the forum: never sent again automatically.
final class PostReportUnknown extends PostReportOutcome {
  /// Constructor.
  const PostReportUnknown();
}

/// Hidden fields the forum's post report form is known to carry. Any other named field refuses the form.
const _knownHiddenFields = {'referer', 'reportsubmit', 'rtype', 'rid', 'fid', 'url', 'inajax', 'handlekey', 'formhash'};

/// Field names of the forum's verification (seccode / secqaa).
bool _isVerificationField(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('seccode') || lower.startsWith('secanswer') || lower.startsWith('secqaa');
}

/// The report form of one floor as the forum served it, see [parsePostReportForm].
final class PostReportForm {
  const PostReportForm._({required this.action, required this.hidden, required this.reasons, required this.target});

  /// Canonical `https://` main host action url.
  final Uri action;

  /// Hidden fields sent as served, in order, without the reason. `tid` is not one of them unless the forum sent it.
  final List<(String, String)> hidden;

  /// Reason choices of the forum. The last one means "other": its text is typed by the user.
  final List<String> reasons;

  /// The floor.
  final PostReportTarget target;

  /// Index of the "other" choice.
  int get customIndex => reasons.length - 1;

  /// The reason text sent for choice [index], with [custom] for the last one; null when it is empty or the forum
  /// would not store it unchanged ([postReportReasonFits]). Nothing is ever cut.
  String? messageFor(int index, String custom) {
    if (index < 0 || index >= reasons.length) {
      return null;
    }
    final text = normalizePostReportReason(index == customIndex ? custom : reasons[index]);
    if (text.isEmpty || !postReportReasonFits(text)) {
      return null;
    }
    return text;
  }

  /// Request body for [message].
  Map<String, String> body(String message) => {for (final (name, value) in hidden) name: value, 'message': message};

  /// Whether [other], a fresh copy, offers the same choices for the same floor and action.
  bool sameChoices(PostReportForm other) =>
      other.target == target && other.action == action && const ListEquality<String>().equals(other.reasons, reasons);
}

/// Action of the report form: exactly `misc.php?mod=report`, optionally with `inajax=1`.
Uri? _reportAction(String? raw) {
  if (raw == null) {
    return null;
  }
  final uri = Uri.tryParse(raw.replaceAll('&amp;', '&'));
  if (uri == null || !isForumScriptUri(uri, 'misc.php')) {
    return null;
  }
  final query = uniqueQueryParameters(uri);
  if (query == null || query['mod'] != 'report') {
    return null;
  }
  if (query.keys.any((e) => e != 'mod' && e != 'inajax') || (query.containsKey('inajax') && query['inajax'] != '1')) {
    return null;
  }
  return Uri(scheme: 'https', host: baseHost, path: '/misc.php', query: uri.query);
}

/// Whether a non-empty hidden `url` names [target]: the forum's own `findpost` link of this post (`ptid` may be 0) or
/// the thread.
bool _isTargetUrl(String raw, PostReportTarget target) {
  final uri = Uri.tryParse(raw);
  if (uri == null || !isForumScriptUri(uri, 'forum.php')) {
    return false;
  }
  final q = uniqueQueryParameters(uri);
  if (q == null) {
    return false;
  }
  if (q['mod'] == 'redirect' && q['goto'] == 'findpost') {
    return q['pid'] == '${target.pid}' && (q['ptid'] == '0' || q['ptid'] == '${target.tid}');
  }
  if (q['mod'] == 'viewthread') {
    return q['tid'] == '${target.tid}';
  }
  return false;
}

final _reasonsDeclRe = RegExp(r'var\s+reasons\s*=\s*\[([^\]]*)\]\s*;');

/// Plain single quoted strings of a `var reasons = ['a', 'b'];` array, null for anything else. Read as text only.
List<String>? parseReportReasonsScript(String script) {
  final decls = _reasonsDeclRe.allMatches(script).toList();
  if (decls.length != 1) {
    return null;
  }
  final body = decls.single.group(1)!;
  final items = <String>[];
  var i = 0;
  void skipSpace() {
    while (i < body.length && (body[i] == ' ' || body[i] == '\t' || body[i] == '\n' || body[i] == '\r')) {
      i++;
    }
  }

  while (true) {
    skipSpace();
    if (i >= body.length) {
      break;
    }
    if (body[i] != "'") {
      return null;
    }
    final end = body.indexOf("'", i + 1);
    if (end < 0) {
      return null;
    }
    final item = body.substring(i + 1, end);
    if (item.contains(r'\') || item.contains('\n') || item.contains('\r')) {
      return null;
    }
    items.add(item);
    i = end + 1;
    skipSpace();
    if (i >= body.length) {
      break;
    }
    if (body[i] != ',') {
      return null;
    }
    i++;
  }
  return items;
}

bool _hasLoginMarker(uh.Document doc, String html) =>
    doc.querySelector('#messagelogin') != null ||
    doc.querySelector('form[name="login"]') != null ||
    html.contains('mod=logging&action=login') ||
    html.contains('mod=logging&amp;action=login');

/// Visible text of an html snippet of the forum, whitespace collapsed and bounded.
String plainForumText(String html) {
  final text = (parseHtmlDocument('<body>$html</body>').body?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}

/// Plain message of a forum message fragment without the form, empty when none.
String _fragmentMessage(uh.Document doc) {
  final node = doc.querySelector('#messagetext p') ?? doc.querySelector('div.alert_error') ?? doc.querySelector('body');
  if (node == null) {
    return '';
  }
  final copy = node.clone(true) as uh.Element;
  for (final e in copy.querySelectorAll('script, style')) {
    e.remove();
  }
  return plainForumText(copy.innerHtml ?? '');
}

/// Parse the ajax report dialog [raw] of [target] (`misc.php?mod=report...&inajax=1`).
///
/// Only one form, `form#form_miscreportPID` posting to `misc.php?mod=report`, with `rtype=post`, `rid` and `fid` of
/// [target], its handle key, a form hash and the `message` textarea is accepted. Hidden values are kept as served:
/// an empty `url` stays empty and a missing `tid` stays missing. Reasons come from the `var reasons = [...]` script,
/// or from `report_select` radios when there is no script; neither is ever run nor sent. Any verification or other
/// field refuses the form so the user falls back to the browser.
///
/// Throws [PostReportFailure] only.
PostReportForm parsePostReportForm(String raw, {required PostReportTarget target}) {
  try {
    return _parsePostReportForm(raw, target: target);
  } on PostReportFailure {
    rethrow;
  } on Object {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
}

PostReportForm _parsePostReportForm(String raw, {required PostReportTarget target}) {
  if (isCloudflareChallengePage(parseHtmlDocument(raw))) {
    throw const PostReportFailure(PostReportProblem.challenge);
  }
  if (!raw.contains('<![CDATA[')) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  final html = unwrapAjax(raw);
  final doc = parseHtmlDocument(html);
  if (_hasLoginMarker(doc, html)) {
    throw const PostReportFailure(PostReportProblem.notLoggedIn);
  }
  final forms = doc.querySelectorAll('form');
  if (forms.isEmpty) {
    final message = _fragmentMessage(doc);
    throw PostReportFailure(
      message.isEmpty ? PostReportProblem.unsupported : PostReportProblem.forumMessage,
      message: message.isEmpty ? null : message,
    );
  }
  if (forms.length != 1 || forms.single.id != 'form_${target.handleKey}') {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  final form = forms.single;
  if ((form.attributes['method'] ?? '').toLowerCase() != 'post') {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  final action = _reportAction(form.attributes['action']);
  if (action == null) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }

  final hidden = <(String, String)>[];
  final radios = <String>[];
  var textareas = 0;
  for (final e in form.querySelectorAll('input, select, textarea, button')) {
    final name = e.attributes['name'] ?? '';
    final tag = e.localName;
    final type = (e.attributes['type'] ?? (tag == 'button' ? 'submit' : 'text')).toLowerCase();
    if (_isVerificationField(name) || e.id.toLowerCase().contains('seccode')) {
      throw const PostReportFailure(PostReportProblem.verificationRequired);
    }
    if (name.isEmpty) {
      // Unnamed controls (the submit button, the reason radios of some styles) are never sent by a browser.
      continue;
    }
    if (tag == 'textarea') {
      if (name != 'message') {
        throw const PostReportFailure(PostReportProblem.unsupported);
      }
      textareas++;
      continue;
    }
    if (tag == 'input' && type == 'hidden') {
      if (!_knownHiddenFields.contains(name) || hidden.any((f) => f.$1 == name)) {
        throw const PostReportFailure(PostReportProblem.unsupported);
      }
      hidden.add((name, e.attributes['value'] ?? ''));
      continue;
    }
    if (tag == 'input' && type == 'radio' && name == 'report_select') {
      // Only fills the textarea in the browser; not a field of the report.
      radios.add(e.attributes['value'] ?? '');
      continue;
    }
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  if (textareas != 1) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  String? value(String name) => hidden.firstWhereOrNull((f) => f.$1 == name)?.$2;
  final formHash = value('formhash');
  final reportSubmit = value('reportsubmit');
  final url = value('url');
  final inAjax = value('inajax');
  if (formHash == null || formHash.isEmpty || reportSubmit == null || reportSubmit.isEmpty) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  if (value('rtype') != 'post' ||
      value('rid') != '${target.pid}' ||
      value('fid') != '${target.fid}' ||
      value('handlekey') != target.handleKey) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  final actionInAjax = uniqueQueryParameters(action)?['inajax'];
  if ((inAjax != null && inAjax != '1') || (inAjax == null && actionInAjax != '1')) {
    // Without inajax the answer is a full page the app can not read: refuse before sending.
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  if (url != null && url.isNotEmpty && !_isTargetUrl(url, target)) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }

  final scriptText = doc.querySelectorAll('script').map((e) => e.text ?? '').join('\n');
  List<String>? reasons;
  if (_reasonsDeclRe.hasMatch(scriptText)) {
    reasons = parseReportReasonsScript(scriptText);
  } else if (radios.isNotEmpty) {
    reasons = radios;
  }
  if (reasons == null ||
      reasons.length < 2 ||
      reasons.toSet().length != reasons.length ||
      reasons.any(
        (e) => normalizePostReportReason(e).isEmpty || !postReportReasonFits(normalizePostReportReason(e)),
      )) {
    throw const PostReportFailure(PostReportProblem.unsupported);
  }
  return PostReportForm._(
    action: action,
    hidden: List.unmodifiable(hidden),
    reasons: List.unmodifiable(reasons),
    target: target,
  );
}

/// The ajax envelope of an answer with nothing before or after it.
final _ajaxEnvelopeRe = RegExp(r'^\s*(?:<\?xml[^>]*\?>\s*)?<root><!\[CDATA\[([\s\S]*)\]\]></root>\s*$');

/// The one script the forum's ajax `showmessage` appends, last in the fragment.
final _responseScriptRe = RegExp(r'<script type="text/javascript" reload="1">([\s\S]*?)</script>\s*$');

final _jsNameRe = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');
final _jsNumberRe = RegExp(r'[0-9]+(?:\.[0-9]+)?');

/// A single quoted javascript string literal with only the escapes of the forum's message, read as text.
final _jsStringRe = RegExp(r"""'((?:[^'\\\r\n]|\\['\\/n"])*)'""");
final _jsEscapeRe = RegExp(r'''\\(['\\/n"])''');

String _unescapeJs(String s) => s.replaceAllMapped(_jsEscapeRe, (m) => m.group(1) == 'n' ? '\n' : m.group(1)!);

enum _Js { name, string, number, punct }

typedef _JsToken = (_Js, String);

/// Tokens of [source], or null for anything outside the plain call statements of the forum's answer: comments,
/// double quoted strings, operators other than `==` and so on. Nothing is ever run.
List<_JsToken>? _jsTokens(String source) {
  final tokens = <_JsToken>[];
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
    } else if (source.startsWith('==', i)) {
      tokens.add((_Js.punct, '=='));
      i += 2;
    } else if ('(){},;:'.contains(c)) {
      tokens.add((_Js.punct, c));
      i++;
    } else if (_jsStringRe.matchAsPrefix(source, i) case final m?) {
      tokens.add((_Js.string, m.group(1)!));
      i = m.end;
    } else if (_jsNameRe.matchAsPrefix(source, i) case final m?) {
      tokens.add((_Js.name, m.group(0)!));
      i = m.end;
    } else if (_jsNumberRe.matchAsPrefix(source, i) case final m?) {
      tokens.add((_Js.number, m.group(0)!));
      i = m.end;
    } else {
      return null;
    }
  }
  return tokens;
}

_JsToken _p(String value) => (_Js.punct, value);

_JsToken _n(String value) => (_Js.name, value);

final class _JsCursor {
  _JsCursor(this._tokens);

  final List<_JsToken> _tokens;
  var _i = 0;

  bool get atEnd => _i == _tokens.length;

  /// Value of the next token when it is a [kind].
  String? next(_Js kind) {
    if (_i < _tokens.length && _tokens[_i].$1 == kind) {
      return _tokens[_i++].$2;
    }
    return null;
  }

  bool take(_JsToken token) {
    if (_i < _tokens.length && _tokens[_i] == token) {
      _i++;
      return true;
    }
    return false;
  }

  bool takeAll(List<_JsToken> tokens) => tokens.every(take);
}

/// `if(typeof errorhandle_H=='function') {errorhandle_H('message', {values});}`: the message and whether the values
/// are `{}`.
(String, bool)? _readCallback(_JsCursor c, String callback) {
  final head = [_n('if'), _p('('), _n('typeof'), _n(callback), _p('=='), (_Js.string, 'function'), _p(')'), _p('{')];
  if (!c.takeAll([...head, _n(callback), _p('(')])) {
    return null;
  }
  final message = c.next(_Js.string);
  if (message == null || !c.takeAll([_p(','), _p('{')])) {
    return null;
  }
  var empty = true;
  if (!c.take(_p('}'))) {
    empty = false;
    do {
      if (c.next(_Js.string) == null || !c.take(_p(':')) || c.next(_Js.string) == null) {
        return null;
      }
    } while (c.take(_p(',')));
    if (!c.take(_p('}'))) {
      return null;
    }
  }
  if (!c.takeAll([_p(')'), _p(';'), _p('}')])) {
    return null;
  }
  return (_unescapeJs(message), empty);
}

/// Kinds of the `showDialog` arguments after the text and the mode, as the forum's `showmessage` writes them without
/// a forward: title, func, cover, funccancel, leftmsg, confirmtxt, canceltxt, closetime (configured), locationtime.
const List<_Arg> _dialogArgs = [
  _Arg.nil,
  _Arg.nil,
  _Arg.number,
  _Arg.nil,
  _Arg.nil,
  _Arg.nil,
  _Arg.nil,
  _Arg.either,
  _Arg.nil,
];

enum _Arg { nil, number, either }

/// `hideWindow('H');showDialog('message', 'mode', null, null, 0, null, null, null, null, 3, null);`: the message and
/// the mode. A forward (a function or a location time) is not a known report answer.
(String, String)? _readDialog(_JsCursor c, String handle) {
  if (!c.takeAll([_n('hideWindow'), _p('('), (_Js.string, handle), _p(')'), _p(';'), _n('showDialog'), _p('(')])) {
    return null;
  }
  final message = c.next(_Js.string);
  if (message == null || !c.take(_p(','))) {
    return null;
  }
  final mode = c.next(_Js.string);
  if (mode == null) {
    return null;
  }
  for (final arg in _dialogArgs) {
    if (!c.take(_p(','))) {
      return null;
    }
    final ok = (arg != _Arg.number && c.take(_n('null'))) || (arg != _Arg.nil && c.next(_Js.number) != null);
    if (!ok) {
      return null;
    }
  }
  if (!c.takeAll([_p(')'), _p(';')])) {
    return null;
  }
  return (_unescapeJs(message), mode);
}

/// Read the answer [raw] of the report request of [form] without running it.
///
/// Only the script the forum's ajax `showmessage` writes is read, token by token, never run: the ajax envelope,
/// exactly one `<script type="text/javascript" reload="1">` that ends the fragment and is a real script element,
/// holding exactly `if(typeof errorhandle_H=='function') {errorhandle_H('text', {...});}` for this form's handle,
/// optionally followed by `hideWindow('H');showDialog('text', 'mode', ...);`.
///
/// Success is only `report_succeed`: the callback with `{}` and the `right` dialog of the same text. The callback alone
/// is an explicit refusal. Anything else (text in comments, strings or plain html, another handle, other statements, a
/// forward, another dialog mode, a bare 200) is [PostReportUnknown]: the forum may have stored the report.
PostReportOutcome parsePostReportResult(String raw, {required PostReportForm form}) {
  try {
    return _parsePostReportResult(raw, form: form);
  } on Object {
    return const PostReportUnknown();
  }
}

PostReportOutcome _parsePostReportResult(String raw, {required PostReportForm form}) {
  final html = _ajaxEnvelopeRe.firstMatch(raw)?.group(1);
  if (html == null || html.contains(']]>') || html.contains('<![CDATA[')) {
    return const PostReportUnknown();
  }
  final lower = html.toLowerCase();
  if ('<script'.allMatches(lower).length != 1 || '</script'.allMatches(lower).length != 1) {
    return const PostReportUnknown();
  }
  final source = _responseScriptRe.firstMatch(html)?.group(1);
  if (source == null || source.contains('<!--')) {
    return const PostReportUnknown();
  }
  // The script must be an element the browser runs, not text of a comment, a textarea, a template and so on.
  final doc = parseHtmlDocument(html);
  final scripts = doc.querySelectorAll('script');
  if (scripts.length != 1 ||
      scripts.single.text != source ||
      !(scripts.single.parent == doc.head || scripts.single.parent == doc.body)) {
    return const PostReportUnknown();
  }
  final tokens = _jsTokens(source);
  if (tokens == null) {
    return const PostReportUnknown();
  }
  final handle = form.target.handleKey;
  final cursor = _JsCursor(tokens);
  final callback = _readCallback(cursor, 'errorhandle_$handle');
  if (callback == null) {
    return const PostReportUnknown();
  }
  final (message, emptyValues) = callback;
  if (cursor.atEnd) {
    return PostReportRejected(plainForumText(message), notLoggedIn: _hasLoginMarker(doc, html));
  }
  final dialog = _readDialog(cursor, handle);
  if (dialog == null || !cursor.atEnd) {
    return const PostReportUnknown();
  }
  final (dialogMessage, mode) = dialog;
  if (mode != 'right' || dialogMessage != message || !emptyValues) {
    return const PostReportUnknown();
  }
  final text = plainForumText(message);
  return text.isEmpty ? const PostReportUnknown() : PostReportSucceeded(text);
}
