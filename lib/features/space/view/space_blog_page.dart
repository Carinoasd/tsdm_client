import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/space/cubit/blog_detail_cubit.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/repository/space_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/post_layout_html.dart';

/// A blog of the member [uid]: its content and comments.
class SpaceBlogPage extends StatefulWidget {
  /// Constructor.
  const SpaceBlogPage({required this.uid, required this.blogId, this.title, super.key});

  /// The author.
  final int uid;

  /// The blog.
  final int blogId;

  /// Its title, shown until the blog loaded.
  final String? title;

  @override
  State<SpaceBlogPage> createState() => _SpaceBlogPageState();
}

class _SpaceBlogPageState extends State<SpaceBlogPage> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  late final BlogDetailCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = BlogDetailCubit(url: spaceBlogUrl(widget.uid, widget.blogId), fetch: const SpaceRepository().fetchBlog);
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    _refreshController.dispose();
    unawaited(_cubit.close());
    super.dispose();
  }

  Widget _content(BuildContext context, BlogDetailState state) {
    final theme = Theme.of(context);
    final blog = state.blog!;
    final outline = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline);
    final header = AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blog.title != null) Text(context.displayText(blog.title!), style: theme.textTheme.titleLarge),
          if (blog.time != null || blog.category != null) ...[
            sizedBoxW4H4,
            Wrap(
              spacing: 12,
              children: [
                if (blog.time != null) Text(blog.time!, style: outline),
                if (blog.category != null) Text(blog.category!, style: outline),
              ],
            ),
          ],
          sizedBoxW12H12,
          PostLayoutHtml(blog.content!),
        ],
      ),
    );
    final comments = state.comments;
    final footer = state.nextCommentsUrl != null || state.loadMoreFailed;
    // The blog, then the comments built as they come near: the header of them, each comment, the next page.
    final count = comments.isEmpty ? 1 : 2 + comments.length + (footer ? 1 : 0);
    return AppCenteredList(
      builder: (context, side, width) => ListView.builder(
        padding: side.copyWith(top: 12, bottom: 24).add(context.safePadding()),
        itemCount: count,
        itemBuilder: (context, index) {
          if (index == 0) return header;
          if (index == 1) {
            return Padding(
              padding: const EdgeInsets.only(top: appSurfaceGap),
              child: AppSectionHeader(
                '${context.t.spacePage.comments} ${blog.commentCount ?? comments.length}',
                icon: Icons.chat_bubble_outline,
                padding: edgeInsetsL12T4R12B4.copyWith(bottom: 8),
              ),
            );
          }
          final i = index - 2;
          if (i < comments.length) {
            return Padding(
              padding: const EdgeInsets.only(bottom: appSurfaceGapCompact),
              child: AppSurface(child: SpaceBlogCommentTile(comments[i])),
            );
          }
          return ListFooter(
            status: listFooterStatus(
              hasMore: state.nextCommentsUrl != null,
              loading: state.loadingMore,
              failed: state.loadMoreFailed,
            ),
            itemCount: comments.length,
            failure: state.failure,
            onLoadMore: _cubit.loadMore,
            onRetry: _cubit.loadMore,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
    value: _cubit,
    child: BlocConsumer<BlogDetailCubit, BlogDetailState>(
      // A load of the blog ended (the first, or a refresh): a refresh that failed keeps the blog and says so.
      listenWhen: (prev, curr) =>
          !identical(prev.blog, curr.blog) || (curr.failure != null && prev.failure == null && !curr.loadMoreFailed),
      listener: (context, state) {
        _refreshController.finishRefresh();
        if (state.status == SpaceLoadStatus.success && state.failure != null && !state.loadMoreFailed) {
          showRefreshFailedSnackBar(context, state.failure, onRetry: _cubit.load);
        }
      },
      builder: (context, state) {
        final body = switch (state.status) {
          SpaceLoadStatus.loading => const ThreadListSkeleton(),
          SpaceLoadStatus.needLogin => NeedLoginPage(
            backUri: GoRouterState.of(context).uri,
            needPop: true,
            popCallback: (_) => _cubit.load(),
          ),
          SpaceLoadStatus.notice => FailureView(
            failure: LoadFailure.fromMessage(state.blog?.message ?? ''),
            onRetry: _cubit.load,
          ),
          SpaceLoadStatus.failure => FailureView(failure: state.failure, onRetry: _cubit.load),
          SpaceLoadStatus.success => EasyRefresh(
            controller: _refreshController,
            header: const MaterialHeader(),
            onRefresh: _cubit.load,
            child: _content(context, state),
          ),
        };
        return Scaffold(
          appBar: AppBar(title: Text(state.blog?.title ?? widget.title ?? context.t.spacePage.blogs)),
          body: SafeArea(bottom: false, child: body),
        );
      },
    ),
  );
}
