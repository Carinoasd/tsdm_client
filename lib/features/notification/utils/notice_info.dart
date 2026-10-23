import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// What a notice is about, for its icon, its title and the sentence of a system notification.
///
/// Told by the notice `type` of the forum (the same on the forum's app API and in the notice's ignore link) and, from
/// the app API only, its `from_idtype`. The values are the ones the forum and its plugins write (`home_notification`):
///
/// | type | from_idtype | kind |
/// |---|---|---|
/// | `post` | `post` | [reply] |
/// | `post` | `quote` | [quote] |
/// | `post` | `moderate_*` (closed, moved, deleted, warned, stuck...) | [moderation] |
/// | `post` | none (notice page, older plugin) | [reply] when the body links a floor, else [post] |
/// | `at` | `at`, `atplus`, `atplusgroup` | [mention] |
/// | `rate`, `ratetrack` | `rate`, none | [rate] |
/// | `pcomment` | `pcomment` | [comment] |
/// | `friend` | `friendrequest` | [friendRequest] |
/// | `friend` | none | [friend] (or [friendRequest] when the body asks to approve) |
/// | `poke` | `pokequery` | [poke] |
/// | `wall` | `uid` | [wall] |
/// | `reward` | none | [reward] |
/// | `activity` | none | [activity] |
/// | `medal` | none | [medal] |
/// | `magic` | none | [magic] |
/// | `system` | `dsumedal`, `changeusergroup`, `modthreads`, `banspeak`, `hongbao`, `sendnotice`... | [system] |
/// | `report`, `pmreport`, `verify*` | `newreport`, `verifythread`... | [manage] |
/// | anything else, or no type (an older plugin, a notice page without the ignore link) | | [generic] |
enum NoticeKind {
  /// A reply to a thread or post of the user.
  reply,

  /// A reply quoting a post of the user.
  quote,

  /// The user was mentioned (`@`) in a post, or a group of the user was.
  mention,

  /// A post of the user was rated.
  rate,

  /// A post of the user got a comment (点评).
  comment,

  /// Another user became a friend.
  friend,

  /// Another user asks to be a friend.
  friendRequest,

  /// Another user poked the user.
  poke,

  /// A message on the user's wall.
  wall,

  /// A moderator acted on a thread or post of the user.
  moderation,

  /// A notice about a post that is none of the above.
  post,

  /// A bounty of the user, or a reply of the user chosen as the best answer.
  reward,

  /// An activity (event thread) of the user.
  activity,

  /// A medal.
  medal,

  /// A magic item used on the user's thread.
  magic,

  /// A notice the forum itself sends: medals, user group, moderation results, red packets...
  system,

  /// Something waiting for a moderator: reports, threads and posts to review.
  manage,

  /// Unknown: an older plugin without the type, or a type not listed here.
  generic,
}

/// Kind of a notice of [type] and [fromIdType], see [NoticeKind]; [target] is the link the notice opens, for the
/// notices whose type does not tell enough.
NoticeKind noticeKindOf({String? type, String? fromIdType, NoticeTarget? target, String? body}) {
  switch (type) {
    case 'post':
      if (fromIdType == 'quote') {
        return NoticeKind.quote;
      }
      if (fromIdType != null && fromIdType.startsWith('moderate_')) {
        return NoticeKind.moderation;
      }
      if (fromIdType == 'post') {
        return NoticeKind.reply;
      }
      return target?.pid != null ? NoticeKind.reply : NoticeKind.post;
    case 'at':
      return NoticeKind.mention;
    case 'rate' || 'ratetrack':
      return NoticeKind.rate;
    case 'pcomment':
      return NoticeKind.comment;
    case 'friend':
      if (fromIdType == 'friendrequest' || (fromIdType == null && (body?.contains('op=add') ?? false))) {
        return NoticeKind.friendRequest;
      }
      return NoticeKind.friend;
    case 'poke':
      return NoticeKind.poke;
    case 'wall':
      return NoticeKind.wall;
    case 'reward':
      return NoticeKind.reward;
    case 'activity':
      return NoticeKind.activity;
    case 'medal':
      return NoticeKind.medal;
    case 'magic':
      return NoticeKind.magic;
    case 'system':
      return NoticeKind.system;
    case 'report' || 'pmreport':
      return NoticeKind.manage;
    case final String t when t.startsWith('verify'):
      return NoticeKind.manage;
    default:
      return NoticeKind.generic;
  }
}

