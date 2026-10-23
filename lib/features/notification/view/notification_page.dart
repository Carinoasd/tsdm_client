import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
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
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/notification/utils/relative_time.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/notification_type.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/back_to_home_button.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:universal_html/parsing.dart';

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

  /// Text of the search box, empty when not searching.
  String _query = '';

  /// Whether the search box replaces the title.
  bool _searching = false;

  late final TextEditingController _searchController;

  /// Plain text of the notification html bodies already searched, by body.
  final _plainTexts = <String, String>{};

  String _plainTextOf(String html, {bool notice = false}) => _plainTexts.putIfAbsent(
    html,
    () => notice
        ? noticePlainTextOfHtml(html)
        : (parseHtmlDocument('<html><body>$html</body></html>').body?.text ?? html),
  );

  /// Whether one of [texts] contains the search text, ignoring case; the texts are only built while searching.
  bool _matches(Iterable<String?> Function() texts) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return true;
    }
    return texts().any((e) => e != null && e.toLowerCase().contains(q));
  }

  /// [list] newest first by [timeOf], the order among the same time kept: the day groups need it, and a broadcast
  /// message carries the time it was written, not when it came (#154).
  static List<T> _newestFirst<T>(Iterable<T> list, int Function(T) timeOf) {
    final sorted = list.toList();
    mergeSort<T>(sorted, compare: (a, b) => timeOf(b).compareTo(timeOf(a)));
    return sorted;
  }

  /// One tab of the page: a centered list of the cards built by [itemBuilder] for the notifications at [timestamps]
  /// (seconds, newest first), grouped under "today", "yesterday" and "earlier"; or the empty state saying [empty].
  /// Both keep the pull to refresh.
  Widget _buildTab(
    BuildContext context, {
    required EasyRefreshController controller,
    required List<int> timestamps,
    required IconData emptyIcon,
    required String empty,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    final tr = context.t;
    // The member's wall clock, like the stored times (see [NotificationTimeOffsets]).
    final uid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
    final now = memberNowOf(notificationCardClock(), NotificationTimeOffsets.of(uid));
    // Rows of the list: a group title (the day) or the index of a card.
    final rows = <Object>[];
    NotificationDay? day;
    for (final (index, timestamp) in timestamps.indexed) {
      final d = notificationDayOf(DateTime.fromMillisecondsSinceEpoch(timestamp * 1000), now);
      if (d != day) {
        rows.add(d);
        day = d;
      }
      rows.add(index);
    }
    return EasyRefresh.builder(
      controller: controller,
      header: const MaterialHeader(),
      onRefresh: () => context.read<NotificationBloc>().add(const NotificationUpdateAllRequested(bypassGate: true)),
      childBuilder: (context, physics) => timestamps.isEmpty
          ? AppScrollableStateView(
              physics: physics,
              child: AppStateView(icon: emptyIcon, message: empty, scrollable: false),
            )
          : AppCenteredList(
              builder: (context, side, _) => ListView.builder(
                physics: physics,
                padding: side.copyWith(top: 4, bottom: 12).add(context.safePadding()),
                itemCount: rows.length,
                itemBuilder: (context, i) => switch (rows[i]) {
                  final NotificationDay d => AppSectionHeader(
                    notificationDayLabel(tr, d),
                    key: ValueKey('notice-day-${d.name}'),
                    padding: EdgeInsets.only(top: i == 0 ? 4 : 12, bottom: 6, left: 4),
                  ),
                  final int index => Padding(
                    padding: i + 1 < rows.length && rows[i + 1] is int
                        ? const EdgeInsets.only(bottom: appSurfaceGapCompact)
                        : EdgeInsets.zero,
                    child: itemBuilder(context, index),
                  ),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
    );
  }

  /// The search box in the app bar, filtering the three tabs by the text of the synced notifications.
  Widget _buildSearchField(BuildContext context) => TextField(
    key: const ValueKey('notice-search-field'),
    controller: _searchController,
    autofocus: true,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(hintText: context.t.noticePage.search.hint, border: InputBorder.none),
    onChanged: (v) => setState(() => _query = v),
  );

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    if (!_searching) {
      _searchController.clear();
      _query = '';
    }
  });

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
    _searchController = TextEditingController();
    // The time offset of the account in use, stored by its last sync, for the relative times.
    final uid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
    if (uid != null && getIt.isRegistered<StorageProvider>()) {
      unawaited(
        NotificationTimeOffsets.load(getIt.get<StorageProvider>(), uid).then((_) {
          if (mounted) {
            setState(() {});
          }
        }),
      );
    }
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
    _searchController.dispose();
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
          // The search filters by what the cards show: the text of a notice and its author, the peer and the summary
          // of a conversation, the summary of a broadcast message.
          final shownNotices = _newestFirst(
            n.where((e) => _matches(() => [_plainTextOf(e.data, notice: true), e.author])),
            (e) => e.timestamp,
          );
          final shownPms = _newestFirst(
            pm.where((e) => _matches(() => [e.peerUsername, _plainTextOf(e.data)])),
            (e) => e.timestamp,
          );
          final shownBms = _newestFirst(bm.where((e) => _matches(() => [_plainTextOf(e.data)])), (e) => e.timestamp);
          final emptyTr = tr.empty;
          String emptyOf(String all, String unread) =>
              _query.trim().isNotEmpty ? emptyTr.search(keyword: _query.trim()) : (onlyShowUnread ? unread : all);

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
                  timestamps: shownNotices.map((e) => e.timestamp).toList(),
                  emptyIcon: Icons.notifications_none_outlined,
                  empty: emptyOf(emptyTr.notice, emptyTr.unreadNotice),
                  itemBuilder: (_, idx) =>
                      NoticeCardV2(key: ValueKey('NOTICE_${shownNotices[idx].id}'), shownNotices[idx]),
                ),
                _buildTab(
                  context,
                  controller: _personalMessageRefreshController,
                  timestamps: shownPms.map((e) => e.timestamp).toList(),
                  emptyIcon: Icons.forum_outlined,
                  empty: emptyOf(emptyTr.personalMessage, emptyTr.unreadPersonalMessage),
                  itemBuilder: (_, idx) =>
                      PersonalMessageCardV2(key: ValueKey('PM_${shownPms[idx].timestamp}'), shownPms[idx]),
                ),
                _buildTab(
                  context,
                  controller: _broadcastMessageRefreshController,
                  timestamps: shownBms.map((e) => e.timestamp).toList(),
                  emptyIcon: Icons.campaign_outlined,
                  empty: emptyOf(emptyTr.broadcastMessage, emptyTr.unreadBroadcastMessage),
                  itemBuilder: (_, idx) =>
                      BroadcastMessageCardV2(key: ValueKey('BM_${shownBms[idx].timestamp}'), shownBms[idx]),
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
              title: _searching ? _buildSearchField(context) : Text(tr.title),
              actions: [
                if (state.status == NotificationStatus.success && !foreign)
                  IconButton(
                    key: const ValueKey('notice-search'),
                    icon: Icon(_searching ? Icons.close : Icons.search_outlined),
                    tooltip: _searching ? tr.search.close : tr.search.tooltip,
                    onPressed: _toggleSearch,
                  ),
                if (state.status == NotificationStatus.success && !foreign && !_searching)
                  _buildUnreadFilterButton(context),
                if (state.status == NotificationStatus.success && !foreign && !_searching)
                  IconButton(
                    key: const ValueKey('notice-mark-all-read'),
                    icon: const Icon(Icons.done_all_outlined),
                    tooltip: tr.markAllRead,
                    onPressed: () async {
                      final done = Completer<bool>();
                      context.read<NotificationBloc>().add(NotificationMarkAllReadRequested(done: done));
                      // Said once the marks are written, not before; a write that failed says so.
                      final written = await done.future;
                      if (context.mounted) {
                        showSnackBar(context: context, message: written ? tr.markAllReadDone : tr.markAllReadFailed);
                      }
                    },
                  ),
                if (!_searching) const BackToHomeButton(),
                if (!_searching)
                  IconButton(
                    icon: const Icon(Icons.block_outlined),
                    tooltip: context.t.userBlock.manageEntry,
                    onPressed: () async => context.pushNamed(ScreenPaths.userBlock),
                  ),
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
