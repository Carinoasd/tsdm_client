import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/achievements/view/achievements_page.dart';
import 'package:tsdm_client/features/activities/view/activities_page.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/view/login_page.dart';
import 'package:tsdm_client/features/bank/view/bank_page.dart';
import 'package:tsdm_client/features/blocking/view/user_block_page.dart';
import 'package:tsdm_client/features/blocking/view/website_blocklist_page.dart';
import 'package:tsdm_client/features/chat/view/chat_history_page.dart';
import 'package:tsdm_client/features/chat/view/chat_page.dart';
import 'package:tsdm_client/features/checkin/view/auto_checkin_page.dart';
import 'package:tsdm_client/features/checkin/view/checkin_calendar_page.dart';
import 'package:tsdm_client/features/custom_emoji/view/custom_emoji_packs_page.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';
import 'package:tsdm_client/features/editor/view/quick_phrases_page.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/view/favorite_page.dart';
import 'package:tsdm_client/features/floor_bookmark/view/floor_bookmark_page.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/view/forum_group_page.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/friend/view/friend_page.dart';
import 'package:tsdm_client/features/home/view/home_page.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/image/view/image_gallery_page.dart';
import 'package:tsdm_client/features/in_app_browser/view/in_app_browser_page.dart';
import 'package:tsdm_client/features/keyboard/view/keyboard_shortcuts_page.dart';
import 'package:tsdm_client/features/latest_thread/view/latest_thread_page.dart';
import 'package:tsdm_client/features/local_draft/view/local_draft_page.dart';
import 'package:tsdm_client/features/login_device/view/login_devices_page.dart';
import 'package:tsdm_client/features/magic/view/magic_center_page.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/medal_center/view/medal_center_page.dart';
import 'package:tsdm_client/features/medal_center/view/medal_title_hub_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/medal_grant_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/my_medals_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/title_exchange_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/title_issue_page.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/member_thread/view/member_thread_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/multi_user/view/manage_account_page.dart';
import 'package:tsdm_client/features/my_thread/view/my_thread_page.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/view/broadcast_message_detail_page.dart';
import 'package:tsdm_client/features/notification/view/notification_detail_page.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/notification/view/notification_search_page.dart';
import 'package:tsdm_client/features/notification/view/notification_sync_all_page.dart';
import 'package:tsdm_client/features/offline_thread/view/offline_threads_page.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/features/packet/view/packet_detail_page.dart';
import 'package:tsdm_client/features/points/views/points_page.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/view/adventure_page.dart';
import 'package:tsdm_client/features/pokemon/view/battle_page.dart';
import 'package:tsdm_client/features/pokemon/view/pokemon_detail_page.dart';
import 'package:tsdm_client/features/pokemon/view/pokemon_equipment_page.dart';
import 'package:tsdm_client/features/pokemon/view/pokemon_page.dart';
import 'package:tsdm_client/features/pokemon/view/pokemon_storage_page.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/view/fast_reply_edit_template_page.dart';
import 'package:tsdm_client/features/post/view/fast_reply_template_page.dart';
import 'package:tsdm_client/features/post/view/poll_create_page.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/profile/view/edit_avatar_page.dart';
import 'package:tsdm_client/features/profile/view/edit_signature_page.dart';
import 'package:tsdm_client/features/profile/view/edit_user_profile_page.dart';
import 'package:tsdm_client/features/profile/view/my_titles_page.dart';
import 'package:tsdm_client/features/profile/view/profile_page.dart';
import 'package:tsdm_client/features/profile/view/switch_user_group_page.dart';
import 'package:tsdm_client/features/profile/view/user_group_progress_page.dart';
import 'package:tsdm_client/features/ranklist/view/ranklist_page.dart';
import 'package:tsdm_client/features/rate/view/fast_rate_edit_template_page.dart';
import 'package:tsdm_client/features/rate/view/fast_rate_template_page.dart';
import 'package:tsdm_client/features/rate/view/rate_log_page.dart';
import 'package:tsdm_client/features/rate/view/rate_post_page.dart';
import 'package:tsdm_client/features/rate_stats/view/rate_stats_page.dart';
import 'package:tsdm_client/features/read_later/view/read_later_page.dart';
import 'package:tsdm_client/features/reading_time/view/reading_stats_page.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/models/historical_log.dart';
import 'package:tsdm_client/features/settings/view/about_page.dart'; // 已恢复干净
import 'package:tsdm_client/features/settings/view/debug_log_page.dart';
import 'package:tsdm_client/features/settings/view/home_layout_page.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/settings/view/thread_card_appearance.dart';
import 'package:tsdm_client/features/settings/widgets/app_license_page.dart';
import 'package:tsdm_client/features/share_receive/models/shared_thread_draft.dart';
import 'package:tsdm_client/features/site_stats/view/site_stats_page.dart';
import 'package:tsdm_client/features/space/view/album_upload_page.dart';
import 'package:tsdm_client/features/space/view/blog_post_page.dart';
import 'package:tsdm_client/features/space/view/space_album_page.dart';
import 'package:tsdm_client/features/space/view/space_blog_page.dart';
import 'package:tsdm_client/features/space/view/space_page.dart';
import 'package:tsdm_client/features/tag/view/tag_cloud_page.dart';
import 'package:tsdm_client/features/task_center/view/task_center_page.dart';
import 'package:tsdm_client/features/thread/v1/view/share_floor_image_page.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread_follow/view/followed_threads_page.dart';
import 'package:tsdm_client/features/thread_visit_history/view/thread_visit_history_page.dart';
import 'package:tsdm_client/features/title_shop/view/title_shop_page.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/features/update/view/local_changelog_page.dart';
import 'package:tsdm_client/features/update/view/update_page.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Tracks root dialogs so external navigation respects their modal barriers.
final popupRouteObserver = PopupRouteObserver();

