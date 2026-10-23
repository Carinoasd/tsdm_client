import 'dart:async';
import 'dart:core';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/widgets/floor_layout.dart';
import 'package:tsdm_client/features/thread/v1/widgets/operation_log_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// How far from an end of the floors the page beyond it is asked for, in heights of the list: far enough that
/// scrolling at a reading pace never reaches the end before the page is there.
const threadPrefetchViewports = 1.5;

/// The page beyond an end of the floors is asked for as well once a floor this close to that end is on screen (short
/// floors are guessed taller than they are before they are laid out, see [_estimatedFloorExtent]).
const threadPrefetchFloors = 6;

/// Height a floor is guessed to have before it is laid out.
const _estimatedFloorExtent = 240.0;

/// Told the floor at the top of the list ([post]) whenever it changes or the list settles; [atThreadTop] when the
/// list shows the start of the thread (its first page, scrolled less than a screen into it).
typedef TopFloorCallback = void Function(Post post, {required bool atThreadTop});

/// The floors of a thread, read on and on: the page after the last one is asked for before the end is reached, the
/// page before the first one when scrolled up to it, and either is put in place without moving what is on screen.
///
/// The list is opened at the first floor of [postList] (the page opened, a floor scrolled to): pages put above it grow
/// up from there, pages after it grow down, see [FloorLayout]. Floors dropped from the pages kept by the thread page
/// ([threadWindowPages]) leave empty places that keep the floors on screen where they are.
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
    this.generation = 0,
    this.firstPage = 1,
    this.lastPage,
    this.nextStatus = ThreadEdgeStatus.idle,
    this.previousStatus = ThreadEdgeStatus.idle,
    this.scrollTargetPid,
    this.scrollTargetSerial = 0,
    this.endOfThread,
    this.newestFirst = false,
    this.onTopFloorChanged,
    this.onLoadNext,
    this.onLoadPrevious,
    this.onRefresh,
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

  /// [ThreadState.generation] of [postList]: a new one starts the list over.
  final int generation;

  /// The first page of [postList]: above it the thread goes on.
  final int firstPage;

  /// The last page of [postList], null when not known.
  final int? lastPage;

  /// The page after the last one.
  final ThreadEdgeStatus nextStatus;

  /// The page before the first one.
  final ThreadEdgeStatus previousStatus;

  /// A floor to bring into view, once per [scrollTargetSerial].
  final String? scrollTargetPid;

  /// See [scrollTargetPid].
  final int scrollTargetSerial;

  /// Shown after the last floor of the thread ([canLoadMore] false): "the last floor" by default.
  final Widget? endOfThread;

  /// The floors are shown newest first: the end of the list is the oldest floor.
  final bool newestFirst;

  /// See [TopFloorCallback].
  final TopFloorCallback? onTopFloorChanged;

  /// Ask for the page after the last one; the thread page's [ThreadBloc] above by default.
  final VoidCallback? onLoadNext;

  /// Ask for the page before the first one; the thread page's [ThreadBloc] above by default.
  final VoidCallback? onLoadPrevious;

  /// Pulled down at the start of the thread; the thread page's [ThreadBloc] above by default.
  final VoidCallback? onRefresh;

  @override
  State<PostList> createState() => PostListState();
}

/// State of [PostList].
class PostListState extends State<PostList> with LoggerMixin {
  /// [ScrollController] comes from outside.
  ///
  /// Note that this class does NOT own the scroll controller.
  ///
  /// Do NOT dispose it here.
  ///
  // ignore: dispose_controllers
  late ScrollController _listScrollController;

  /// The floors above the opening place, growing up.
  final _aboveController = ListController();

  /// The floors from the opening place down.
  final _belowController = ListController();

  /// The sliver the zero offset of the list is at: the first floor it was opened with.
  static const ValueKey<String> _belowKey = ValueKey('thread-floors-below');

  final _layout = FloorLayout();

  /// Marks the card of the floor scrolled to so it can be kept in view while the freshly built list settles, see
  /// [_scrollToTarget].
  final GlobalKey _initialPostKey = GlobalKey();

  /// Key of the slot carrying [_initialPostKey].
  String? _targetKey;
  Timer? _holdTimer;
  int _holdCorrections = 0;

