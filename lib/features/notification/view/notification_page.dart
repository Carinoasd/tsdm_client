import 'dart:async';
import 'dart:math' as math;

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/notice_block_filter.dart';
import 'package:tsdm_client/features/local_notice/notification_permission_prompt.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/notification_type.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/back_to_home_button.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/indicator.dart';

enum _Actions { markAllNoticeAsRead, markAllPersonalMessageAsRead, markAllBroadcastMessageAsRead, syncAllAccounts }

/// Notice page, shows Notice and PrivateMessage of current user.
class NotificationPage extends StatefulWidget {
  /// Constructor.
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> with SingleTickerProviderStateMixin, LoggerMixin {
  late final EasyRefreshController _noticeRefreshController;
  late final EasyRefreshController _personalMessageRefreshController;
  late final EasyRefreshController _broadcastMessageRefreshController;
  late final TabController _tabController;

  /// Flag indicating only show unread messages or not
  bool onlyShowUnread = false;

  /// One tab of the page: a centered list of [count] cards built by [itemBuilder], or the empty state; both keep the
  /// pull to refresh.
  Widget _buildTab(
    BuildContext context, {
    required EasyRefreshController controller,
    required int count,
    required IconData emptyIcon,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    return EasyRefresh.builder(
      controller: controller,
      header: const MaterialHeader(),
      onRefresh: () => context.read<NotificationBloc>().add(const NotificationUpdateAllRequested(bypassGate: true)),
      childBuilder: (context, physics) => count == 0
          ? AppScrollableStateView(
              physics: physics,
              child: AppStateView(icon: emptyIcon, message: context.t.general.noData, scrollable: false),
            )
          : AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                physics: physics,
                padding: side.copyWith(top: 4, bottom: 12).add(context.safePadding()),
                itemCount: count,
                itemBuilder: itemBuilder,
                separatorBuilder: (_, _) => appListSeparator,
              ),
            ),
    );
  }

  /// "Unread only" toggle in the app bar, applied to all three tabs.
  ///
  /// It used to take a row of its own above the tabs, mostly empty (feedback 110). Selected, it gets a tonal
  /// background and the filled icon; the tooltip and the semantics name it and tell its state.
  Widget _buildUnreadFilterButton(BuildContext context) {
    final tr = context.t.noticePage;
    final colorScheme = Theme.of(context).colorScheme;
    // Merged so the toggled state belongs to the button's own node (its tooltip is the label).
    return MergeSemantics(
      child: Semantics(
        toggled: onlyShowUnread,
        child: IconButton(
          key: const ValueKey('notice-unread-filter'),
          isSelected: onlyShowUnread,
          icon: const Icon(Icons.mark_email_unread_outlined),
          selectedIcon: const Icon(Icons.mark_email_unread),
          tooltip: '${tr.appBar.unread} · ${tr.appBar.unreadDetail}',
          style: onlyShowUnread
              ? IconButton.styleFrom(
                  backgroundColor: colorScheme.secondaryContainer,
                  foregroundColor: colorScheme.onSecondaryContainer,
                )
              : null,
          onPressed: () => setState(() => onlyShowUnread = !onlyShowUnread),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _noticeRefreshController = EasyRefreshController(controlFinishLoad: true, controlFinishRefresh: true);
    _personalMessageRefreshController = EasyRefreshController(controlFinishLoad: true, controlFinishRefresh: true);
    _broadcastMessageRefreshController = EasyRefreshController(controlFinishLoad: true, controlFinishRefresh: true);
    _tabController = TabController(vsync: this, length: 3);
    // The first visit of the notice page: the card explaining the notification permission, once.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await askNotificationPermission(
        context,
        trigger: NotificationPermissionTrigger.noticePage,
        loggedIn: context.readOrNull<AuthenticationRepository>()?.currentUser != null,
      );
    });
  }

