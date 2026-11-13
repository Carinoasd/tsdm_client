import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/doing/models/doing_models.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_v4.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

final _uidRe = RegExp(r'[?&;]uid=(\d+)');
final _doidRe = RegExp(r'dl(\d+)$');
final _digitsRe = RegExp(r'\d+');

int? _intOf(RegExp re, String? s) => s == null ? null : int.tryParse(re.firstMatch(s)?.group(1) ?? '');

String? _textOf(uh.Element? e) {
  final s = e?.text?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s == null || s.isEmpty ? null : s;
}

String? _avatarOf(uh.Element? img) {
  final url = img?.attributes['src'] ?? img?.attributes['data-src'];
  return url == null || url.isEmpty ? null : spaceAbsoluteUrl(url);
}

/// What a record may hold: the forum cuts a longer one (`getstr($message, 200)`), a Chinese character counting two.
const doingMaxLength = 200;

/// The length of [text] as the forum counts it for [doingMaxLength] (`cutstr`, as the page's own counter): one for
/// a character of one byte, two for any other.
int doingLengthOf(String text) => text.runes.fold(0, (sum, rune) => sum + (rune < 0x80 ? 1 : 2));

/// The first page of the records: the [view] of the account in use, or the member [uid]'s own.
String doingListUrl({DoingView view = DoingView.all, int? uid}) => uid != null && uid > 0
    ? '$baseUrl/home.php?mod=space&uid=$uid&do=doing&view=me'
    : '$baseUrl/home.php?mod=space&do=doing&view=${view.query}';

/// The record [doid] alone, as the link of a notice opens it.
String doingUrl(int doid) => '$baseUrl/home.php?mod=space&do=doing&doid=$doid';

/// The page [page] of the replies of the record [doid], the fragment the website loads under it.
String doingCommentsUrl(int doid, {int page = 1}) =>
    '$baseUrl/home.php?mod=spacecp&ac=doing&op=getcomment&doid=$doid&inajax=1&page_c=$page';

/// A page of records (`home.php?mod=space&do=doing&view=all|follow|we|me[&uid=N][&page=P]`, twenty a page).
///
/// ```html
/// <form id="mood_addform" action="home.php?mod=spacecp&ac=doing&view=all">…<textarea name="message">…</textarea>
///   <input type="hidden" name="formhash" value="…" /></form>            (the account's own lists)
/// <div class="xld xlda">
///   <div id="KEYdl3" class="doing_list cl"><div class="doing_list_item">
///     <div class="doing_avatar"><a href="home.php?mod=space&uid=35"><img …></a></div>
///     <div class="item_right">
///       <div class="item_author_box"><a href="home.php?mod=space&uid=35" class="author_name">NAME</a></div>
///       <div class="item_info_date"><span><span title="2026-11-10 13:47">1&nbsp;分钟前</span></span></div>
///       <div class="item_content"><div class="mbm">MESSAGE</div>
///         <div class="doing_images">…<img src="THUMB" file="PICTURE" class="doing_image zoom" />…</div>
///         <div class="share_card_box mbm">…what it shares…</div></div>
///       <div class="item_info">…
///         <a class="doing_comment_btn icon_box" data-doid="3"><i></i><span>3</span></a>     (回复 without replies)
///         <a href="home.php?mod=spacecp&ac=doing&op=delete&doid=3&handlekey=doinghk_3">删除</a>   (the own ones)
///       </div>
///     </div>
///   </div></div>
/// </div>
/// <div class="pgs cl mtm"><div class="pg">…<a href="…&page=2" class="nxt">下一页</a></div></div>
/// ```
///
/// None is `<p class="emp">现在还没有记录</p>`; what the forum prints instead (`doing_status_off` "抱歉，记录功能尚未开启",
/// the login prompt of the lists of an account) is the page's [SpaceListPage.message].
SpaceListPage<Doing> parseDoingListPage(uh.Document document) {
  final ct = document.querySelector('div#ct');
  final rows = ct?.querySelectorAll('div.doing_list[id*="dl"]') ?? const <uh.Element>[];
  final form = ct?.querySelector('form#mood_addform');
  if (rows.isEmpty && form == null && ct?.querySelector('p.emp') == null) {
    if (spaceNoticeOf(document) case final notice?) {
      return SpaceListPage(items: const [], message: notice.message, needLogin: notice.needLogin);
    }
  }
  final items = <Doing>[];
  for (final row in rows) {
    final button = row.querySelector('a.doing_comment_btn');
    final doid = int.tryParse(button?.attributes['data-doid'] ?? '') ?? _intOf(_doidRe, row.id);
    final author = row.querySelector('a.author_name') ?? row.querySelector('div.doing_avatar a[href*="uid="]');
    final uid = _intOf(
      _uidRe,
      row.querySelector('div.doing_avatar a')?.attributes['href'] ?? author?.attributes['href'],
    );
    final content = row.querySelector('div.item_content');
    if (doid == null || uid == null || content == null) {
      continue;
    }
    final images = <String>[];
    for (final img in content.querySelectorAll('div.doing_images img')) {
      final url = img.attributes['file'] ?? img.attributes['zoomfile'] ?? img.attributes['src'];
      if (url != null && url.isNotEmpty) {
        images.add(spaceAbsoluteUrl(url));
      }
    }
    for (final e in [...content.querySelectorAll('div.doing_images'), ...content.querySelectorAll('.share_card_img')]) {
      e.remove();
    }
    items.add(
      Doing(
        doid: doid,
        uid: uid,
        username: _textOf(row.querySelector('a.author_name')) ?? '$uid',
        avatarUrl: _avatarOf(row.querySelector('div.doing_avatar img')),
        time: _textOf(row.querySelector('div.item_info_date')),
        content: content,
        imageUrls: images,
        replyCount: int.tryParse(_textOf(button?.querySelector('span')) ?? '') ?? 0,
        canDelete: row.querySelector('a[href*="op=delete"][href*="doid="]') != null,
      ),
    );
  }
  return SpaceListPage(
    items: items,
    nextPageUrl: spaceNextPageUrlOf(ct),
    session: spaceSessionOf(document),
    canPost: form?.querySelector('textarea[name="message"]') != null,
  );
}

