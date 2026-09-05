import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Parsed favorites list page (`home.php?mod=space&do=favorite&type=thread[&page=N]`).
final class FavoriteListPage {
  /// Constructor.
  const FavoriteListPage({required this.items, this.nextPageUrl, this.needLogin = false});

  /// Records in this page.
  final List<FavoriteThread> items;

  /// Absolute url of the next page, null when this is the last page.
  final String? nextPageUrl;

  /// The server answered with a "please login" notice instead of the list.
  final bool needLogin;
}

/// Hidden parameters of the favorite dialogs (add and delete share the same shape).
typedef FavoriteFormParameters = ({String formHash, String referer});

/// Result of adding a thread to favorites.
sealed class FavoriteAddResult {
  const FavoriteAddResult();
}

/// Added, `succeedhandle_k_favorite(url, msg, {'id': TID, 'favid': FAVID})`.
final class FavoriteAdded extends FavoriteAddResult {
  /// Constructor.
  const FavoriteAdded(this.favid);

  /// Id of the new record, null in the unlikely case the server omitted it.
  final String? favid;

  @override
  String toString() => 'FavoriteAdded(favid=$favid)';
}

/// The thread was already in favorites (`errorhandle_k_favorite('抱歉，您已收藏，请勿重复收藏', {})`).
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

String? _errorMessage(String body, String handleKey) =>
    RegExp("errorhandle_$handleKey\\('([^']*)'").firstMatch(body)?.group(1)?.trim();

bool _succeeded(String body, String handleKey) => body.contains('succeedhandle_$handleKey(');

String _plainText(String body) {
  final text = _unwrapCdata(body)
      .replaceAll(_scriptRe, ' ')
      .replaceAll(_tagRe, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.isEmpty ? 'unknown' : text.truncate(120, ellipsis: true);
}

/// Parse the favorites list page.
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
FavoriteListPage parseFavoriteListPage(uh.Document document) {
  final listNode = document.querySelector('ul#favorite_ul');
  if (listNode == null) {
    final message = document.querySelector('div#messagetext')?.innerText.trim() ?? '';
    final needLogin =
        document.querySelector('div#messagelogin') != null || message.contains('登录') || message.contains('登入');
    return FavoriteListPage(items: const [], needLogin: needLogin);
  }
  final items = listNode.querySelectorAll('li').map(_parseItem).whereType<FavoriteThread>().toList();
  final nextPageUrl =
      (document.querySelector('div.pgs > div.pg > a.nxt') ?? document.querySelector('div.pg > a.nxt'))
          ?.attributes['href']
          ?.prependHost();
  return FavoriteListPage(items: items, nextPageUrl: nextPageUrl);
}

FavoriteThread? _parseItem(uh.Element li) {
  final checkbox = li.querySelector('input[name="favorite[]"]');
  final favid = li.id.startsWith('fav_') ? li.id.substring(4) : checkbox?.attributes['value'];
  final titleNode = li.querySelector('a[href*="mod=viewthread"]');
  final href = titleNode?.attributes['href'];
  final tid = checkbox?.attributes['vid'] ?? href?.uriQueryParameter('tid');
  if (favid == null || favid.isEmpty || titleNode == null || href == null || tid == null || tid.isEmpty) {
    return null;
  }
  final description = li.querySelector('div.quote blockquote')?.innerText.trim();
  return FavoriteThread(
    favid: favid,
    tid: tid,
    title: titleNode.innerText.trim(),
    url: href.prependHost(),
    time: li.querySelector('span.xg1 span[title]')?.attributes['title']?.parseToDateTimeUtc8(),
    description: description == null || description.isEmpty ? null : description,
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
  if (_succeeded(body, 'k_favorite')) {
    return FavoriteAdded(_favidRe.firstMatch(body)?.group(1));
  }
  final message = _errorMessage(body, 'k_favorite');
  if (message != null) {
    return message.contains('已收藏') ? const FavoriteAlreadyExists() : FavoriteAddFailed(message);
  }
  return FavoriteAddFailed(_plainText(body));
}

/// Parse the answer of the delete-favorite form.
///
/// "抱歉，您指定的收藏不存在" counts as removed: the record is gone either way.
FavoriteRemoveResult parseFavoriteRemoveResult(String body) {
  if (_succeeded(body, 'favdelete')) {
    return const FavoriteRemoveResult(removed: true);
  }
  final message = _errorMessage(body, 'favdelete');
  if (message != null) {
    return FavoriteRemoveResult(removed: message.contains('不存在'), message: message);
  }
  return FavoriteRemoveResult(removed: false, message: _plainText(body));
}
