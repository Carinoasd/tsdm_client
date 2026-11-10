import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

part 'post_comment.mapper.dart';

/// One comment (点评) under a floor.
///
/// The forum prints the comments of a floor in its `div#comment_PID.cm` ([splitPostComments]) and the pages after the
/// first through `forum.php?mod=misc&action=commentmore` ([parsePostCommentMore]). The forum's app API gives the same
/// as fields since plugin 3.7.0 ([PostComment.fromApi], [postCommentsFromApi]).
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

  /// The comment [c] of a floor of the forum's app API (plugin 3.7.0: `posts[].comments[]` of a thread page answer of
  /// `schema` 21 or later, `comments[]` of a page of comments, `schema` 22), the same [PostComment] the page's row
  /// gives: `id` (every comment has it, whoever reads), the author (`authorid` 0 a guest, named as the page names
  /// one), `avatar`, `dateline` as the forum's wall clock with [timeOffset] (the answer's `timeoffset`) printed as
  /// the page keeps it ("2026-11-10 10:34"), the plain text `comment` with its line breaks, and `can_delete`.
  factory PostComment.fromApi(Map<String, dynamic> c, {num timeOffset = 8}) {
    final uid = tsdmAppInt(c['authorid']);
    final name = tsdmAppText(c['author']).trim();
    final avatar = tsdmAppText(c['avatar']).trim();
    final id = tsdmAppInt(c['id']);
    final at = tsdmAppWallClockTime(c['dateline'], timeOffset);
    return PostComment(
      id: id > 0 ? id : null,
      authorUid: uid > 0 ? uid : null,
      authorName: name.isEmpty ? _guestName : name,
      avatarUrl: avatar.isEmpty ? null : avatar,
      time: at == null
          ? null
          : '${at.year}-${at.month}-${at.day} '
                '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
      content: tsdmAppText(c['comment']).replaceAll('\r\n', '\n').trim(),
      canDelete: tsdmAppInt(c['can_delete']) == 1 && id > 0,
    );
  }

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

/// What the forum's page prints for the author of a guest's comment.
const _guestName = '游客';

/// The average of one item the comments of a floor scored (点评 with 评分项: the stars the page prints above the
/// comments), as the forum's app API gives it (plugin 3.7.0, `comment_scores`).
@immutable
final class PostCommentScore {
  /// Constructor.
  const PostCommentScore({required this.name, required this.score});

  /// The item's name, as the forum set it.
  final String name;

  /// The average, 0 to 5.
  final double score;

  /// [score] as the page prints it: always with one decimal ("4.0", "4.5").
  String get text => score.toStringAsFixed(1);

  @override
  bool operator ==(Object other) => other is PostCommentScore && other.name == name && other.score == score;

  @override
  int get hashCode => Object.hash(name, score);
}

/// The comments in `comments` of a floor or of a page of comments of the forum's app API (plugin 3.7.0), newest
/// first as the forum gives them; null when [comments] is not a list (an older plugin: the floor has no such field).
List<PostComment>? postCommentsFromApi(Object? comments, {num timeOffset = 8}) => comments is List
    ? [for (final c in comments.whereType<Map<String, dynamic>>()) PostComment.fromApi(c, timeOffset: timeOffset)]
    : null;

/// The averages in `comment_scores` of a floor or of a page of comments (plugin 3.7.0), items without a name left
/// out; empty when there are none.
List<PostCommentScore> postCommentScoresFromApi(Object? scores) => scores is List
    ? [
        for (final s in scores.whereType<Map<String, dynamic>>())
          if (tsdmAppText(s['name']).trim().isNotEmpty && s['score'] is num)
            PostCommentScore(name: tsdmAppText(s['name']).trim(), score: (s['score'] as num).toDouble()),
      ]
    : const [];

/// A page of the comments of a floor answered by the forum's app API as fields (plugin 3.7.0, `type: comments`,
/// `schema` 22) in [data]; null for anything else (an older plugin's write result, the forum's fragment, its
/// message).
///
/// The times are the forum's wall clock with the answer's own `timeoffset` (plugin 3.8.0: the offset of the account
/// the page was served to, as the thread page's); an answer that names none (before) has them printed with
/// [timeOffset], the offset the floor's page printed its times with.
///
/// There is a next page while this one is before the last (`page` below `pages`) and has comments.
PostCommentPage? postCommentPageFromApi(Object? data, {num timeOffset = 8}) {
  final json = tsdmAppAnswerJson(data);
  if (json == null || json['ok'] != 1 || json['type'] != 'comments') {
    return null;
  }
  final comments = postCommentsFromApi(
    json['comments'],
    timeOffset: json['timeoffset'] is num ? json['timeoffset'] as num : timeOffset,
  );
  if (comments == null) {
    return null;
  }
  return (comments: comments, hasMore: comments.isNotEmpty && tsdmAppInt(json['page']) < tsdmAppInt(json['pages']));
}

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

/// The length of [text] as the forum counts a comment against its limit (`cutstr($comment, 200)` of
/// `post/newreply.php`, on the escaped text): a printable ASCII character, a tab or a line break 1 (an escaped `&`,
/// `"`, `<`, `>` as well: `cutstr` counts the entity as its character), any other character 2, a control character
/// 0. The forum cuts a longer comment without saying so; the window's counter (`dstrLenCalc`) counts otherwise.
int postCommentLength(String text) => text.runes.fold(0, (n, r) => n + _postCommentUnits(r));

int _postCommentUnits(int rune) => rune >= 128 ? 2 : (rune == 9 || rune == 10 || (rune >= 32 && rune <= 126) ? 1 : 0);

/// The longest start of [text] whose [postCommentLength] is at most [limit], cut as the forum's `cutstr` cuts it (by
/// code point).
String postCommentFit(String text, int limit) {
  final buffer = StringBuffer();
  var n = 0;
  for (final rune in text.runes) {
    n += _postCommentUnits(rune);
    if (n > limit) {
      break;
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}