/// The page [page] of the replies of the record [doid] out of its fragment [html]
/// (`home.php?mod=spacecp&ac=doing&op=getcomment&doid=N&inajax=1&page_c=P`): ten top replies a page, each followed by
/// its own replies (`dtll`; those past the third are printed hidden behind "查看更多", and are read all the same).
///
/// ```html
/// <div id="comment_1_li" class="doing_list cl cl " style="padding-left:0em;"><div class="doing_list_item">
///   <div class="doing_avatar"><a href="home.php?mod=space&uid=31"><img …></a></div>
///   <div class="item_right">
///     <div class="item_author_box"><a href="home.php?mod=space&uid=31" class="author_name">NAME</a></div>
///     <div class="item_info_date"><span>2026-11-10 13:47</span><span>来自 </span></div>
///     <div class="item_content"><div class="item_content_box mbm">
///       <span>回复 <a … class="author_name">NAME</a>: </span>MESSAGE</div></div>
///     <div class="item_info">…<a onclick="docomment_form(3, 1, 'KEY');">回复</a>
///       <a href="home.php?mod=spacecp&ac=doing&op=delete&doid=3&docid=1&handlekey=doinghk_3_1">删除</a>…</div>
///   </div>
/// </div></div>
/// <div id="comment_4_li" class="doing_list cl cl dtll " style="padding-left:4em;">…</div>
/// <div id="comment_toggle_1_li" class="doing_comment_list cl dtll toggle-comment">…查看更多(4)…</div>
/// <div class="pg"><strong>1</strong><a onclick="docomment_get_page(3, 'KEY', 2);" data-page="2">2</a>…</div>
/// ```
///
/// A reply once deleted keeps its row without its author and is left out; none at all is `div.doing_empty`.
DoingCommentPage parseDoingComments(String html, {required int doid, required int page}) {
  final body = parseHtmlDocument('<html><body>$html</body></html>').body;
  final comments = <DoingComment>[];
  for (final row in body?.querySelectorAll(r'div[id^="comment_"][id$="_li"]') ?? const <uh.Element>[]) {
    final id = int.tryParse(row.id.substring('comment_'.length, row.id.length - '_li'.length));
    final author = row.querySelector('div.item_author_box a.author_name');
    final uid = _intOf(_uidRe, author?.attributes['href']);
    final name = _textOf(author);
    final message = row.querySelector('div.item_content_box');
    if (id == null || uid == null || uid <= 0 || name == null || message == null) {
      continue;
    }
    comments.add(
      DoingComment(
        id: id,
        doid: doid,
        uid: uid,
        username: name,
        avatarUrl: _avatarOf(row.querySelector('div.doing_avatar img')),
        time: _textOf(row.querySelector('div.item_info_date span')),
        message: message,
        nested: row.classes.contains('dtll'),
        canReply: row.querySelector('a[onclick^="docomment_form"]') != null,
        canDelete: row.querySelector('a[href*="op=delete"][href*="docid="]') != null,
      ),
    );
  }
  final hasMore = (body?.querySelectorAll('div.pg a[data-page]') ?? const <uh.Element>[]).any(
    (a) => (int.tryParse(_digitsRe.firstMatch(a.attributes['data-page'] ?? '')?.group(0) ?? '') ?? 0) > page,
  );
  return DoingCommentPage(comments: comments, page: page, hasMore: hasMore);
}

