import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/friend/bloc/friend_bloc.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/widgets/friend_card.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';

/// Page listing the friends of a user.
///
/// The user is located by [uid] (preferred) or [username]; when both are null the current user's list is shown.
class FriendPage extends StatefulWidget {
  /// Constructor.
  const FriendPage({this.uid, this.username, super.key});

  /// Uid of the user whose friends are listed.
  final String? uid;

  /// Username of the user whose friends are listed.
  final String? username;

  @override
  State<FriendPage> createState() => _FriendPageState();
}

class _FriendPageState extends State<FriendPage> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _refreshController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildList(BuildContext context, FriendState state) {
    final tr = context.t.friendPage;
    // The list of the account in use: no member named, or the account's own uid.
    final selfUid = context.read<AuthenticationRepository>().currentUser?.uid;
    final own = (widget.uid == null && widget.username == null) || (selfUid != null && widget.uid == '$selfUid');
    if (!state.refreshing) {
      _refreshController.finishRefresh();
    }
    final bloc = context.read<FriendBloc>();
    return EasyRefresh.builder(
      controller: _refreshController,
      scrollController: _scrollController,
      header: const MaterialHeader(),
      onRefresh: () => bloc.add(const FriendRefreshRequested()),
      childBuilder: (context, physics) => AppCenteredList(
        builder: (context, side, width) {
          final padding = side.copyWith(top: 12, bottom: 12).add(context.safePadding());
          if (state.items.isEmpty) {
            // The own list says how friends get in it; another member's is just empty.
            return ListView(
              physics: physics,
              controller: _scrollController,
              padding: padding,
              children: [
                sizedBoxW32H32,
                AppStateView(
                  icon: Icons.people_outline,
                  message: own ? tr.empty : tr.emptyOther,
                  detail: own ? tr.emptyHint : null,
                  scrollable: false,
                ),
              ],
            );
          }
          // Two columns on wide windows; each row holds up to two friend cards.
          final columns = appColumnsFor(width);
          final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
          final rows = appRowCount(state.items.length, columns);
          return ListView.separated(
            physics: physics,
            controller: _scrollController,
            padding: padding,
            // The end of the list is its last row: built when it comes near, it asks the next page.
            itemCount: rows + 1,
            itemBuilder: (context, row) => row == rows
                ? ListFooter(
                    status: listFooterStatus(
                      hasMore: state.nextPageUrl != null,
                      loading: state.loadingMore || state.refreshing,
                      failed: state.loadMoreFailed,
                    ),
                    itemCount: state.items.length,
                    failure: state.failure,
                    onLoadMore: () => bloc.add(const FriendLoadMoreRequested()),
                    onRetry: () => bloc.add(const FriendLoadMoreRequested()),
                  )
                : AppColumnsRow(
                    row: row,
                    columns: columns,
                    count: state.items.length,
                    gap: gap,
                    itemBuilder: (context, index) => FriendCard(state.items[index]),
                  ),
            separatorBuilder: (context, index) => SizedBox(height: gap),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, FriendState state) => switch (state.status) {
    // The shape of the friends to come instead of a spinner over the whole page.
    FriendStatus.initial || FriendStatus.loading => const ThreadListSkeleton(),
    FriendStatus.needLogin => NeedLoginPage(
      backUri: GoRouterState.of(context).uri,
      needPop: true,
      popCallback: (context) => context.read<FriendBloc>().add(const FriendLoadRequested()),
    ),
    // The forum's own explanation (privacy settings, no such member), as it wrote it.
    FriendStatus.notice => FailureView(
      failure: LoadFailure.fromMessage(state.message ?? ''),
      onRetry: () => context.read<FriendBloc>().add(const FriendLoadRequested()),
    ),
    FriendStatus.failure => FailureView(
      failure: state.failure,
      onRetry: () => context.read<FriendBloc>().add(const FriendLoadRequested()),
    ),
    FriendStatus.success => _buildList(context, state),
  };

  Widget _buildTitle(BuildContext context, FriendState state) {
    final tr = context.t.friendPage;
    final name = state.ownerName ?? widget.username;
    final count = state.totalCount;
    final String? subtitle;
    if (name == null) {
      subtitle = count == null ? null : tr.subtitleCountOnly(count: count);
    } else {
      subtitle = count == null ? name : tr.subtitle(name: name, count: count);
    }
    if (subtitle == null) {
      return Text(tr.title);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(tr.title),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.friendPage;
    // No target given: show the current user's list.
    final selfUid = context.read<AuthenticationRepository>().currentUser?.uid;
    final uid = widget.uid ?? (widget.username == null ? selfUid?.toString() : null);
    if (uid == null && widget.username == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.title)),
        body: NeedLoginPage(backUri: GoRouterState.of(context).uri, needPop: true),
      );
    }
    return MultiRepositoryProvider(
      providers: [RepositoryProvider(create: (_) => const FriendRepository())],
      child: BlocProvider(
        create: (context) => FriendBloc(
          friendRepository: context.repo(),
          firstPageUrl: FriendRepository.listUrl(uid: uid, username: widget.username),
        )..add(const FriendLoadRequested()),
        child: BlocListener<FriendBloc, FriendState>(
          // A refresh that failed keeps the friends on screen and says so.
          listenWhen: (prev, curr) =>
              prev.refreshing && !curr.refreshing && curr.status == FriendStatus.success && curr.failure != null,
          listener: (context, state) {
            final bloc = context.read<FriendBloc>();
            showRefreshFailedSnackBar(
              context,
              state.failure,
              onRetry: () {
                if (!bloc.isClosed) {
                  bloc.add(const FriendRefreshRequested());
                }
              },
            );
          },
          child: BlocBuilder<FriendBloc, FriendState>(
            builder: (context, state) => Scaffold(
              appBar: AppBar(title: _buildTitle(context, state)),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            ),
          ),
        ),
      ),
    );
  }
}
