import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_v4.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

final _uidRe = RegExp(r'[?&;]uid=(\d+)');
final _tidRe = RegExp(r'[?&;]tid=(\d+)');
final _digitsRe = RegExp(r'\d+');
final _countRe = RegExp(r'\((\d+)\)');
final _relayRe = RegExp(r'quickrelay\(\s*\d+\s*,\s*(\d+)');
final _feedInfoRe = RegExp(r'feedInfo\s*=\s*\{[^}]*archiver:\s*(\d+)\s*,\s*primary:\s*(\d+)');

int? _intOf(RegExp re, String? s) => s == null ? null : int.tryParse(re.firstMatch(s)?.group(1) ?? '');

String? _textOf(uh.Element? e) {
  final s = e?.text?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s == null || s.isEmpty ? null : s;
}

String? _avatarOf(uh.Element? img) {
  final url = img?.attributes['src'] ?? img?.attributes['data-src'];
  return url == null || url.isEmpty ? null : spaceAbsoluteUrl(url);
}

/// The first page of the broadcasts: of the member [uid] (`home.php?mod=follow&uid=N&do=view`), else the [view] of
/// the account in use (`home.php?mod=follow&view=follow|other`).
String followFeedUrl({FollowFeedView view = FollowFeedView.follow, int? uid}) => uid != null && uid > 0
    ? '$baseUrl/home.php?mod=follow&uid=$uid&do=view'
    : '$baseUrl/home.php?mod=follow&view=${view == FollowFeedView.hall ? 'other' : 'follow'}';

/// The first page of the members [uid] follows, or of their [followers]; of the account in use without [uid].
String followListUrl({required bool followers, int? uid}) =>
    '$baseUrl/home.php?mod=follow&do=${followers ? 'follower' : 'following'}${uid != null && uid > 0 ? '&uid=$uid' : ''}';

/// Whether [url] is a further page of broadcasts ([followMoreFeedUrl]), answered as a fragment.
bool isFollowMoreFeedUrl(String url) => url.contains('op=getfeed');

String _moreFeedUrl(String scope, {required bool archive, required int page}) =>
    '$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=${archive ? 1 : 0}&page=$page&inajax=1&$scope';

/// The page [page] of the broadcasts after the first page [firstPageUrl] ([followFeedUrl]), the way the website loads
/// more of them: `home.php?mod=spacecp&ac=follow&op=getfeed&archiver=A&page=P&inajax=1` with `viewtype` of the
/// account's own lists or `uid` of a member; [archive] asks the broadcasts the forum filed away (older than its
/// `followretainday`), which follow the recent ones and count their pages from one again.
String followMoreFeedUrl(String firstPageUrl, {required bool archive, required int page}) {
  final query = Uri.tryParse(firstPageUrl)?.queryParameters ?? const <String, String>{};
  final uid = int.tryParse(query['uid'] ?? '');
  return _moreFeedUrl(
    uid != null && uid > 0 ? 'uid=$uid' : 'viewtype=${query['view'] == 'other' ? 'other' : 'follow'}',
    archive: archive,
    page: page,
  );
}

/// Where the further page [url] ([followMoreFeedUrl]) is: the archive or the recent ones, and its page.
({bool archive, int page}) followMoreFeedPosition(String url) {
  final query = Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
  return (archive: query['archiver'] == '1', page: int.tryParse(query['page'] ?? '') ?? 1);
}

/// The further page [url] moved to [archive] and [page], of the same broadcasts.
String followMoreFeedUrlAt(String url, {required bool archive, required int page}) {
  final query = Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
  final uid = int.tryParse(query['uid'] ?? '');
  return _moreFeedUrl(
    uid != null && uid > 0 ? 'uid=$uid' : 'viewtype=${query['viewtype'] == 'other' ? 'other' : 'follow'}',
    archive: archive,
    page: page,
  );
}