  int _targetSerial = 0;

  /// The user scrolled up at least once: the page before is asked for only then, not right when a page in the middle
  /// of the thread is opened.
  bool _scrolledUp = false;

  bool _checkScheduled = false;

  /// Current page number
  int pageNumber = 1;

  /// Whether the list shows every floor from the start of the thread: none above was dropped and the first page is
  /// on screen. "Back to top" scrolls up only then; otherwise the thread is opened at its start again.
  bool get startsAtThreadTop => widget.firstPage <= 1 && !_layout.hasDropped;

  @override
  void initState() {
    super.initState();
    _listScrollController = widget.scrollController;
    _layout.layOut(widget.postList, widget.generation);
    _targetSerial = widget.scrollTargetSerial;
    final target = widget.scrollTargetPid ?? widget.initialPostID?.toString();
    _targetKey = target == null ? null : _keyOfPid(target);
    if (_targetKey != null) {
      // Scroll to post, if any.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTarget());
    } else {
      // Opened at the floors' start (or the floor asked for is not among them): the title above them shows too.
      _showStart();
    }
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(PostList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.postList, widget.postList) || oldWidget.generation != widget.generation) {
      final generation = _layout.generation;
      _layout.layOut(widget.postList, widget.generation);
      if (generation != _layout.generation) {
        // Started over without being built anew.
        _targetKey = null;
        _showStart();
      }
    }
    if (widget.scrollTargetSerial != _targetSerial) {
      _targetSerial = widget.scrollTargetSerial;
      final target = widget.scrollTargetPid;
      if (target != null) {
        _targetKey = _keyOfPid(target);
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTarget());
      }
    }
    _scheduleCheck();
  }

  /// Key of the slot of the floor with [pid]: the floor where it is rather than its copy as a hot reply.
  String? _keyOfPid(String pid) {
    for (final key in ['floor:$pid', 'hot:$pid']) {
      if (_layout.belowItemIndexOf(key) != null || _layout.aboveItemIndexOf(key) != null) {
        return key;
      }
    }
    return null;
  }

  /// Show the start of the floors (the title above them) on the next layout.
  void _showStart() {
    final controller = _listScrollController;
    if (controller is ThreadScrollController) {
      controller.alignToStartOnNextLayout();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && controller.hasClients && controller.position.hasContentDimensions) {
        controller.jumpTo(controller.position.minScrollExtent);
      }
    });
  }

  /// Scroll to the floor of [_targetKey] and hold it there while the list settles.
  ///
  /// Right after a thread (re)load the list is built from estimated extents: avatars, medals and attachments are
  /// still loading and `super_sliver_list` keeps correcting the scroll offset while real extents replace the
  /// estimates, so the post we just revealed drifts away (up to the top of the page once the offset gets clamped).
  /// The list's own `animateToItem` also aims at the item's raw offset, which lies past the end for the last post.
  ///
  /// So: jump to the post with the list's offset of it, then for about two seconds re-align its card with the exact,
  /// range-clamped offset from the viewport every 100 ms. The hold ends as soon as the user touches the list.
  Future<void> _scrollToTarget() async {
    final key = _targetKey;
    if (!mounted || key == null || !_listScrollController.hasClients) {
      return;
    }
    // Rebuilt with the key on the floor first.
    setState(() {});
    final below = _layout.belowItemIndexOf(key);
    final above = _layout.aboveItemIndexOf(key);
    debug('scroll to $key: below=$below above=$above');
    final ListController controller;
    final int index;
    if (below != null && _belowController.isAttached) {
      (controller, index) = (_belowController, below);
    } else if (above != null && _aboveController.isAttached) {
      (controller, index) = (_aboveController, above);
    } else {
      return;
    }
    // A jump, not the list's `animateToItem`: its animation is nobody's to stop and kept ticking on a list already
    // gone (the page left right after opening at a floor), throwing on every frame (GitHub #235). The hold below
    // keeps the floor in place from here.
    controller.jumpToItem(index: index, scrollController: _listScrollController, alignment: 0);
    // The offset of the item is its raw one, past the end for the last floors: kept within the scroll range in the
    // same frame, so nothing past the end (a blank) is ever painted. (`ListController.getOffsetToReveal` would give
    // it first, but is only for tests.)
    if (_listScrollController.hasClients) {
      final position = _listScrollController.position;
      if (position.hasContentDimensions) {
        final clamped = position.pixels.clamp(position.minScrollExtent, position.maxScrollExtent);
        if (clamped != position.pixels) {
          position.jumpTo(clamped);
        }
      }
    }
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

  /// Put the card of the target post at the top of the viewport (or as close as the ends of the list allow).
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

  /// End the hold started by [_scrollToTarget]: the settle window passed or the user took over.
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

  void _loadNext() {
    if (widget.onLoadNext case final onLoadNext?) {
      onLoadNext();
      return;
    }
    final bloc = context.readOrNull<ThreadBloc>();
    if (bloc != null && !bloc.isClosed) {
      // The page after the last one loaded, not after the one in view: scrolled back up into an earlier page, the next
      // page of that one was loaded a second time.
      bloc.add(ThreadLoadMoreRequested(bloc.state.currentPage + 1));
    }
  }

  void _loadPrevious() {
    if (widget.onLoadPrevious case final onLoadPrevious?) {
      onLoadPrevious();
      return;
    }
    final bloc = context.readOrNull<ThreadBloc>();
    if (bloc != null && !bloc.isClosed) {
      bloc.add(const ThreadLoadPreviousRequested());
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    // The user scrolling towards the start of the floors (a drag, a fling, a mouse wheel), not the list placing itself.
    if (notification is UserScrollNotification && notification.direction == ScrollDirection.forward) {
      _scrolledUp = true;
    }
    _scheduleCheck();
    return false;
  }

  /// Look at the ends of the list and the floor on top after the next frame.
  void _scheduleCheck() {
    if (_checkScheduled) {
      return;
    }
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) {
        return;
      }
      _checkEdges();
      _reportTopFloor();
    });
  }

  /// Ask for the page beyond an end of the floors once that end is less than [threadPrefetchViewports] away.
  void _checkEdges() {
    if (!_listScrollController.hasClients || widget.postList.isEmpty) {
      return;
    }
    final position = _listScrollController.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final reach = position.viewportDimension * threadPrefetchViewports;
    if (widget.canLoadMore &&
        widget.nextStatus == ThreadEdgeStatus.idle &&
        (position.extentAfter < reach || _nearLastFloor())) {
      _loadNext();
    }
    if (widget.firstPage > 1 &&
        widget.previousStatus == ThreadEdgeStatus.idle &&
        _scrolledUp &&
        (_extentAboveFloors(position) < reach || _nearFirstFloor())) {
      _loadPrevious();
    }
  }

  /// Whether a floor among the last [threadPrefetchFloors] is on screen.
  bool _nearLastFloor() {
    final below = _belowController.isAttached ? _belowController.visibleRange : null;
    if (below != null) {
      return below.$2 >= _layout.below.length - threadPrefetchFloors;
    }
    // Only floors above the opening place on screen: the floors after them are below, all of them.
    return _layout.below.where((e) => !e.isDropped).length < threadPrefetchFloors &&
        _aboveController.isAttached &&
        (_aboveController.visibleRange?.$1 ?? _layout.above.length) < threadPrefetchFloors;
  }

  /// Whether a floor among the first [threadPrefetchFloors] is on screen.
  bool _nearFirstFloor() {
    final above = _aboveController.isAttached ? _aboveController.visibleRange : null;
    if (above != null) {
      return above.$2 >= _layout.above.length - threadPrefetchFloors;
    }
    final below = _belowController.isAttached ? _belowController.visibleRange : null;
    if (below == null || _layout.above.any((e) => !e.isDropped)) {
      return false;
    }
    final dropped = _layout.below.takeWhile((e) => e.isDropped).length;
    return below.$1 < dropped + threadPrefetchFloors;
  }

  /// How far the top of the list is above the viewport, without the empty places of dropped floors that were not laid
  /// out again since (they still count with the height they had).
  double _extentAboveFloors(ScrollPosition position) {
    var before = position.extentBefore;
    if (position.pixels > 0 && _belowController.isAttached) {
      var dropped = 0.0;
      for (var i = 0; i < _layout.below.length && _layout.below[i].isDropped; i++) {
        dropped += _belowController.extentForIndex(i).$1;
      }
      before -= math.min(dropped, position.pixels);
    }
    return before;
  }

  /// Tell the floor at the top of the list (the page indicator, the reading position).
  void _reportTopFloor() {
    Post? top;
    final above = _aboveController.isAttached ? _aboveController.visibleRange : null;
    if (above != null) {
      for (var i = math.min(above.$2, _layout.above.length - 1); i >= above.$1 && i >= 0; i--) {
        if (_layout.aboveItem(i).post case final post?) {
          top = post;
          break;
        }
      }
    }
    final below = _belowController.isAttached ? _belowController.visibleRange : null;
    if (top == null && below != null) {
      for (var i = math.max(below.$1, 0); i <= below.$2 && i < _layout.below.length; i++) {
        if (_layout.below[i].post case final post?) {
          top = post;
          break;
        }
      }
    }
    if (top == null) {
      return;
    }
    if (top.page != pageNumber) {
      pageNumber = top.page;
      //  Current page changes.
      context.readOrNull<JumpPageCubit>()?.setPageInfo(currentPage: top.page);
    }
    final position = _listScrollController.hasClients ? _listScrollController.position : null;
    final atThreadTop =
        startsAtThreadTop &&
        position != null &&
        position.hasViewportDimension &&
        position.hasContentDimensions &&
        position.extentBefore < position.viewportDimension;
    widget.onTopFloorChanged?.call(top, atThreadTop: atThreadTop);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _aboveController.dispose();
    _belowController.dispose();
    super.dispose();
  }

  /// Height a floor is guessed to have before it is laid out; an empty place has none.
  double _estimate(FloorSlot? slot) => slot == null || slot.isDropped ? 0 : _estimatedFloorExtent;

  Widget _buildSlot(BuildContext context, FloorSlot slot) {
    final post = slot.post;
    if (post == null) {
      // A dropped floor: its place stays, without height.
      return SizedBox.shrink(key: ValueKey(slot.key));
    }
    Widget card = _FloorSurface(child: widget.widgetBuilder(context, post));
    // Adding or removing the key is a structural change: that floor is rebuilt into a new element on the next build
    // after the floor scrolled to changes. A card must therefore not rely on its own `context` across an async gap
    // that may span such a rebuild; the edit flow takes what it needs before opening the editor (GitHub #76).
    if (slot.key == _targetKey) {
      card = KeyedSubtree(key: _initialPostKey, child: card);
    }
    return KeyedSubtree(
      key: ValueKey(slot.key),
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.useDivider ? 8 : 4),
        child: _layout.pageStarts.contains(slot.key)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  PageDivider(page: post.page),
                  card,
                ],
              )
            : card,
      ),
    );
  }

  List<Widget> _buildSlivers(BuildContext context) {
    final side = MediaQuery.sizeOf(context).width < 600 ? 6.0 : 16.0;
    return [
      // Above the opening place, top to bottom; laid out upwards from it.
      if (widget.latestModAct != null && widget.latestModAct!.isNotEmpty && widget.threadID != null)
        SliverToBoxAdapter(
          // Same column and side room as the floors below it.
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 8, side, 0),
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
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, height: 1.35),
              ),
            ),
          ),
        ),
      ),
      if (widget.firstPage > 1)
        SliverToBoxAdapter(
          child: _EdgeLoader(
            key: const ValueKey('thread-previous-page'),
            previous: true,
            page: widget.firstPage - 1,
            status: widget.previousStatus,
            onLoad: _loadPrevious,
            // Asked for once the user scrolls up to it; the button for when that is not enough.
            idleLabel: t.threadPage.loadPage(page: widget.firstPage - 1),
          ),
        ),
      SuperSliverList.builder(
        listController: _aboveController,
        itemCount: _layout.above.length,
        itemBuilder: (context, index) => _buildSlot(context, _layout.aboveItem(index)),
        findChildIndexCallback: (key) => key is ValueKey<String> ? _layout.aboveItemIndexOf(key.value) : null,
        extentEstimation: (index, _) =>
            index == null ? 0 : _estimate(index < _layout.above.length ? _layout.aboveItem(index) : null),
        // A floor is built again when scrolled back to (its content kept apart, see MunchedHtml), never kept alive
        // off screen: a long thread kept every floor it went through.
        addAutomaticKeepAlives: false,
      ),
      SuperSliverList.builder(
        key: _belowKey,
        listController: _belowController,
        itemCount: _layout.below.length,
        itemBuilder: (context, index) => _buildSlot(context, _layout.below[index]),
        findChildIndexCallback: (key) => key is ValueKey<String> ? _layout.belowItemIndexOf(key.value) : null,
        extentEstimation: (index, _) =>
            index == null ? 0 : _estimate(index < _layout.below.length ? _layout.below[index] : null),
        addAutomaticKeepAlives: false,
      ),
      if (widget.postList.isNotEmpty)
        SliverToBoxAdapter(
          child: widget.canLoadMore
              ? _EdgeLoader(
                  key: const ValueKey('thread-next-page'),
                  page: (widget.lastPage ?? widget.firstPage) + 1,
                  status: widget.nextStatus,
                  onLoad: _loadNext,
                  // Asked for by itself before it is reached; the button for when it is not.
                  idleLabel: t.threadPage.loadPage(page: (widget.lastPage ?? widget.firstPage) + 1),
                )
              // On the last page there is nothing to pull: the end of the list says so.
              : widget.endOfThread ?? _LastFloorFooter(newestFirst: widget.newestFirst),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // No scroll bar: the list grows at both ends and the bar would jump with every page put above.
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: RefreshIndicator(
        // At the start of the thread only: above a page in the middle the pull goes on to the page before.
        notificationPredicate: (notification) => notification.depth == 0 && widget.firstPage <= 1,
        onRefresh: () async {
          if (!mounted) {
            return;
          }
          if (widget.onRefresh case final onRefresh?) {
            onRefresh();
            return;
          }
          context.readOrNull<ThreadBloc>()?.add(ThreadRefreshRequested());
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Listener(
            // The user taking over ends the settle hold of [_scrollToTarget].
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _stopHold(),
            child: CustomScrollView(
              controller: _listScrollController,
              center: _belowKey,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: _buildSlivers(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scroll controller of the thread page's list: positions that can show the start of the list (its minimum
/// offset: the list's zero offset is at its first floor, the title is above it) on their next layout, before anything
/// is painted at the zero offset.
class ThreadScrollController extends ScrollController {
  /// Constructor. The list places itself: no offset kept in the page storage.
  ThreadScrollController() : super(keepScrollOffset: false);

  bool _alignToStart = false;

  /// Show the start of the list on its next layout (the floors of a list built anew, or replaced, are laid out
  /// right after).
  void alignToStartOnNextLayout() => _alignToStart = true;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _ThreadScrollPosition(
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
        controller: this,
      );
}

class _ThreadScrollPosition extends ScrollPositionWithSingleContext {
  _ThreadScrollPosition({
    required super.physics,
    required super.context,
    required this.controller,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final ThreadScrollController controller;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    if (!applied || !controller._alignToStart) {
      return applied;
    }
    controller._alignToStart = false;
    if ((pixels - minScrollExtent).abs() < 0.01) {
      return true;
    }
    // Laid out again from the start before it is painted.
    correctPixels(minScrollExtent);
    return false;
  }
}

/// A page boundary in the list: "page N" between the last floor of a page and the first one of the next.
class PageDivider extends StatelessWidget {
  /// Constructor.
  const PageDivider({required this.page, super.key});

  /// The page beginning below.
  final int page;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    final line = Expanded(child: Divider(color: Theme.of(context).colorScheme.outlineVariant, height: 1));
    return Padding(
      key: ValueKey('thread-page-divider-$page'),
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              // The global translations: they need no TranslationProvider above the list.
              t.threadPage.pageDivider(page: page),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
          line,
        ],
      ),
    );
  }
}

/// The end of the floors where a page is loaded: its loading, a failure to retry, or (before it is asked) a button.
class _EdgeLoader extends StatelessWidget {
  const _EdgeLoader({
    required this.page,
    required this.status,
    required this.onLoad,
    this.idleLabel,
    this.previous = false,
    super.key,
  });

  final int page;

  /// Whether the page is the one before the floors.
  final bool previous;

  final ThreadEdgeStatus status;

  final VoidCallback onLoad;

  /// The button to ask for the page before it is asked by itself; a loading row when null.
  final String? idleLabel;

  @override
  Widget build(BuildContext context) {
    final tr = t.threadPage;
    final color = Theme.of(context).colorScheme.outline;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: color);
    final Widget child;
    switch (status) {
      case ThreadEdgeStatus.failed:
        child = Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(tr.pageLoadFailed(page: page), style: style),
            TextButton.icon(onPressed: onLoad, icon: const Icon(Icons.refresh_outlined), label: Text(t.general.retry)),
          ],
        );
      case ThreadEdgeStatus.idle when idleLabel != null:
        // No spinner before it is asked: nothing turns while nothing loads.
        child = TextButton.icon(
          onPressed: onLoad,
          icon: Icon(previous ? Icons.expand_less_outlined : Icons.expand_more_outlined),
          label: Text(idleLabel!),
        );
      case ThreadEdgeStatus.idle || ThreadEdgeStatus.loading:
        child = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            sizedBoxW8H8,
            Flexible(
              child: Text(tr.loadingPage(page: page), style: style),
            ),
          ],
        );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Center(child: child),
    );
  }
}

