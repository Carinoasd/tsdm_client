import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Parsed favorites list page (`home.php?mod=space&do=favorite&type=TYPE[&page=N]`).
final class FavoriteListPage<T extends FavoriteItem> {
  /// Constructor.
  const FavoriteListPage({required this.items, this.nextPageUrl, this.needLogin = false});

  /// Records in this page.
  final List<T> items;

  /// Absolute url of the next page, null when this is the last page.
  final String? nextPageUrl;

  /// The server answered with a "please login" notice instead of the list.
  final bool needLogin;
}

/// Hidden parameters of the favorite dialogs (add and delete share the same shape).
typedef FavoriteFormParameters = ({String formHash, String referer});

/// Result of adding a thread or a forum to favorites.
sealed class FavoriteAddResult {
  const FavoriteAddResult();
}

/// Added, `succeedhandle_HANDLEKEY(url, msg, {'id': ID, 'favid': FAVID})`.
final class FavoriteAdded extends FavoriteAddResult {
  /// Constructor.
  const FavoriteAdded(this.favid);

  /// Id of the new record, null in the unlikely case the server omitted it.
  final String? favid;

  @override
  String toString() => 'FavoriteAdded(favid=$favid)';
}

/// The thread or forum was already in favorites (`errorhandle_HANDLEKEY('抱歉，您已收藏，请勿重复收藏', {})`).
final class FavoriteAlreadyExists extends FavoriteAddResult {
  /// Constructor.
  const FavoriteAlreadyExists();

  @override
  String toString() => 'FavoriteAlreadyExists';
}

/// The server refused with [message].
final class FavoriteAddFailed extends FavoriteAddResult {
  /// Constructor.
  const FavoriteAddFailed(this.message);

  /// Reason told by the server.
  final String message;

  @override
  String toString() => 'FavoriteAddFailed($message)';
}

/// Result of removing a favorite record.
final class FavoriteRemoveResult {
  /// Constructor.
  const FavoriteRemoveResult({required this.removed, this.message});

  /// True when the record is gone: removed right now, or it did not exist anymore.
  final bool removed;

  /// Message told by the server, if any.
  final String? message;

  @override
  String toString() => 'FavoriteRemoveResult(removed=$removed, message=$message)';
}

final _cdataRe = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true);
final _favidRe = RegExp(r"'favid'\s*:\s*'(\d+)'");
final _tagRe = RegExp('<[^>]+>');
final _scriptRe = RegExp('<script.*?</script>', dotAll: true);

/// Unwrap the html carried in an ajax xml answer `<root><![CDATA[...]]></root>`.
String _unwrapCdata(String body) => _cdataRe.firstMatch(body)?.group(1) ?? body;

/// The server echoes whatever `handlekey` the client sent (`k_favorite`, `favdelete`, `favoriteforum`,
/// `a_delete_FAVID` on the web pages), so the answers are matched on the prefix only.
final _errorRe = RegExp(r"errorhandle_\w+\('([^']*)'");
final _succeedRe = RegExp(r'succeedhandle_\w+\(');

String? _errorMessage(String body) => _errorRe.firstMatch(body)?.group(1)?.trim();

bool _succeeded(String body) => _succeedRe.hasMatch(body);

