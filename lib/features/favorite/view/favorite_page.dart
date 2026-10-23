import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/favorite/bloc/favorite_bloc.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/widgets/favorite_card.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';

/// Page listing what the current user added to favorites: a tab of threads (帖子) and a tab of forums (版块), like
/// the web page `home.php?mod=space&do=favorite&type=thread|forum`.
class FavoritePage extends StatelessWidget {
  /// Constructor.
  const FavoritePage({this.initialType = FavoriteType.thread, super.key});

  /// Tab to open first.
  final FavoriteType initialType;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.favoritePage;
    return DefaultTabController(
      length: FavoriteType.values.length,
      initialIndex: FavoriteType.values.indexOf(initialType),
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          bottom: TabBar(
            tabs: [
              Tab(text: tr.threadTab),
              Tab(text: tr.forumTab),
            ],
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: TabBarView(
            children: [for (final type in FavoriteType.values) _FavoriteTab(type, key: ValueKey(type))],
          ),
        ),
      ),
    );
  }
}

/// One tab: the list of records of [type] with pull to refresh, load more and removal.
class _FavoriteTab extends StatefulWidget {
  const _FavoriteTab(this.type, {super.key});

  final FavoriteType type;

  @override
  State<_FavoriteTab> createState() => _FavoriteTabState();
}

class _FavoriteTabState extends State<_FavoriteTab> with AutomaticKeepAliveClientMixin {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  final _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _refreshController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _confirmRemove(BuildContext context, FavoriteItem item) async {
    final tr = context.t.favoritePage;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.remove,
      message: tr.removeConfirm(title: item.title),
      dangerous: true,
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    context.read<FavoriteBloc>().add(FavoriteRemoveRequested(item));
  }

  Widget _buildList(BuildContext context, FavoriteState state) {
    final tr = context.t.favoritePage;
    if (!state.refreshing) {
      _refreshController.finishRefresh();
    }
    final bloc = context.read<FavoriteBloc>();
    return EasyRefresh.builder(
      controller: _refreshController,
      scrollController: _scrollController,
      header: const MaterialHeader(),
      onRefresh: () => bloc.add(const FavoriteRefreshRequested()),
      childBuilder: (context, physics) {
        if (state.items.isEmpty) {
          // What the list is for and how a record gets in it.
          return ListView(
            physics: physics,
            controller: _scrollController,
            padding: edgeInsetsL12T4R12.add(context.safePadding()),
            children: [
              sizedBoxW32H32,
              AppStateView(
                icon: Icons.star_outline,
                message: switch (widget.type) {
                  FavoriteType.thread => tr.empty,
                  FavoriteType.forum => tr.emptyForum,
                },
                detail: switch (widget.type) {
                  FavoriteType.thread => tr.emptyHint,
                  FavoriteType.forum => tr.emptyForumHint,
                },
              ),
            ],
          );
        }
        return AppCenteredList(
          builder: (context, side, _) => ListView.separated(
            physics: physics,
            controller: _scrollController,
            padding: side.copyWith(top: 8).add(context.safePadding()),
            // The end of the list is its last item: built when it comes near, it asks the next page.
            itemCount: state.items.length + 1,
            itemBuilder: (context, index) {
              if (index == state.items.length) {
                return ListFooter(
                  status: listFooterStatus(
                    hasMore: state.nextPageUrl != null,
                    loading: state.loadingMore || state.refreshing,
                    failed: state.loadMoreFailed,
                  ),
                  itemCount: state.items.length,
                  failure: state.failure,
                  onLoadMore: () => bloc.add(const FavoriteLoadMoreRequested()),
                  onRetry: () => bloc.add(const FavoriteLoadMoreRequested()),
                );
              }
              final item = state.items[index];
              return FavoriteCard(
                item,
                removing: state.removing.contains(item.favid),
                onRemove: () async => _confirmRemove(context, item),
              );
            },
            separatorBuilder: (context, index) => appListSeparator,
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, FavoriteState state) => switch (state.status) {
    // The shape of the records to come instead of a spinner over the whole page.
    FavoriteStatus.initial || FavoriteStatus.loading => const ThreadListSkeleton(),
    FavoriteStatus.needLogin => NeedLoginPage(
      backUri: GoRouterState.of(context).uri,
      needPop: true,
      popCallback: (context) => context.read<FavoriteBloc>().add(const FavoriteLoadRequested()),
    ),
    FavoriteStatus.failure => FailureView(
      failure: state.failure,
      onRetry: () => context.read<FavoriteBloc>().add(const FavoriteLoadRequested()),
    ),
    FavoriteStatus.success => _buildList(context, state),
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tr = context.t.favoritePage;
    return BlocProvider(
      create: (context) =>
          FavoriteBloc(favoriteRepository: context.repo(), authenticationRepository: context.repo(), type: widget.type)
            ..add(const FavoriteLoadRequested()),
      child: MultiBlocListener(
        listeners: [
          BlocListener<FavoriteBloc, FavoriteState>(
            listenWhen: (prev, curr) => prev.removedCount != curr.removedCount,
            listener: (context, state) => showSnackBar(context: context, message: tr.removed),
          ),
          BlocListener<FavoriteBloc, FavoriteState>(
            listenWhen: (prev, curr) => prev.failureCount != curr.failureCount,
            listener: (context, state) => showSnackBar(
              context: context,
              message: tr.actionFailed(err: state.lastFailure ?? ''),
            ),
          ),
          // A refresh that failed keeps the records on screen and says so.
          BlocListener<FavoriteBloc, FavoriteState>(
            listenWhen: (prev, curr) =>
                prev.refreshing && !curr.refreshing && curr.status == FavoriteStatus.success && curr.failure != null,
            listener: (context, state) {
              final bloc = context.read<FavoriteBloc>();
              showRefreshFailedSnackBar(
                context,
                state.failure,
                onRetry: () {
                  if (!bloc.isClosed) {
                    bloc.add(const FavoriteRefreshRequested());
                  }
                },
              );
            },
          ),
        ],
        child: BlocBuilder<FavoriteBloc, FavoriteState>(builder: _buildBody),
      ),
    );
  }
}
