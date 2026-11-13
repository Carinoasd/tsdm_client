import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// A link of the forum found in a piece of text by [findForumLinkInText].
@immutable
final class ForumLinkInText {
  /// Constructor.
  const ForumLinkInText({required this.url, required this.route});

  /// The link, absolute and on the forum host: what `dispatchAsUrl` opens.
  final String url;

  /// The page of the app the link opens, null when the app has none (the "open in app" page shows it then).
  final RecognizedRoute? route;

  /// Whether the link opens a thread (or a floor of one).
  bool get isThread => route?.screenPath == ScreenPaths.threadV1;

  @override
  bool operator ==(Object other) => other is ForumLinkInText && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'ForumLinkInText($url)';
}

/// The characters a url is made of (RFC 3986): any other character, a white space, a CJK character or punctuation,
/// ends it. Shared texts often put words right after the link without a space.
const _urlChars = r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]";

/// A web link with its scheme, or a link of the forum written without one (`www.tsdm39.com/…`, `tsdm39.com/…`) that
/// does not go on from a longer host or path. Without a scheme a path or a query must follow: the bare name of the
/// site in a sentence ("tsdm39.com 打不开") is no link.
final _linkRe = RegExp(
  '(?:https?://$_urlChars+)|(?:(?<![A-Za-z0-9.\\-/@:%])(?:www\\.)?tsdm39\\.com(?![A-Za-z0-9\\-]|\\.[A-Za-z0-9])[/?#]$_urlChars*)',
  caseSensitive: false,
);

/// Punctuation that ends a sentence rather than the link when it closes a match.
final _trailingRe = RegExp(r"[.,;:!?'\x22]+$");

/// The first link of the forum in [text], null when there is none.
///
/// Every link of the text is looked at in order, as a whole: a link of another site never counts, also when a forum
/// link sits inside it (`https://other.site/?u=https://www.tsdm39.com/…`), nor does a host merely starting like the
/// forum's (`www.tsdm39.com.other.site`, `www.tsdm39.com@other.site`). A link of the forum is taken as the forum
/// rewrites it in posts ([fixOldForumUrl]): its old domains and the rewritten paths of threads and forums
/// (`thread-1-2-1.html`, `forum-2-1.html`) are the current pages.
///
/// The link is then parsed as the app parses any forum link ([ParseUrl.parseUrlToRoute]).
ForumLinkInText? findForumLinkInText(String text) {
  for (final match in _linkRe.allMatches(text)) {
    final raw = _trimLink(match.group(0)!);
    final withScheme = raw.toLowerCase().startsWith('http') ? raw : 'https://$raw';
    final fixed = fixOldForumUrl(withScheme);
    final uri = Uri.tryParse(fixed);
    if (uri == null || !uri.isForumHost) {
      continue;
    }
    // Always the canonical https host of the forum, whatever the text said: no user info, no port.
    final url = Uri(
      scheme: 'https',
      host: baseHost,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
    return ForumLinkInText(url: url, route: url.parseUrlToRoute());
  }
  return null;
}

/// [link] without the punctuation closing the sentence it ends, and without a closing bracket it does not open.
String _trimLink(String link) {
  var s = link;
  while (true) {
    final before = s;
    s = s.replaceFirst(_trailingRe, '');
    for (final (open, close) in const [('(', ')'), ('[', ']')]) {
      if (s.endsWith(close) && close.allMatches(s).length > open.allMatches(s).length) {
        s = s.substring(0, s.length - 1);
      }
    }
    if (s == before) {
      return s;
    }
  }
}

/// The link of the forum a change of a text field from [before] to [after] put in at once: a paste (or a drop) of a
/// piece of text with a forum link in it. Null when the change put no such link in, also when it is the last
/// character of a link typed one by one: only what was inserted by the change is looked at.
///
/// [selection] is the selection of the field before the change: a paste replacing the selected text (all of it, or a
/// link selected and pasted over with another) inserted what is now between the text before and after the selection.
ForumLinkInText? forumLinkPasted(String before, String after, {TextSelection? selection}) {
  if (selection != null && selection.isValid && !selection.isCollapsed && selection.end <= before.length) {
    final head = before.substring(0, selection.start);
    final tail = before.substring(selection.end);
    if (after.length >= head.length + tail.length && after.startsWith(head) && after.endsWith(tail)) {
      final inserted = after.substring(head.length, after.length - tail.length);
      return inserted.length < 2 ? null : findForumLinkInText(inserted);
    }
  }
  if (after.length <= before.length) {
    return null;
  }
  var start = 0;
  final common = before.length < after.length ? before.length : after.length;
  while (start < common && before.codeUnitAt(start) == after.codeUnitAt(start)) {
    start++;
  }
  var end = 0;
  while (end < common - start &&
      before.codeUnitAt(before.length - 1 - end) == after.codeUnitAt(after.length - 1 - end)) {
    end++;
  }
  final inserted = after.substring(start, after.length - end);
  // One character is a key press.
  if (inserted.length < 2) {
    return null;
  }
  return findForumLinkInText(inserted);
}
