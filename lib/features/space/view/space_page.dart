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
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/widgets/space_social_widgets.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
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
  album,

  /// The wall.
  wall
  ;

  /// The tab named [name] (`blog`, `album`, `wall`), the blogs by default.
  static SpaceTab of(String? name) => values.where((e) => e.name == name).firstOrNull ?? blog;
}

/// The blogs, the albums and the wall of the member [uid], a tab each.
///
/// The member's own space offers to post a blog and to upload pictures; the wall offers to write a message to whom
/// the forum prints its message box, and on each message the forum's own reply and delete.
class SpacePage extends StatefulWidget {
  /// Constructor.
  const SpacePage({required this.uid, this.username, this.initialTab = SpaceTab.blog, this.wallCid, super.key});

  /// The member; 0 for the account in use.
  final int uid;

  /// Their name, for the title.
  final String? username;

  /// The tab shown first.
  final SpaceTab initialTab;

  /// The wall shows this message only (the link of a wall notice), until all the messages are asked for.
  final int? wallCid;

  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final SpaceListCubit<SpaceBlog> _blogs;
  late final SpaceListCubit<SpaceAlbum> _albums;
  late SpaceListCubit<SpaceBlogComment> _wall;
  late int? _wallCid = widget.wallCid;

  /// The member; the account in use for a link without one (`home.php?mod=space&do=wall`).
  late final int _uid = widget.uid > 0 ? widget.uid : context.read<AuthenticationRepository>().currentUser?.uid ?? 0;

