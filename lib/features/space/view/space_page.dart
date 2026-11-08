import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';

/// The tabs of [SpacePage].
enum SpaceTab {
  /// The blogs.
  blog,

  /// The albums.
  album
  ;

  /// The tab named [name] (`blog`, `album`), the blogs by default.
  static SpaceTab of(String? name) => values.where((e) => e.name == name).firstOrNull ?? blog;
}

/// The blogs and the albums of the member [uid], a tab each.
///
/// The member's own space offers to post a blog and to upload pictures.
class SpacePage extends StatefulWidget {
  /// Constructor.
  const SpacePage({required this.uid, this.username, this.initialTab = SpaceTab.blog, super.key});

  /// The member.
  final int uid;

  /// Their name, for the title.
  final String? username;

  /// The tab shown first.
  final SpaceTab initialTab;

  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final SpaceListCubit<SpaceBlog> _blogs;
  late final SpaceListCubit<SpaceAlbum> _albums;

  /// The account changes, to show the owner's actions to the owner only.
  late final Stream<AuthStatus> _authChanges = context.read<AuthenticationRepository>().status;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: SpaceTab.values.length, vsync: this, initialIndex: widget.initialTab.index)
      ..addListener(() => setState(() {}));
    const repo = SpaceRepository();
    _blogs = SpaceListCubit<SpaceBlog>(
      firstPageUrl: spaceBlogListUrl(widget.uid),
      fetch: repo.fetchBlogList,
      keyOf: (e) => e.blogId,
    );
    _albums = SpaceListCubit<SpaceAlbum>(
      firstPageUrl: spaceAlbumListUrl(widget.uid),
      fetch: repo.fetchAlbumList,
      keyOf: (e) => e.albumId,
    );
    unawaited(_blogs.load());
    unawaited(_albums.load());
  }

  @override
  void dispose() {
    _tabController.dispose();
    unawaited(_blogs.close());
    unawaited(_albums.close());
    super.dispose();
  }

  bool get _own => context.read<AuthenticationRepository>().currentUser?.uid == widget.uid;

  Future<void> _write() async {
    final path = switch (SpaceTab.values[_tabController.index]) {
      SpaceTab.blog => ScreenPaths.spaceBlogPost,
      SpaceTab.album => ScreenPaths.spaceAlbumUpload,
    };
    final changed = await context.pushNamed<bool>(path);
    if (!mounted || !(changed ?? false)) return;
    unawaited(_blogs.refresh());
    unawaited(_albums.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage;
    final tab = SpaceTab.values[_tabController.index];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.username ?? (tab == SpaceTab.blog ? tr.blogs : tr.albums)),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: tr.blogs),
            Tab(text: tr.albums),
          ],
        ),
      ),
      // Follows the account in use: another account's space offers nothing to write.
      floatingActionButton: StreamBuilder<AuthStatus>(
        stream: _authChanges,
        builder: (context, _) => _own
            ? FloatingActionButton(
                tooltip: tab == SpaceTab.blog ? tr.newBlog : tr.upload,
                onPressed: _write,
                child: Icon(tab == SpaceTab.blog ? Icons.edit_outlined : Icons.add_photo_alternate_outlined),
              )
            : const SizedBox.shrink(),
      ),
      body: SafeArea(
        bottom: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            BlocProvider.value(
              value: _blogs,
              child: _SpaceList<SpaceBlog>(
                emptyIcon: Icons.article_outlined,
                emptyMessage: tr.emptyBlogs,
                itemBuilder: (context, blog) => SpaceBlogCard(blog),
              ),
            ),
            BlocProvider.value(
              value: _albums,
              child: _SpaceList<SpaceAlbum>(
                emptyIcon: Icons.photo_library_outlined,
                emptyMessage: tr.emptyAlbums,
                grid: true,
                itemBuilder: (context, album) => SpaceAlbumTile(album),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of the space, refreshed by pulling down, the next page loaded at its end.
class _SpaceList<T> extends StatefulWidget {
  const _SpaceList({
    required this.emptyIcon,
    required this.emptyMessage,
    required this.itemBuilder,
    this.grid = false,
  });

  final IconData emptyIcon;
  final String emptyMessage;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Tiles in a grid (the albums) rather than cards in a column.
  final bool grid;

  @override
  State<_SpaceList<T>> createState() => _SpaceListState<T>();
}

class _SpaceListState<T> extends State<_SpaceList<T>> with AutomaticKeepAliveClientMixin {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return BlocConsumer<SpaceListCubit<T>, SpaceListState<T>>(
      listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing,
      listener: (context, state) {
        _refreshController.finishRefresh();
        if (state.failure != null && state.status == SpaceLoadStatus.success) {
          showRefreshFailedSnackBar(context, state.failure, onRetry: () => context.read<SpaceListCubit<T>>().refresh());
        }
      },
      builder: (context, state) {
        final cubit = context.read<SpaceListCubit<T>>();
        return switch (state.status) {
          SpaceLoadStatus.loading => const ThreadListSkeleton(),
          SpaceLoadStatus.needLogin => NeedLoginPage(
            backUri: GoRouterState.of(context).uri,
            needPop: true,
            popCallback: (_) => cubit.load(),
          ),
          SpaceLoadStatus.notice => FailureView(
            failure: LoadFailure.fromMessage(state.message ?? ''),
            onRetry: cubit.load,
          ),
          SpaceLoadStatus.failure => FailureView(failure: state.failure, onRetry: cubit.load),
          SpaceLoadStatus.success => EasyRefresh(
            controller: _refreshController,
            header: const MaterialHeader(),
            onRefresh: cubit.refresh,
            child: _content(context, state, cubit),
          ),
        };
      },
    );
  }

  Widget _content(BuildContext context, SpaceListState<T> state, SpaceListCubit<T> cubit) {
    final footer = ListFooter(
      status: listFooterStatus(
        hasMore: state.nextPageUrl != null,
        loading: state.loadingMore || state.refreshing,
        failed: state.loadMoreFailed,
      ),
      itemCount: state.items.length,
      failure: state.failure,
      onLoadMore: cubit.loadMore,
      onRetry: cubit.loadMore,
    );
    return AppCenteredList(
      builder: (context, side, width) {
        final padding = side
            .copyWith(top: 12, bottom: 12 + 72)
            .add(context.safePadding())
            .resolve(Directionality.of(context));
        if (state.items.isEmpty) {
          return ListView(
            padding: padding,
            children: [
              sizedBoxW32H32,
              AppStateView(icon: widget.emptyIcon, message: widget.emptyMessage, scrollable: false),
            ],
          );
        }
        final note = state.hiddenNote;
        if (widget.grid) {
          final columns = (width / 180).floor().clamp(2, 6);
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: padding.copyWith(bottom: 0),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: appSurfaceGapCompact,
                    crossAxisSpacing: appSurfaceGapCompact,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: state.items.length,
                  itemBuilder: (context, index) => widget.itemBuilder(context, state.items[index]),
                ),
              ),
              SliverPadding(
                padding: padding.copyWith(top: 0),
                sliver: SliverToBoxAdapter(child: footer),
              ),
            ],
          );
        }
        return ListView.separated(
          padding: padding,
          itemCount: state.items.length + (note == null ? 1 : 2),
          separatorBuilder: (_, _) => const SizedBox(height: appSurfaceGapCompact),
          itemBuilder: (context, index) {
            if (index < state.items.length) return widget.itemBuilder(context, state.items[index]);
            if (note != null && index == state.items.length) {
              return Padding(
                padding: edgeInsetsL12T4R12B4,
                child: Text(note, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
              );
            }
            return footer;
          },
        );
      },
    );
  }
}
