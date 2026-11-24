import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/in_app_browser/utils/open_forum_page.dart';
import 'package:tsdm_client/features/multi_user/widgets/account_switch_dialog.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/notification/utils/notice_page_tab.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';
import 'package:universal_html/parsing.dart';

/// Least width of a tile of the entry grids at text scale 1: five on a row of a phone, four at 1.3 times the text.
const _entryTileMinWidth = 64.0;

/// Fewest and most tiles on a row of the entry grids.
const _entryMinColumns = 4;
const _entryMaxColumns = 5;

/// An entry of the "me" tab: icon, label and what a tap does.
typedef _MeEntry = ({Key key, IconData icon, String label, VoidCallback onTap});

/// The "me" tab of the home shell: the account in use and every page of it, in one place.
///
/// Up top the account card: avatar, name, user group (a tap opens the profile), the check-in of the day and the
/// switch to another saved account. Under it the rows of the account (editing its profile; the moderator's panel for an
/// account of a management group), then its pages in three grids: content (threads, favorites, bookmarks, history, the
/// drafts kept on this device and the forum's drafts box), social (private messages, friends, visitors) and stats
/// (points, check-ins, reading, ratings); then the services of the forum in the same grid (tasks, magic, bank,
/// ranklist, activities, medals and titles, achievements, pokemon center, the background shop, and the pages of the
/// forum's other plugins opened in a browser: game center, court, CP system, part-time job) and the list of the app
/// itself (accounts, settings, about).
///
/// The settings were a tab of their own before; the whole settings page is one tap away here, nothing in it moved. The
/// pages the side navigation of wide windows listed besides its tabs are entries here as well.
///
/// Without an account: the login, the services (a tap asks for a login), the settings and about.
class MePage extends StatefulWidget {
  /// Constructor.
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  final _scrollController = ScrollController();
  late final StreamSubscription<ScrollToTopEvent> _scrollToTopSub;

  @override
  void initState() {
    super.initState();
    // A double tap on the tab of this page in the navigation.
    _scrollToTopSub = scrollToTopStream.stream.listen((event) {
      if (event.tabIndex == HomeTab.me.index && mounted && _scrollController.hasClients) {
        unawaited(_scrollController.animateTo(0, duration: duration200, curve: Curves.easeInOut));
      }
    });
    spaceModulesOff.addListener(_onSwitchesChanged);
    TsdmAppApi.pluginInfo.addListener(_onSwitchesChanged);
  }