/// A broadcast of a list.
///
/// ```html
/// <li class="cl" id="feed_li_718">
///   <div class="z flw_avt"><a href="home.php?mod=space&uid=31"><img …></a></div>   (the first of a member's run only)
///   <div class="flw_article">
///     <a href="home.php?mod=spacecp&ac=follow&feedid=718&op=delete" id="c_delete_718" class="flw_delete">删除</a>
///     <div class="flw_author"><a href="home.php?mod=space&uid=31">NAME</a>
///       <span class="xg1">&nbsp;<span title="2026-11-10 13:46">13&nbsp;秒前</span></span></div>
///     <div class="flw_quotenote xs2 pbw">NOTE</div>                    (a reply, a relay)
///     <div class="flw_quote">                                           (with a note only)
///       <h2 class="wx pbn"><a href="forum.php?mod=viewthread&tid=T&extra=page%3D1">TITLE</a></h2>
///       <div class="pbm c cl" id="original_content_718">…the beginning of the thread…</div>
///       <div class="xg1 cl"><span class="y"><a id="relay_718" onclick="quickrelay(718, T);">转播(1)</a>
///         <a onclick="quickreply(F, T, 718)">回复(3)</a></span>
///         <a href="home.php?mod=space&uid=31">AUTHOR</a> 发表于 2026-11-7 22:05&nbsp;
///         #<a href="forum.php?mod=forumdisplay&fid=F">FORUM</a></div>
///     </div>
///   </div>
/// </li>
/// ```
///
/// A thread that is gone leaves "内容已被删除" in `original_content_…` and no title nor counts. The link of the
/// original author under a note carries the uid of the broadcaster (the forum's template), so only the name is read.
FollowFeed? _feedOf(uh.Element li) {
  final feedId = int.tryParse(_digitsRe.firstMatch(li.id)?.group(0) ?? '');
  final author = li.querySelector('div.flw_author a[href*="uid="]');
  final uid = _intOf(_uidRe, author?.attributes['href']);
  final name = _textOf(author);
  if (feedId == null || uid == null || name == null) {
    return null;
  }
  final titleLink = li.querySelector('h2 a[href*="mod=viewthread"]');
  final relay = li.querySelector('a[id^="relay_"]');
  final reply = li.querySelector('a[onclick^="quickreply"]');
  final threadId = _intOf(_tidRe, titleLink?.attributes['href']) ?? _intOf(_relayRe, relay?.attributes['onclick']);
  final content = li.querySelector('div[id^="original_content_"]');
  if (content != null) {
    // The attachments are downloaded in the thread; the pictures are served from the forum.
    for (final attach in content.querySelectorAll('div.flw_attach')) {
      attach.remove();
    }
    for (final img in content.querySelectorAll('img[src]')) {
      img.attributes['src'] = spaceAbsoluteUrl(img.attributes['src']!);
    }
  }
  final note = li.querySelector('div.flw_quotenote');
  final footer = relay?.parent?.parent ?? reply?.parent?.parent;
  final forum = footer?.querySelector('a[href*="mod=forumdisplay"]');
  String? origin;
  if (note != null && footer != null) {
    final rest = footer.clone(true) as uh.Element;
    for (final e in [...rest.querySelectorAll('span.y'), ...rest.querySelectorAll('a[href*="mod=forumdisplay"]')]) {
      e.remove();
    }
    origin = _textOf(rest)?.replaceFirst(RegExp(r'\s*#$'), '');
    if (origin != null && origin.isEmpty) {
      origin = null;
    }
  }
  return FollowFeed(
    feedId: feedId,
    uid: uid,
    username: name,
    time: _textOf(li.querySelector('div.flw_author span.xg1')),
    note: note,
    threadId: threadId,
    threadTitle: _textOf(titleLink),
    content: content,
    threadMissing: footer == null,
    origin: origin,
    forumName: _textOf(forum),
    relayCount: _intOf(_countRe, relay?.text),
    replyCount: _intOf(_countRe, reply?.text),
    canRelay: relay != null && threadId != null,
    canDelete: li.querySelector('a.flw_delete') != null,
  );
}

List<FollowFeed> _feedsOf(uh.Element? root) => [
  for (final li in root?.querySelectorAll('li[id^="feed_li_"]') ?? const <uh.Element>[]) ?_feedOf(li),
];

