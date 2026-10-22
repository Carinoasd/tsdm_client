import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/member_thread/cubit/member_thread_cubit.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The threads and the replies of another member ("TA的主题"), in the two tabs the forum's page has.
///
/// The member is located by [uid] and/or [username] as the link named them ([memberThreadUrl]); the account's own
/// lists open the "my threads" page instead (the route's redirect, [memberThreadRedirect]). The rows look as on the
/// "my threads" page. A member blocked on this device has their lists hidden, as their threads are everywhere else.
class MemberThreadPage extends StatefulWidget {
  /// Constructor.
  const MemberThreadPage({this.uid, this.username, this.initialTab = MemberThreadTab.thread, this.cubit, super.key});

  /// Uid of the member.
  final String? uid;

  /// Name of the member.
  final String? username;

  /// The tab shown first: the replies for a link to them (`type=reply`).
  final MemberThreadTab initialTab;

  /// Test seam: a cubit owned by the caller.
  final MemberThreadCubit? cubit;

  @override
  State<MemberThreadPage> createState() => _MemberThreadPageState();
}

class _MemberThreadPageState extends State<MemberThreadPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final MemberThreadCubit _cubit;
  final Map<MemberThreadTab, EasyRefreshController> _refreshControllers = {
    for (final tab in MemberThreadTab.values)
      tab: EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true),
  };
  StreamSubscription<AuthStatus>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: MemberThreadTab.values.length,
      initialIndex: widget.initialTab.index,
      vsync: this,
    );
    _cubit =
        widget.cubit ?? MemberThreadCubit(repository: MyThreadRepository(), uid: widget.uid, username: widget.username);
    // What the forum shows of the member depends on who asks: another account coming into use reloads both lists,
    // and so does a login of the account in use again while a list was refused (the forum may have dropped its
    // session, issue #25, and answered as to a guest). The status replayed to a new listener ended before: no login.
    final auth = context.readOrNull<AuthenticationRepository>();
    if (auth != null) {
      final replayed = auth.latestStatus;
      _authSubscription = auth.status.listen((status) {
        if (identical(status, replayed) || status is AuthStatusLoading) {
          return;
        }
        final lists = MemberThreadTab.values.map(_cubit.state.of);
        if (lists.every((e) => e.status == MemberThreadStatus.initial)) {
          return;
        }
        final changed = _cubit.askedUid != auth.effectiveCurrentUid;
        final refused = lists.any(
          (e) => e.status == MemberThreadStatus.needLogin || e.status == MemberThreadStatus.failed,
        );
        if (changed || (status is AuthStatusAuthed && refused)) {
          unawaited(_cubit.reloadAll());
        }
      });
    }
    for (final tab in MemberThreadTab.values) {
      unawaited(_cubit.load(tab));
    }
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.cubit == null) {
      unawaited(_cubit.close());
    }
    _tabController.dispose();
    for (final controller in _refreshControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _buildTab(BuildContext context, MemberThreadState state, MemberThreadTab tab) {
    final list = state.of(tab);
    final controller = _refreshControllers[tab]!;
    switch (list.status) {
      case MemberThreadStatus.initial || MemberThreadStatus.loading:
        return const CenteredCircularIndicator();
      case MemberThreadStatus.needLogin:
        return NeedLoginPage(
          backUri: GoRouterState.of(context).uri,
          needPop: true,
          popCallback: (_) async => _cubit.reloadAll(),
        );
      case MemberThreadStatus.notice:
        // The forum's own explanation (no such member, the forum closed), or another page than the list.
        final message = list.message;
        return AppStateView(
          icon: Icons.info_outline,
          message: message == null || message.isEmpty ? context.t.memberThreadPage.notList : message,
        );
      case MemberThreadStatus.failed:
        return buildRetryButton(context, () => _cubit.load(tab));
      case MemberThreadStatus.success:
        break;
    }
    if (!list.refreshing) {
      controller.finishRefresh();
    }
    if (!list.loadingMore) {
      controller.finishLoad(list.nextPageUrl == null ? IndicatorResult.noMore : IndicatorResult.success);
    }
    final Widget child;
    if (list.items.isEmpty) {
      child = AppStateView(icon: Icons.article_outlined, message: context.t.general.noData);
    } else {
      child = AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          padding: side.copyWith(top: 8).add(context.safePadding()),
          itemCount: list.items.length,
          itemBuilder: (context, index) => MyThreadCard(list.items[index]),
          separatorBuilder: (context, index) => appListSeparator,
        ),
      );
    }
    return EasyRefresh(
      controller: controller,
      header: const MaterialHeader(),
      footer: const MaterialFooter(),
      onRefresh: () async => _cubit.load(tab),
      onLoad: () async {
        if (list.nextPageUrl == null) {
          controller.finishLoad(IndicatorResult.noMore);
          return;
        }
        await _cubit.loadMore(tab);
      },
      child: child,
    );
  }

  /// The lists, or what replaces them for a member blocked on this device: by uid, or by name while the uid is not
  /// known (a link by name answered by the web page, which names no uid on a single page), held back until the block
  /// list is known.
  Widget _buildBody(BuildContext context, MemberThreadState state) {
    final blockList = currentBlockList(context);
    final name = state.ownerName ?? widget.username;
    final hidden = switch (state.ownerUid) {
      final int uid => blockList.hides(uid),
      null when name != null && name.isNotEmpty =>
        !blockList.isKnown || blockList.users.any((e) => forumUsernameKey(e.username) == forumUsernameKey(name)),
      null => false,
    };
    if (hidden) {
      final tr = context.t.userBlock;
      if (!blockList.isKnown) {
        return AppStateView(
          icon: Icons.hourglass_empty_outlined,
          message: blockList.status == UserBlockListStatus.failed ? tr.loadFailedHint : tr.listPending,
        );
      }
      return AppStateView(icon: Icons.block_outlined, message: context.t.memberThreadPage.blocked);
    }
    return TabBarView(
      controller: _tabController,
      children: [for (final tab in MemberThreadTab.values) _buildTab(context, state, tab)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.memberThreadPage;
    return BlocProvider.value(
      value: _cubit,
      child: MultiBlocListener(
        listeners: [
          for (final tab in MemberThreadTab.values)
            BlocListener<MemberThreadCubit, MemberThreadState>(
              listenWhen: (prev, curr) => curr.of(tab).failureCount > prev.of(tab).failureCount,
              listener: (context, state) => showFailedToLoadSnackBar(context),
            ),
        ],
        child: BlocBuilder<MemberThreadCubit, MemberThreadState>(
          builder: (context, state) {
            final name = state.ownerName ?? widget.username;
            // A link naming the account in use in a way the route could not tell (`uid=00`, a name spelt otherwise):
            // the forum answered the own list.
            final own = state.ownerUid != null && state.ownerUid == state.viewerUid;
            return Scaffold(
              appBar: AppBar(
                title: Text(
                  own
                      ? context.t.myThreadPage.title
                      : (name == null || name.isEmpty ? tr.titleUnknown : tr.title(name: name)),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.person_outline),
                    tooltip: context.t.profilePage.title,
                    onPressed: () async => context.pushNamed(
                      ScreenPaths.profile,
                      queryParameters: {
                        'uid': ?(state.ownerUid?.toString() ?? widget.uid),
                        if (state.ownerUid == null && widget.uid == null) 'username': ?name,
                      },
                    ),
                  ),
                ],
                bottom: TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(child: Text(context.t.myThreadPage.threadTab.title)),
                    Tab(child: Text(context.t.myThreadPage.replyTab.title)),
                  ],
                ),
              ),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            );
          },
        ),
      ),
    );
  }
}
