import 'package:tsdm_client/constants/url.dart';
import 'package:universal_html/html.dart' as uh;

/// The rankings the app shows, each a page of the forum's `misc.php?mod=ranklist`.
enum RanklistKind {
  /// Members by their credits (`type=member&view=credit`).
  credit,

  /// Members by their posts (`type=member&view=post`).
  post,

  /// Members by their online time this month (`type=member&view=onlinetime`).
  online,

  /// Threads (`type=thread`), ordered by one of [RanklistThreadView].
  thread,
}

/// The orders of the thread ranking, the `view` of `type=thread`.
enum RanklistThreadView {
  /// Most replied.
  replies,

  /// Most viewed.
  views,

  /// Most favorited.
  favtimes,

  /// Hottest.
  heats,
}

/// Url of the ranking [kind]; [threadView] orders the thread ranking.
String ranklistUrl(RanklistKind kind, {RanklistThreadView threadView = RanklistThreadView.replies}) => switch (kind) {
  RanklistKind.credit => '$baseUrl/misc.php?mod=ranklist&type=member&view=credit',
  RanklistKind.post => '$baseUrl/misc.php?mod=ranklist&type=member&view=post',
  RanklistKind.online => '$baseUrl/misc.php?mod=ranklist&type=member&view=onlinetime',
  RanklistKind.thread => '$baseUrl/misc.php?mod=ranklist&type=thread&view=${threadView.name}',
};

/// A member in a member ranking.
final class RanklistMember {
  /// Constructor.
  const RanklistMember({
    required this.rank,
    required this.uid,
    required this.username,
    required this.value,
    this.groupName,
  });

  /// Place in the ranking, 1 the first.
  final int rank;

  /// Member id.
  final String uid;

  /// Member name.
  final String username;

  /// The value ranked, as the forum prints it (`991509`, `11160 分钟`).
  final String value;

  /// User group the forum shows with the member, null when it shows none.
  final String? groupName;
}

/// A thread in the thread ranking.
final class RanklistThread {
  /// Constructor.
  const RanklistThread({
    required this.rank,
    required this.tid,
    required this.title,
    required this.value,
    this.forumName,
    this.author,
  });

  /// Place in the ranking, 1 the first.
  final int rank;

  /// Thread id.
  final String tid;

  /// Thread title.
  final String title;

  /// The value ranked (replies, views…), as the forum prints it.
  final String value;

  /// Name of the forum the thread is in.
  final String? forumName;

  /// Name of the thread author.
  final String? author;
}

/// One ranking page: the members or the threads listed, and when the forum made the list.
final class RanklistData {
  /// Constructor.
  const RanklistData({this.members = const [], this.threads = const [], this.lastUpdate, this.nextUpdate, this.notice});

  /// Members of a member ranking.
  final List<RanklistMember> members;

  /// Threads of the thread ranking.
  final List<RanklistThread> threads;

  /// When the forum made the cached list (`2026-11-9 00:42`).
  final String? lastUpdate;

  /// When the forum makes the list again.
  final String? nextUpdate;

  /// The forum's cache notice as printed, kept when the times in it are not recognized.
  final String? notice;

  /// Nothing listed.
  bool get isEmpty => members.isEmpty && threads.isEmpty;
}

final _uidRe = RegExp(r'[?&]uid=(\d+)');
final _tidRe = RegExp(r'[?&]tid=(\d+)');
final _timeRe = RegExp(r'\d{4}-\d{1,2}-\d{1,2} \d{1,2}:\d{2}');
final _spaceRe = RegExp(r'\s+');

String _textOf(uh.Element? element) => (element?.text ?? '').replaceAll(_spaceRe, ' ').trim();

/// The user group in the member info [p] of a member ranking, before its value label; [beforeColon] is the text of
/// [p] up to the colon of the label.
///
/// The forum prints the group in `<font>` or as text followed by its icon (`<img class="vm">`), then the label: the
/// group is the font, else the text before the icon, else the text before the last space (`管理员 积分数`). The post
/// ranking prints no group (`帖子数: …`).
String? _groupOf(uh.Element p, String beforeColon) {
  String? nonEmpty(String s) => s.isEmpty ? null : s;
  if (p.querySelector('font') case final font?) {
    return nonEmpty(_textOf(font));
  }
  if (p.querySelector('img') != null) {
    final buffer = StringBuffer();
    for (final node in p.nodes) {
      if (node is uh.Element && node.localName == 'img') {
        return nonEmpty(buffer.toString().replaceAll(_spaceRe, ' ').trim());
      }
      buffer.write(node.text ?? '');
    }
  }
  final label = beforeColon.trimRight().lastIndexOf(' ');
  return label <= 0 ? null : nonEmpty(beforeColon.substring(0, label).trim());
}