String _plainText(String body) {
  final text = _unwrapCdata(
    body,
  ).replaceAll(_scriptRe, ' ').replaceAll(_tagRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? 'unknown' : text.truncate(120, ellipsis: true);
}

/// Parse the thread favorites list page (`type=thread`).
///
/// ```html
/// <ul id="favorite_ul">
///   <li id="fav_FAVID" class="bbda ptm pbm">
///     <a class="y" href="home.php?mod=spacecp&ac=favorite&op=delete&favid=FAVID">删除</a>
///     <input type="checkbox" name="favorite[]" value="FAVID" vid="TID" />
///     <a href="forum.php?mod=viewthread&tid=TID">title</a> <span class="xg1"><span title="2026-9-6 02:39">4 秒前</span></span>
///     <div class="quote"><blockquote id="quote_preview">note</blockquote></div>   <!-- only with a note -->
///   </li>
/// </ul>
/// <div class="pgs cl mtm"><div class="pg">...<a class="nxt" href="...&page=2">下一页</a></div></div>
/// ```
///
/// Guests get a Discuz! 提示信息 page (`div#messagetext` "请先登录后才能继续浏览") which is reported as [FavoriteListPage.needLogin].
/// An empty list has `<p class="emp">您还没有添加任何收藏</p>` and no `ul#favorite_ul`.
FavoriteListPage<FavoriteThread> parseFavoriteListPage(uh.Document document) =>
    _parseListPage(document, _parseThreadItem);

/// Parse the forum favorites list page (`type=forum`): same shape as the thread one, the title link is
/// `a[href*="mod=forumdisplay"]` and the checkbox `vid` is the fid.
FavoriteListPage<FavoriteForum> parseFavoriteForumListPage(uh.Document document) =>
    _parseListPage(document, _parseForumItem);

/// Parse the list page of [type].
FavoriteListPage<FavoriteItem> parseFavoriteListPageOfType(uh.Document document, FavoriteType type) => switch (type) {
  FavoriteType.thread => parseFavoriteListPage(document),
  FavoriteType.forum => parseFavoriteForumListPage(document),
};

FavoriteListPage<T> _parseListPage<T extends FavoriteItem>(uh.Document document, T? Function(uh.Element) parseItem) {
  final listNode = document.querySelector('ul#favorite_ul');
  if (listNode == null) {
    final message = document.querySelector('div#messagetext')?.innerText.trim() ?? '';
    final needLogin =
        document.querySelector('div#messagelogin') != null || message.contains('登录') || message.contains('登入');
    return FavoriteListPage(items: const [], needLogin: needLogin);
  }
  final items = listNode.querySelectorAll('li').map(parseItem).whereType<T>().toList();
  final nextPageUrl = (document.querySelector('div.pgs > div.pg > a.nxt') ?? document.querySelector('div.pg > a.nxt'))
      ?.attributes['href']
      ?.prependHost();
  return FavoriteListPage(items: items, nextPageUrl: nextPageUrl);
}

/// The parts every record shares: favid, title link, time and note; null when the link is not there.
({String favid, uh.Element titleNode, String href, String? id, DateTime? time, String? description})? _parseItemCommon(
  uh.Element li, {
  required String linkSelector,
}) {
  final checkbox = li.querySelector('input[name="favorite[]"]');
  final favid = li.id.startsWith('fav_') ? li.id.substring(4) : checkbox?.attributes['value'];
  final titleNode = li.querySelector(linkSelector);
  final href = titleNode?.attributes['href'];
  if (favid == null || favid.isEmpty || titleNode == null || href == null) {
    return null;
  }
  final description = li.querySelector('div.quote blockquote')?.innerText.trim();
  return (
    favid: favid,
    titleNode: titleNode,
    href: href,
    id: checkbox?.attributes['vid'],
    time: li.querySelector('span.xg1 span[title]')?.attributes['title']?.parseToDateTimeUtc8(),
    description: description == null || description.isEmpty ? null : description,
  );
}

FavoriteThread? _parseThreadItem(uh.Element li) {
  final common = _parseItemCommon(li, linkSelector: 'a[href*="mod=viewthread"]');
  if (common == null) {
    return null;
  }
  final tid = common.id ?? common.href.uriQueryParameter('tid');
  if (tid == null || tid.isEmpty) {
    return null;
  }
  return FavoriteThread(
    favid: common.favid,
    tid: tid,
    title: common.titleNode.innerText.trim(),
    url: common.href.prependHost(),
    time: common.time,
    description: common.description,
  );
}

FavoriteForum? _parseForumItem(uh.Element li) {
  final common = _parseItemCommon(li, linkSelector: 'a[href*="mod=forumdisplay"]');
  if (common == null) {
    return null;
  }
  final fid = common.id ?? common.href.uriQueryParameter('fid');
  if (fid == null || fid.isEmpty) {
    return null;
  }
  return FavoriteForum(
    favid: common.favid,
    fid: fid,
    title: common.titleNode.innerText.trim(),
    url: common.href.prependHost(),
    time: common.time,
    description: common.description,
  );
}

/// Parse the hidden `formhash` and `referer` of a favorite dialog (add or delete), null when there is no form, e.g.
/// the record does not exist anymore.
FavoriteFormParameters? parseFavoriteForm(String body) {
  final document = parseHtmlDocument(_unwrapCdata(body));
  final formHash = document.querySelector('input[name="formhash"]')?.attributes['value'];
  if (formHash == null || formHash.isEmpty) {
    return null;
  }
  return (formHash: formHash, referer: document.querySelector('input[name="referer"]')?.attributes['value'] ?? '');
}

/// Parse the answer of the add-favorite form.
FavoriteAddResult parseFavoriteAddResult(String body) {
  if (_succeeded(body)) {
    return FavoriteAdded(_favidRe.firstMatch(body)?.group(1));
  }
  final message = _errorMessage(body);
  if (message != null) {
    return message.contains('已收藏') ? const FavoriteAlreadyExists() : FavoriteAddFailed(message);
  }
  return FavoriteAddFailed(_plainText(body));
}

/// Parse the answer of the delete-favorite form.
///
/// "抱歉，您指定的收藏不存在" counts as removed: the record is gone either way.
FavoriteRemoveResult parseFavoriteRemoveResult(String body) {
  if (_succeeded(body)) {
    return const FavoriteRemoveResult(removed: true);
  }
  final message = _errorMessage(body);
  if (message != null) {
    return FavoriteRemoveResult(removed: message.contains('不存在'), message: message);
  }
  return FavoriteRemoveResult(removed: false, message: _plainText(body));
}