/// The first page of broadcasts ([followFeedUrl], asked as [url]): the twenty latest in `ul#followlist`.
///
/// More of them follow when the page carries the script that loads them (`var feedInfo = {…, archiver: 1, primary: 1,
/// …}`): the recent ones from their page two while `primary` is set, else the filed ones (page one of them came with
/// this page already, see `home/follow/feed`); a shorter page is followed by the filed ones from their first page.
/// Without broadcasts the page prints `div.emp`; what the forum prints
/// instead (`follow_status_off` "抱歉，广播功能尚未开启", the login prompt) is the page's [SpaceListPage.message].
SpaceListPage<FollowFeed> parseFollowFeedPage(uh.Document document, String url) {
  final list = document.querySelector('ul#followlist');
  final session = spaceSessionOf(document);
  if (list == null) {
    if (spaceNoticeOf(document) case final notice?) {
      return SpaceListPage(items: const [], message: notice.message, needLogin: notice.needLogin);
    }
    return SpaceListPage(items: const [], needLogin: session == null, session: session);
  }
  final feeds = _feedsOf(list);
  String? next;
  for (final script in document.querySelectorAll('script')) {
    final match = _feedInfoRe.firstMatch(script.text ?? '');
    if (match == null) {
      continue;
    }
    final primary = match.group(2) != '0';
    if (primary || match.group(1) != '0') {
      next = followMoreFeedUrl(url, archive: !primary, page: 2);
    }
    break;
  }
  // A page of fewer than twenty carries no such script and the website stops there, though the forum still answers
  // the filed ones (a member with one recent broadcast and a hundred filed shows one): they are asked from their
  // first page, which only repeats what this page may already hold of them.
  if (next == null && feeds.isNotEmpty) {
    next = followMoreFeedUrl(url, archive: true, page: 1);
  }
  // A list without a broadcast to show has no end to load more from: it is the empty list.
  return SpaceListPage(items: feeds, nextPageUrl: feeds.isEmpty ? null : next, session: session);
}

/// A further page of broadcasts ([followMoreFeedUrl]) out of its fragment [html]: the `<li>` of the list, or the word
/// `false` once there are no more (null).
List<FollowFeed>? parseFollowMoreFeeds(String html) {
  if (html.trim() == 'false') {
    return null;
  }
  return _feedsOf(parseHtmlDocument('<html><body><ul>$html</ul></body></html>').body);
}

/// A page of the members followed, or of the followers ([followListUrl]).
///
/// ```html
/// <ul class="flw_ulist">
///   <li class="cl">
///     <a href="home.php?mod=space&uid=35" title="NAME" class="flw_avt"><img …></a>
///     <span class="z flw_status_2">互相关注</span>
///     <a id="a_followmod_35" href="home.php?mod=spacecp&ac=follow&op=del&fuid=35" class="flw_btn_unfo">取消关注</a>
///     <h6 class="pbn xs2"><a href="home.php?mod=space&uid=35" title="NAME">NAME</a>
///       <span id="followbkame_35" class="xg1 xs1 xw0">REMARK</span></h6>
///     <p><span class="xg1">最近动作: </span>…</p>
///     <p class="ptm xg1">粉丝: <a …><strong id="followernum_35">1</strong></a>人 关注: <a …><strong>1</strong></a>人
///       | <a href="…&op=bkname&fuid=35&handlekey=followbkame_35" id="fbkname_35">添加备注</a> | …</p>
///   </li>
/// </ul>
/// <div class="pg">…<a href="home.php?mod=follow&do=following&page=2" class="nxt">下一页</a></div>
/// ```
///
/// The follow link is printed in the account's own lists (`flw_btn_fo` 关注 for a follower not followed back), the
/// remark in its list of the followed. What the forum prints instead (`follower_status_off` "抱歉，关注功能尚未开启",
/// the login prompt, a member that does not exist) is the page's [SpaceListPage.message].
SpaceListPage<FollowUser> parseFollowListPage(uh.Document document) {
  final session = spaceSessionOf(document);
  final list = document.querySelector('ul.flw_ulist');
  if (list == null) {
    if (spaceNoticeOf(document) case final notice?) {
      return SpaceListPage(items: const [], message: notice.message, needLogin: notice.needLogin);
    }
    return SpaceListPage(items: const [], needLogin: session == null, session: session);
  }
  final items = <FollowUser>[];
  for (final li in list.children.where((e) => e.localName == 'li')) {
    final link = li.querySelector('h6 a[href*="uid="]');
    final uid = _intOf(_uidRe, link?.attributes['href']);
    final name = _textOf(link);
    if (uid == null || name == null) {
      continue;
    }
    final button = li.querySelector('a[id^="a_followmod_"]');
    final counts = li.querySelectorAll('p.ptm strong');
    // "最近动作: …", under the name.
    final recent = li.children.where((e) => e.localName == 'p' && !e.classes.contains('ptm')).firstOrNull;
    recent?.querySelector('span.xg1')?.remove();
    items.add(
      FollowUser(
        uid: uid,
        username: name,
        avatarUrl: _avatarOf(li.querySelector('a.flw_avt img')),
        remark: _textOf(li.querySelector('span[id^="followbkame_"]')),
        recentNote: _textOf(recent),
        followerCount: int.tryParse(_textOf(li.querySelector('strong[id^="followernum_"]')) ?? ''),
        followingCount: counts.length > 1 ? int.tryParse(_textOf(counts[1]) ?? '') : null,
        following: button == null ? null : (button.attributes['href'] ?? '').contains('op=del'),
        mutual: li.querySelector('span.flw_status_2') != null,
        canRemark: li.querySelector('a[id^="fbkname_"]') != null,
      ),
    );
  }
  return SpaceListPage(
    items: items,
    nextPageUrl: spaceNextPageUrlOf(document.querySelector('div#ct') ?? document.documentElement),
    session: session,
  );
}

