import 'package:collection/collection.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart' as rewards;
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The id of the "发帖排行" block of the homepage (`Kahrpba`): each row is a member and a post count, not a thread
/// and its author.
const _rankBlockId = 5;

/// The forum's homepage (`forum.php`) as the shared repository fetched it: the web page (or an older plugin's answer,
/// rebuilt as one), or the structured answer of the forum's app API (plugin 2.3.0, `schema: 5`).
///
/// The homepage tab, the topics tab and the activities page read it through the path the page needs, so that the
/// web page is parsed as it always was and the structured answer is never parsed from a `document` (which a lean
/// answer, `nodoc=1`, does not even carry), but for the "我收藏的版块" panel of a plugin before 2.8.1
/// ([favoritesPanelNeedsDocument]) and the activity links of a plugin before 2.8.2 (`activitiesNeedDocument`).
sealed class ForumHomePage {
  const ForumHomePage();

  /// The uid the page was served to, null for a guest (the `parseLoggedUidFromDocument` of the web page).
  int? get servedUid;

  /// Today's daily red packet the page offers, null when there is none or it was claimed already.
  DailyRedPacketConfig? get dailyRedPacket;

  /// The form hash of the session the page was served to, null when the page names none.
  String? get formHash;

  /// The forum's own `checknewpm` request of the page (`dailyVisitUri` of the daily rewards), which also credits
  /// the daily login: the web page carries it in a script; an answer of plugin 2.3.0 names it in `checknewpm`
  /// (`''` when the page printed none), since the script is in no lean answer's `document`.
  Uri? get dailyVisitUri;
}

/// The web page of the homepage (or an older plugin's answer, whose `document` holds its blocks), parsed as before.
final class ForumHomeWebPage extends ForumHomePage {
  /// Constructor.
  ///
  /// [checknewpm] is the `checknewpm` of the JSON answer the document came from, when it is one of plugin 2.3.0
  /// (the `unknown` answer of the cached guest index): the script it names is in no lean answer's `document`.
  const ForumHomeWebPage(this.document, {this.checknewpm});

  /// The page.
  final uh.Document document;

  /// The `checknewpm` of the answer, null for the web page and an older plugin's answer.
  final String? checknewpm;

  @override
  int? get servedUid => parseLoggedUidFromDocument(document);

  @override
  DailyRedPacketConfig? get dailyRedPacket => parseDailyRedPacketConfig(document);

  @override
  String? get formHash => parseFormHash(document);

  /// The request the answer names when it is the forum's own, else the one the page's scripts hold, if any.
  @override
  Uri? get dailyVisitUri => rewards.dailyVisitUriOfSource(checknewpm ?? '') ?? rewards.dailyVisitUri(document);
}

/// The structured answer of the forum's app API ([indexApiAnswerOf]): the homepage, or the forum's message.
final class ForumHomeApiPage extends ForumHomePage {
  /// Constructor.
  const ForumHomeApiPage(this.json);

  /// The answer.
  final Map<String, dynamic> json;

  /// The page is served to the account `uid` names (0 for a guest); a message answer names no account.
  @override
  int? get servedUid {
    final uid = _int(json['ok'] == 1 ? json['uid'] : null);
    return uid > 0 ? uid : null;
  }

  @override
  DailyRedPacketConfig? get dailyRedPacket => dailyRedPacketFromApi(json);

  @override
  String? get formHash {
    final hash = _text(json['formhash']);
    return hash.isEmpty ? null : hash;
  }

  @override
  Uri? get dailyVisitUri => rewards.dailyVisitUriOfSource(_text(json['checknewpm']));

  /// Whether the account the page was served to may see the forum's statistics (`misc.php?mod=stat`), as the answer
  /// tells it (plugin 3.8.0, `user.allow_stat`: the user group's permission); null when it does not tell (an older
  /// plugin, a message answer).
  bool? get allowsSiteStats {
    final user = json['ok'] == 1 ? json['user'] : null;
    final allowed = user is Map<String, dynamic> ? user['allow_stat'] : null;
    return allowed is num ? allowed == 1 : null;
  }
}