/// Icon of [kind].
IconData noticeKindIcon(NoticeKind kind) => switch (kind) {
  NoticeKind.reply => Icons.reply_outlined,
  NoticeKind.quote => Icons.format_quote_outlined,
  NoticeKind.mention => Icons.alternate_email_outlined,
  NoticeKind.rate => Icons.thumb_up_alt_outlined,
  NoticeKind.comment => Icons.comment_outlined,
  NoticeKind.friend => Icons.people_outline,
  NoticeKind.friendRequest => Icons.person_add_alt_outlined,
  NoticeKind.poke => Icons.waving_hand_outlined,
  NoticeKind.wall => Icons.edit_note_outlined,
  NoticeKind.moderation => Icons.gavel_outlined,
  NoticeKind.post => Icons.article_outlined,
  NoticeKind.reward => Icons.emoji_events_outlined,
  NoticeKind.activity => Icons.event_outlined,
  NoticeKind.medal => Icons.military_tech_outlined,
  NoticeKind.magic => Icons.auto_fix_high_outlined,
  NoticeKind.system => Icons.info_outline,
  NoticeKind.manage => Icons.admin_panel_settings_outlined,
  NoticeKind.generic => Icons.notifications_outlined,
};

/// Title of [kind], as the card shows it.
String noticeKindLabel(Translations tr, NoticeKind kind) {
  final k = tr.noticePage.kind;
  return switch (kind) {
    NoticeKind.reply => k.reply,
    NoticeKind.quote => k.quote,
    NoticeKind.mention => k.mention,
    NoticeKind.rate => k.rate,
    NoticeKind.comment => k.comment,
    NoticeKind.friend => k.friend,
    NoticeKind.friendRequest => k.friendRequest,
    NoticeKind.poke => k.poke,
    NoticeKind.wall => k.wall,
    NoticeKind.moderation => k.moderation,
    NoticeKind.post => k.post,
    NoticeKind.reward => k.reward,
    NoticeKind.activity => k.activity,
    NoticeKind.medal => k.medal,
    NoticeKind.magic => k.magic,
    NoticeKind.system => k.system,
    NoticeKind.manage => k.manage,
    NoticeKind.generic => k.generic,
  };
}

/// The person and the action of a notice of [kind] by [author] ("A 回复了你的帖子"), null when the kind has no such
/// sentence or the author is unknown.
String? noticeActionOf(Translations tr, NoticeKind kind, String? author) {
  if (author == null || author.isEmpty) {
    return null;
  }
  final a = tr.noticePage.action;
  return switch (kind) {
    NoticeKind.reply => a.reply(user: author),
    NoticeKind.quote => a.quote(user: author),
    NoticeKind.mention => a.mention(user: author),
    NoticeKind.rate => a.rate(user: author),
    NoticeKind.comment => a.comment(user: author),
    NoticeKind.friend => a.friend(user: author),
    NoticeKind.friendRequest => a.friendRequest(user: author),
    NoticeKind.poke => a.poke(user: author),
    NoticeKind.wall => a.wall(user: author),
    _ => null,
  };
}

/// Whether a notice of [kind] can be answered with a reply to the floor it links.
bool noticeKindRepliable(NoticeKind kind) =>
    kind == NoticeKind.reply || kind == NoticeKind.quote || kind == NoticeKind.mention || kind == NoticeKind.comment;

/// The page a notice opens: the floor of its first "find post" link, else the thread of its first thread link.
@immutable
final class NoticeTarget {
  /// Constructor.
  const NoticeTarget({required this.tid, this.pid});

  /// Thread id, null when only the floor is known.
  final int? tid;

  /// Post id, null when only the thread is known.
  final int? pid;

  /// The forum url of the target, as the app routes it.
  String get url => pid != null
      ? '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=$pid${tid != null ? '&ptid=$tid' : ''}'
      : '$baseUrl/forum.php?mod=viewthread&tid=$tid';

  @override
  bool operator ==(Object other) => other is NoticeTarget && other.tid == tid && other.pid == pid;

  @override
  int get hashCode => Object.hash(tid, pid);

  @override
  String toString() => 'NoticeTarget(tid: $tid, pid: $pid)';
}

/// Everything shown of one notice, read once from its html: see [NoticeInfo.of].
final class NoticeInfo {
  const NoticeInfo._({
    required this.kind,
    required this.author,
    required this.authorId,
    required this.target,
    required this.threadTitle,
    required this.quote,
    required this.text,
  });

