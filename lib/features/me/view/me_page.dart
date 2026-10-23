import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/multi_user/widgets/account_switch_dialog.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/notification/utils/notice_page_tab.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';
import 'package:universal_html/parsing.dart';

/// Content width from which the entries of the account fit on one row.
const _wideEntriesWidth = 600.0;

/// An entry of the "me" tab: icon, label and what a tap does.
typedef _MeEntry = ({Key key, IconData icon, String label, VoidCallback onTap});

/// The "me" tab of the home shell: the account in use and every page of it, in one place.
///
/// Up top the account card: avatar, name, user group (a tap opens the profile), the check-in of the day and the
/// switch to another saved account. Under it the pages of the account (threads, favorites, history, drafts, private
/// messages, friends, points, medals and titles), then the services of the forum (activities, medal center, title
/// shop, bank, pokemon center, achievements) and the app itself (accounts, settings, about).
///
/// The settings were a tab of their own before; the whole settings page is one tap away here, nothing in it moved. The
/// pages the side navigation of wide windows listed besides its tabs are entries here as well.
///
/// Without an account: the login, the settings and about.
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
  }

  @override
  void dispose() {
    unawaited(_scrollToTopSub.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  /// The account in use, the stored one before the homepage verified it; null without one.
  UserLoginInfo? _account(BuildContext context) {
    final account = watchCurrentAccount(context);
    if (account != null) {
      return account.user;
    }
    return context.readOrNull<AuthenticationRepository>()?.currentUser;
  }

  /// Open [path] above the shell.
  void _open(String path, {Map<String, String> query = const {}}) =>
      unawaited(context.pushNamed(path, queryParameters: query));

  /// The pages of the account in use.
  List<_MeEntry> _accountEntries(BuildContext context) {
    final tr = context.t.mePage.entries;
    return [
      (
        key: const ValueKey('me-my-threads'),
        icon: Icons.article_outlined,
        label: tr.myThreads,
        onTap: () => _open(ScreenPaths.myThread),
      ),
      (
        key: const ValueKey('me-favorites'),
        icon: Icons.star_outline,
        label: tr.favorites,
        onTap: () => _open(ScreenPaths.favorite),
      ),
      (
        key: const ValueKey('me-history'),
        icon: Icons.history_outlined,
        label: tr.history,
        onTap: () => _open(ScreenPaths.threadVisitHistory),
      ),
      // The drafts box of the forum, the third tab of "my threads".
      (
        key: const ValueKey('me-drafts'),
        icon: Icons.drafts_outlined,
        label: tr.drafts,
        onTap: () => _open(ScreenPaths.myThread, query: {'tab': 'drafts'}),
      ),
      // The private messages are a tab of the notifications.
      (
        key: const ValueKey('me-messages'),
        icon: Icons.mail_outline,
        label: tr.messages,
        onTap: () {
          noticePageTabRequest.value = NoticePageTab.personalMessage;
          showHomeTab(context, HomeTab.notice);
        },
      ),
      (
        key: const ValueKey('me-friends'),
        icon: Icons.people_outline,
        label: tr.friends,
        onTap: () => _open(ScreenPaths.friend),
      ),
      (
        key: const ValueKey('me-points'),
        icon: Icons.show_chart_outlined,
        label: tr.points,
        onTap: () => _open(ScreenPaths.points),
      ),
      (
        key: const ValueKey('me-medals'),
        icon: Icons.workspace_premium_outlined,
        label: context.t.medalTitleHub.title,
        onTap: () => _open(ScreenPaths.medalTitleHub),
      ),
    ];
  }

  /// A row of the lists under the entries.
  Widget _row(BuildContext context, {required Key key, required IconData icon, required String title, String? path}) =>
      SectionListTile(
        key: key,
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: path == null ? null : () => _open(path),
      );

  /// The services of the forum: the pages the side navigation listed besides its tabs, and the others of the account.
  Widget _buildServices(BuildContext context) => AppTileGroup(
    title: context.t.mePage.services,
    icon: Icons.apps_outlined,
    children: [
      _row(
        context,
        key: const ValueKey('me-activities'),
        icon: Icons.event_outlined,
        title: context.t.navigation.activities,
        path: ScreenPaths.activities,
      ),
      _row(
        context,
        key: const ValueKey('me-medal-center'),
        icon: Icons.military_tech_outlined,
        title: context.t.medalCenter.title,
        path: ScreenPaths.medalCenter,
      ),
      _row(
        context,
        key: const ValueKey('me-title-shop'),
        icon: Icons.sell_outlined,
        title: context.t.titleShop.title,
        path: ScreenPaths.titleShop,
      ),
      _row(
        context,
        key: const ValueKey('me-bank'),
        icon: Icons.account_balance_outlined,
        title: context.t.bank.title,
        path: ScreenPaths.bank,
      ),
      _row(
        context,
        key: const ValueKey('me-pokemon'),
        icon: Icons.catching_pokemon,
        title: context.t.pokemon.title,
        path: ScreenPaths.pokemon,
      ),
      _row(
        context,
        key: const ValueKey('me-achievements'),
        icon: Icons.emoji_events_outlined,
        title: context.t.achievementsPage.title,
        path: ScreenPaths.achievements,
      ),
    ],
  );

  /// The app: the accounts saved on this device (with an account), the settings and about.
  Widget _buildApp(BuildContext context, {required bool loggedIn}) => AppTileGroup(
    title: context.t.mePage.app,
    icon: Icons.tune_outlined,
    children: [
      if (loggedIn)
        _row(
          context,
          key: const ValueKey('me-manage-accounts'),
          icon: Icons.manage_accounts_outlined,
          title: context.t.manageAccountPage.title,
          path: ScreenPaths.manageAccount,
        ),
      _row(
        context,
        key: const ValueKey('me-settings'),
        icon: Icons.settings_outlined,
        title: context.t.navigation.settings,
        path: ScreenPaths.settings.path,
      ),
      _row(
        context,
        key: const ValueKey('me-about'),
        icon: Icons.info_outline,
        title: context.t.settingsPage.othersSection.about,
        path: ScreenPaths.about,
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
            final padding = appCenteredPadding(constraints.maxWidth, maxWidth: appFormMaxWidth);
            final gap = constraints.maxWidth < _wideEntriesWidth ? appSurfaceGapCompact + 4 : appSurfaceGap + 4;
            return ListView(
              key: const ValueKey('me-page-list'),
              controller: _scrollController,
              padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
              children: [
                if (account case final UserLoginInfo user) ...[
                  _AccountCard(user: user),
                  SizedBox(height: gap),
                  _EntryGrid(
                    title: context.t.mePage.mine,
                    entries: _accountEntries(context),
                    wide: constraints.maxWidth >= _wideEntriesWidth,
                  ),
                  SizedBox(height: gap),
                  _buildServices(context),
                ] else
                  const _GuestCard(),
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
  const _AccountCard({required this.user});

  final UserLoginInfo user;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  /// The name of the user group of each account seen, from its profile: the homepage loaded it, so it is usually
  /// cached; otherwise it is asked once.
  final _groups = <int, Future<String?>>{};

  Future<String?> _groupOf(int uid) => _groups[uid] ??= () async {
    final repository = context.readOrNull<ProfileRepository>();
    if (repository == null) {
      return null;
    }
    final page = (await repository.fetchProfile().run()).toNullable();
    final profile = page == null ? null : (await buildProfilePage(page).run()).toNullable();
    final group = profile?.userGroup;
    if (group == null || group.isEmpty) {
      return null;
    }
    // Html, the group's name with the forum's color and icon; the name is enough here.
    final name = parseHtmlDocument(group).body?.firstEndDeepText()?.trim();
    return name == null || name.isEmpty ? null : name;
  }();

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final uid = user.uid;
    final username = user.username ?? '';
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final tr = context.t.mePage;
    return Card(
      key: const ValueKey('me-account-card'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: appSurfaceShape(context),
      color: colorScheme.surfaceContainerLow,
      child: DecoratedBox(
        // The look of the greeting card of the homepage.
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topRight,
            radius: 1.4,
            colors: [colorScheme.primaryContainer.withValues(alpha: 0.55), colorScheme.surfaceContainerLow],
            stops: const [0, 0.6],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const ValueKey('me-account-profile'),
              onTap: () async => context.pushNamed(ScreenPaths.loggedUserProfile),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
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
                      ),
                    ),
                    sizedBoxW12H12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SingleLineText(username, style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
                                      : _Pill(icon: Icons.verified_user_outlined, label: snapshot.data!),
                                ),
                              if (uid != null)
                                Text(
                                  tr.uid(uid: uid),
                                  style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Tooltip(
                      message: context.t.profilePage.title,
                      child: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  if (context.readOrNull<CheckinBloc>() != null) ...[
                    Expanded(
                      child: CheckinButton(enableSnackBar: true, label: context.t.homepage.welcome.checkin),
                    ),
                    sizedBoxW8H8,
                  ],
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('me-switch-account'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                      icon: const Icon(Icons.switch_account_outlined),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(appInnerRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colorScheme.onSecondaryContainer),
            sizedBoxW4H4,
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600),
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
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: edgeInsetsL16T16R16B16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppIconTile(Icons.person_outline, size: 64, color: colorScheme.surfaceContainerHighest),
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
              icon: const Icon(Icons.login_outlined),
              label: Text(context.t.loginPage.login),
              onPressed: () async => context.pushNamed(ScreenPaths.login),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pages of the account as a grid of tiles: four on a row on phones, all of them on one row in wider windows.
class _EntryGrid extends StatelessWidget {
  const _EntryGrid({required this.title, required this.entries, required this.wide});

  final String title;
  final List<_MeEntry> entries;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final columns = wide ? entries.length : 4;
    return AppSurface(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(title, icon: Icons.person_outline, padding: const EdgeInsets.fromLTRB(4, 8, 4, 8)),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final entry in entries) SizedBox(width: width, child: _EntryTile(entry)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A tile of [_EntryGrid]: icon over a label of up to two lines.
class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry);

  final _MeEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: entry.key,
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(appInnerRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(entry.icon, color: colorScheme.primary),
                sizedBoxW4H4,
                Text(
                  entry.label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