/// Whether account [uid] may see the forum's statistics, as the homepage [page] served to it tells
/// ([ForumHomeApiPage.allowsSiteStats]); null when no page tells: none loaded yet, the web page, an older plugin, a
/// page served to another account or to a guest.
bool? siteStatsAllowedBy(ForumHomePage? page, {required int? uid}) =>
    page is ForumHomeApiPage && uid != null && page.servedUid == uid ? page.allowsSiteStats : null;

/// The structured homepage answer in [data]: a JSON answer of the forum's app API that carries every field the app
/// reads (plugin 2.3.0, `type: index` with `schema` 5 or later: the statistics, the viewer, the links of the status
/// bar, the categories with their forums, the favorite forums, the `Kahrpba` blocks and slides, the daily red
/// packet), or the forum's own message of such a plugin (the site closed, please log in: `ok` 0, `error: message`,
/// with `login` telling a guest apart). Null when the answer has to be read from its `document` as before: a web
/// page, another page's answer, an older plugin's answer (`type: index` without `schema`), a failed build.
///
/// The page is then built by `homepageStateFromApi` and [forumGroupsFromApi]; the `document` of the answer, when
/// there is one, is never parsed, but for the "我收藏的版块" panel of a plugin before 2.8.1, which the answer names by
/// id only ([favoritesPanelNeedsDocument]), and the activity links of a plugin before 2.8.2, which gives the
/// description of 活动专区 as plain text (`activitiesNeedDocument`).
Map<String, dynamic>? indexApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 5;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'index' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The account a structured homepage answer [json] was served to, null for a guest or a message answer (which names
/// no username): what the web page's header user node tells (`parseLoggedUserFromDocument`).
UserLoginInfo? servedUserOf(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    return null;
  }
  final user = _map(json['user']);
  final uid = _int(user['uid']);
  final username = _text(user['username']);
  if (uid <= 0 || username.isEmpty) {
    return null;
  }
  return UserLoginInfo(uid: uid, username: username);
}

/// Whether a structured homepage answer [json] is the guest's: the page served to nobody (`uid` 0), or the forum's
/// login prompt (`login` 1). With an account in use, that session is dead (issue #25), as the guest web page tells.
bool indexAnswerIsGuest(Map<String, dynamic> json) => json['ok'] == 1 ? _int(json['uid']) <= 0 : json['login'] == 1;

/// Today's daily red packet of a structured homepage answer [json]: `red_packet` is the object the forum's footer
/// passes to `hongbaoDailyInit` while the viewer has not claimed it today, null otherwise.
DailyRedPacketConfig? dailyRedPacketFromApi(Map<String, dynamic> json) {
  final packet = json['red_packet'];
  return packet is Map<String, dynamic> && packet.containsKey('dateflag')
      ? DailyRedPacketConfig.fromServerJson(packet)
      : null;
}

/// The status bar of a structured homepage answer [json] (`stats`: 今日, 昨日, 帖子), as the web page's `p.chart.z`
/// is read; empty when the answer has none (a message).
ForumStatus forumStatusFromApi(Map<String, dynamic> json) {
  final stats = json['stats'];
  if (stats is! Map<String, dynamic>) {
    return const ForumStatus.empty();
  }
  return ForumStatus(
    todayCount: '${_int(stats['todayposts'])}',
    yesterdayCount: '${_int(stats['yesterdayposts'])}',
    threadCount: '${_int(stats['posts'])}',
  );
}

/// The viewer of a structured homepage answer [json] with the links of its status bar (`user`, `links`: 我的帖子,
/// 最新回复 when the guide is on), as the web page's header and `div#chart > div.y` are read: the account [username]
/// the app has wins, as it always did (the answer's name otherwise, empty for a guest); the avatar [avatarUrl] the
/// app has wins, the answer's is taken when the app has none.
LoggedUserInfo loggedUserInfoFromApi(Map<String, dynamic> json, {String? username, String? avatarUrl}) {
  final user = _map(json['user']);
  final avatar = _text(user['avatar']);
  final links = _list(json['links'])
      .map((e) => (_text(e['title']), _text(e['url'])))
      .where((e) => e.$2.isNotEmpty)
      .map((e) => (e.$1.isEmpty ? 'unknown' : e.$1, e.$2))
      .toList();
  return LoggedUserInfo(
    username: username ?? _text(user['username']),
    relatedLinkPairList: links,
    avatarUrl: avatarUrl ?? (avatar.isEmpty ? null : avatar),
  );
}