  @override
  void dispose() {
    _noticeRefreshController.dispose();
    _personalMessageRefreshController.dispose();
    _broadcastMessageRefreshController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage;
    return BlocListener<NotificationBloc, NotificationState>(
      listener: (context, state) {
        final inUse = watchCurrentAccount(context, listen: false)?.user?.uid;
        if (state.status == NotificationStatus.success &&
            (state.ownerUid == null || inUse == null || state.ownerUid == inUse)) {
          final blocked = currentBlockList(context, listen: false);
          final n = state.noticeList.where((e) => !e.alreadyRead && !isBlockedNoticeAuthor(e.authorId, blocked)).length;
          // Conversations with locally blocked users stay listed below but are muted: they do not count in the badge.
          final pm = state.personalMessageList
              .where((e) => !e.alreadyRead && !isMutedPersonalMessagePeer(e.peerUid, blocked))
              .length;
          final bm = state.broadcastMessageList.where((e) => !e.alreadyRead).length;
          context.read<NotificationStateCubit>().setAll(
            noticeCount: n,
            personalMessageCount: pm,
            broadcastMessageCount: bm,
          );
        }
      },
      child: BlocBuilder<NotificationBloc, NotificationState>(
        builder: (context, state) {
          // Lists of another account than the one in use (switched, the new account's lists not in yet) are never
          // shown: the page waits for them.
          final inUse = watchCurrentAccount(context)?.user?.uid;
          final foreign = state.ownerUid != null && inUse != null && state.ownerUid != inUse;
          // Notices of locally blocked users stay stored (and keep their read state) but are not listed.
          final blocked = currentBlockList(context);
          final noticeList = state.noticeList.where((e) => !isBlockedNoticeAuthor(e.authorId, blocked));
          final (n, pm, bm) = switch (onlyShowUnread) {
            true => (
              noticeList.where((e) => !e.alreadyRead),
              state.personalMessageList.where((e) => !e.alreadyRead),
              state.broadcastMessageList.where((e) => !e.alreadyRead),
            ),
            false => (noticeList, state.personalMessageList, state.broadcastMessageList),
          };

          // Unread counters on the tabs: same rules as the badge above (muted conversations are not counted), and
          // only for the kinds whose unread badge is enabled in settings.
          // Settings are only read once there is something to count, like the cards do.
          final settings = state.status == NotificationStatus.success
              ? getIt.get<SettingsRepository>().currentSettings
              : null;
          final unreadCounts = settings != null
              ? (
                  settings.showUnreadNoticeBadge ? noticeList.where((e) => !e.alreadyRead).length : 0,
                  settings.showUnreadPersonalMessageBadge
                      ? state.personalMessageList
                            .where((e) => !e.alreadyRead && !isMutedPersonalMessagePeer(e.peerUid, blocked))
                            .length
                      : 0,
                  settings.showUnreadBroadcastMessageBadge
                      ? state.broadcastMessageList.where((e) => !e.alreadyRead).length
                      : 0,
                )
              : (0, 0, 0);

          final body = switch (state.status) {
            _ when foreign => const CenteredCircularIndicator(),
            NotificationStatus.initial || NotificationStatus.loading => const CenteredCircularIndicator(),
            NotificationStatus.success => TabBarView(
              controller: _tabController,
              children: [
                _buildTab(
                  context,
                  controller: _noticeRefreshController,
                  count: n.length,
                  emptyIcon: Icons.notifications_none_outlined,
                  itemBuilder: (_, idx) =>
                      NoticeCardV2(key: ValueKey('NOTICE_${n.elementAt(idx).id}'), n.elementAt(idx)),
                ),
                _buildTab(
                  context,
                  controller: _personalMessageRefreshController,
                  count: pm.length,
                  emptyIcon: Icons.forum_outlined,
                  itemBuilder: (_, idx) => PersonalMessageCardV2(
                    key: ValueKey('PM_${pm.elementAt(idx).timestamp}'),
                    pm.elementAt(idx),
                  ),
                ),
                _buildTab(
                  context,
                  controller: _broadcastMessageRefreshController,
                  count: bm.length,
                  emptyIcon: Icons.campaign_outlined,
                  itemBuilder: (_, idx) => BroadcastMessageCardV2(
                    key: ValueKey('BM_${bm.elementAt(idx).timestamp}'),
                    bm.elementAt(idx),
                  ),
                ),
              ],
            ),
            NotificationStatus.failure => buildRetryButton(
              context,
              () => context.read<NotificationBloc>().add(const NotificationUpdateAllRequested(bypassGate: true)),
            ),
          };
          return Scaffold(
            appBar: AppBar(
              title: Text(tr.title),
              actions: [
                if (state.status == NotificationStatus.success) _buildUnreadFilterButton(context),
                const BackToHomeButton(),
                IconButton(
                  icon: const Icon(Icons.block_outlined),
                  tooltip: context.t.userBlock.manageEntry,
                  onPressed: () async => context.pushNamed(ScreenPaths.userBlock),
                ),
                // TODO: Notification search.
                // IconButton(
                //   icon: const Icon(Icons.saved_search_outlined),
                //   onPressed: () => context.pushNamed(ScreenPaths.noticeSearch),
                // ),
                PopupMenuButton<_Actions>(
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _Actions.markAllNoticeAsRead,
                      child: Row(
                        children: [
                          const Icon(Icons.notifications_paused_outlined),
                          sizedBoxPopupMenuItemIconSpacing,
                          Text(tr.cardMenu.markAllNoticeAsRead),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: _Actions.markAllPersonalMessageAsRead,
                      child: Row(
                        children: [
                          const Icon(Icons.notifications_active_outlined),
                          sizedBoxPopupMenuItemIconSpacing,
                          Text(tr.cardMenu.markAllPersonalMessageAsRead),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: _Actions.markAllBroadcastMessageAsRead,
                      child: Row(
                        children: [
                          const Icon(Icons.notification_important_outlined),
                          sizedBoxPopupMenuItemIconSpacing,
                          Text(tr.cardMenu.markAllBroadcastMessageAsRead),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _Actions.syncAllAccounts,
                      child: Row(
                        children: [
                          const Icon(Icons.sync_outlined),
                          sizedBoxPopupMenuItemIconSpacing,
                          Text(tr.syncAllPage.title),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) async {
                    if (value == _Actions.syncAllAccounts) {
                      // Starting while a run is in progress is a no-op, the page then shows that run.
                      unawaited(context.read<NotificationSyncAllCubit>().start());
                      await context.pushNamed(ScreenPaths.notificationSyncAll);
                      return;
                    }
                    final noticeType = switch (value) {
                      _Actions.markAllNoticeAsRead => NotificationType.notice,
                      _Actions.markAllPersonalMessageAsRead => NotificationType.personalMessage,
                      _Actions.markAllBroadcastMessageAsRead => NotificationType.broadcastMessage,
                      _Actions.syncAllAccounts => throw StateError('unreachable'),
                    };

                    context.read<NotificationBloc>().add(
                      NotificationMarkTypeReadRequested(markType: noticeType, markAsRead: true),
                    );
                  },
                ),
              ],
              bottom: _PreferredSizeComponentBottom(_tabController, unreadCounts),
            ),
            body: SafeArea(bottom: false, child: body),
          );
        },
      ),
    );
  }
}

/// Composition of [TabBar] and [LinearProgressIndicator].
class _PreferredSizeComponentBottom extends StatelessWidget implements PreferredSizeWidget {
  const _PreferredSizeComponentBottom(this.tabController, this.unreadCounts);

  final TabController tabController;

  /// Unread notices, personal messages and broadcast messages shown next to the tab titles, 0 to hide.
  final (int, int, int) unreadCounts;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage;
    final (n, pm, bm) = unreadCounts;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BlocBuilder<AutoNotificationCubit, AutoNoticeState>(
          builder: (context, state) {
            return switch (state) {
              AutoNoticeStateStopped() => sizedBoxW2H2,
              AutoNoticeStateTicking(:final total, :final remain) => LinearProgressIndicator(
                value: math.max(1 - remain.inSeconds / total.inSeconds, 0),
                minHeight: 2,
              ),
              AutoNoticeStatePending() => const LinearProgressIndicator(minHeight: 2),
              AutoNoticeStatePaused(:final total, :final remain) => LinearProgressIndicator(
                value: math.max(1 - remain.inSeconds / total.inSeconds, 0),
                minHeight: 2,
                color: Theme.of(context).colorScheme.outline,
              ),
            };
          },
        ),
        TabBar(
          controller: tabController,
          tabs: [
            Tab(child: _TabLabel(tr.noticeTab.title, n)),
            Tab(child: _TabLabel(tr.privateMessageTab.title, pm)),
            Tab(child: _TabLabel(tr.broadcastMessageTab.title, bm)),
          ],
        ),
      ],
    );
  }

  /// Composed of [TabBar] height and [LinearProgressIndicator] height.
  @override
  Size get preferredSize => const Size.fromHeight(46 + 2);
}

/// Title of a tab with the number of unread items, if any.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.title, this.unread);

  final String title;

  final int unread;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (unread > 0) ...[
          sizedBoxW4H4,
          DecoratedBox(
            decoration: BoxDecoration(color: colorScheme.primary, borderRadius: BorderRadius.circular(appInnerRadius)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.onPrimary),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