/// Minutes of an online time value as the forum prints it (`11160 分钟`), null when it is not one.
int? ranklistOnlineMinutes(String value) =>
    int.tryParse(RegExp(r'^(\d+)\s*\D*$').firstMatch(value.trim())?.group(1) ?? '');

/// The message of the forum's 提示信息 page (a ranking turned off: `此排行功能已关闭`), null for any other page.
String? ranklistServerMessage(uh.Document document) {
  final node = document.querySelector('div#messagetext > p');
  if (node == null) {
    return null;
  }
  final text = _textOf(node);
  return text.isEmpty ? null : text;
}

/// Parse the ranking page [document] of `misc.php?mod=ranklist`.
///
/// * Members: `div.xld.hasrank > dl`, the place in `dd.ranknum`, the name in `dt:not(.y) > a`, and in the last
///   `dd > p` the user group (when shown) followed by `label: value` (`积分数: 991509`, `帖子数: <a>14</a>`,
///   `在线时间: 11160 分钟`).
/// * Threads: the rows of `div.tl table` with a `td.icn` place, the title link in `th`, the forum in `td.frm`, the
///   author in `td.by cite`, the value in the last cell.
/// * `div.notice`: `排行榜数据已被缓存，上次于 <time> 被更新，下次将于 <time> 进行更新`.
RanklistData parseRanklistPage(uh.Document document) {
  final members = <RanklistMember>[];
  for (final (index, dl) in document.querySelectorAll('div.hasrank > dl').indexed) {
    final link = dl.querySelectorAll('dt').where((e) => !e.classes.contains('y')).firstOrNull?.querySelector('a');
    final uid = _uidRe.firstMatch(link?.attributes['href'] ?? '')?.group(1);
    final username = _textOf(link);
    if (uid == null || username.isEmpty) {
      continue;
    }
    final p = dl.querySelectorAll('dd > p').lastOrNull;
    final info = _textOf(p);
    final colon = info.lastIndexOf(RegExp('[:：]'));
    final value = colon < 0 ? info : info.substring(colon + 1).trim();
    final group = p == null || colon < 0 ? null : _groupOf(p, info.substring(0, colon));
    members.add(
      RanklistMember(
        rank: int.tryParse(_textOf(dl.querySelector('dd.ranknum'))) ?? index + 1,
        uid: uid,
        username: username,
        value: value,
        groupName: group,
      ),
    );
  }

  final threads = <RanklistThread>[];
  final rows = document.querySelectorAll('div.tl table tr').where((e) => e.querySelector('td.icn') != null);
  for (final (index, tr) in rows.indexed) {
    final link = tr.querySelector('th > a');
    final tid = _tidRe.firstMatch(link?.attributes['href'] ?? '')?.group(1);
    final title = _textOf(link);
    if (tid == null || title.isEmpty) {
      continue;
    }
    final forum = _textOf(tr.querySelector('td.frm'));
    final author = _textOf(tr.querySelector('td.by cite'));
    threads.add(
      RanklistThread(
        rank: int.tryParse(_textOf(tr.querySelector('td.icn'))) ?? index + 1,
        tid: tid,
        title: title,
        value: _textOf(tr.querySelectorAll('td').lastOrNull),
        forumName: forum.isEmpty ? null : forum,
        author: author.isEmpty ? null : author,
      ),
    );
  }

  final notice = _textOf(document.querySelector('div.notice'));
  final times = _timeRe.allMatches(notice).map((e) => e.group(0)!).toList();
  return RanklistData(
    members: members,
    threads: threads,
    lastUpdate: times.elementAtOrNull(0),
    nextUpdate: times.elementAtOrNull(1),
    notice: notice.isEmpty ? null : notice,
  );
}