/// The swiper of a structured homepage answer [json] (`slides`): every slide with a picture, in the order given.
List<SwiperUrl> swiperUrlsFromApi(Map<String, dynamic> json) => _list(json['slides'])
    .map((e) => SwiperUrl(coverUrl: _text(e['image']), linkUrl: _text(e['url'])))
    .where((e) => e.coverUrl.isNotEmpty)
    .toList();

/// The unread notice count and the new message mark of a structured homepage answer [json] (`unread`), as the web
/// page's header is read (`buildUnreadInfoStatus`).
(int unreadNoticeCount, bool hasUnreadMessage) unreadInfoFromApi(Map<String, dynamic> json) {
  final unread = _map(json['unread']);
  return (_int(unread['notice']), _int(unread['pm']) > 0);
}

/// The `Kahrpba` tabs of a structured homepage answer [json] (`blocks`), in the order given, see
/// `homepageStateFromApi`; empty for a guest (the forum prints the block to members only) and on a forum without
/// the plugin.
///
/// A `Kahrpba` template the plugin cannot read (an older one, on the production forum) gives no `blocks` and the
/// whole `table#Kahrpba` as `blocks_html` instead: the tabs are then parsed from it as from the page
/// ([parsePinnedThreadGroupsFromDocument]), with the reordering and the rank mark of that parser.
List<PinnedThreadGroup> pinnedThreadGroupsFromApi(Map<String, dynamic> json) {
  final blocks = _list(json['blocks']);
  final blocksHtml = _text(json['blocks_html']);
  if (blocks.isEmpty && blocksHtml.trim().isNotEmpty) {
    return parsePinnedThreadGroupsFromDocument(parseHtmlDocument('<html><body>$blocksHtml</body></html>'));
  }
  final groups = <PinnedThreadGroup>[];
  for (final block in blocks) {
    final rows = _list(block['rows']).map(_pinnedThreadOf).whereType<PinnedThread>().toList();
    if (rows.isEmpty) {
      // A tab without any row the app can show would be an empty card as tall as the full ones (GitHub #155).
      continue;
    }
    groups.add(
      PinnedThreadGroup(title: _text(block['title']), threadList: rows, isRank: _int(block['id']) == _rankBlockId),
    );
  }
  return groups;
}

/// A row of a `Kahrpba` tab: the link (a thread, a member's space, or the member of the rank) with its title, and
/// the author (the member of a thread, the post count of the rank, the new member of 见习天使) with the link to the
/// member's space when the page has one (empty otherwise: the rank's count, a new member named in a thread's title).
/// Null for a row without a link (a new member who did not report in: a span, not a link, on the page), which the
/// page parser never gave either.
PinnedThread? _pinnedThreadOf(Map<String, dynamic> row) {
  final url = _text(row['url']);
  final title = _text(row['title']);
  if (url.isEmpty || title.isEmpty) {
    talker.info('skip pinned row without a link: ${row['title']}');
    return null;
  }
  final author = _text(row['author']);
  return PinnedThread(
    threadUrl: url,
    threadTitle: title,
    authorUrl: _text(row['author_url']),
    authorName: author.isEmpty ? title : author,
  );
}

