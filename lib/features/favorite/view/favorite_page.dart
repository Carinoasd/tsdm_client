import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/favorite/bloc/favorite_bloc.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/widgets/favorite_card.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_cubit.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_dialog.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

/// Page listing what the current user added to favorites: a tab of threads (帖子) and a tab of forums (版块), like
/// the web page `home.php?mod=space&do=favorite&type=thread|forum`.
class FavoritePage extends StatelessWidget {
  /// Constructor.
  const FavoritePage({this.initialType = FavoriteType.thread, super.key});

  /// Tab to open first.
  final FavoriteType initialType;

  @override
  Widget build(BuildContext context) {
    // A wide window shows the thread tapped on the right of the list.
    return TwoPaneLayout(list: _buildPage(context));
  }

  /// The page, under the [TwoPaneLayout] of [build].
  Widget _buildPage(BuildContext context) {
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

  /// Threads picked for saving offline (tids); empty when none is being picked.
  final Set<String> _selected = {};

  /// Threads that have an offline copy now (tids).
  Set<String> _copied = {};

  /// Whether the thread tab offers the offline batch: the setting is on and an account is in use.
  bool get _offlineOn =>
      widget.type == FavoriteType.thread && appOfflineThreads.enabled && appOfflineThreads.currentUid() != null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCopies());
  }

  Future<void> _loadCopies() async {
    final uid = _offlineOn ? appOfflineThreads.currentUid() : null;
    if (uid == null) {
      return;
    }
    final copies = await appOfflineThreads.copies(uid);
    if (mounted) {
      setState(() => _copied = {for (final c in copies) '${c.tid}'});
    }
  }

  /// Every thread of the favorites, the pages not loaded on the screen yet included: asked one after the other with the
  /// batch's pause ([next]), and stopped by its cancel. A page that fails ends the list there, with the reason.
  Future<OfflineBatchList> _allThreads(FavoriteState state, Future<bool> Function() next) async {
    final items = [...state.items];
    var url = state.nextPageUrl;
    String? failure;
    final repository = context.repo<FavoriteRepository>();
    final failedToLoad = context.t.general.failedToLoad;
    final visited = <String>{};
    // A page naming itself again would never end.
    while (url != null && visited.add(url)) {
      if (!await next()) {
        break;
      }
      final page = (await repository.fetchListPageOf(widget.type, url).run()).toNullable();
      if (page == null) {
        failure = failedToLoad;
        break;
      }
      items.addAll(page.items);
      url = page.nextPageUrl;
    }
    return (jobs: _jobsOf(items), failure: failure);
  }

  List<OfflineBatchJob> _jobsOf(Iterable<FavoriteItem> items) => [
    for (final item in items)
      if (item case FavoriteThread(:final tid, :final title) when int.tryParse(tid) != null)
        (tid: int.parse(tid), title: title),
  ];

  Future<void> _download(Future<OfflineBatchList> Function(Future<bool> Function() next) jobs) async {
    await showOfflineBatchDialog(context: context, mode: OfflineBatchMode.download, jobs: jobs);
    if (mounted) {
      setState(_selected.clear);
      await _loadCopies();
    }
  }

  Widget _buildOfflineBar(BuildContext context, FavoriteState state) {
    final tr = context.t.offlineBatch;
    final selecting = _selected.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Row(
        children: [
          if (selecting) ...[
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: tr.clearSelection,
              onPressed: () => setState(_selected.clear),
            ),
            Text(tr.selectedCount(count: _selected.length)),
          ],
          const Spacer(),
          IconButton(
            icon: Icon(selecting ? Icons.download_for_offline : Icons.download_for_offline_outlined),
            tooltip: selecting ? tr.downloadSelected : tr.downloadAll,
            onPressed: selecting
                ? () async => _download((_) async {
                    final picked = state.items.where((e) => _selected.contains(e.targetId));
                    return (jobs: _jobsOf(picked), failure: null);
                  })
                : () async => _download((next) async => _allThreads(state, next)),
          ),
          IconButton(
            icon: const Icon(Icons.offline_pin_outlined),
            tooltip: tr.copies,
            onPressed: () async {
              await context.pushNamed(ScreenPaths.offlineThreads);
              if (mounted) {
                await _loadCopies();
              }
            },
          ),
        ],
      ),
    );
  }

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
    final list = EasyRefresh.builder(
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
                offline: _copied.contains(item.targetId),
                selected: _selected.contains(item.targetId),
                onSelect: _offlineOn && item is FavoriteThread
                    ? () => setState(() => _selected.add(item.targetId))
                    : null,
                onToggle: _selected.isEmpty
                    ? null
                    : () => setState(() {
                        if (!_selected.remove(item.targetId)) {
                          _selected.add(item.targetId);
                        }
                      }),
              );
            },
            separatorBuilder: (context, index) => appListSeparator,
          ),
        );
      },
    );
    if (!_offlineOn) {
      return list;
    }
    return Column(
      children: [
        _buildOfflineBar(context, state),
        Expanded(child: list),
      ],
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