/// The end of the floors on the last page of the thread.
class _LastFloorFooter extends StatelessWidget {
  const _LastFloorFooter({required this.newestFirst});

  /// The floors are shown newest first.
  final bool newestFirst;

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
              // The global translations: they need no TranslationProvider above the list. Newest first, the end of
              // the list is the oldest floor.
              newestFirst ? t.threadPage.firstFloorReached : t.threadPage.lastFloorReached,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The end of the thread: how many floors it has, a reply to it, and the floors posted since the last page was
/// loaded.
class ThreadEndCard extends StatelessWidget {
  /// Constructor.
  const ThreadEndCard({
    required this.floors,
    required this.status,
    this.newestFirst = false,
    this.onReply,
    this.onLoadNewReplies,
    super.key = const ValueKey('thread-last-floor-footer'),
  });

  /// Floors of the thread, null when not known.
  final int? floors;

  /// The floors are shown newest first: the end of the list is the oldest floor.
  final bool newestFirst;

  /// Asking for new replies ([ThreadState.nextStatus]).
  final ThreadEdgeStatus status;

  /// Open the reply bar; null where the account cannot reply.
  final VoidCallback? onReply;

  /// Ask the last page again; null where new replies are not at the end (newest floors first, offline).
  final VoidCallback? onLoadNewReplies;