/// For the following structure, filter and combine thread and its author.
///
/// <div class="Kahrpba_threads">
///   <a href="thread_url">
///     thread_title
///   </a>
///   <a href="author_url">
///     <em>author_name</em>
///   </a>
///
/// Filter out thread_url, thread_title, author_url and author_name.
///
/// Where [element] is <div class="Kahrpba_threads"> node.
PinnedThread? _pinnedThreadOfElement(uh.Element element) {
  final allNode = element.querySelectorAll('a').toList();
  // The "见习天使" (new members) tab lists one link per row, to the new member's space: "欢迎NAME加入~" (GitHub #155).
  // The member is both the row and its "author", so the tile shows the avatar and name and opens the profile.
  if (allNode.length == 1) {
    final url = allNode.single.attributes['href'];
    final text = allNode.single.firstEndDeepText()?.trim();
    if (url == null || text == null || text.isEmpty || !url.contains('mod=space')) {
      talker.info('skip pinned row with one link that is not a user space');
      return null;
    }
    final name = RegExp('^欢迎(.+?)加入').firstMatch(text)?.group(1)?.trim();
    return PinnedThread(
      threadUrl: url,
      threadTitle: text,
      authorUrl: url,
      authorName: name == null || name.isEmpty ? text : name,
    );
  }
  // There should be two <a> in children.
  if (allNode.length != 2) {
    talker.info(
      'skip build thread author pair: '
      'node count is ${allNode.length}',
    );
    return null;
  }

  final threadUrl = allNode[0].attributes['href'];
  if (threadUrl == null) {
    talker.info('skip incomplete thread author pair: thread url not found');
    return null;
  }

  final threadTitle = allNode[0].firstEndDeepText();
  if (threadTitle == null) {
    talker.info('skip incomplete thread author pair: thread title not found');
    return null;
  }

  final authorUrl = allNode[1].attributes['href'];
  if (authorUrl == null) {
    talker.info('skip incomplete thread author pair: author url not found');
    return null;
  }

  final authorName = allNode[1].firstEndDeepText();
  if (authorName == null) {
    talker.info('skip incomplete thread author pair: author name not found');
    return null;
  }

  return PinnedThread(threadUrl: threadUrl, threadTitle: threadTitle, authorUrl: authorUrl, authorName: authorName);
}

/// The tabs of the homepage block of the `Kahrpba` plugin (最新活动, 见习天使, ..., 发帖排行) read from the web page
/// [document] (or the `blocks_html` of a structured answer), in the order the website shows them; tabs without any
/// row the app can show are left out (GitHub #155).
List<PinnedThreadGroup> parsePinnedThreadGroupsFromDocument(uh.Document document) {
  final pinnedThreadGroupList = <PinnedThreadGroup>[];
  final navNameList = document
      .querySelector('td#Kahrpba_nav')
      ?.children
      .map((e) => e.firstEndDeepText())
      .whereType<String>()
      .toList();
  final navShowList = document
      .querySelector('td#Kahrpba_show')
      ?.children
      .where((e) => e.id.startsWith('Kahrpba_c'))
      .whereType<uh.Element>()
      .toList();

  if (navNameList != null && navShowList != null && navNameList.length == navShowList.length) {
    if (navNameList.length >= 7) {
      navNameList
        ..swap(4, 6)
        ..swap(5, 6);
    }
    final count = navNameList.length;
    for (var i = 0; i < count; i++) {
      final threadList = navShowList[i]
          .querySelectorAll('div.Kahrpba_threads')
          .map(_pinnedThreadOfElement)
          .whereType<PinnedThread>()
          .toList();
      // Kept even when empty here so the reordering below still finds every tab where it expects it; empty
      // groups are left out after that.
      final group = PinnedThreadGroup(title: navNameList[i], threadList: threadList);
      pinnedThreadGroupList.add(group);
    }

    // The sort on server side is not as displayed, fix the sort to keep the
    // same with website appearance.
    if (pinnedThreadGroupList.length >= 7) {
      pinnedThreadGroupList
        ..swap(4, 5)
        ..swap(5, 6);
      // The rank is the last tab once reordered; marked before empty tabs are left out and the indices move.
      pinnedThreadGroupList[6] = pinnedThreadGroupList[6].copyWith(isRank: true);
    }
  }
  // A tab without any row the app can show would be an empty card as tall as the full ones (GitHub #155).
  pinnedThreadGroupList.removeWhere((e) => e.threadList.isEmpty);
  return pinnedThreadGroupList;
}