/// What the viewer is to the member [uid], out of the head of a follow page of that member ([followListUrl] with
/// their uid); null on the viewer's own pages, for a guest, and for what the forum prints instead.
///
/// ```html
/// <div class="flw_hd">
///   <div class="tns"><table><tr>
///     <th><p><a href="home.php?mod=follow&uid=35&do=view">117</a></p><span>…广播…</span></th>
///     <th><p><a href="home.php?mod=follow&do=following&uid=35">1</a></p><span>…关注…</span></th>
///     <td><p><a href="home.php?mod=follow&do=follower&uid=35" id="followernum_35">1</a></p><span>…粉丝…</span></td>
///   </tr></table></div>
///   <div class="mtm o cl">
///     <div id="followflag">…<span class="z flw_status_2">互相关注</span>
///       <a id="a_followmod_35" href="…&op=del&fuid=35&from=head">取消关注</a></div>
///     <div id="unfollowflag" style="display: none"><span class="z flw_status_1">TA已关注您</span>
///       <a id="a_followmod_35" href="…&op=add&hash=HASH&fuid=35&from=head" class="flw_btn_fo">关注</a></div>
///   </div>
/// </div>
/// <div class="h cl">…<h2 class="mt">NAME<span class="xs1 xg1 xw0"><span id="followbkame_35">REMARK</span>
///   <a … id="fbkname_35">[修改备注]</a></span></h2></div>
/// ```
///
/// The block shown (the other one is `display: none`) tells whether the viewer follows the member: a member followed
/// back is 互相关注 (`flw_status_2`), one who follows the viewer and is not followed prints "TA已关注您".
FollowRelation? parseFollowRelation(uh.Document document, int uid) {
  final session = spaceSessionOf(document);
  final followed = document.querySelector('div#followflag');
  final unfollowed = document.querySelector('div#unfollowflag');
  if (session == null || followed == null || unfollowed == null) {
    return null;
  }
  final following = !(followed.attributes['style'] ?? '').contains('none');
  final head = document.querySelector('div.flw_hd');
  int? count(String selector) => int.tryParse(_textOf(head?.querySelector(selector)) ?? '');
  final title = document.querySelector('div.h h2.mt');
  final remark = _textOf(title?.querySelector('span[id^="followbkame_"]'));
  // The name is the title without the remark and its link.
  title?.querySelector('span')?.remove();
  return FollowRelation(
    session: session,
    uid: uid,
    username: _textOf(title),
    following: following,
    followsViewer: following
        ? followed.querySelector('span.flw_status_2') != null
        : unfollowed.querySelector('span[class*="flw_status"]') != null,
    remark: following ? remark : null,
    feedCount: count('th p a[href*="do=view"]'),
    followingCount: count('th p a[href*="do=following"]'),
    followerCount: count('td p a[href*="do=follower"]'),
  );
}

