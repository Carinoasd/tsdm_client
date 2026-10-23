import 'dart:async';
import 'dart:core';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/widgets/operation_log_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A widget that retrieve data from network and supports refresh.
class PostList extends StatefulWidget {
  /// Constructor.
  const PostList({
    required this.threadID,
    required this.postList,
    required this.widgetBuilder,
    required this.canLoadMore,
    required this.scrollController,
    required this.latestModAct,
    this.title,
    this.pageNumber = 1,
    this.useDivider = false,
    this.initialPostID,
    super.key,
  });

  /// Thread title.
  final String? title;

  /// Fetch page number "&page=[pageNumber]".
  final int pageNumber;

  /// Thread ID.
  final String? threadID;

  /// Build a list of [Widget].
  final Widget Function(BuildContext, Post) widgetBuilder;

  /// Floors are separate rounded surfaces; a wider gap between them when true, a thin one otherwise.
  final bool useDivider;

  /// List of [Post] content.
  final List<Post> postList;

  /// Flag indicating can load more pages in current post list.
  final bool canLoadMore;

  /// The [ScrollController] passed from outside.
  final ScrollController scrollController;

  /// Optional initial post id.
  ///
  /// Scroll to this post once page built.
  /// Useful in some "find post" situation.
  final int? initialPostID;

  /// Latest modification action.
  final String? latestModAct;

  @override
  State<PostList> createState() => _PostListState();
}

class _PostListState extends State<PostList> with LoggerMixin {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);

  /// [ScrollController] comes from outside.
  ///
  /// Note that this class does NOT own the scroll controller.
  ///
  /// FIXME: How to ensure controller lives longer than the class instance.
  ///
  /// Do NOT dispose it here.
  ///
  // ignore: dispose_controllers
  late ScrollController _listScrollController;

  late ListController _listController;

  /// Marks the card of [PostList.initialPostID] so it can be kept in view while the freshly built list settles, see
  /// [_scrollToInitialPost].
  final GlobalKey _initialPostKey = GlobalKey();
  Timer? _holdTimer;
  int _holdCorrections = 0;

  /// Current page number
  int pageNumber = 1;

  void _updatePageNumber() {
    final p = _listController.visibleRange?.$1;
    if (p != null) {
      // List forms through separator builder, divide 2 because of the separator
      // widget.
      final p2 = widget.postList[p ~/ 2].page;
      if (p2 != pageNumber) {
        pageNumber = p2;
        //  Current page changes.
        context.read<JumpPageCubit>().setPageInfo(currentPage: p2);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // Try use the thread type in widget which comes from routing.
    _listScrollController = widget.scrollController;
    _listController = ListController();
    _listController.addListener(_updatePageNumber);

    if (widget.initialPostID != null) {
      // Scroll to post, if any.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToInitialPost());
    }
  }

  /// Item index (separators included) of the post with [postID], null when it is not in the list.
  int? _itemIndexOf(int postID) {
    final id = '$postID';
    for (final (index, post) in widget.postList.indexed) {
      if (post.postID == id) {
        return index * 2;
      }
    }
    return null;
  }

  /// Scroll to [PostList.initialPostID] and hold it there while the list settles.
  ///
  /// Right after a thread (re)load the list is built from estimated extents: avatars, medals and attachments are
  /// still loading and `super_sliver_list` keeps correcting the scroll offset while real extents replace the
  /// estimates, so the post we just revealed drifts away (up to the top of the page once the offset gets clamped).
  /// The list's own `animateToItem` also aims at the item's raw offset, which lies past the end for the last post.
  ///
  /// So: approach the post with the list's estimate, then for about two seconds re-align its card with the exact,
  /// range-clamped offset from the viewport every 100 ms. The hold ends as soon as the user touches the list.
  Future<void> _scrollToInitialPost() async {
    if (!mounted || !_listScrollController.hasClients || !_listController.isAttached) {
      return;
    }
    debug('scroll to pid: ${widget.initialPostID}');
    final index = _itemIndexOf(widget.initialPostID!);
    if (index == null) {
      return;
    }
    debug('scroll to position: $index');
    _listController.animateToItem(
      index: index,
      scrollController: _listScrollController,
      alignment: 0,
      duration: (_) => duration200,
      curve: (_) => Curves.ease,
    );
    _holdCorrections = 0;
    _holdTimer?.cancel();
    var ticks = 0;
    _holdTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_listScrollController.hasClients || ++ticks > 20) {
        _stopHold();
        return;
      }
      _alignInitialPost();
    });
  }

  /// Put the card of the initial post at the top of the viewport (or as close as the end of the list allows).
  void _alignInitialPost() {
    final renderObject = _initialPostKey.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) {
      // Not built yet: the approach animation is still on its way.
      return;
    }
    final position = _listScrollController.position;
    final target = RenderAbstractViewport.of(
      renderObject,
    ).getOffsetToReveal(renderObject, 0).offset.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((position.pixels - target).abs() > 2) {
      _holdCorrections++;
      position.jumpTo(target);
    }
  }

  /// End the hold started by [_scrollToInitialPost]: the settle window passed or the user took over.
  void _stopHold() {
    if (_holdTimer == null) {
      return;
    }
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_holdCorrections > 0) {
      debug('scroll hold: re-aligned the post $_holdCorrections times');
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _refreshController.dispose();
    _listController
      ..removeListener(_updatePageNumber)
      ..dispose();
    super.dispose();
  }

  Widget _buildPostList() {
    if (widget.postList.isEmpty) {
      return sizedBoxEmpty;
    }

    // The first floor of that pid only: a hot reply is in the list twice when the first page and the page it is on
    // are both loaded (first as hot, then where it is), and the key may be on one of them.
    final initialIndex = widget.initialPostID == null
        ? -1
        : widget.postList.indexWhere((e) => e.postID == '${widget.initialPostID}');
    return SuperSliverList.separated(
      listController: _listController,
      itemCount: widget.postList.length,
      itemBuilder: (context, index) {
        final post = widget.postList[index];
        // Each floor paints into its own layer, so scrolling moves layers instead of repainting every card.
        final card = RepaintBoundary(child: _FloorSurface(child: widget.widgetBuilder(context, post)));
        // Adding or removing the key is a structural change: that floor is rebuilt into a new element on the next
        // build after `initialPostID` changes (the thread page drops its scroll target one frame after a reload). A
        // card must therefore not rely on its own `context` across an async gap that may span such a rebuild; the
        // edit flow takes what it needs before opening the editor (GitHub #76).
        return index == initialIndex ? KeyedSubtree(key: _initialPostKey, child: card) : card;
      },
      separatorBuilder: (context, index) => widget.useDivider ? sizedBoxW8H8 : sizedBoxW4H4,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The bloc reloads the thread and this list is rebuilt with the result: both indicators are done by then. The
    // refresh one used to be left "processing", so after a pull to refresh a blank of its height stayed above the
    // title (feedback 113).
    _refreshController
      ..finishRefresh()
      ..finishLoad();

    return EasyRefresh.builder(
      scrollBehaviorBuilder: (physics) {
        // Should use ERScrollBehavior instead of
        // ScrollConfiguration.of(context)
        return ERScrollBehavior(physics).copyWith(physics: physics, scrollbars: false);
      },
      header: const MaterialHeader(position: IndicatorPosition.locator),
      footer: const MaterialFooter(),
      controller: _refreshController,
      scrollController: _listScrollController,
      onRefresh: () async {
        if (!mounted) {
          return;
        }
        context.read<ThreadBloc>().add(ThreadRefreshRequested());
      },
      // On the last page there is nothing to pull: the end of the list says so ([_LastFloorFooter]) instead of a snack
      // bar at every pull.
      onLoad: widget.canLoadMore
          ? () async {
              if (!mounted) {
                return;
              }
              // The page after the last one loaded, not after the one in view: scrolled back up into an earlier page,
              // the next page of that one was loaded a second time.
              context.read<ThreadBloc>().add(ThreadLoadMoreRequested(context.read<ThreadBloc>().state.currentPage + 1));
            }
          : null,
      childBuilder: (context, physics) {
        return Listener(
          // The user taking over ends the settle hold of [_scrollToInitialPost].
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _stopHold(),
          child: CustomScrollView(
            physics: physics,
            controller: _listScrollController,
            slivers: [
              const HeaderLocator.sliver(),
              if (widget.latestModAct != null && widget.latestModAct!.isNotEmpty && widget.threadID != null)
                SliverToBoxAdapter(
                  // Same column and side room as the floors below it.
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      MediaQuery.sizeOf(context).width < 600 ? 6 : 16,
                      8,
                      MediaQuery.sizeOf(context).width < 600 ? 6 : 16,
                      0,
                    ),
                    child: AppContentWidth(
                      maxWidth: appReadingMaxWidth,
                      child: OperationLogCard(latestAction: widget.latestModAct!, tid: widget.threadID!),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: AppContentWidth(
                  maxWidth: appReadingMaxWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    // Full width: the column centres its child, so a short title used to sit in the middle while a
                    // long one wrapped from the left (feedback 113). Every title starts at the left.
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(
                        widget.title ?? '',
                        style: Theme.of(
                          context,
                        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, height: 1.35),
                      ),
                    ),
                  ),
                ),
              ),
              _buildPostList(),
              if (!widget.canLoadMore && widget.postList.isNotEmpty)
                const SliverToBoxAdapter(child: _LastFloorFooter()),
            ],
          ),
        );
      },
    );
  }
}

