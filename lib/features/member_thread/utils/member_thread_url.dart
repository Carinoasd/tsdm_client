import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// The two lists of a member's "TA的主题" page: their threads and their replies (`type=thread|reply`).
enum MemberThreadTab {
  /// The threads (`type=thread`).
  thread,

  /// The replies (`type=reply`), one row per reply.
  reply,
}

/// The first page of the list [tab] of the member named by [uid] and/or [username], as the forum links it
/// (`home.php?mod=space&uid=N&do=thread&view=me&type=thread|reply`).
///
/// Both are passed on as the link gave them: the forum locates the member by `username` when there is one (a renamed
/// member by the name history too) and by `uid` otherwise, as it does for every space page.
///
/// With [fid] (above 0) the list holds what the member posted in that forum only: the forum's `fid` filter of the
/// page (`source/app/home/child/space/thread.php`, both lists), kept by the links to the next pages.
String memberThreadUrl(MemberThreadTab tab, {String? uid, String? username, int? fid}) {
  final who = [
    if (uid != null && uid.isNotEmpty) 'uid=${Uri.encodeQueryComponent(uid)}',
    if (username != null && username.isNotEmpty) 'username=${Uri.encodeQueryComponent(username)}',
  ].join('&');
  final forum = fid != null && fid > 0 ? '&fid=$fid' : '';
  return '$baseUrl/home.php?mod=space&$who&do=thread&view=me&type=${tab.name}$forum';
}

/// The query of the route of a member's list ([ScreenPaths.memberThread]): the member by [uid], by [username] when
/// the uid is not known, the list [tab] when it is not the threads, and the forum [fid] the page may limit the lists
/// to (above 0).
Map<String, String> memberThreadQuery({int? uid, String? username, String? tab, int? fid}) => {
  if (uid != null && uid > 0) 'uid': '$uid' else if (username != null && username.isNotEmpty) 'username': username,
  'tab': ?tab,
  if (fid != null && fid > 0) 'fid': '$fid',
};

/// Whether the author of a floor ([uid], [username]) is the account in use ([accountUid], [accountName]): by the uid
/// when the floor has one, else by the name as the forum compares names ([forumUsernameKey]), as the member list
/// route tells the own list ([memberThreadRedirect]).
bool isAccountMember({
  required int? uid,
  required String username,
  required int? accountUid,
  required String? accountName,
}) => uid != null && uid > 0
    ? uid == accountUid
    : accountName != null && username.isNotEmpty && forumUsernameKey(username) == forumUsernameKey(accountName);

/// [value] as PHP's `intval` reads a query parameter (the forum's `intval($_GET['uid'])`): its leading digits after
/// optional blanks and sign, 0 when there are none (`abc`, empty, missing).
int forumIntval(String? value) {
  final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(value ?? '');
  return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
}

/// The tab of the account's own "my threads" page a list link ([queryParameters] of
/// `home.php?mod=space&do=thread&view=me…`) names: `reply` for the replies (`type=reply`), `drafts` for the draft
/// box (`type=thread&filter=save`, also when the type is left out), null for the threads.
String? myThreadTabOf(Map<String, String> queryParameters) {
  final type = queryParameters['type'];
  if (type == 'reply') {
    return 'reply';
  }
  final threads = type == null || type.isEmpty || type == 'thread';
  return threads && queryParameters['filter'] == 'save' ? 'drafts' : null;
}

/// A member's name as the forum compares it: the forum looks a name up in its member table, whose collation
/// (`utf8mb4_unicode_ci`) ignores the case, the trailing blanks and the full-width forms of the ASCII letters
/// (`AG_LOW`, `ag_low `, `ａｇ_low` all find `ag_low` on the test forum).
String forumUsernameKey(String name) {
  final buffer = StringBuffer();
  for (final rune in name.trimRight().runes) {
    // Full-width ASCII (U+FF01 to U+FF5E) and the ideographic space.
    buffer.writeCharCode(
      rune >= 0xFF01 && rune <= 0xFF5E
          ? rune - 0xFEE0
          : rune == 0x3000
          ? 0x20
          : rune,
    );
  }
  return buffer.toString().trimRight().toLowerCase();
}

/// Where the route of a member's list (`ScreenPaths.memberThread` with [queryParameters]) goes instead when the member
/// is the account in use ([currentUid], [currentUsername]): the account's own "my threads" page on the tab the link
/// named ([myThreadTabOf]: `tab=reply` of the route, its `filter=save`), with its drafts and the forum's filters. Null
/// when it is another member, or when no account is in use.
///
/// The member is told as the forum tells it: by the name when the route has one ([forumUsernameKey]), by the uid
/// otherwise ([forumIntval]).
String? memberThreadRedirect(Map<String, String> queryParameters, {int? currentUid, String? currentUsername}) {
  final username = queryParameters['username'];
  final bool self;
  if (username != null && username.isNotEmpty) {
    self =
        currentUsername != null &&
        currentUsername.isNotEmpty &&
        forumUsernameKey(username) == forumUsernameKey(currentUsername);
  } else {
    final uid = forumIntval(queryParameters['uid']);
    self = uid > 0 && uid == currentUid;
  }
  if (!self) {
    return null;
  }
  final tab = queryParameters['tab'] == 'reply' ? 'reply' : (queryParameters['filter'] == 'save' ? 'drafts' : null);
  return Uri(path: ScreenPaths.myThread, queryParameters: tab == null ? null : {'tab': tab}).toString();
}