/// A page of records of the forum's app API (plugin 4.0.0: `type: space_doing`, `schema` 57), asked as [url]: the
/// same records as the web page ([parseDoingListPage]), the times on the member's wall clock (`Y-m-d H:i`).
///
/// The content is the record's `message_html` and the html of what it shares (`card.html`) for the app's renderer,
/// the pictures of the card left out as the web parser leaves them; the pictures of the record are `images[].url`.
/// The post box is the page's `post` form (the member's own lists, as the web page prints it).
SpaceListPage<Doing> doingListPageFromApi(Map<String, dynamic> json, String url) {
  final items = <Doing>[];
  for (final row in tsdmAppList(json['doings'])) {
    final doid = tsdmAppInt(row['doid']);
    final uid = tsdmAppInt(row['uid']);
    if (doid <= 0 || uid <= 0) {
      continue;
    }
    final content = uh.DivElement()
      ..classes.add('item_content')
      ..append(spaceV4Html(tsdmAppText(row['message_html']))..classes.add('mbm'));
    final card = tsdmAppText(tsdmAppMap(row['card'])['html']);
    if (card.trim().isNotEmpty) {
      final box = spaceV4Html(card)..classes.add('share_card_box');
      for (final e in box.querySelectorAll('.share_card_img')) {
        e.remove();
      }
      content.append(box);
    }
    final username = tsdmAppText(row['username']);
    items.add(
      Doing(
        doid: doid,
        uid: uid,
        username: username.isEmpty ? '$uid' : username,
        avatarUrl: spaceV4Url(row['avatar']),
        time: spaceV4Time(row['dateline'], json),
        content: content,
        imageUrls: [
          for (final image in tsdmAppList(row['images'])) ?spaceV4Url(image['url']),
        ],
        replyCount: tsdmAppInt(row['replynum']),
        canDelete: row['can_delete'] == 1,
      ),
    );
  }
  return SpaceListPage(
    items: items,
    nextPageUrl: spaceV4NextPageUrl(url, json),
    session: spaceV4Session(json),
    canPost: json['post'] is Map,
  );
}

/// The page [page] of the replies of the record [doid] of the forum's app API (plugin 4.0.0: `type: space_docomment`,
/// `schema` 58): the same replies as the fragment ([parseDoingComments]), each top reply followed by its own (the
/// folded ones too), the rows the forum left of a deleted reply left out. A reply to a reply begins with whom it
/// answers, as the web page prints it.
DoingCommentPage doingCommentsFromApi(Map<String, dynamic> json, {required int doid, required int page}) {
  final comments = <DoingComment>[];
  for (final row in tsdmAppList(json['comments'])) {
    final id = tsdmAppInt(row['id']);
    final uid = tsdmAppInt(row['uid']);
    final username = tsdmAppText(row['username']);
    if (id <= 0 || uid <= 0 || username.isEmpty || row['deleted'] == 1) {
      continue;
    }
    final message = uh.DivElement()..classes.add('item_content_box');
    final replyTo = tsdmAppText(tsdmAppMap(row['reply_to'])['username']);
    if (replyTo.isNotEmpty) {
      message.append(uh.SpanElement()..text = '${t.spacePage.doing.replyTo(name: replyTo)}: ');
    }
    spaceV4Html(tsdmAppText(row['message_html']), into: message);
    comments.add(
      DoingComment(
        id: id,
        doid: doid,
        uid: uid,
        username: username,
        avatarUrl: spaceV4Url(row['avatar']),
        time: spaceV4Time(row['dateline'], json),
        message: message,
        nested: tsdmAppInt(row['layer']) > 0,
        canReply: row['reply'] is Map,
        canDelete: row['can_delete'] == 1,
      ),
    );
  }
  final current = tsdmAppInt(json['page']);
  return DoingCommentPage(
    comments: comments,
    page: page,
    hasMore: (current > 0 ? current : page) < tsdmAppInt(json['pages']),
  );
}