  @override
  Widget build(BuildContext context) {
    final tr = t.threadPage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final side = MediaQuery.sizeOf(context).width < 600 ? 6.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 8, side, 24),
      child: AppContentWidth(
        maxWidth: appReadingMaxWidth,
        child: Card(
          margin: EdgeInsets.zero,
          shape: appSurfaceShape(context),
          color: colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    Icon(Icons.check_circle_outline, size: 18, color: colorScheme.outline),
                    Text(
                      newestFirst ? tr.firstFloorReached : tr.lastFloorReached,
                      style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
                    ),
                    if (floors case final floors? when floors > 0) ...[
                      Text('·', style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline)),
                      Text(
                        tr.floorCount(count: floors),
                        key: const ValueKey('thread-floor-count'),
                        style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
                      ),
                    ],
                  ],
                ),
                if (status == ThreadEdgeStatus.failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(tr.newRepliesFailed, style: textTheme.bodySmall?.copyWith(color: colorScheme.error)),
                  ),
                if (onReply != null || onLoadNewReplies != null) ...[
                  sizedBoxW8H8,
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (onReply != null)
                        FilledButton.tonalIcon(
                          key: const ValueKey('thread-end-reply'),
                          onPressed: onReply,
                          icon: const Icon(Icons.reply_outlined),
                          label: Text(tr.sendReplyHint),
                        ),
                      if (onLoadNewReplies != null)
                        OutlinedButton.icon(
                          key: const ValueKey('thread-end-new-replies'),
                          onPressed: status == ThreadEdgeStatus.loading ? null : onLoadNewReplies,
                          icon: status == ThreadEdgeStatus.loading
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.refresh_outlined),
                          label: Text(tr.loadNewReplies),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
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
