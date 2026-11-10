import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

part 'post_comment.mapper.dart';

/// One comment (点评) under a floor.
///
/// The forum prints the comments of a floor in its `div#comment_PID.cm` ([splitPostComments]) and the pages after the
/// first through `forum.php?mod=misc&action=commentmore` ([parsePostCommentMore]). A later answer of the forum's app
/// API can build the same fields directly.
@MappableClass()
final class PostComment with PostCommentMappable {
  /// Constructor.
  const PostComment({
    required this.authorName,
    required this.content,
    this.id,
    this.authorUid,
    this.avatarUrl,
    this.time,
    this.canDelete = false,
  });

  /// The comment's id (`pre_forum_postcomment.id`), known when the forum offers to delete it.
  final int? id;

  /// The author's uid, null for a guest.
  final int? authorUid;

  /// The author's name, as the page prints it ("游客" for a guest).
  final String authorName;

  /// The author's avatar.
  final String? avatarUrl;

  /// When it was posted: the full time the page keeps in the `title` of a relative one ("2026-11-10 10:34"), else the
  /// time as printed.
  final String? time;

  /// The text, with the line breaks the forum printed.
  final String content;

  /// The forum offers this account to delete it (`modaction('delcomment', ID)`: moderators of the forum).
  final bool canDelete;
}

/// A page of the comments of a floor.
typedef PostCommentPage = ({List<PostComment> comments, bool hasMore});

/// `onclick="modaction('delcomment', 18)"`.
final _deleteRe = RegExp(r"""modaction\(\s*['"]delcomment['"]\s*,\s*(\d+)""");

/// The prefix of the time line ("发表于 …").
final _postedOnRe = RegExp(r'^\s*(?:发表于|發表於)\s*');

/// Split the comment block of floor [pid] out of the floor's content [data] (`div.pcb` of the web page, `body_html`
/// of the app API).
///
/// Returns the content without the block, as the forum printed it (the cut is made on the source, nothing is
/// serialized again), and the comments of the block. A floor without the block, or with a block whose end cannot be
/// found, comes back unchanged without comments: the content renderer then shows the block as before.
({String data, PostCommentPage? comments}) splitPostComments(String data, String pid) {
  final marker = data.indexOf('id="comment_$pid"');
  if (marker < 0) {
    return (data: data, comments: null);
  }
  final start = data.lastIndexOf('<div', marker);
  if (start < 0 || data.indexOf('>', start) < marker) {
    return (data: data, comments: null);
  }
  final end = _endOfDiv(data, start);
  if (end == null) {
    return (data: data, comments: null);
  }
  final block = data.substring(start, end);
  final root = parseHtmlDocument(block).querySelector('div#comment_$pid');
  if (root == null) {
    return (data: data, comments: null);
  }
  return (data: data.replaceRange(start, end, ''), comments: _commentsIn(root));
}

/// The end (exclusive) of the `<div>` opened at [start] in [html], null when it is not closed.
///
/// The forum escapes what a comment says (`dhtmlspecialchars`), so the tags in the block are the template's.
int? _endOfDiv(String html, int start) {
  final tags = RegExp(r'<div\b|</div\s*>', caseSensitive: false);
  var depth = 0;
  for (final m in tags.allMatches(html, start)) {
    if (m[0]!.startsWith('</')) {
      depth--;
      if (depth == 0) {
        return m.end;
      }
    } else {
      depth++;
    }
  }
  return null;
}

/// The comments in [root] and whether the forum has a next page of them (`a.nxt`, or a link to [nextPage]).
PostCommentPage _commentsIn(uh.Element root, {int nextPage = 2}) {
  final comments = root.querySelectorAll('div.pstl').map(_commentOf).whereType<PostComment>().toList(growable: false);
  final pager = root.querySelectorAll('div.pgs a');
  final hasMore = pager.any(
    (a) =>
        a.classes.contains('nxt') ||
        ((a.attributes['href'] ?? '').contains('commentmore') &&
            Uri.tryParse(a.attributes['href']!.replaceAll('&amp;', '&'))?.queryParameters['page'] == '$nextPage'),
  );
  return (comments: comments, hasMore: hasMore);
}

/// The comments of page [page] of `forum.php?mod=misc&action=commentmore` ([html], the fragment the forum answers).
PostCommentPage parsePostCommentMore(String html, {required int page}) {
  final root = parseHtmlDocument('<div>$html</div>').body!;
  return _commentsIn(root, nextPage: page + 1);
}

