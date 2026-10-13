/// The JSON page answer the forum's app API (Discuz plugin `tsdmapp`, `tsdmapp.class.php`) gives for a web page,
/// rebuilt here from the web page itself: the blocks the plugin keeps for that kind of page, cut by position exactly as
/// its `skeleton()` does, plus the `<title>` (since 1.6.0), the `<link>`s and the `discuz_uid` script of the page head
/// (`headlinks()`).
///
/// Tests feed a page fixture through this and the app's parser, and check the result is the one of the web page: the
/// pages plugin 1.6.0 adds (notice, my threads, friends, guide) have no recorded JSON answer yet, and the others need
/// none of their own. The answers of 1.5.0, the plugin on the forum now, are the same without the title.
library;

import 'dart:convert';

RegExp _re(String source) => RegExp(source, caseSensitive: false);

extension<T extends Object> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// One kept block: its start tag, whether only the first one counts, and the tag the block is cut before (else the
/// matching end tag).
typedef _Rule = ({RegExp start, bool first, RegExp? end});

_Rule _r(String start, {bool first = false, String? end}) =>
    (start: _re(start), first: first, end: end == null ? null : _re(end));

final _Rule _pt = _r(r'<div\b[^>]*\bid="pt"');
final _Rule _ct = _r(r'<div\b[^>]*\bid="ct"', end: r'<div\b[^>]*\bid="ft"');

/// The page types plugin 1.6.0 adds: notice, my threads (`do=thread`, type `mythread`), friends and guide, cut like the
/// private message pages (`#pt`, `#ct` up to the footer). Only 1.6.0 and later answer them.
const pagesSince160 = {'notice', 'mythread', 'friend', 'guide'};

/// `$keep` of the plugin, by page type.
final Map<String, List<_Rule>> _keep = {
  'viewthread': [
    _pt,
    _r(r'<div\b[^>]*\bid="postlist"', end: r'<form\b[^>]*\bid="modactions"'),
    _r(r'<form\b[^>]*\bid="fastpostform"'),
    _r(r'<input\b[^>]*\bname="srhfid"'),
    _r(r'<div\b[^>]*\bclass="[^"]*\bmodact\b[^"]*"'),
    _r(r'<div\b[^>]*\bid="md_[^"]*_menu"'),
    _r(r'<div\b[^>]*\bclass="pg"', first: true),
  ],
  'index': [_r(r'<div\b[^>]*\bid="hd"'), _pt, _ct],
  for (final page in ['pm', 'favorite', 'search', ...pagesSince160]) page: [_pt, _ct],
};

/// `$common` of the plugin: kept on every page.
final List<_Rule> _common = [
  _r(r'<div\b[^>]*\bid="messagetext"'),
  _r(r'<div\b[^>]*\bid="messagelogin"'),
  _r(r'<form\b[^>]*\bid="lsform"'),
  _r(r'<div\b[^>]*\bid="um"'),
  _r(r'<div\b[^>]*\bclass="block_name"'),
  _r(r'<script\b[^>]*\bsrc="[^"]*\bop=checknewpm\b[^"]*"[^>]*>', first: true),
];

const _void = {'input', 'img', 'br', 'hr', 'link', 'meta'};

/// `element_end()`: the position after the end tag matching the start tag at [start], skipping comments, scripts and
/// styles; null when there is none.
int? _elementEnd(String html, int start) {
  final open = _re(r'<([a-z][a-z0-9]*)\b[^>]*>').matchAsPrefix(html, start);
  if (open == null) {
    return null;
  }
  final tag = open.group(1)!.toLowerCase();
  var pos = start + open.group(0)!.length;
  if (_void.contains(tag) || open.group(0)!.endsWith('/>')) {
    return pos;
  }
  var depth = 1;
  final re = _re('<!--|<(script|style)\\b[^>]*>|<(/?)($tag)\\b[^>]*>');
  while (pos < html.length) {
    final t = re.allMatches(html, pos).firstOrNull;
    if (t == null) {
      return null;
    }
    if (t.group(0) == '<!--') {
      final close = html.indexOf('-->', t.start + 4);
      if (close < 0) {
        return null;
      }
      pos = close + 3;
      continue;
    }
    final skipped = t.group(1);
    if (skipped != null && skipped.toLowerCase() != tag) {
      final close = html.toLowerCase().indexOf('</${skipped.toLowerCase()}', t.start + 1);
      if (close < 0) {
        return null;
      }
      pos = close + 2;
      continue;
    }
    pos = t.end;
    depth += t.group(2) == '/' ? -1 : 1;
    if (depth == 0) {
      return pos;
    }
  }
  return null;
}

/// `skeleton()`: the kept blocks of [html] for page [type] in page order, a block inside another one only once, after
/// the form hash input the plugin puts first.
String pageDocumentOf(String html, String type) {
  final ranges = <(int, int)>[];
  for (final rule in [...?_keep[type], ..._common]) {
    for (final hit in rule.start.allMatches(html)) {
      final end = rule.end?.allMatches(html, hit.start).firstOrNull?.start ?? _elementEnd(html, hit.start);
      if (end != null) {
        ranges.add((hit.start, end));
      }
      if (rule.first) {
        break;
      }
    }
  }
  ranges.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.compareTo(a.$2));
  final out = StringBuffer();
  var last = -1;
  for (final (start, end) in ranges) {
    if (start < last) {
      continue;
    }
    out
      ..write(html.substring(start, end))
      ..write('\n');
    last = end;
  }
  // The plugin writes the session's FORMHASH; a page shows it in a form field or in links.
  final formHash = _re(r'name="formhash" value="(\w+)"|formhash=(\w{8})\b').firstMatch(html)?.let((m) => m[1] ?? m[2]);
  return '${formHash == null ? '' : '<input type="hidden" name="formhash" value="$formHash" />\n'}$out';
}

/// `headlinks()`: the `<title>` of the page head when [title] (plugin 1.6.0 and later), its `<link>`s and the script
/// declaring `discuz_uid`.
String pageHeadOf(String html, {required bool title}) {
  final head = RegExp(r'<head\b.*?</head>', caseSensitive: false, dotAll: true).firstMatch(html)?.group(0) ?? '';
  return [
    if (title) ?_re(r'<title\b[^>]*>[^<]*</title>').firstMatch(head)?.group(0),
    ..._re(r'<link\b[^>]*>').allMatches(head).map((m) => m.group(0)!),
    ?_re(r'<script\b[^>]*>[^<]*\bdiscuz_uid\s*=[^<]*</script>').firstMatch(head)?.group(0),
  ].join('\n');
}

/// The JSON answer of page [type] for the web page [html], as plugin 1.6.0 gives it, or as 1.5.0 does when [v150] (the
/// head without the title; it answers none of [pagesSince160]). A forum notice on the page makes it a failure, which
/// still carries the blocks, as the plugin does.
String pageAnswerOf(String html, String type, {bool v150 = false}) {
  assert(!v150 || !pagesSince160.contains(type), 'plugin 1.5.0 answers $type as the web page');
  final message = _re(r'<div\b[^>]*\bid="messagetext"').hasMatch(html);
  final uid = int.tryParse(RegExp(r"discuz_uid\s*=\s*'(\d+)'").firstMatch(html)?.group(1) ?? '') ?? 0;
  return jsonEncode({
    if (message) ...{
      'ok': 0,
      'error': 'message',
      'message': 'notice',
    } else ...{
      'ok': 1,
      'api': 1,
      'uid': uid,
      'type': type,
      'page': 1,
    },
    'head': pageHeadOf(html, title: !v150),
    'document': pageDocumentOf(html, type),
  });
}
