import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/thread_picking.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

/// Page to show info about latest thread page.
class LatestThreadPage extends StatefulWidget {
  /// Constructor.
  const LatestThreadPage({required this.url, this.title, this.repository, this.moderateRepository, super.key});

  /// Url the the page.
  final String url;

  /// App bar title, e.g. the guide module name (最新热门); the generic "latest thread" title when null.
  final String? title;

  /// Repository override (tests); the real one is used when null.
  final LatestThreadRepository? repository;

  /// Where the management of the threads picked goes (tests); the app's client when null.
  final ModerateRepository? moderateRepository;

  @override
  State<LatestThreadPage> createState() => _LatestThreadPageState();
}

class _LatestThreadPageState extends State<LatestThreadPage> with ListThreadPicking {
  late final EasyRefreshController _refreshController;

  @override
  late final ModerateRepository pickingRepository = widget.moderateRepository ?? ModerateRepository.network();

  /// [thread] as a moderator may pick it.
  static ListPickableThread _pickable(LatestThread thread) => (
    tid: thread.threadID ?? '',
    title: thread.title ?? '',
    fid: thread.threadID == null ? null : fidOfForumUrl(thread.forumUrl),
    authorUid: thread.threadAuthor?.uid,
    filtered: true,
  );

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
                    ? buildPickableCard(
                        context,
                        _pickable(state.threadList[index]),
                        (onPick, onStartPicking) => LatestThreadCard(
                          state.threadList[index],
                          onPick: onPick,
                          onStartPicking: onStartPicking,
                        ),
                      )
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
    // A wide window shows the thread tapped on the right of the list.
    return TwoPaneLayout(list: _buildPage(context));
  }

  /// The page, under the [TwoPaneLayout] of [build].
  Widget _buildPage(BuildContext context) {
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

          watchPickingAccount(context);
          final bloc = context.read<LatestThreadBloc>();
          return buildPickingPopScope(
            child: Scaffold(
              appBar:
                  buildPickingAppBar(
                    context,
                    [for (final thread in state.threadList) _pickable(thread)],
                    onDone: () {
                      if (!bloc.isClosed) {
                        bloc.add(LatestThreadRefreshRequested(widget.url));
                      }
                    },
                  ) ??
                  AppBar(
                    title: Text(
                      widget.title ??
                          switch (state.tagName) {
                            final name? => context.t.tagPage.title(name: name),
                            // A tag page is named before the page tells the tag (loading, failed).
                            null when widget.url.contains('mod=tag') => context.t.tagPage.cloudTitle,
                            null => context.t.latestThreadPage.title,
                          },
                    ),
                  ),
              body: SafeArea(bottom: false, child: body),
            ),
          );
        },
      ),
    );
  }
}
