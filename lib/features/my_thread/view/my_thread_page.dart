import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/draft_box/view/draft_box_panel.dart';
import 'package:tsdm_client/features/my_thread/bloc/my_thread_bloc.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/load_more_failed_footer.dart';

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

  /// The cards of [items], with the retry of a next page that failed to load ([loadMoreFailed]) at the end.
  Widget _buildList(
    BuildContext context,
    List<MyThread> items, {
    required bool loadMoreFailed,
    required VoidCallback onRetry,
  }) => AppCenteredList(
    builder: (context, side, _) => ListView.separated(
      padding: side.copyWith(top: 8).add(context.safePadding()),
      itemCount: items.length + (loadMoreFailed ? 1 : 0),
      itemBuilder: (context, index) =>
          index < items.length ? MyThreadCard(items[index]) : LoadMoreFailedFooter(onRetry: onRetry),
      separatorBuilder: (context, index) => appListSeparator,
    ),
  );

  Widget _buildThreadTab(BuildContext context, MyThreadState state) {
    if (state.status == MyThreadStatus.loading || state.refreshingThread) {
      return const CenteredCircularIndicator();
    }
    _threadRefreshController
      ..finishRefresh()
      ..finishLoad();
    final Widget child;
    if (state.threadList.isEmpty && state.threadFailed) {
      // Failed, not empty: "no data" would be wrong.
      return buildRetryButton(context, () => context.read<MyThreadBloc>().add(MyThreadRefreshThreadRequested()));
    } else if (state.threadList.isEmpty) {
      child = AppStateView(icon: Icons.article_outlined, message: context.t.general.noData);
    } else {
      child = _buildList(
        context,
        state.threadList,
        loadMoreFailed: state.threadLoadMoreFailed,
        onRetry: () => context.read<MyThreadBloc>().add(const MyThreadLoadMoreThreadRequested()),
      );
    }
    return EasyRefresh(
      controller: _threadRefreshController,
      header: const MaterialHeader(),
      footer: const MaterialFooter(),
      onRefresh: () async {
        context.read<MyThreadBloc>().add(MyThreadRefreshThreadRequested());
      },
      onLoad: () async {
        if (state.nextThreadPageUrl == null) {
          _threadRefreshController.finishLoad(IndicatorResult.noMore);
          return;
        }
        context.read<MyThreadBloc>().add(const MyThreadLoadMoreThreadRequested());
      },
      child: child,
    );
  }

  Widget _buildReplyTab(BuildContext context, MyThreadState state) {
    if (state.status == MyThreadStatus.loading || state.refreshingReply) {
      return const CenteredCircularIndicator();
    }
    _replyRefreshController
      ..finishRefresh()
      ..finishLoad();
    final Widget child;
    if (state.replyList.isEmpty && state.replyFailed) {
      // Failed, not empty: "no data" would be wrong.
      return buildRetryButton(context, () => context.read<MyThreadBloc>().add(MyThreadRefreshReplyRequested()));
    } else if (state.replyList.isEmpty) {
      child = AppStateView(icon: Icons.article_outlined, message: context.t.general.noData);
    } else {
      child = _buildList(
        context,
        state.replyList,
        loadMoreFailed: state.replyLoadMoreFailed,
        onRetry: () => context.read<MyThreadBloc>().add(const MyThreadLoadMoreReplyRequested()),
      );
    }

    return EasyRefresh(
      controller: _replyRefreshController,
      header: const MaterialHeader(),
      footer: const MaterialFooter(),
      onRefresh: () async {
        context.read<MyThreadBloc>().add(MyThreadRefreshReplyRequested());
      },
      onLoad: () async {
        if (state.nextReplyPageUrl == null) {
          _replyRefreshController.finishLoad(IndicatorResult.noMore);
          return;
        }
        context.read<MyThreadBloc>().add(const MyThreadLoadMoreReplyRequested());
      },
      child: child,
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
    _threadRefreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);
    _replyRefreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);
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
      child: BlocConsumer<MyThreadBloc, MyThreadState>(
        // A refresh that failed with the list on screen keeps the list: say it failed, every time it ends so.
        listenWhen: (prev, curr) =>
            (prev.refreshingThread && !curr.refreshingThread && curr.threadFailed && curr.threadList.isNotEmpty) ||
            (prev.refreshingReply && !curr.refreshingReply && curr.replyFailed && curr.replyList.isNotEmpty),
        listener: (context, state) => showFailedToLoadSnackBar(context),
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
    );
  }
}