/// The forum groups of a structured homepage answer [json] for the topics tab, as `buildGroupListFromDocument`
/// reads them from the web page: the "我收藏的版块" panel first when the viewer has favorite forums
/// ([_favoritesPanelOf]), then every category (`forum.php?gid=`) with its forums ([Forum.fromApi]: the latest thread,
/// the subforums the forum's setting lists; since plugin 2.8.2 a link forum, a forum the viewer may not enter and
/// the links to threads of the description, as the page prints them) and its moderators (`moderators`, the names of
/// the page's 分区版主 row, plugin 2.4.0; none before).
List<ForumGroup> forumGroupsFromApi(Map<String, dynamic> json) {
  final categories = _list(json['categories']);
  final groups = categories
      .map(
        (c) => ForumGroup(
          name: _text(c['name']),
          url: 'forum.php?gid=${_int(c['fid'])}',
          forumList: _list(c['forums']).map(Forum.fromApi).toList(),
          moderators: c['moderators'] is List
              ? (c['moderators'] as List).whereType<String>().where((e) => e.isNotEmpty).toList()
              : const [],
        ),
      )
      .toList();
  final favorites = _favoritesPanelOf(json, categories, groups);
  if (favorites.isEmpty) {
    return groups;
  }
  return [
    ForumGroup(name: '我收藏的版块', url: 'home.php?mod=space&do=favorite&type=forum', forumList: favorites),
    ...groups,
  ];
}

/// The forums of the "我收藏的版块" panel of a structured homepage answer [json], in the page's order; empty when the
/// page prints no panel.
///
/// * Plugin 2.8.1 gives the panel as the page prints it (`favorites`, [Forum.fromApi]): each forum's own counts (the
///   categories add the subforums into their forum's), a favorite subforum with all of its data, a forum the viewer
///   may not enter ([Forum.isPrivate]) and a link forum ([Forum.redirectUrl]) as the page shows them.
/// * Before (plugin 2.3.0 to 2.8.0) the answer names the favorites by id only (`favorite_forums`); the repository
///   then asks the page once more with its `document` ([favoritesPanelNeedsDocument]) and the panel is read from the
///   page ([favoriteForumsOfDocument]).
/// * Without either (that request failed, or the document holds no panel it can read) each favorite is looked up
///   among the forums of the categories, or among their subforums, which the answer lists by name only; one listed
///   nowhere, a forum the viewer may not see, is left out of the panel but still seeded, see [favoriteForumIdsOf].
List<Forum> _favoritesPanelOf(
  Map<String, dynamic> json,
  List<Map<String, dynamic>> categories,
  List<ForumGroup> groups,
) {
  if (json.containsKey('favorites')) {
    return _list(json['favorites']).where((e) => _int(e['fid']) > 0).map(Forum.fromApi).toList();
  }
  final favoriteIds = favoriteForumIdsOf(json);
  if (favoriteIds.isEmpty) {
    return const [];
  }
  if (json['document'] is String) {
    final panel = favoriteForumsOfDocument(tsdmAppPageDocument(json), fids: favoriteIds);
    if (panel != null) {
      return panel;
    }
    talker.info('favorite forums panel not read from the document of the homepage answer, looked up in the categories');
  }
  final forums = {
    for (final g in groups)
      for (final f in g.forumList) f.forumID: f,
  };
  // A subforum is listed under its forum by id and name only: the panel shows it with those.
  final subforums = {
    for (final c in categories)
      for (final f in _list(c['forums']))
        for (final sub in _list(f['subforums']))
          if (_int(sub['fid']) > 0) _int(sub['fid']): Forum.fromApi({'fid': _int(sub['fid']), 'name': sub['name']}),
  };
  final favorites = favoriteIds.map((fid) => forums[fid] ?? subforums[fid]).whereType<Forum>().toList();
  if (favorites.length != favoriteIds.length) {
    talker.info(
      'favorite forums not among the categories left out of the panel: '
      '${favoriteIds.where((e) => !forums.containsKey(e) && !subforums.containsKey(e))}',
    );
  }
  return favorites;
}