/// One comment row `div.pstl`; null for the row of the item scores (no `div.psta`) and an empty row.
///
/// ```html
/// <div class="pstl xs1 cl">
///   <div class="psta vm">
///     <a href="home.php?mod=space&uid=33" c="1"><img data-src="AVATAR"></a>
///     <a href="home.php?mod=space&uid=33" class="xi2 xw1">NAME</a>
///   </div>
///   <div class="psti">
///     TEXT&nbsp;
///     <span class="xg1">发表于 <span title="2026-11-10 10:34">6&nbsp;秒前</span>&nbsp;IP:…&nbsp;
///       <a href="javascript:;" onclick="modaction('delcomment', 18)">删除</a></span>
///   </div>
/// </div>
/// ```
///
/// The more pages print the avatar without its link, a guest's row the name as text; the older layout put the
/// author link in `div.psti`. A comment made by a reply (`rpid`) has the links to that reply after its text, which
/// are not its text.
PostComment? _commentOf(uh.Element row) {
  final psta = row.querySelector('div.psta');
  final body = row.querySelector('div.psti');
  if (psta == null || body == null) {
    return null;
  }
  final author =
      psta.querySelector('a.xi2') ??
      body.children.where((e) => e.localName == 'a' && e.classes.contains('xi2')).firstOrNull;
  final name = (author?.text ?? psta.text ?? '').replaceAll(' ', ' ').trim();
  final uid = int.tryParse(Uri.tryParse(_unescape(author?.attributes['href'] ?? ''))?.queryParameters['uid'] ?? '');
  final avatar = _avatarOf(psta.querySelector('img'));

  uh.Element? timeNode;
  final buffer = StringBuffer();
  void collect(uh.Node node) {
    if (node.nodeType == uh.Node.TEXT_NODE) {
      buffer.write(node.text ?? '');
      return;
    }
    if (node is! uh.Element || node == author) {
      return;
    }
    if (node.parentNode == body && node.localName == 'span' && node.classes.contains('xg1')) {
      timeNode ??= node;
      return;
    }
    final href = node.attributes['href'] ?? '';
    if (node.localName == 'script' ||
        node.localName == 'style' ||
        (node.localName == 'a' && (href.contains('goto=findpost') || href.contains('action=reply')))) {
      return;
    }
    if (node.localName == 'br') {
      buffer.writeln();
      return;
    }
    node.nodes.forEach(collect);
  }

  body.nodes.forEach(collect);
  final content = buffer.toString().replaceAll(' ', ' ').split('\n').map((e) => e.trim()).join('\n').trim();
  if (name.isEmpty && content.isEmpty) {
    return null;
  }

  String? time;
  int? id;
  if (timeNode case final node?) {
    time = node.querySelector('span[title]')?.attributes['title']?.trim();
    if (time == null || time.isEmpty) {
      // The text before the IP and the delete link.
      final text = node.nodes
          .where((e) => e.nodeType == uh.Node.TEXT_NODE)
          .map((e) => e.text ?? '')
          .join()
          .replaceAll(' ', ' ');
      final ip = text.indexOf('IP:');
      time = (ip < 0 ? text : text.substring(0, ip)).replaceFirst(_postedOnRe, '').trim();
    }
    if (time.isEmpty) {
      time = null;
    }
    for (final a in node.querySelectorAll('a')) {
      final match = _deleteRe.firstMatch(a.attributes['onclick'] ?? '');
      if (match != null) {
        id = int.tryParse(match.group(1)!);
        break;
      }
    }
  }
  return PostComment(
    id: id,
    authorUid: uid,
    authorName: name,
    avatarUrl: avatar,
    time: time,
    content: content,
    canDelete: id != null,
  );
}

String _unescape(String s) => s.replaceAll('&amp;', '&');

/// The avatar of an `<img>`: the lazy `data-src` first; a path of the forum (`./data/avatar/…`) on its host.
String? _avatarOf(uh.Element? img) {
  final url = (img?.attributes['data-src'] ?? img?.attributes['data-original'] ?? img?.attributes['src'])?.trim();
  if (url == null || url.isEmpty) {
    return null;
  }
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }
  if (url.startsWith('//')) {
    return 'https:$url';
  }
  return (url.startsWith('./') ? url.substring(2) : url).prependHost();
}

/// The url of the forum's comment window of floor [pid] of thread [tid] (`a.cmmnt`).
String postCommentWindowUrl({required String tid, required String pid}) =>
    '$baseUrl/forum.php?mod=misc&action=comment&tid=$tid&pid=$pid&extra=&page=1';
