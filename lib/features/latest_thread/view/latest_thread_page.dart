import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';

/// Page to show info about latest thread page.
class LatestThreadPage extends StatefulWidget {
  /// Constructor.
  const LatestThreadPage({required this.url, this.title, this.repository, super.key});

  /// Url the the page.
  final String url;

  /// App bar title, e.g. the guide module name (最新热门); the generic "latest thread" title when null.
  final String? title;

  /// Repository override (tests); the real one is used when null.
  final LatestThreadRepository? repository;

  @override
  State<LatestThreadPage> createState() => _LatestThreadPageState();
}

class _LatestThreadPageState extends State<LatestThreadPage> {
  late final EasyRefreshController _refreshController;

  Widget _buildBody(BuildContext context, LatestThreadState state) {
    if (!state.refreshing) {
      _refreshController.finishRefresh();
    }
    final bloc = context.read<LatestThreadBloc>();

    return EasyRefresh.builder(
      controller: _refreshController,
      header: const MaterialHeader(),
      onRefresh: () async {
        bloc.add(LatestThreadRefreshRequested(widget.url));
      },
      childBuilder: (context, physics) => state.threadList.isEmpty
          // The guide page can be empty (最新精华 has no threads); say so instead of showing a blank list.
          ? AppScrollableStateView(
              physics: physics,
              child: AppStateView(
                icon: Icons.article_outlined,
                message: context.t.latestThreadPage.empty,
                scrollable: false,
              ),
            )
          : AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                physics: physics,
                padding: side.copyWith(top: 8).add(context.safePadding()),
                // The end of the list is its last item: built when it comes near, it asks the next page.
                itemCount: state.threadList.length + 1,
                itemBuilder: (context, index) => index < state.threadList.length
                    ? LatestThreadCard(state.threadList[index])
                    : ListFooter(
                        status: listFooterStatus(
                          hasMore: state.nextPageUrl != null,
                          loading: state.loadingMore || state.refreshing,
                          failed: state.loadMoreFailed,
                        ),
                        itemCount: state.threadList.length,
                        failure: state.failure,
                        onLoadMore: () => bloc.add(LatestThreadLoadMoreRequested()),
                        onRetry: () => bloc.add(LatestThreadLoadMoreRequested()),
                      ),
                separatorBuilder: (context, index) => appListSeparator,
              ),
            ),
    );
  }

  @override
  void initState() {
    super.initState();
    _refreshController = EasyRefreshController(controlFinishRefresh: true);
  }

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => widget.repository ?? LatestThreadRepository()),
        BlocProvider(
          create: (context) =>
              LatestThreadBloc(latestThreadRepository: context.repo())..add(LatestThreadRefreshRequested(widget.url)),
        ),
      ],
      child: BlocConsumer<LatestThreadBloc, LatestThreadState>(
        // A refresh that failed keeps the threads on screen and says so.
        listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing && curr.failure != null,
        listener: (context, state) {
          final bloc = context.read<LatestThreadBloc>();
          showRefreshFailedSnackBar(
            context,
            state.failure,
            onRetry: () {
              if (!bloc.isClosed) {
                bloc.add(LatestThreadRefreshRequested(widget.url));
              }
            },
          );
        },
        builder: (context, state) {
          final body = switch (state.status) {
            // The shape of the threads to come instead of a spinner over the whole page.
            LatestThreadStatus.initial || LatestThreadStatus.loading => const ThreadListSkeleton(),
            LatestThreadStatus.failed => FailureView(
              failure: state.failure,
              onRetry: () => context.read<LatestThreadBloc>().add(LatestThreadRefreshRequested(widget.url)),
            ),
            LatestThreadStatus.success => _buildBody(context, state),
          };

          return Scaffold(
            appBar: AppBar(title: Text(widget.title ?? context.t.latestThreadPage.title)),
            body: SafeArea(bottom: false, child: body),
          );
        },
      ),
    );
  }
}