/// Whether the "我收藏的版块" panel of a structured homepage answer [json] is only on the web page: the viewer has
/// favorite forums (`favorite_forums`), the plugin is older than 2.8.1 (no `favorites`, the panel's own data) and the
/// answer was asked lean (`nodoc=1`, no `document`).
///
/// The answer then names the favorites by id only, and the categories cannot stand in for the panel: their counts
/// include the subforums', and a favorite subforum is listed there by name only, if at all. `ForumHomeRepository` asks
/// the page once more without `nodoc=1`, and the panel is read from its `document` ([favoriteForumsOfDocument]). No
/// such request for an answer of plugin 2.8.1, a guest's, a member's without favorites, or the forum's message.
bool favoritesPanelNeedsDocument(Map<String, dynamic> json) =>
    json['ok'] == 1 &&
    !json.containsKey('favorites') &&
    json['document'] is! String &&
    favoriteForumIdsOf(json).isNotEmpty;

/// The forums of the "我收藏的版块" panel of the web page [document] (`div#category_0`), as the page prints them and in
/// its order; null when the page has no panel, or none of its forums can be read.
///
/// Each forum is read by the readers of the forum lists ([Forum.fromFlRowNode] for the list layout of up to three
/// favorites, [Forum.fromFlGNode] for the grid of more): the panel's own counts, the icon, the latest thread (only its
/// time in the grid, as the page prints). What those readers leave out is added:
/// * a forum the viewer may not enter prints "私密版块" in place of the latest thread ([Forum.isPrivate]);
/// * a link forum (its links open a new window, the latest thread is the "链接到外部地址" link, or "私密版块" for one
///   the viewer may not enter) prints no counts: the list reader drops such a row and the grid reader gives it -1
///   counts, so it is built from its name and icon with 0 counts, and [Forum.redirectUrl] is the forum's own page,
///   which the forum redirects (the page prints no address);
/// * a forum bound to a domain of its own links to that domain, without its id: it takes the id at its place in
///   [fids] (`favorite_forums`, the panel's forums in the panel's order) when the panel has as many forums;
/// * the list layout prints an anonymous author as text after the time ("2026-9-23 21:58 匿名"), which its reader
///   does not take apart.
List<Forum>? favoriteForumsOfDocument(uh.Document document, {List<int> fids = const []}) {
  final panel = document.querySelector('div#category_0');
  if (panel == null) {
    return null;
  }
  final cells = <_FavoriteCell>[];
  for (final row in panel.querySelectorAll('table > tbody > tr')) {
    if (row.children.isEmpty) {
      continue;
    }
    if (row.querySelector('h2') != null) {
      cells.add(
        _FavoriteCell(
          node: row,
          read: Forum.fromFlRowNode,
          title: row.querySelector('td > h2 > a'),
          icon: row.querySelector('td.fl_icn img'),
          slot: row.querySelector('td.fl_by > div'),
          hasCounts: row.querySelector('td.fl_i span') != null,
        ),
      );
      continue;
    }
    // The grid pads its last row with empty cells.
    for (final cell in row.querySelectorAll('td.fl_g').where((e) => e.children.isNotEmpty)) {
      final items = cell.querySelectorAll('dl > dd');
      cells.add(
        _FavoriteCell(
          node: cell,
          read: Forum.fromFlGNode,
          title: cell.querySelector('dl > dt > a'),
          icon: cell.querySelector('div.fl_icn_g img'),
          // After the counts (`<em>`, none for a link forum), before what a plugin adds (`index_favforum_extra`).
          slot: items.firstWhereOrNull((e) => e.querySelector('em') == null),
          hasCounts: items.any((e) => e.querySelector('em') != null),
        ),
      );
    }
  }
  final byPlace = cells.length == fids.length;
  final forums = cells.indexed
      .map((e) => _favoriteForumOf(e.$2, placeFid: byPlace ? fids[e.$1] : null))
      .whereType<Forum>()
      .toList();
  return forums.isEmpty ? null : forums;
}

