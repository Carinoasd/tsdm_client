import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/draft_box/view/draft_box_panel.dart';
import 'package:tsdm_client/features/my_thread/bloc/my_thread_bloc.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';

/// Page to show the threads and replies published by current logged user.
class MyThreadPage extends StatefulWidget {
  /// Constructor.
  const MyThreadPage({super.key, this.showDrafts = false, this.showReplies = false});

  /// Enter the draft tab after saving from the editor, or from a link to the draft box (`filter=save`).
  final bool showDrafts;

  /// Enter the reply tab, from a link to the replies (`type=reply`).
  final bool showReplies;

  @override
  State<MyThreadPage> createState() => _MyThreadPageState();
}

class _MyThreadPageState extends State<MyThreadPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  late final EasyRefreshController _threadRefreshController;
  late final EasyRefreshController _replyRefreshController;

  /// One tab: the shape of the rows while its first page loads, the failure with its retry when that failed, the
  /// rows with the shared end of the list ([ListFooter]) otherwise. A refresh keeps the rows on screen.
  Widget _buildTab(
    BuildContext context, {
    required EasyRefreshController controller,
    required List<MyThread> items,
    required bool loading,
    required bool refreshing,
    required bool failed,
    required bool hasMore,
    required bool loadingMore,
    required bool loadMoreFailed,
    required LoadFailure? failure,
    required String emptyMessage,
    required VoidCallback onRefresh,
    required VoidCallback onLoadMore,
  }) {
    if (loading || (refreshing && items.isEmpty)) {
      return const ThreadListSkeleton();
    }
    if (!refreshing) {
      controller.finishRefresh();
    }
    if (items.isEmpty && failed) {
      // Failed, not empty: "no data" would be wrong.
      return FailureView(failure: failure, onRetry: onRefresh);
    }
    return EasyRefresh.builder(
      controller: controller,
      header: const MaterialHeader(),
      onRefresh: () async => onRefresh(),
      childBuilder: (context, physics) => items.isEmpty
          ? AppScrollableStateView(
              physics: physics,
              child: AppStateView(icon: Icons.article_outlined, message: emptyMessage, scrollable: false),
            )
          : AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                physics: physics,
                padding: side.copyWith(top: 8).add(context.safePadding()),
                // The end of the list is its last item: built when it comes near, it asks the next page.
                itemCount: items.length + 1,
                itemBuilder: (context, index) => index < items.length
                    ? MyThreadCard(items[index])
                    : ListFooter(
                        status: listFooterStatus(
                          hasMore: hasMore,
                          loading: loadingMore || refreshing,
                          failed: loadMoreFailed,
                        ),
                        itemCount: items.length,
                        failure: failure,
                        onLoadMore: onLoadMore,
                        onRetry: onLoadMore,
                      ),
                separatorBuilder: (context, index) => appListSeparator,
              ),
            ),
    );
  }

  Widget _buildThreadTab(BuildContext context, MyThreadState state) {
    final bloc = context.read<MyThreadBloc>();
    return _buildTab(
      context,
      controller: _threadRefreshController,
      items: state.threadList,
      loading: state.status == MyThreadStatus.loading,
      refreshing: state.refreshingThread,
      failed: state.threadFailed,
      hasMore: state.nextThreadPageUrl != null,
      loadingMore: state.loadingMoreThread,
      loadMoreFailed: state.threadLoadMoreFailed,
      failure: state.threadFailure,
      emptyMessage: context.t.myThreadPage.threadTab.empty,
      onRefresh: () => bloc.add(MyThreadRefreshThreadRequested()),
      onLoadMore: () => bloc.add(const MyThreadLoadMoreThreadRequested()),
    );
  }

  Widget _buildReplyTab(BuildContext context, MyThreadState state) {
    final bloc = context.read<MyThreadBloc>();
    return _buildTab(
      context,
      controller: _replyRefreshController,
      items: state.replyList,
      loading: state.status == MyThreadStatus.loading,
      refreshing: state.refreshingReply,
      failed: state.replyFailed,
      hasMore: state.nextReplyPageUrl != null,
      loadingMore: state.loadingMoreReply,
      loadMoreFailed: state.replyLoadMoreFailed,
      failure: state.replyFailure,
      emptyMessage: context.t.myThreadPage.replyTab.empty,
      onRefresh: () => bloc.add(MyThreadRefreshReplyRequested()),
      onLoadMore: () => bloc.add(const MyThreadLoadMoreReplyRequested()),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      initialIndex: widget.showDrafts ? 2 : (widget.showReplies ? 1 : 0),
      vsync: this,
    );
    _threadRefreshController = EasyRefreshController(controlFinishRefresh: true);
    _replyRefreshController = EasyRefreshController(controlFinishRefresh: true);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _threadRefreshController.dispose();
    _replyRefreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => MyThreadRepository()),
        BlocProvider(
          create: (context) =>
              MyThreadBloc(myThreadRepository: context.repo())..add(MyThreadLoadInitialDataRequested()),
        ),
      ],
      child: MultiBlocListener(
        // A refresh that failed with the list on screen keeps the list: say it failed and why, every time it ends so.
        listeners: [
          BlocListener<MyThreadBloc, MyThreadState>(
            listenWhen: (prev, curr) =>
                prev.refreshingThread && !curr.refreshingThread && curr.threadFailed && curr.threadList.isNotEmpty,
            listener: (context, state) {
              final bloc = context.read<MyThreadBloc>();
              showRefreshFailedSnackBar(
                context,
                state.threadFailure,
                onRetry: () {
                  if (!bloc.isClosed) {
                    bloc.add(MyThreadRefreshThreadRequested());
                  }
                },
              );
            },
          ),
          BlocListener<MyThreadBloc, MyThreadState>(
            listenWhen: (prev, curr) =>
                prev.refreshingReply && !curr.refreshingReply && curr.replyFailed && curr.replyList.isNotEmpty,
            listener: (context, state) {
              final bloc = context.read<MyThreadBloc>();
              showRefreshFailedSnackBar(
                context,
                state.replyFailure,
                onRetry: () {
                  if (!bloc.isClosed) {
                    bloc.add(MyThreadRefreshReplyRequested());
                  }
                },
              );
            },
          ),
        ],
        child: BlocBuilder<MyThreadBloc, MyThreadState>(
          builder: (context, state) {
            return Scaffold(
              appBar: AppBar(
                title: Text(context.t.myThreadPage.title),
                bottom: TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(child: Text(context.t.myThreadPage.threadTab.title)),
                    Tab(child: Text(context.t.myThreadPage.replyTab.title)),
                    Tab(child: Text(context.t.draftBox.title)),
                  ],
                ),
              ),
              body: SafeArea(
                bottom: false,
                child: TabBarView(
                  controller: _tabController,
                  children: [_buildThreadTab(context, state), _buildReplyTab(context, state), const DraftBoxPanel()],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