/// The end of the floors on the last page of the thread.
class _LastFloorFooter extends StatelessWidget {
  const _LastFloorFooter();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Padding(
      key: const ValueKey('thread-last-floor-footer'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: color),
          sizedBoxW4H4,
          Flexible(
            child: Text(
              // The global translations: they need no TranslationProvider above the list.
              t.threadPage.lastFloorReached,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A floor of the thread as a rounded surface, at most [appReadingMaxWidth] wide so lines stay readable on desktop.
class _FloorSurface extends StatelessWidget {
  const _FloorSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Phones keep most of the width for the text.
    final side = MediaQuery.sizeOf(context).width < 600 ? 6.0 : 16.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: side),
      child: AppContentWidth(
        maxWidth: appReadingMaxWidth,
        child: Card(margin: EdgeInsets.zero, shape: appSurfaceShape(context), child: child),
      ),
    );
  }
}

/// Delegate to build a persistent sliver app bar.
class SliverAppBarPersistentDelegate extends SliverPersistentHeaderDelegate {
  /// Constructor.
  const SliverAppBarPersistentDelegate({
    required this.buildHeader,
    required this.headerMaxExtent,
    required this.headerMinExtent,
  });

  /// Builder to build the app bar.
  final Widget Function(BuildContext, double, {required bool overlapsContent}) buildHeader;

  /// Max extent of top header.
  final double headerMaxExtent;

  /// Min extent of top header.
  final double headerMinExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return buildHeader(context, shrinkOffset, overlapsContent: overlapsContent);
  }

  @override
  double get maxExtent => headerMaxExtent;

  @override
  double get minExtent => headerMinExtent;

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) => true;
}
