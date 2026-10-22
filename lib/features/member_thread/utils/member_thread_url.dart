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
String memberThreadUrl(MemberThreadTab tab, {String? uid, String? username}) {
  final who = [
    if (uid != null && uid.isNotEmpty) 'uid=${Uri.encodeQueryComponent(uid)}',
    if (username != null && username.isNotEmpty) 'username=${Uri.encodeQueryComponent(username)}',
  ].join('&');
  return '$baseUrl/home.php?mod=space&$who&do=thread&view=me&type=${tab.name}';
}

/// Where the route of a member's list (`ScreenPaths.memberThread` with [queryParameters]) goes instead when the member
/// is the account in use ([currentUid], [currentUsername]): the account's own "my threads" page, with its drafts and
/// the forum's filters. Null when it is another member, or when no account is in use.
///
/// The member is told as the forum tells it: by the name when the route has one, by the uid otherwise.
String? memberThreadRedirect(Map<String, String> queryParameters, {int? currentUid, String? currentUsername}) {
  final username = queryParameters['username'];
  if (username != null && username.isNotEmpty) {
    return currentUsername != null && currentUsername.isNotEmpty && username == currentUsername
        ? ScreenPaths.myThread
        : null;
  }
  final uid = int.tryParse(queryParameters['uid'] ?? '');
  return uid != null && uid > 0 && uid == currentUid ? ScreenPaths.myThread : null;
}