  /// A module of the space, or a plugin of the forum ([TsdmAppApi.sitePluginOff]), was found switched off: its entry
  /// goes.
  void _onSwitchesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The homepage the app loaded tells whether the account may see the forum's statistics.
    final repository = context.readOrNull<ForumHomeRepository>();
    if (!identical(repository, _homeRepository)) {
      _homeRepository = repository;
      unawaited(_homePageSub?.cancel());
      _homePage = repository?.getCache();
      _homePageSub = repository?.pageStream.listen((page) {
        if (mounted && !identical(page, _homePage)) {
          setState(() => _homePage = page);
        }
      });
    }
  }

  @override
  void dispose() {
    spaceModulesOff.removeListener(_onSwitchesChanged);
    TsdmAppApi.pluginInfo.removeListener(_onSwitchesChanged);
    unawaited(_scrollToTopSub.cancel());
    unawaited(_homePageSub?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  ForumHomeRepository? _homeRepository;
  StreamSubscription<ForumHomePage>? _homePageSub;

  /// The homepage loaded last, null before any.
  ForumHomePage? _homePage;

  /// The account in use, the stored one before the homepage verified it; null without one.
  UserLoginInfo? _account(BuildContext context) {
    final account = watchCurrentAccount(context);
    if (account != null) {
      return account.user;
    }
    return context.readOrNull<AuthenticationRepository>()?.currentUser;
  }

  /// The profile of each account seen: the homepage loaded it, so it is usually cached; otherwise it is asked once.
  final _profiles = <int, Future<UserProfile?>>{};

  Future<UserProfile?> _profileOf(int uid) => _profiles[uid] ??= () async {
    final repository = context.readOrNull<ProfileRepository>();
    if (repository == null) {
      return null;
    }
    // The profile of this very account, by its uid: the account in use may change while the page is on its way.
    final page = (await repository.fetchProfile(uid: '$uid').run()).toNullable();
    final profile = page == null ? null : (await buildProfilePage(page).run()).toNullable();
    if (profile != null && profile.uid == '$uid') {
      ManagementGroupCache.remember(uid, value: (profile.moderatorGroup ?? '').trim().isNotEmpty);
    }
    if (profile == null) {
      // Asked again next time the page is built, not kept as missing.
      _profiles.removeWhere((key, _) => key == uid);
    }
    return profile;
  }();

  /// Open [path] above the shell.
  void _open(String path, {Map<String, String> query = const {}}) =>
      unawaited(context.pushNamed(path, queryParameters: query));

  /// The pages of the account with what it wrote, kept and read.
  List<_MeEntry> _contentEntries(BuildContext context) {
    final tr = context.t.mePage.entries;
    return [
      (
        key: const ValueKey('me-my-threads'),
        icon: Symbols.article_rounded,
        label: tr.myThreads,
        onTap: () => _open(ScreenPaths.myThread),
      ),
      (
        key: const ValueKey('me-favorites'),
        icon: Symbols.star_rounded,
        label: tr.favorites,
        onTap: () => _open(ScreenPaths.favorite),
      ),
      (
        key: const ValueKey('me-collections'),
        icon: Symbols.collections_bookmark_rounded,
        label: tr.collections,
        onTap: () => _open(ScreenPaths.collections, query: {'tab': 'mine'}),
      ),
      (
        key: const ValueKey('me-followed-threads'),
        icon: Symbols.notifications_active_rounded,
        label: tr.followedThreads,
        onTap: () => _open(ScreenPaths.followedThreads),
      ),
      (
        key: const ValueKey('me-floor-bookmarks'),
        icon: Symbols.turned_in_not_rounded,
        label: tr.bookmarks,
        onTap: () => _open(ScreenPaths.floorBookmarks),
      ),
      (
        key: const ValueKey('me-read-later'),
        icon: Symbols.watch_later_rounded,
        label: tr.readLater,
        onTap: () => _open(ScreenPaths.readLater),
      ),
      (
        key: const ValueKey('me-history'),
        icon: Symbols.history_rounded,
        label: tr.history,
        onTap: () => _open(ScreenPaths.threadVisitHistory),
      ),
      // The drafts kept on this device while writing, and the drafts box of the forum (the third tab of "my threads"):
      // named apart so the one is not taken for the other.
      (
        key: const ValueKey('me-local-drafts'),
        icon: Symbols.edit_note_rounded,
        label: tr.localDrafts,
        onTap: () => _open(ScreenPaths.localDrafts),
      ),
      (
        key: const ValueKey('me-drafts'),
        icon: Symbols.drafts_rounded,
        label: tr.drafts,
        onTap: () => _open(ScreenPaths.myThread, query: {'tab': 'drafts'}),
      ),
      (
        key: const ValueKey('me-downloads'),
        icon: Symbols.download_rounded,
        label: tr.downloads,
        onTap: () => _open(ScreenPaths.attachmentDownloads),
      ),
    ];
  }

  /// The other users: messages, friends and visitors, the broadcasts of the members followed and the records.
  List<_MeEntry> _socialEntries(BuildContext context) {
    final tr = context.t.mePage.entries;
    final off = spaceModulesOff.value;
    return [
      // The private messages are a tab of the notifications.
      (
        key: const ValueKey('me-messages'),
        icon: Symbols.mail_rounded,
        label: tr.messages,
        onTap: () {
          noticePageTabRequest.value = NoticePageTab.personalMessage;
          showHomeTab(context, HomeTab.notice);
        },
      ),
      (
        key: const ValueKey('me-friends'),
        icon: Symbols.people_rounded,
        label: tr.friends,
        onTap: () => _open(ScreenPaths.friend),
      ),
      (
        key: const ValueKey('me-visitors'),
        icon: Symbols.visibility_rounded,
        label: tr.visitors,
        onTap: () => _open(ScreenPaths.friend, query: {'view': 'visitor'}),
      ),
      // Offered until the forum says their module is switched off.
      if (!off.contains(SpaceModule.broadcast))
        (
          key: const ValueKey('me-follow-feed'),
          icon: Symbols.dynamic_feed_rounded,
          label: tr.followFeed,
          onTap: () => _open(ScreenPaths.followFeed),
        ),
      if (!off.contains(SpaceModule.doing))
        (
          key: const ValueKey('me-doings'),
          icon: Symbols.edit_note_rounded,
          label: tr.doings,
          onTap: () => _open(ScreenPaths.doing),
        ),
    ];
  }

  /// The numbers of the account: points, check-ins, reading and ratings; and the forum's own statistics, unless the
  /// homepage says the account [uid] may not see them (plugin 3.8.0 of the forum's app API; shown as before while
  /// nothing tells).
  List<_MeEntry> _statsEntries(BuildContext context, {required int? uid}) {
    final tr = context.t.mePage.entries;
    return [
      (
        key: const ValueKey('me-points'),
        icon: Symbols.show_chart_rounded,
        label: tr.points,
        onTap: () => _open(ScreenPaths.points),
      ),
      (
        key: const ValueKey('me-checkin-calendar'),
        icon: Symbols.event_available_rounded,
        label: tr.checkinCalendar,
        onTap: () => _open(ScreenPaths.checkinCalendar),
      ),
      (
        key: const ValueKey('me-reading-stats'),
        icon: Symbols.bar_chart_rounded,
        label: tr.readingStats,
        onTap: () => _open(ScreenPaths.readingStats),
      ),
      (
        key: const ValueKey('me-rating-stats'),
        icon: Symbols.thumb_up_alt_rounded,
        label: tr.ratingStats,
        onTap: () => _open(ScreenPaths.ratingStats),
      ),
      if (siteStatsAllowedBy(_homePage, uid: uid) ?? true)
        (
          key: const ValueKey('me-site-stats'),
          icon: Symbols.query_stats_rounded,
          label: tr.siteStats,
          onTap: () => _open(ScreenPaths.siteStats),
        ),
    ];
  }

  /// The services of the forum: the pages the side navigation listed besides its tabs, and the others of the account.
  /// Listed for a guest too, a tap on one that needs an account asks for a login then.
  List<_MeEntry> _serviceEntries(BuildContext context, {required bool loggedIn}) {
    _MeEntry service(Key key, IconData icon, String label, String path, {bool needLogin = true}) => (
      key: key,
      icon: icon,
      label: label,
      onTap: () => _open(needLogin && !loggedIn ? ScreenPaths.login : path),
    );
    final t = context.t;
    return [
      service(const ValueKey('me-tasks'), Symbols.task_alt_rounded, t.taskCenter.title, ScreenPaths.taskCenter),
      service(const ValueKey('me-magic'), Symbols.auto_fix_high_rounded, t.magicCenter.title, ScreenPaths.magicCenter),
      service(const ValueKey('me-bank'), Symbols.account_balance_rounded, t.bank.title, ScreenPaths.bank),
      service(
        const ValueKey('me-ranklist'),
        Symbols.leaderboard_rounded,
        t.ranklistPage.title,
        ScreenPaths.ranklist,
        needLogin: false,
      ),
      service(const ValueKey('me-activities'), Symbols.event_rounded, t.navigation.activities, ScreenPaths.activities),
      // The medal centre and the title shop are on the page of medals and titles.
      service(
        const ValueKey('me-medals'),
        Symbols.workspace_premium_rounded,
        t.medalTitleHub.title,
        ScreenPaths.medalTitleHub,
      ),
      service(
        const ValueKey('me-achievements'),
        Symbols.emoji_events_rounded,
        t.achievementsPage.title,
        ScreenPaths.achievements,
      ),
      service(const ValueKey('me-pokemon'), Icons.catching_pokemon, t.pokemon.title, ScreenPaths.pokemon),
      // The background shop: the app's own pages with plugin 4.1.0, the website's before (`status`; none asked here).
      if (TsdmAppApi.backgroundShop case final shop? when shop != TsdmAppBackgroundShop.none)
        (
          key: const ValueKey('me-background-shop'),
          icon: Symbols.wallpaper_rounded,
          label: t.backgroundShop.title,
          onTap: () => !loggedIn
              ? _open(ScreenPaths.login)
              : shop == TsdmAppBackgroundShop.native
              ? _open(ScreenPaths.backgroundShop)
              : unawaited(_openPluginPage('$baseUrl/plugin.php?id=background:memcp')),
        ),
      for (final (id, page, icon, label, needLogin) in [
        ('gamecenter', 'gamecenter', Symbols.sports_esports_rounded, t.mePage.entries.gameCenter, false),
        ('tsdm_court', 'tsdm_court:court', Symbols.gavel_rounded, t.mePage.entries.court, true),
        ('tsdmcp', 'tsdmcp', Symbols.favorite_rounded, t.mePage.entries.cpSystem, true),
        ('np_cliworkdz', 'np_cliworkdz:work', Symbols.work_rounded, t.mePage.entries.partTimeJob, true),
      ])
        // Offered until the forum's app API says the plugin is switched off.
        if (!TsdmAppApi.sitePluginOff(id))
          (
            key: ValueKey('me-plugin-$id'),
            icon: icon,
            label: label,
            onTap: () => needLogin && !loggedIn
                ? _open(ScreenPaths.login)
                : unawaited(_openPluginPage('$baseUrl/plugin.php?id=$page')),
          ),
    ];
  }

  /// Open the page of one of the forum's plugins in a browser, signed in with the account in use.
  Future<void> _openPluginPage(String url) async {
    if (!await openForumPageInBrowser(GoRouter.of(context), url) && mounted) {
      showSnackBar(context: context, message: context.t.openInAppPage.browserLaunchFailed, clearPrevious: true);
    }
  }

  /// A row of the app's list.
  Widget _row(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String path,
  }) => SectionListTile(
    key: key,
    leading: Icon(icon),
    title: Text(title),
    trailing: const Icon(Symbols.chevron_right_rounded),
    onTap: () => _open(path),
  );

  /// The rows of the account under its card: editing its profile, and the forum's moderation panel for an account of a
  /// management group (管理组, read from its profile).
  Widget _buildAccountRows(BuildContext context, {required int? uid}) => FutureBuilder<UserProfile?>(
    future: uid == null ? null : _profileOf(uid),
    builder: (context, snapshot) => AppTileGroup(
      key: const ValueKey('me-account-rows'),
      children: [
        _row(
          context,
          key: const ValueKey('me-edit-profile'),
          icon: Symbols.person_edit_rounded,
          title: context.t.editUserProfilePage.title,
          path: ScreenPaths.editUserProfile,
        ),
        if (uid != null && snapshot.data?.uid == '$uid' && (snapshot.data?.moderatorGroup ?? '').trim().isNotEmpty)
          _row(
            context,
            key: const ValueKey('me-moderator-panel'),
            icon: Symbols.admin_panel_settings_rounded,
            title: context.t.modcp.panel,
            path: ScreenPaths.moderatorPanel,
          ),
      ],
    ),
  );

  /// The app: the accounts saved on this device (with an account), the settings and about.
  Widget _buildApp(BuildContext context, {required bool loggedIn}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _GroupCaption(context.t.mePage.app),
      AppTileGroup(
        children: [
          if (loggedIn)
            _row(
              context,
              key: const ValueKey('me-manage-accounts'),
              icon: Symbols.manage_accounts_rounded,
              title: context.t.manageAccountPage.title,
              path: ScreenPaths.manageAccount,
            ),
          _row(
            context,
            key: const ValueKey('me-settings'),
            icon: Symbols.settings_rounded,
            title: context.t.navigation.settings,
            path: ScreenPaths.settings.path,
          ),
          _row(
            context,
            key: const ValueKey('me-about'),
            icon: Symbols.info_rounded,
            title: context.t.settingsPage.othersSection.about,
            path: ScreenPaths.about,
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final account = _account(context);
    final loggedIn = account != null;
    return Scaffold(
      appBar: AppBar(title: Text(context.t.mePage.title)),
      body: SafeArea(
        left: false,
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final padding = appCenteredPadding(constraints.maxWidth, maxWidth: appFormMaxWidth, minPadding: 16);
            final gap = constraints.maxWidth >= 600 ? appSurfaceGap + 4 : appSurfaceGapCompact + 4;
            final tr = context.t.mePage;
            return ListView(
              key: const ValueKey('me-page-list'),
              controller: _scrollController,
              padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
              children: [
                if (account case final UserLoginInfo user) ...[
                  _AccountCard(user: user, profileOf: _profileOf),
                  SizedBox(height: gap),
                  _buildAccountRows(context, uid: user.uid),
                  SizedBox(height: gap),
                  for (final (key, title, entries) in [
                    ('me-group-content', tr.content, _contentEntries(context)),
                    ('me-group-social', tr.social, _socialEntries(context)),
                    ('me-group-stats', tr.stats, _statsEntries(context, uid: user.uid)),
                  ]) ...[
                    _EntryGrid(key: ValueKey(key), title: title, entries: entries),
                    SizedBox(height: gap),
                  ],
                ] else ...[
                  const _GuestCard(),
                  SizedBox(height: gap),
                ],
                _EntryGrid(
                  key: const ValueKey('me-group-services'),
                  title: tr.services,
                  entries: _serviceEntries(context, loggedIn: loggedIn),
                ),
                SizedBox(height: gap),
                _buildApp(context, loggedIn: loggedIn),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The account in use: avatar, name, user group and uid (a tap opens the profile), the check-in of the day and the
/// switch to another saved account.
class _AccountCard extends StatefulWidget {
  const _AccountCard({required this.user, required this.profileOf});

  final UserLoginInfo user;

  /// The profile of an account, shared with the page.
  final Future<UserProfile?> Function(int uid) profileOf;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  /// The name of the user group of each account seen, from its profile.
  final _groups = <int, Future<String?>>{};

  Future<String?> _groupOf(int uid) => _groups[uid] ??= () async {
    final profile = await widget.profileOf(uid);
    final group = profile?.userGroup;
    final name = group == null || group.isEmpty
        // Html, the group's name with the forum's color and icon; the name is enough here.
        ? null
        : parseHtmlDocument(group).body?.firstEndDeepText()?.trim();
    if (name == null || name.isEmpty) {
      // Asked again next time the card is built, not kept as missing.
      _groups.removeWhere((key, _) => key == uid);
      return null;
    }
    return name;
  }();

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final uid = user.uid;
    final username = user.username ?? '';
    final textTheme = Theme.of(context).textTheme;
    final tr = context.t.mePage;
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    // Not a panel: the account heads the page on the page itself, as the greeting of the homepage.
    return Material(
      key: const ValueKey('me-account-card'),
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            child: InkWell(
              key: const ValueKey('me-account-profile'),
              onTap: () async => context.pushNamed(ScreenPaths.loggedUserProfile),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: HeroUserAvatar(
                        key: ValueKey(username),
                        username: username,
                        avatarUrl: avatarUrlOfUid(uid?.toString()),
                        // A tab kept alive off screen: no hero flying in from it.
                        disableHero: true,
                        // The default circle is the color of the card itself.
                        backgroundColor: surfaces.card,
                      ),
                    ),
                    sizedBoxW12H12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SingleLineText(
                            username,
                            style: textTheme.headlineSmall?.copyWith(
                              fontSize: 24,
                              height: 1.3,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          sizedBoxW4H4,
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (uid != null)
                                FutureBuilder<String?>(
                                  future: _groupOf(uid),
                                  builder: (context, snapshot) => snapshot.data == null
                                      ? const SizedBox.shrink()
                                      : _Pill(icon: Symbols.verified_user_rounded, label: snapshot.data!),
                                ),
                              if (uid != null)
                                Text(
                                  tr.uid(uid: uid),
                                  style: textTheme.bodySmall?.copyWith(
                                    fontSize: 12.5,
                                    color: surfaces.muted,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Tooltip(
                      message: context.t.profilePage.title,
                      child: Icon(Symbols.chevron_right_rounded, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                if (context.readOrNull<CheckinBloc>() != null) ...[
                  Expanded(
                    child: CheckinButton(enableSnackBar: true, label: context.t.homepage.welcome.checkin),
                  ),
                  sizedBoxW8H8,
                ],
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('me-switch-account'),
                    style: appHeroActionStyle(context),
                    icon: const Icon(Symbols.switch_account_rounded),
                    label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr.switchAccount, maxLines: 1)),
                    onPressed: () async =>
                        showDialog<void>(context: context, builder: (_) => const AccountSwitchDialog()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded piece of information of the account card.
class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Neutral: the user group is information, not an action.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppSurfaces.of(context).control,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colorScheme.primary),
            sizedBoxW4H4,
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: colorScheme.onSurface, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Without an account: what a login gives, and the login.
class _GuestCard extends StatelessWidget {
  const _GuestCard();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.mePage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: const ValueKey('me-guest-card'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: appSurfaceShape(context),
      child: Padding(
        padding: edgeInsetsL16T16R16B16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppIconTile(Symbols.person_rounded, size: 64, color: colorScheme.surfaceContainerHighest),
                sizedBoxW12H12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr.guestTitle, style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                      sizedBoxW4H4,
                      Text(tr.guestDetail, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            sizedBoxW16H16,
            FilledButton.icon(
              key: const ValueKey('me-login'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Symbols.login_rounded),
              label: Text(context.t.loginPage.login),
              onPressed: () async => context.pushNamed(ScreenPaths.login),
            ),
          ],
        ),
      ),
    );
  }
}

/// The name of a group of "me", on the page above its panel: small, bold, quiet, no icon.
class _GroupCaption extends StatelessWidget {
  const _GroupCaption(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 13 * 0.06,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Number of tiles on a row of an entry grid [width] wide: as many as fit at [_entryTileMinWidth] times the text
/// scale [textScale], [_entryMinColumns] to [_entryMaxColumns].
int meEntryColumns(double width, double textScale) =>
    (width / (_entryTileMinWidth * textScale)).floor().clamp(_entryMinColumns, _entryMaxColumns);

/// A group of entries: its name on the page, then a panel with a grid of tiles, every tile the same width; five on a
/// row of a phone, fewer with a larger text ([meEntryColumns]).
class _EntryGrid extends StatelessWidget {
  const _EntryGrid({required this.title, required this.entries, super.key});

  final String title;
  final List<_MeEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupCaption(title),
        AppSurface(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = meEntryColumns(
                constraints.maxWidth,
                MediaQuery.textScalerOf(context).scale(14) / 14,
              );
              // A hair narrower: the rounding of the division must not push the last tile of a row to the next one.
              final width = constraints.maxWidth / columns - 0.01;
              return Wrap(
                children: [
                  for (final entry in entries) SizedBox(width: width, child: _EntryTile(entry)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A tile of [_EntryGrid]: icon over a label of up to two lines, on the panel itself.
class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry);

  final _MeEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // The full label on hover or a long press: a narrow tile may cut a long one.
    return Tooltip(
      message: entry.label,
      // The label of the tile already says it to screen readers.
      excludeFromSemantics: true,
      child: Material(
        key: entry.key,
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(appInnerRadius),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          child: InkWell(
            onTap: entry.onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(entry.icon, size: 24, color: colorScheme.primary),
                    const SizedBox(height: 6),
                    Text(
                      entry.label,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 12.5, height: 1.25),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
