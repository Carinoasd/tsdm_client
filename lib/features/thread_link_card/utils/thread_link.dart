import 'package:flutter/foundation.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/uri.dart';

/// At most this many links of one floor are drawn as cards ([threadLinkOf]); the links after them stay links.
const maxThreadLinkCardsPerFloor = 10;

/// A link in a post's content to a thread of the forum, drawn as a card of the thread.
@immutable
final class ThreadLink {
  /// Constructor.
  const ThreadLink({required this.tid, required this.url});

  /// The thread linked.
  final int tid;

  /// The url opened when the card is tapped: the link itself, on the forum host.
  final String url;

  @override
  bool operator ==(Object other) => other is ThreadLink && other.tid == tid && other.url == url;

  @override
  int get hashCode => Object.hash(tid, url);

  @override
  String toString() => 'ThreadLink($tid, $url)';
}

/// The thread a link to [href] showing [text] leads to, when it is drawn as a card: the link shows a url itself (a
/// link with text of its own stays as the author wrote it) and points at a thread of the forum.
///
/// The links of a thread:
///
/// * `forum.php?mod=viewthread&tid=N` (with any other parameter: a page, an order, a floor anchor);
/// * `thread-N-P-X.html`, the rewritten url of page `P`;
/// * `forum.php?mod=redirect&goto=findpost&pid=…&ptid=N`, a floor of the thread.
///
/// The text shows the url as the forum prints it: the url (with or without its scheme); for a url longer than 65
/// characters its first 32 and last 19 characters around ` ... ` (`parseurl` of `function_discuzcode.php`); or
/// another url of the same thread: the forum turns the link of `[url]…/thread-N-P-X.html[/url]` into
/// `forum.php?mod=viewthread&tid=N&page=P` and leaves the text as it was written.
ThreadLink? threadLinkOf(String href, String text) {
  final link = _threadLinkOfUrl(href.trim());
  if (link == null) {
    return null;
  }
  if (_showsUrl(href, text)) {
    return link;
  }
  final shown = _threadLinkOfUrl(_urlOfText(text));
  return shown != null && shown.tid == link.tid ? link : null;
}

/// The thread [url] links, null for a url of anything else or out of the forum.
ThreadLink? _threadLinkOfUrl(String url) {
  if (url.isEmpty) {
    return null;
  }
  final parsed = Uri.tryParse(url);
  if (parsed == null) {
    return null;
  }
  // `//www.tsdm39.com/…`: on the scheme of the page.
  final uri = !parsed.hasScheme && parsed.hasAuthority ? Uri.tryParse('https:$url') : parsed;
  if (uri == null || !uri.isForumOrRelative) {
    return null;
  }
  final absolute = uri.hasScheme ? uri : Uri.parse('$baseUrl/').resolveUri(uri);
  final path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;

  final rewritten = _rewrittenRe.firstMatch(path);
  if (rewritten != null) {
    final tid = int.parse(rewritten.group(1)!);
    final page = int.tryParse(rewritten.group(2)!) ?? 1;
    return ThreadLink(
      tid: tid,
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid${page > 1 ? '&page=$page' : ''}',
    );
  }
  if (path.toLowerCase() != 'forum.php') {
    return null;
  }
  final Map<String, String> query;
  try {
    query = uri.queryParameters;
  } on FormatException {
    return null;
  }
  final tid = switch (query['mod']) {
    'viewthread' => _id(query['tid']),
    'redirect' when query['goto'] == 'findpost' => _id(query['ptid']),
    _ => null,
  };
  if (tid == null) {
    return null;
  }
  return ThreadLink(tid: tid, url: '$absolute');
}

/// The url [text] is, empty when it is not one: a word without white space starting with `http://`, `https://` or
/// `www.`.
String _urlOfText(String text) {
  final t = text.trim();
  if (t.isEmpty || t.contains(RegExp(r'\s'))) {
    return '';
  }
  final lower = t.toLowerCase();
  if (lower.startsWith('www.')) {
    return 'http://$t';
  }
  return lower.startsWith('http://') || lower.startsWith('https://') ? t : '';
}

/// `thread-N-P-X.html`.
final _rewrittenRe = RegExp(r'^thread-([1-9]\d*)-(\d+)-\d+\.html$', caseSensitive: false);

/// The cut text of a long url: `<first 32> ... <last 19>`.
final _cutRe = RegExp(r'^(.+) \.\.\. (.+)$');

int? _id(String? s) {
  final id = int.tryParse(s ?? '');
  return id != null && id > 0 ? id : null;
}

/// [url] without its `http://` or `https://`, in lower case: the text of a link may leave the scheme out (`www.…`).
String _bare(String url) {
  final s = url.trim().toLowerCase();
  if (s.startsWith('https://')) {
    return s.substring('https://'.length);
  }
  if (s.startsWith('http://')) {
    return s.substring('http://'.length);
  }
  return s;
}

/// Whether [text] is the url [href] itself, as the forum prints a link without text of its own.
bool _showsUrl(String href, String text) {
  final t = _bare(text.replaceAll(RegExp(r'\s+'), ' '));
  if (t.isEmpty) {
    return false;
  }
  final h = _bare(href);
  if (t == h) {
    return true;
  }
  final cut = _cutRe.firstMatch(t);
  if (cut == null) {
    return false;
  }
  final head = _bare(cut.group(1)!);
  final tail = cut.group(2)!;
  return head.length + tail.length < h.length && h.startsWith(head) && h.endsWith(tail);
}
