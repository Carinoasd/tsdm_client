part of 'homepage_bloc.dart';

/// Build the homepage state from a structured answer [json] of the forum's app API (`indexApiAnswerOf`), for the
/// account [username] the app has (null to take the one the answer names) with the avatar [avatarUrl] the app has
/// (null to take the one the answer names), as the web page is parsed with them.
///
/// The same [HomepageState] the web page gives, from the fields instead of the html:
///
/// * `stats` is the status bar ([forumStatusFromApi]), `user` the viewer with `links` of the status bar
///   ([loggedUserInfoFromApi]);
/// * `blocks` are the `Kahrpba` tabs in the order the website shows them ([pinnedThreadGroupsFromApi]: `id` 5 the
///   rank, a tab without any row left out, GitHub #155; `blocks_html` parsed as the page when the plugin could not
///   read the template);
/// * `slides` is the swiper ([swiperUrlsFromApi]), `unread` the header's notice count and new message mark
///   ([unreadInfoFromApi]);
/// * `red_packet` is today's daily red packet (none for a guest, as from the page), `formhash` the form hash to
///   claim it with;
/// * `online` are the numbers of the "在线会员" line (plugin 3.8.0, [HomeOnline]; none for an older answer).
///
/// The forum's message (`ok` 0): the login prompt (`login` 1) asks to log in; any other message, or the prompt for
/// an app that has no account, is the failure the web page of it would be parsed as.
HomepageState homepageStateFromApi(Map<String, dynamic> json, String? username, {String? avatarUrl}) {
  if (json['ok'] != 1) {
    return HomepageState(
      status: username == null || json['login'] == 1 ? HomepageStatus.needLogin : HomepageStatus.failure,
    );
  }
  final loggedUserInfo = loggedUserInfoFromApi(json, username: username, avatarUrl: avatarUrl);
  final loggedUsername = loggedUserInfo.username;
  final (unreadNoticeCount, hasUnreadMessage) = unreadInfoFromApi(json);
  return HomepageState(
    status: loggedUsername.isNotEmpty ? HomepageStatus.success : HomepageStatus.needLogin,
    forumStatus: forumStatusFromApi(json),
    loggedUserInfo: loggedUserInfo,
    pinnedThreadGroupList: pinnedThreadGroupsFromApi(json),
    swiperUrlList: swiperUrlsFromApi(json),
    unreadNoticeCount: unreadNoticeCount,
    hasUnreadMessage: hasUnreadMessage,
    // As from the page: the forum only offers the packet to a member.
    dailyRedPacket: loggedUsername.isEmpty ? null : dailyRedPacketFromApi(json),
    formHash: ForumHomeApiPage(json).formHash,
    online: HomeOnline.fromApi(json['online']),
  );
}
