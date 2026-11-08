import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

/// The structured friends answer in [data]: a JSON answer of the forum's app API that carries a friends list page
/// (`home.php?mod=space&do=friend`, the own list or another member's) as fields (plugin 2.5.0, `type: friend`,
/// `schema` 10 or later), or the forum's own message of such a plugin (a guest, the friends switched off: `ok` 0,
/// `error: message`, with `login` telling the two apart). Null when the answer has to be read from its `document`
/// as before: a web page, an older plugin's answer (no `schema`, no `login`), a failed build, and the privacy page
/// the forum prints instead of another member's list, which the plugin answers without a `schema` (the list module
/// never ran).
///
/// The list is then built by [friendListPageFromApi]; the `document` of the answer, when there is one, is never
/// parsed.
Map<String, dynamic>? friendApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 10;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'friend' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The friends list of a structured answer [json] ([friendApiAnswerOf]) of the page [url], the same [FriendListPage]
/// the web page gives through `parseFriendListPage`: the rows as [Friend.fromApi] builds them (the credits only on
/// another member's list, `self` 0, as the page prints them only there; a member who is not there any more
/// dropped), the total the page prints ("当前共有 N 个好友", `count`), whose list it is (`owner.username`, which the
/// page parser reads from the title "NAME的好友") and the url of the next page when the forum has one (`has_next`: the
/// page's "下一页" link, the page asked with the next `page`). The forum's message (`ok` 0) is the notice the page
/// showed instead of the list ([FriendListPage.message]), with [FriendListPage.needLogin] when it asks to log in
/// ([tsdmAppMessageAsksLogin]). An empty list is a page (`count` 0, `friends []`), not a message.
FriendListPage friendListPageFromApi(Map<String, dynamic> json, String url) {
  if (json['ok'] != 1) {
    final message = tsdmAppText(json['message']).trim();
    talker.info('friends page: the forum answered a message: $message');
    return FriendListPage(
      items: const [],
      message: message.isEmpty ? null : message,
      needLogin: tsdmAppMessageAsksLogin(json),
    );
  }
  final ownList = tsdmAppInt(json['self']) == 1;
  // The visitors list (`view=visitor`) carries the time of each visit in `dateline`.
  final visitOffset = json['view'] == 'visitor' ? tsdmAppTimeOffset(json) : null;
  final items = tsdmAppList(
    json['friends'],
  ).map((e) => Friend.fromApi(e, ownList: ownList, visitTimeOffset: visitOffset)).nonNulls.toList();
  final ownerName = tsdmAppText(tsdmAppMap(json['owner'])['username']).trim();
  final page = tsdmAppInt(json['page']);
  final nextPageUrl = tsdmAppInt(json['has_next']) == 1 && page > 0 ? tsdmAppListPageUrl(url, page + 1) : null;
  return FriendListPage(
    items: items,
    nextPageUrl: nextPageUrl,
    totalCount: tsdmAppInt(json['count']),
    ownerName: ownerName.isEmpty ? null : ownerName,
  );
}
