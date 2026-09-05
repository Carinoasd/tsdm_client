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
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

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

  /// Use [Divider] instead of [SizedBox] between list items.
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

    return SuperSliverList.separated(
      listController: _listController,
      itemCount: widget.postList.length,
      itemBuilder: (context, index) {
        final post = widget.postList[index];
        final card = widget.widgetBuilder(context, post);
        return post.postID == '${widget.initialPostID}' ? KeyedSubtree(key: _initialPostKey, child: card) : card;
      },
      separatorBuilder: (context, index) => widget.useDivider ? const Divider(thickness: 0.5) : sizedBoxW4H4,
    );
  }

  @override
  Widget build(BuildContext context) {
    _refreshController.finishLoad();

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
      onLoad: () async {
        if (!mounted) {
          return;
        }
        if (!widget.canLoadMore) {
          showNoMoreSnackBar(context);
          _refreshController.finishLoad();
          return;
        }
        context.read<ThreadBloc>().add(ThreadLoadMoreRequested(context.read<JumpPageCubit>().state.currentPage + 1));
      },
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
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: edgeInsetsL12T4R12B4,
                      child: OperationLogCard(latestAction: widget.latestModAct!, tid: widget.threadID!),
                    ),
                  ),
                ),
              SliverPadding(
                padding: edgeInsetsL12T4R12B4,
                sliver: SliverToBoxAdapter(
                  child: Text(widget.title ?? '', style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
              _buildPostList(),
            ],
          ),
        );
      },
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