/// Tracks pushed pages, so a page that is only covered (the pokemon centre, while the battle page is on top of it) can
/// refresh itself when it is shown again.
final routeObserver = RouteObserver<PageRoute<dynamic>>();

/// App router instance wrapped with global singleton widgets.
final router = GoRouter(
  initialLocation: ScreenPaths.homepage,
  observers: [popupRouteObserver, routeObserver],
  routes: _appRoutes,
);

/// All named routes in app.
final List<RouteBase> _appRoutes = [
  // The four tabs of the bottom navigation bar (phones) and of the side navigation (tablets and desktop), in the order
  // of [HomeTab]: homepage, forums, notifications and "me". Every other page is opened above the shell.
  StatefulShellRoute(
    // Partial global singleton page here.
    builder: (context, router, navigator) => HomePage(showNavigationBar: true, child: navigator),
    // Slide horizontally between the shell branches instead of switching instantly.
    navigatorContainerBuilder: (context, navigationShell, children) =>
        AnimatedBranchPageView(navigationShell: navigationShell, children: children),
    branches: [
      StatefulShellBranch(
        routes: [AppRoute(path: ScreenPaths.homepage, builder: (_) => const HomepagePage())],
      ),
      StatefulShellBranch(
        routes: [AppRoute(path: ScreenPaths.topic, builder: (_) => const TopicsPage())],
      ),
      StatefulShellBranch(
        routes: [AppRoute(path: ScreenPaths.notice, builder: (_) => const NotificationPage(asTab: true))],
      ),
      StatefulShellBranch(
        routes: [AppRoute(path: ScreenPaths.me, builder: (_) => const MePage())],
      ),
    ],
  ),
  // The settings were the third tab; the "me" tab opens them now, as do the menus of the list pages.
  AppRoute(
    path: ScreenPaths.settings.path,
    builder: (_) => const SettingsPage(),
    routes: [
      AppRoute(
        path: ScreenPaths.settingsThreadAppearance.path,
        builder: (_) => const SettingsThreadCardAppearancePage(),
      ),
      AppRoute(path: ScreenPaths.settingsHomeLayout.path, builder: (_) => const SettingsHomeLayoutPage()),
    ],
  ),
  AppRoute(
    path: ScreenPaths.loggedUserProfile,
    builder: (state) {
      final heroTag = state.uri.queryParameters['hero'];
      return ProfilePage(heroTag: heroTag);
    },
  ),
  AppRoute(path: ScreenPaths.about, builder: (_) => const AboutPage()),
  AppRoute(path: ScreenPaths.activities, builder: (_) => const ActivitiesPage()),
  AppRoute(path: ScreenPaths.license, builder: (_) => const AppLicensePage()),
  AppRoute(path: ScreenPaths.keyboardShortcuts, builder: (_) => const KeyboardShortcutsPage()),
  AppRoute(
    path: ScreenPaths.forum,
    builder: (state) {
      final title = state.uri.queryParameters['appBarTitle'];
      final threadTypeName = state.uri.queryParameters['threadTypeName'];
      final threadTypeID = state.uri.queryParameters['threadTypeID'];
      final FilterType? threadType;
      if (threadTypeName != null && threadTypeID != null) {
        threadType = FilterType(name: threadTypeName, typeID: threadTypeID);
      } else {
        threadType = null;
      }
      return ForumPage(title: title, fid: state.pathParameters['fid']!, threadType: threadType);
    },
  ),
  AppRoute(
    path: ScreenPaths.forumGroup,
    builder: (state) {
      final gid = state.pathParameters['gid'];
      final title = state.uri.queryParameters['title'];

      return ForumGroupPage(gid: gid!, title: title);
    },
  ),
  // The same page shows in the detail pane of the list pages on wide windows (`TwoPaneLayout`), built from the same
  // query; a deep link or a notification still opens it here, as a page of its own.
  AppRoute(path: ScreenPaths.threadV1, builder: (state) => ThreadPage.fromQuery(state.uri.queryParameters)),
  AppRoute(
    path: ScreenPaths.search,
    builder: (state) {
      final keyword = state.uri.queryParameters['keyword'];
      final authorUid = state.uri.queryParameters['authorUid'];
      final authorName = state.uri.queryParameters['authorName'];
      final fid = state.uri.queryParameters['fid'];
      final page = state.uri.queryParameters['page'];
      return SearchPage(keyword: keyword, authorUid: authorUid, authorName: authorName, fid: fid, page: page);
    },
  ),
  AppRoute(path: ScreenPaths.rootNotice, builder: (_) => const NotificationPage()),
  AppRoute(
    path: ScreenPaths.reply,
    builder: (state) {
      final target = state.pathParameters['target']!;
      final noticeTypeIndex = state.uri.queryParameters['noticeType']!.parseToInt()!;
      return NoticeDetailPage(url: target, noticeType: NoticeType.values[noticeTypeIndex]);
    },
  ),
  AppRoute(
    path: ScreenPaths.fastReplyTemplate,
    builder: (state) {
      final pick = bool.parse(state.pathParameters['pick']!);
      return FastReplyTemplatePage(pick: pick);
    },
  ),
  AppRoute(
    path: ScreenPaths.fastReplyTemplateEdit,
    builder: (state) {
      final editType = FastReplyTemplateEditType.values[int.parse(state.pathParameters['editType']!)];
      final initialValue = state.extra as FastReplyTemplateModel?;
      return FastReplyTemplateEditPage(editType, initialValue);
    },
  ),
  AppRoute(path: ScreenPaths.quickPhrases, builder: (_) => const QuickPhrasesPage()),
  AppRoute(path: ScreenPaths.noticeSearch, builder: (_) => const NotificationSearchPage()),
  AppRoute(path: ScreenPaths.notificationSyncAll, builder: (_) => const NotificationSyncAllPage()),
  AppRoute(
    path: ScreenPaths.myThread,
    builder: (state) => MyThreadPage(
      showDrafts: state.uri.queryParameters['tab'] == 'drafts',
      showReplies: state.uri.queryParameters['tab'] == 'reply',
    ),
  ),
  AppRoute(
    path: ScreenPaths.memberThread,
    // The current user's own list is the "my threads" page, with its drafts and filters.
    redirect: (context, state) {
      final auth = context.readOrNull<AuthenticationRepository>();
      return memberThreadRedirect(
        state.uri.queryParameters,
        currentUid: auth?.effectiveCurrentUid,
        currentUsername: auth?.effectiveCurrentUser?.username,
      );
    },
    builder: (state) => MemberThreadPage(
      uid: state.uri.queryParameters['uid'],
      username: state.uri.queryParameters['username'],
      initialTab: state.uri.queryParameters['tab'] == MemberThreadTab.reply.name
          ? MemberThreadTab.reply
          : MemberThreadTab.thread,
    ),
  ),
  AppRoute(
    path: ScreenPaths.favorite,
    builder: (state) => FavoritePage(
      initialType: state.uri.queryParameters['type'] == FavoriteType.forum.queryValue
          ? FavoriteType.forum
          : FavoriteType.thread,
    ),
  ),
  AppRoute(path: ScreenPaths.offlineThreads, builder: (state) => const OfflineThreadsPage()),
  AppRoute(path: ScreenPaths.floorBookmarks, builder: (_) => const FloorBookmarkPage()),
  AppRoute(
    path: ScreenPaths.friend,
    builder: (state) => FriendPage(
      uid: state.uri.queryParameters['uid'],
      username: state.uri.queryParameters['username'],
      visitor: state.uri.queryParameters['view'] == 'visitor',
      online: state.uri.queryParameters['view'] == 'online',
    ),
  ),
  // A member's blogs and albums: home.php?mod=space&uid=N&do=blog|album[&id=M].
  AppRoute(
    path: ScreenPaths.space,
    builder: (state) => SpacePage(
      uid: int.tryParse(state.uri.queryParameters['uid'] ?? '') ?? 0,
      username: state.uri.queryParameters['username'],
      initialTab: SpaceTab.of(state.uri.queryParameters['tab']),
    ),
  ),
  AppRoute(
    path: ScreenPaths.spaceBlog,
    builder: (state) => SpaceBlogPage(
      uid: int.tryParse(state.uri.queryParameters['uid'] ?? '') ?? 0,
      blogId: int.tryParse(state.uri.queryParameters['blogId'] ?? '') ?? 0,
      title: state.uri.queryParameters['title'],
    ),
  ),
  AppRoute(
    path: ScreenPaths.spaceAlbum,
    builder: (state) => SpaceAlbumPage(
      uid: int.tryParse(state.uri.queryParameters['uid'] ?? '') ?? 0,
      albumId: int.tryParse(state.uri.queryParameters['albumId'] ?? '') ?? 0,
      name: state.uri.queryParameters['name'],
    ),
  ),
  AppRoute(path: ScreenPaths.spaceBlogPost, builder: (_) => const BlogPostPage()),
  AppRoute(
    path: ScreenPaths.spaceAlbumUpload,
    builder: (state) => AlbumUploadPage(albumId: int.tryParse(state.uri.queryParameters['albumId'] ?? '')),
  ),
  AppRoute(path: ScreenPaths.tagCloud, builder: (_) => const TagCloudPage()),
  AppRoute(
    path: ScreenPaths.latestThread,
    builder: (state) {
      final url = state.uri.queryParameters['url']!;
      return LatestThreadPage(url: url, title: state.uri.queryParameters['title']);
    },
  ),
  AppRoute(
    path: ScreenPaths.login,
    builder: (state) {
      final username = state.uri.queryParameters['username'];
      if (state.extra == null) {
        return LoginPage(username: username);
      }
      final loginArgsMap = state.extra! as Map<String, dynamic>;
      final redirectBackState = loginArgsMap['redirectBackState'] as GoRouterState;
      return LoginPage(redirectBackState: redirectBackState, username: username);
    },
  ),
  AppRoute(
    path: ScreenPaths.profile,
    builder: (state) {
      final uid = state.uri.queryParameters['uid'];
      final username = state.uri.queryParameters['username'];
      final heroTag = state.uri.queryParameters['hero'];
      // Fill uid and username to access user profile page.
      // Actually each one of them is enough to locate the user space url.
      // When both are provided, use uid in advance.
      return ProfilePage(uid: uid, username: username, heroTag: heroTag);
    },
  ),
  AppRoute(path: ScreenPaths.editAvatar, builder: (_) => const EditAvatarPage()),
  AppRoute(path: ScreenPaths.switchUserGroup, builder: (_) => const SwitchUserGroupPage()),
  AppRoute(path: ScreenPaths.userGroupProgress, builder: (_) => const UserGroupProgressPage()),
  AppRoute(path: ScreenPaths.switchTitle, builder: (_) => const MyTitlesPage()),
  AppRoute(path: ScreenPaths.titleShop, builder: (_) => const TitleShopPage()),
  AppRoute(path: ScreenPaths.magicCenter, builder: (_) => const MagicCenterPage()),
  AppRoute(path: ScreenPaths.userBlock, builder: (_) => const UserBlockPage()),
  AppRoute(path: ScreenPaths.websiteBlocklist, builder: (_) => const WebsiteBlocklistPage()),
  AppRoute(path: ScreenPaths.medalCenter, builder: (_) => const MedalCenterPage()),
  AppRoute(path: ScreenPaths.ranklist, builder: (_) => const RanklistPage()),
  AppRoute(
    path: ScreenPaths.siteStats,
    builder: (state) => SiteStatsPage(url: state.uri.queryParameters['url']),
  ),
  AppRoute(path: ScreenPaths.medalTitleHub, builder: (_) => const MedalTitleHubPage()),
  AppRoute(path: ScreenPaths.titleExchange, builder: (_) => const TitleExchangePage()),
  AppRoute(path: ScreenPaths.myMedals, builder: (_) => const MyMedalsPage()),
  AppRoute(path: ScreenPaths.medalGrant, builder: (_) => const MedalGrantPage()),
  AppRoute(path: ScreenPaths.titleIssue, builder: (_) => const TitleIssuePage()),
  AppRoute(path: ScreenPaths.bank, builder: (_) => const BankPage()),
  AppRoute(path: ScreenPaths.taskCenter, builder: (_) => const TaskCenterPage()),
  AppRoute(
    path: ScreenPaths.pokemon,
    builder: (state) => PokemonPage(initialTab: (state.extra as int?) ?? 0),
  ),
  AppRoute(
    path: ScreenPaths.pokemonDetail,
    builder: (state) => PokemonDetailPage(pokemon: state.extra! as Pokemon),
  ),
  AppRoute(path: ScreenPaths.pokemonAdventure, builder: (_) => const AdventurePage()),
  AppRoute(
    path: ScreenPaths.pokemonBattle,
    builder: (state) => BattlePage(args: state.extra! as BattlePageArgs),
  ),
  AppRoute(path: ScreenPaths.pokemonStorage, builder: (_) => const PokemonStoragePage()),
  AppRoute(
    path: ScreenPaths.pokemonEquipment,
    builder: (state) => PokemonEquipmentPage(pokemon: state.extra! as Pokemon),
  ),
  AppRoute(path: ScreenPaths.editUserProfile, builder: (_) => const EditUserProfilePage()),
  AppRoute(path: ScreenPaths.editSignature, builder: (_) => const EditSignaturePage()),
  AppRoute(
    path: ScreenPaths.ratePost,
    builder: (state) {
      final username = state.pathParameters['username']!;
      final pid = state.pathParameters['pid']!;
      final floor = state.pathParameters['floor']!;
      final rateAction = state.pathParameters['rateAction']!;
      return RatePostPage(username: username, pid: pid, floor: floor, rateAction: rateAction);
    },
  ),
  AppRoute(
    path: ScreenPaths.rateLog,
    builder: (state) {
      final tid = state.pathParameters['tid']!;
      final pid = state.pathParameters['pid']!;
      final threadTitle = state.uri.queryParameters['threadTitle'];
      final total = state.uri.queryParameters['total'];
      return RateLogPage(tid: tid, pid: pid, threadTitle: threadTitle, total: total);
    },
  ),
  AppRoute(
    path: ScreenPaths.fastRateTemplate,
    builder: (state) {
      final pick = bool.parse(state.pathParameters['pick']!);
      return FastRateTemplatePage(pick: pick);
    },
  ),
  AppRoute(
    path: ScreenPaths.fastRateTemplateEdit,
    builder: (state) {
      final editType = FastRateTemplateEditType.values[int.parse(state.pathParameters['editType']!)];
      final initialValue = state.extra as FastRateTemplateModel?;
      return FastRateTemplateEditPage(editType, initialValue);
    },
  ),
  AppRoute(path: ScreenPaths.points, builder: (_) => const PointsPage()),
  AppRoute(path: ScreenPaths.checkinCalendar, builder: (_) => const CheckinCalendarPage()),
  AppRoute(path: ScreenPaths.ratingStats, builder: (_) => const RateStatsPage()),
  AppRoute(path: ScreenPaths.moderatorPanel, builder: (_) => const ModeratorPanelPage()),
  AppRoute(path: ScreenPaths.achievements, builder: (_) => const AchievementsPage()),
  AppRoute(
    path: ScreenPaths.editPost,
    builder: (state) {
      final editType = state.pathParameters['editType']?.parseToInt();
      final fid = state.pathParameters['fid']!;
      final tid = state.uri.queryParameters['tid'];
      final pid = state.uri.queryParameters['pid'];
      assert(editType != null, 'PostEditType enum value is not a integer: $editType');
      assert(PostEditType.values.length > editType!, 'invalid PostEditType enum value: $editType');
      return PostEditPage(
        // Switching the thread kind replaces this route with the same path and another `kind` query: the pages carry
        // no key, so the navigator would keep the old page state and never fetch the form for the new kind.
        key: ValueKey('post-edit-${state.uri}'),
        editType: PostEditType.values[editType!],
        fid: fid,
        tid: tid,
        pid: pid,
        pollOffered: state.uri.queryParameters['poll'] == '1',
        threadKind: ThreadKind.fromQuery(state.uri.queryParameters['kind']),
        transfer: switch (state.extra) {
          final ThreadModeTransfer transfer => transfer,
          SharedThreadDraft(:final transfer) => transfer,
          _ => null,
        },
        mentionSuggestions: switch (state.extra) {
          final List<MentionSuggestion> suggestions => suggestions,
          _ => null,
        },
        sharedImages: switch (state.extra) {
          SharedThreadDraft(:final imagePaths) => imagePaths,
          _ => null,
        },
      );
    },
  ),
  AppRoute(
    path: ScreenPaths.createPoll,
    builder: (state) {
      final fid = state.pathParameters['fid']!;
      // Guard: only a positive forum id reaches the page, which then validates the forum's own form.
      if (!RegExp(r'^[1-9]\d*$').hasMatch(fid)) return const PollCreateInvalidPage();
      return PollCreatePage(
        fid: fid,
        transfer: state.extra is ThreadModeTransfer ? state.extra! as ThreadModeTransfer : null,
      );
    },
  ),
  AppRoute(
    path: ScreenPaths.broadcastMessageDetail,
    builder: (state) {
      final pmid = state.pathParameters['pmid']!;
      return BroadcastMessageDetailPage(pmid: pmid);
    },
  ),
  AppRoute(
    path: ScreenPaths.chat,
    builder: (state) {
      final uid = state.pathParameters['uid']!;
      String? username;
      if (state.extra is Map<String, dynamic>) {
        final map = state.extra! as Map<String, dynamic>;
        username = map['username'] as String?;
      }
      return ChatPage(username: username, uid: uid);
    },
  ),
  AppRoute(
    path: ScreenPaths.chatHistory,
    builder: (state) {
      final uid = state.pathParameters['uid']!;
      return ChatHistoryPage(uid: uid);
    },
  ),
  ImageGalleryRoute(),
  AppRoute(
    path: ScreenPaths.shareFloorImage,
    // Only opened from a floor's menu with the floor: nothing to render without it.
    redirect: (_, state) => state.extra is ShareFloorImageArgs ? null : ScreenPaths.homepage,
    builder: (state) => ShareFloorImagePage(state.extra! as ShareFloorImageArgs),
  ),
  AppRoute(path: ScreenPaths.threadVisitHistory, builder: (_) => const ThreadVisitHistoryPage()),
  AppRoute(path: ScreenPaths.readLater, builder: (_) => const ReadLaterPage()),
  AppRoute(path: ScreenPaths.readingStats, builder: (_) => const ReadingStatsPage()),
  AppRoute(path: ScreenPaths.localDrafts, builder: (_) => const LocalDraftPage()),
  AppRoute(path: ScreenPaths.followedThreads, builder: (_) => const FollowedThreadsPage()),
  AppRoute(path: ScreenPaths.customEmojiPacks, builder: (_) => const CustomEmojiPacksPage()),
  AppRoute(
    path: ScreenPaths.customEmojiPack,
    builder: (state) => CustomEmojiPackPage(packId: state.pathParameters['packId']!),
  ),
  AppRoute(path: ScreenPaths.autoCheckinDetail, builder: (_) => const AutoCheckinPage()),
  AppRoute(path: ScreenPaths.debugLog, builder: (_) => const DebugLogPage()),
  AppRoute(path: ScreenPaths.debugHistoricalLog, builder: (_) => const DebugHistoricalLogPage()),
  AppRoute(
    path: ScreenPaths.debugHistoricalLogDetail,
    builder: (state) {
      final log = state.extra as HistoricalLog?;
      return DebugHistoricalLogDetailPage(log!);
    },
  ),
  AppRoute(
    path: ScreenPaths.packetDetail,
    builder: (state) {
      final tid = int.parse(state.pathParameters['tid']!);
      return PacketDetailPage(tid);
    },
  ),
  AppRoute(path: ScreenPaths.manageAccount, builder: (_) => const ManageAccountPage()),
  AppRoute(path: ScreenPaths.loginDevices, builder: (_) => const LoginDevicesPage()),
  AppRoute(path: ScreenPaths.update, builder: (_) => const UpdatePage()),
  AppRoute(path: ScreenPaths.localChangelog, builder: (_) => const LocalChangelogPage()),
  // 接收路由参数
  AppRoute(
    path: ScreenPaths.openInApp,
    builder: (state) {
      final url = state.uri.queryParameters['url'];
      final autoOpen = state.uri.queryParameters['autoOpen'] == 'true';
      return OpenInAppPage(initialUrl: url, autoOpen: autoOpen);
    },
  ),
  AppRoute(
    path: ScreenPaths.inAppBrowser,
    builder: (state) => InAppBrowserPage(Uri.tryParse(state.uri.queryParameters['url'] ?? '')),
  ),
];

/// Refer from wondrous app.
/// Custom router declaration.
class AppRoute extends GoRoute {
  /// Constructor.
  AppRoute({
    required super.path,
    required Widget Function(GoRouterState s) builder,
    List<GoRoute> routes = const [],
    super.parentNavigatorKey,
    super.redirect,
  }) : super(
         name: path,
         routes: routes,
         pageBuilder: (context, state) =>
             MaterialPage<void>(name: path, arguments: state.pathParameters, child: RootPage(path, builder(state))),
       );
}