/// A broadcast of the forum's app API (plugin 4.0.0, a row of `feeds` of [json]), as the web parser reads it
/// ([_feedOf]); null for a row without its member.
///
/// A thread the viewer may not read (`restricted`: the forum, its read permission, its price) is the thread without
/// its title and beginning, and the app's words in place of the beginning; a thread gone (`thread` null) is the
/// forum's words that it was deleted.
FollowFeed? _feedFromApi(Map<String, dynamic> row, Map<String, dynamic> json) {
  final feedId = tsdmAppInt(row['feedid']);
  final uid = tsdmAppInt(row['uid']);
  final username = tsdmAppText(row['username']);
  if (feedId <= 0 || uid <= 0 || username.isEmpty) {
    return null;
  }
  final words = t.spacePage.forumWords;
  final noteHtml = tsdmAppText(row['note_html']);
  final note = noteHtml.trim().isEmpty ? null : (spaceV4Html(noteHtml)..classes.add('flw_quotenote'));
  final thread = row['thread'] is Map<String, dynamic> && row['deleted'] != 1 ? tsdmAppMap(row['thread']) : null;
  if (thread == null) {
    return FollowFeed(
      feedId: feedId,
      uid: uid,
      username: username,
      time: spaceV4Time(row['dateline'], json),
      note: note,
      content: uh.DivElement()..text = words.threadDeleted,
      threadMissing: true,
      canDelete: row['delete'] is Map,
    );
  }
  final tid = tsdmAppInt(thread['tid']);
  final restricted = tsdmAppText(thread['restricted']).isNotEmpty;
  final contentHtml = thread['content_html'];
  final content = restricted
      ? (uh.DivElement()..text = words.threadRestricted)
      : contentHtml is String && contentHtml.trim().isNotEmpty
      ? spaceV4Html(contentHtml)
      : null;
  final author = tsdmAppText(thread['author']);
  final posted = spaceV4Time(thread['dateline'], json);
  final subject = tsdmAppText(thread['subject']);
  final forum = tsdmAppText(thread['forum']);
  return FollowFeed(
    feedId: feedId,
    uid: uid,
    username: username,
    time: spaceV4Time(row['dateline'], json),
    note: note,
    threadId: tid > 0 ? tid : null,
    threadTitle: subject.isEmpty ? null : subject,
    content: content,
    origin: note != null && author.isNotEmpty && posted != null ? words.postedBy(name: author, time: posted) : null,
    forumName: forum.isEmpty ? null : forum,
    relayCount: tsdmAppInt(thread['relay']),
    replyCount: tsdmAppInt(thread['replies']),
    canRelay: tid > 0 && tsdmAppText(thread['relay_url']).isNotEmpty,
    canDelete: row['delete'] is Map,
  );
}

/// The broadcasts of [json] of the forum's app API (plugin 4.0.0).
List<FollowFeed> followFeedsFromApi(Map<String, dynamic> json) => [
  for (final row in tsdmAppList(json['feeds'])) ?_feedFromApi(row, json),
];

/// The url of the next part of broadcasts `next` of [json] (plugin 4.0.0), absolute and asked as the website asks it
/// (`inajax=1`: the web parser reads it as the fragment it then is), null once there are no more.
String? followNextFeedUrlFromApi(Map<String, dynamic> json) {
  final next = spaceV4Url(json['next']);
  if (next == null) {
    return null;
  }
  return next.contains('inajax=') ? next : '$next&inajax=1';
}

/// A first page of broadcasts of the forum's app API (plugin 4.0.0: `type: space_feed`, `schema` 59, `more` 0): the
/// broadcasts ([followFeedsFromApi]) and the forum's own `next` part, the session of the page. A list without a
/// broadcast to show is the empty list, as [parseFollowFeedPage] reads it.
SpaceListPage<FollowFeed> followFeedPageFromApi(Map<String, dynamic> json) {
  final feeds = followFeedsFromApi(json);
  return SpaceListPage(
    items: feeds,
    nextPageUrl: feeds.isEmpty ? null : followNextFeedUrlFromApi(json),
    session: spaceV4Session(json),
  );
}

/// A page of the members followed, or of the followers, of the forum's app API (plugin 4.0.0: `type: space_follow`,
/// `schema` 60), asked as [url], as [parseFollowListPage] reads it: the follow button of a row is its `unfollow_url`
/// or `follow_url` (none on another member's list of the viewer itself), "互相关注" is `mutual` 1, the remark and its
/// link are on the account's own list of the followed only.
SpaceListPage<FollowUser> followListPageFromApi(Map<String, dynamic> json, String url) {
  final items = <FollowUser>[];
  for (final row in tsdmAppList(json['users'])) {
    final uid = tsdmAppInt(row['uid']);
    final username = tsdmAppText(row['username']);
    if (uid <= 0 || username.isEmpty) {
      continue;
    }
    final remark = tsdmAppText(row['note']).trim();
    final recent = tsdmAppText(row['recentnote']).replaceAll(RegExp(r'\s+'), ' ').trim();
    items.add(
      FollowUser(
        uid: uid,
        username: username,
        avatarUrl: spaceV4Url(row['avatar']),
        remark: remark.isEmpty ? null : remark,
        recentNote: recent.isEmpty ? null : recent,
        followerCount: row.containsKey('follower') ? tsdmAppInt(row['follower']) : null,
        followingCount: row.containsKey('following') ? tsdmAppInt(row['following']) : null,
        following: tsdmAppText(row['unfollow_url']).isNotEmpty
            ? true
            : tsdmAppText(row['follow_url']).isNotEmpty
            ? false
            : null,
        mutual: row['mutual'] == 1,
        canRemark: tsdmAppText(row['note_url']).isNotEmpty,
      ),
    );
  }
  return SpaceListPage(items: items, nextPageUrl: spaceV4NextPageUrl(url, json), session: spaceV4Session(json));
}