/// A forum of the favorites panel as the page prints it: the row (list layout) or cell (grid) [node], the reader of
/// its layout ([read]), its [title] link, its [icon], the [slot] of its latest thread, and whether it prints counts.
final class _FavoriteCell {
  const _FavoriteCell({
    required this.node,
    required this.read,
    required this.title,
    required this.icon,
    required this.slot,
    required this.hasCounts,
  });

  final uh.Element node;
  final Forum? Function(uh.Element) read;
  final uh.Element? title;
  final uh.Element? icon;
  final uh.Element? slot;
  final bool hasCounts;
}

/// The forum of a [cell] of the favorites panel, see [favoriteForumsOfDocument]; [placeFid] is its id by its place in
/// the panel, for a forum whose links do not name it.
Forum? _favoriteForumOf(_FavoriteCell cell, {required int? placeFid}) {
  final title = cell.title;
  final href = title?.attributes['href'];
  if (title != null && placeFid != null && (href?.uriQueryParameter('fid')?.parseToInt() == null)) {
    // Bound to a domain of its own: the readers take the id from the link.
    title.attributes['href'] = 'forum.php?mod=forumdisplay&fid=$placeFid';
  }
  final slotText = cell.slot?.innerText.trim();
  final private = slotText == '私密版块' || slotText == '私密版塊';
  final slotLink = cell.slot?.querySelector('a');
  final link =
      (slotLink != null && !(slotLink.attributes['href']?.contains('tid=') ?? false)) ||
      (title?.attributes['target'] == '_blank' && !cell.hasCounts);
  if (!link) {
    final forum = cell.read(cell.node)?.copyWith(isPrivate: private);
    return forum == null ? null : _withAnonymousAuthor(forum, cell.slot);
  }
  final url = title?.firstHref();
  final fid = url?.uriQueryParameter('fid')?.parseToInt();
  final name = title?.firstEndDeepText()?.trim();
  if (url == null || fid == null || name == null) {
    talker.error('failed to build link forum of the favorites panel: fid=$fid, name=$name');
    return null;
  }
  return Forum(
    forumID: fid,
    url: url,
    name: name,
    iconUrl: cell.icon?.dataOriginalOrSrcImgUrl() ?? '',
    threadCount: 0,
    replyCount: 0,
    latestThreadUrl: null,
    latestThreadTime: null,
    latestThreadTimeText: null,
    threadTodayCount: null,
    isPrivate: private,
    redirectUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=$fid',
  );
}

/// [forum] with the anonymous author of its latest thread that the list layout prints as text after the time
/// ("2026-9-23 21:58 匿名", or after the `<span title>` of a recent time) in the `<cite>` of [slot]; [forum] as it is
/// when the author is a link (a member) or there is no latest thread.
Forum _withAnonymousAuthor(Forum forum, uh.Element? slot) {
  final cite = slot?.querySelector('cite');
  if (forum.latestThreadUrl == null || cite == null || cite.querySelector('a') != null) {
    return forum;
  }
  final span = cite.querySelector('span[title]');
  if (span != null) {
    final author = cite.innerText.trim().substring(span.innerText.trim().length).trim();
    return author.isEmpty ? forum : forum.copyWith(latestThreadUserName: author);
  }
  final words = cite.innerText.trim().split(RegExp(r'\s+'));
  if (words.length < 3) {
    return forum;
  }
  final timeText = '${words[0]} ${words[1]}';
  return forum.copyWith(
    latestThreadTime: forum.latestThreadTime ?? timeText.parseToDateTimeUtc8(),
    latestThreadTimeText: timeText,
    latestThreadUserName: words.skip(2).join(' '),
  );
}

/// The forums the viewer of a structured homepage answer [json] has favorited (`favorite_forums`, the ids the
/// page's "我收藏的版块" panel lists), in the page's order; empty for a guest and for a member without any.
List<int> favoriteForumIdsOf(Map<String, dynamic> json) {
  final ids = json['favorite_forums'];
  if (ids is! List) {
    return const [];
  }
  return ids.map(_int).where((e) => e > 0).toList();
}

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

int _int(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';