  /// The account changes: the owner's actions follow the account in use.
  StreamSubscription<AuthStatus>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: SpaceTab.values.length, vsync: this, initialIndex: widget.initialTab.index)
      ..addListener(() => setState(() {}));
    const repo = SpaceRepository();
    _blogs = SpaceListCubit<SpaceBlog>(
      firstPageUrl: spaceBlogListUrl(_uid),
      fetch: repo.fetchBlogList,
      keyOf: (e) => e.blogId,
    );
    _albums = SpaceListCubit<SpaceAlbum>(
      firstPageUrl: spaceAlbumListUrl(_uid),
      fetch: repo.fetchAlbumList,
      keyOf: (e) => e.albumId,
    );
    _wall = _wallCubit();
    unawaited(_blogs.load());
    unawaited(_albums.load());
    unawaited(_wall.load());
    _authSubscription = context.read<AuthenticationRepository>().status.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _tabController.dispose();
    unawaited(_blogs.close());
    unawaited(_albums.close());
    unawaited(_wall.close());
    super.dispose();
  }

  SpaceListCubit<SpaceBlogComment> _wallCubit() => SpaceListCubit<SpaceBlogComment>(
    firstPageUrl: spaceWallUrl(_uid, cid: _wallCid),
    fetch: const SpaceRepository().fetchWall,
    keyOf: (e) => e.cid,
  );

  /// The whole wall, after the one message of a notice.
  void _showWholeWall() {
    final old = _wall;
    setState(() {
      _wallCid = null;
      _wall = _wallCubit();
    });
    unawaited(old.close());
    unawaited(_wall.load());
  }

  Future<void> _writeOnWall(SpaceSession session, {SpaceBlogComment? replyTo}) async {
    // A wall opened without its member is the account's own: the one its page was served to.
    final owner = _uid > 0 ? _uid : session.uid;
    if (await showWallMessageDialog(context, session: session, ownerUid: owner, replyTo: replyTo) && mounted) {
      unawaited(_wall.refresh());
    }
  }

  Future<void> _deleteFromWall(SpaceSession session, SpaceBlogComment comment) async {
    if (await deleteWallMessage(context, session: session, comment: comment) && mounted) {
      unawaited(_wall.refresh());
    }
  }

  Widget _wallTile(BuildContext context, SpaceListState<SpaceBlogComment> state, SpaceBlogComment comment) {
    final session = state.session;
    return AppSurface(
      child: SpaceBlogCommentTile(
        comment,
        trailing: session == null || !(comment.canReply || comment.canDelete)
            ? null
            : WallMessageActions(
                onReply: comment.canReply ? () async => _writeOnWall(session, replyTo: comment) : null,
                onDelete: comment.canDelete ? () async => _deleteFromWall(session, comment) : null,
              ),
      ),
    );
  }

  bool get _own => context.read<AuthenticationRepository>().currentUser?.uid == _uid;

  Future<void> _write() async {
    final path = switch (SpaceTab.values[_tabController.index]) {
      SpaceTab.blog => ScreenPaths.spaceBlogPost,
      SpaceTab.album => ScreenPaths.spaceAlbumUpload,
      SpaceTab.wall => null,
    };
    if (path == null) return;
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
        title: Text(
          widget.username ??
              switch (tab) {
                SpaceTab.blog => tr.blogs,
                SpaceTab.album => tr.albums,
                SpaceTab.wall => tr.wall.title,
              },
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: tr.blogs),
            Tab(text: tr.albums),
            Tab(text: tr.wall.title),
          ],
        ),
      ),
      // Follows the account in use: another account's space offers nothing to write; a wall offers to whom the forum
      // printed its message box, on the account its page was served to.
      floatingActionButton: tab == SpaceTab.wall
          ? BlocBuilder<SpaceListCubit<SpaceBlogComment>, SpaceListState<SpaceBlogComment>>(
              bloc: _wall,
              builder: (context, state) => switch (state.session) {
                final session? when state.canPost && state.status == SpaceLoadStatus.success => FloatingActionButton(
                  tooltip: tr.wall.post,
                  onPressed: () async => _writeOnWall(session),
                  child: const Icon(Icons.edit_note_outlined),
                ),
                _ => const SizedBox.shrink(),
              },
            )
          : _own
          ? FloatingActionButton(
              tooltip: tab == SpaceTab.blog ? tr.newBlog : tr.upload,
              onPressed: _write,
              child: Icon(tab == SpaceTab.blog ? Icons.edit_outlined : Icons.add_photo_alternate_outlined),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            BlocProvider.value(
              value: _blogs,
              child: SpaceListView<SpaceBlog>(
                emptyIcon: Icons.article_outlined,
                emptyMessage: tr.emptyBlogs,
                itemBuilder: (context, blog) => SpaceBlogCard(blog),
              ),
            ),
            BlocProvider.value(
              value: _albums,
              child: SpaceListView<SpaceAlbum>(
                emptyIcon: Icons.photo_library_outlined,
                emptyMessage: tr.emptyAlbums,
                grid: true,
                itemBuilder: (context, album) => SpaceAlbumTile(album),
              ),
            ),
            BlocProvider.value(
              value: _wall,
              child: BlocListener<SpaceListCubit<SpaceBlogComment>, SpaceListState<SpaceBlogComment>>(
                listenWhen: (prev, curr) => curr.status == SpaceLoadStatus.notice && prev.status != curr.status,
                listener: (context, state) {
                  if (spaceModuleSwitchedOff(state.message)) markSpaceModuleOff(SpaceModule.wall);
                },
                child: SpaceListView<SpaceBlogComment>(
                  key: ValueKey(_wall),
                  emptyIcon: Icons.forum_outlined,
                  emptyMessage: tr.wall.empty,
                  itemBuilder: (context, comment) =>
                      _wallTile(context, context.read<SpaceListCubit<SpaceBlogComment>>().state, comment),
                  footer: _wallCid == null
                      ? null
                      : Center(
                          child: TextButton.icon(
                            onPressed: _showWholeWall,
                            icon: const Icon(Icons.forum_outlined),
                            label: Text(tr.wall.all),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of the space ([SpaceListCubit] above it), refreshed by pulling down, the next page loaded at its end.
class SpaceListView<T> extends StatefulWidget {
  /// Constructor.
  const SpaceListView({
    required this.emptyIcon,
    required this.emptyMessage,
    required this.itemBuilder,
    this.grid = false,
    this.footer,
    super.key,
  });

  /// Icon of the empty list.
  final IconData emptyIcon;

  /// Words of the empty list.
  final String emptyMessage;

  /// An item.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Tiles in a grid (the albums) rather than cards in a column.
  final bool grid;

  /// After the items (and the note), before the loading footer.
  final Widget? footer;

  @override
  State<SpaceListView<T>> createState() => _SpaceListViewState<T>();
}

class _SpaceListViewState<T> extends State<SpaceListView<T>> with AutomaticKeepAliveClientMixin {
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
              ?widget.footer,
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
        final extra = [
          if (note != null)
            Padding(
              padding: edgeInsetsL12T4R12B4,
              child: Text(
                context.displayText(note),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ?widget.footer,
          footer,
        ];
        return ListView.separated(
          padding: padding,
          itemCount: state.items.length + extra.length,
          separatorBuilder: (_, _) => const SizedBox(height: appSurfaceGapCompact),
          itemBuilder: (context, index) => index < state.items.length
              ? widget.itemBuilder(context, state.items[index])
              : extra[index - state.items.length],
        );
      },
    );
  }
}