  /// Read [notice]: its kind, author, target, thread title, quoted text and plain text.
  factory NoticeInfo.of(NoticeV2 notice) {
    final body = parseHtmlDocument('<html><body>${notice.data}</body></html>').body;
    final target = body == null ? null : noticeTargetOf(body);
    final authorId = notice.authorId != null && notice.authorId! > 0 ? notice.authorId : null;
    return NoticeInfo._(
      kind: noticeKindOf(type: notice.ignoreType, fromIdType: notice.fromIdType, target: target, body: notice.data),
      author: notice.author ?? (body == null ? null : Notice.parseAuthorName(body, authorId)),
      authorId: authorId,
      target: target,
      threadTitle: body == null ? null : _threadTitleOf(body),
      quote: body == null ? null : _quoteOf(body),
      text: body == null ? '' : noticePlainTextOf(body),
    );
  }

  /// What the notice is about.
  final NoticeKind kind;

  /// Name of the user who triggered it, null for a system notice or when unknown.
  final String? author;

  /// Uid of that user, null for a system notice or when unknown.
  final int? authorId;

  /// The page it opens, null when it links none.
  final NoticeTarget? target;

  /// Title of the thread it is about, null when it names none.
  final String? threadTitle;

  /// Text quoted in it (the mentioning post, the reason of a rate or of a moderation), null when none.
  final String? quote;

  /// Its text, without the trailing "view" links.
  final String text;
}

/// The page [body] of a notice opens, see [NoticeTarget]; null when it links neither a floor nor a thread.
NoticeTarget? noticeTargetOf(uh.Element body) {
  NoticeTarget? thread;
  for (final a in body.querySelectorAll('a[href]')) {
    final q = _forumQuery(a.attributes['href'], 'forum.php');
    if (q == null) {
      continue;
    }
    if (q['mod'] == 'redirect' && q['goto'] == 'findpost') {
      final pid = int.tryParse(q['pid'] ?? '');
      if (pid != null && pid > 0) {
        final tid = int.tryParse(q['ptid'] ?? '');
        return NoticeTarget(tid: tid != null && tid > 0 ? tid : null, pid: pid);
      }
    }
    if (thread == null && q['mod'] == 'viewthread') {
      final tid = int.tryParse(q['tid'] ?? '');
      if (tid != null && tid > 0) {
        thread = NoticeTarget(tid: tid);
      }
    }
  }
  return thread;
}

/// Query of [href] when it is a forum link to [script], else null.
Map<String, String>? _forumQuery(String? href, String script) {
  if (href == null) {
    return null;
  }
  final uri = Uri.tryParse(href.replaceAll('&amp;', '&'));
  if (uri == null || !isForumScript(uri, script)) {
    return null;
  }
  return safeQueryParameters(uri);
}

/// Title of the thread named in [body]: the text of its first link to a floor or a thread that is not a trailing
/// "view" link (`a.lit`).
String? _threadTitleOf(uh.Element body) {
  for (final a in body.querySelectorAll('a[href]')) {
    if (a.classes.contains('lit')) {
      continue;
    }
    final q = _forumQuery(a.attributes['href'], 'forum.php');
    if (q == null || !((q['mod'] == 'redirect' && q['goto'] == 'findpost') || q['mod'] == 'viewthread')) {
      continue;
    }
    final title = _collapse(a.innerText);
    if (title.isNotEmpty) {
      return title;
    }
  }
  return null;
}

/// Quoted text of [body]: the block quote (mention, rate, moderation) or the summary (a reviewed reply).
String? _quoteOf(uh.Element body) {
  final node = body.querySelector('blockquote') ?? body.querySelector('p.summary');
  if (node == null) {
    return null;
  }
  final text = _collapse(node.innerText);
  return text.isEmpty ? null : text;
}

/// Plain text of the notice [body] in one line, the trailing "view" links (`a.lit`) left out.
String noticePlainTextOf(uh.Element body) {
  final clone = body.clone(true) as uh.Element;
  for (final a in clone.querySelectorAll('a.lit')) {
    a.remove();
  }
  return _collapse(clone.innerText);
}

/// Plain text of the notice html [html] in one line, see [noticePlainTextOf].
String noticePlainTextOfHtml(String html) {
  final body = parseHtmlDocument('<html><body>$html</body></html>').body;
  return body == null ? '' : noticePlainTextOf(body);
}

String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
