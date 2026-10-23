import 'dart:math' as math;

import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/card/post_card/post_medal_menu_info.dart';
import 'package:universal_html/html.dart' as uh;

part 'thread_bloc.mapper.dart';
part 'thread_event.dart';
part 'thread_state.dart';

/// Emitter.
typedef ThreadEmitter = Emitter<ThreadState>;

/// Where the floors of a page just loaded go.
enum _Merge {
  /// They are the floors on screen now.
  replace,

  /// After the floors on screen (the next page, the last page asked again).
  append,

  /// Before the floors on screen (the page before the first one).
  prepend,
}

/// Bloc the thread page.
class ThreadBloc extends Bloc<ThreadEvent, ThreadState> with LoggerMixin {
  /// Constructor.
  ThreadBloc({
    required String? tid,
    required String? pid,
    required String? onlyVisibleUid,
    required bool? reverseOrder,
    required int? exactOrder,
    required ThreadRepository threadRepository,
    int? Function()? currentUid,
  }) : _threadRepository = threadRepository,
       _currentUid = currentUid ?? _requestAccountUid,
       super(
         ThreadState(
           tid: tid,
           pid: pid,
           onlyVisibleUid: onlyVisibleUid,
           reverseOrder: reverseOrder,
           exactOrder: exactOrder,
         ),
       ) {
    on<ThreadLoadMoreRequested>(_onThreadLoadMoreRequested);
    on<ThreadRefreshRequested>(_onThreadRefreshRequested);
    on<ThreadJumpPageRequested>(_onThreadJumpPageRequested);
    on<ThreadClosedStateUpdated>(_onThreadUpdateClosedState);
    on<ThreadOnlyViewAuthorRequested>(_onThreadOnlyViewAuthorRequested);
    on<ThreadViewAllAuthorsRequested>(_onThreadViewAllAuthorsRequested);
    on<ThreadChangeViewOrderRequested>(_onThreadChangeViewOrderRequested);
    on<ThreadLoadPreviousRequested>(_onThreadLoadPreviousRequested);
    on<ThreadLoadNewRepliesRequested>(_onThreadLoadNewRepliesRequested);
    on<ThreadJumpToFloorRequested>(_onThreadJumpToFloorRequested);
  }

  final ThreadRepository _threadRepository;

  /// The account the requests of the page go out as now, null for a guest ([ThreadState.floorsUid]).
  final int? Function() _currentUid;

  /// The account of the global cookie, the one every request of the page is sent as.
  static int? _requestAccountUid() =>
      getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null;

  /// The state of the load begun for account [uid] that failed with the floors [previousPosts] on screen before it
  /// ([changes] applied on top).
  ///
  /// The floors come back, with their offline mark, only when they were loaded for the same account. Floors of another
  /// account are dropped with everything else their page told (title, forum, reply form): a reload for the account in
  /// use after a switch or a removal must never leave the previous account's floors on screen, read back offline or
  /// not, when it fails (no network).
  ThreadState _failedState(int? uid, {List<Post>? previousPosts, ThreadState Function(ThreadState)? changes}) {
    final apply = changes ?? (ThreadState s) => s;
    if (state.floorsUid == uid) {
      return apply(
        state.copyWith(
          status: ThreadStatus.failure,
          postList: previousPosts ?? state.postList,
          nextStatus: ThreadEdgeStatus.idle,
          previousStatus: ThreadEdgeStatus.idle,
        ),
      );
    }
    debug('drop the floors of a previous account after a failed reload');
    return apply(
      ThreadState(
        tid: state.tid,
        pid: state.pid,
        onlyVisibleUid: state.onlyVisibleUid,
        reverseOrder: state.reverseOrder,
        exactOrder: state.exactOrder,
        status: ThreadStatus.failure,
        floorsUid: uid,
        generation: state.generation + 1,
      ),
    );
  }

  /// Number of the latest load that replaces the floors on screen: refresh, jump, only one author, all authors, order
  /// (the reload for another account is a refresh or a jump, see ThreadPage).
  ///
  /// The events are handled concurrently, so such a load may begin while an earlier one is still pending; the latest
  /// one supersedes it, and the result of a superseded load, success or failure, is dropped. Otherwise the earlier one
  /// still reached the page after the later one cleared it: after an account switch the request of the previous
  /// account ended (IdentityChangedException) once the reload for the new one had begun, put the old floors back with
  /// a "failed to load" message, and the new floors were appended to them, every floor twice (GitHub #184 follow-up).
  /// Load more appends to the floors of the load it began under, so it is dropped as well once a later one began.
  int _pageLoad = 0;

  /// The load ([_pageLoad]) the page after the last one is being asked under, null when none is on its way: the list
  /// asks for it again and again while scrolling near the end, one request is enough.
  int? _nextLoadOf;

  /// The load ([_pageLoad]) the page before the first one is being asked under, null when none is on its way.
  int? _previousLoadOf;

  /// Begin a load that replaces the floors on screen, superseding every load begun before it.
  int _beginPageLoad() => ++_pageLoad;

  /// Whether the result of a load begun under [load] still goes on screen.
  bool _isCurrent(int load) {
    if (load == _pageLoad) {
      return true;
    }
    debug('drop the result of a superseded thread load');
    return false;
  }

  /// Whether the failure [e] of a load begun under [load] is shown (and handled).
  ///
  /// Not when the load was superseded, nor for a request dropped because the account in use changed while it was
  /// pending: that is no failure of the page, which reloads for the new account (ThreadPage), and saying "failed to
  /// load" would be wrong.
  bool _showsFailure(int load, AppException e) {
    if (!_isCurrent(load)) {
      return false;
    }
    if (e is IdentityChangedException) {
      debug('drop the thread load of a previous account');
      return false;
    }
    return true;
  }

  /// [state] emptied for a load that replaces the floors on screen ([changes] applied on top): the list starts over
  /// (a new [ThreadState.generation]), nothing is asked at either end, no floor is scrolled to.
  ThreadState _replacing({ThreadState Function(ThreadState)? changes}) {
    final next = state.copyWith(
      status: ThreadStatus.loading,
      postList: [],
      generation: state.generation + 1,
      nextStatus: ThreadEdgeStatus.idle,
      previousStatus: ThreadEdgeStatus.idle,
      scrollTargetPid: null,
      jumpFloorMissed: null,
    );
    return changes == null ? next : changes(next);
  }

  AsyncEither<ThreadPageInfo> _fetch(int? page, {int? pageFallback, String? onlyVisibleUid, bool keepAuthor = true}) =>
      _threadRepository.fetchThreadPage(
        tid: state.tid,
        pid: state.pid,
        pageNumber: page ?? 1,
        pageFallback: pageFallback,
        onlyVisibleUid: keepAuthor ? state.onlyVisibleUid : onlyVisibleUid,
        reverseOrder: state.reverseOrder,
        exactOrder: state.exactOrder,
      );

  Future<void> _onThreadLoadMoreRequested(ThreadLoadMoreRequested event, ThreadEmitter emit) async {
    // Appends to the floors of the current load: begins none of its own.
    final load = _pageLoad;
    final uid = _currentUid();
    // Floors of the same account on screen: the page goes after them, and they stay on screen whatever happens.
    final appending = state.postList.isNotEmpty && state.floorsUid == uid;
    if (appending) {
      if (_nextLoadOf == load) {
        // On its way already.
        return;
      }
      if (state.status == ThreadStatus.success &&
          event.pageNumber >= state.firstPage &&
          event.pageNumber <= state.currentPage) {
        // On screen already.
        return;
      }
      _nextLoadOf = load;
      emit(state.copyWith(nextStatus: ThreadEdgeStatus.loading));
    } else if (state.status == ThreadStatus.failure) {
      // Restoring from failure.
      emit(state.copyWith(status: ThreadStatus.loading));
    }
    try {
      await _threadRepository
          .fetchThreadPage(
            tid: state.tid,
            pid: state.pid,
            pageNumber: event.pageNumber,
            pageFallback: event.pageFallback,
            onlyVisibleUid: state.onlyVisibleUid,
            reverseOrder: state.reverseOrder,
            exactOrder: state.exactOrder,
          )
          .match(
            (e) {
              if (!_showsFailure(load, e)) {
                return;
              }
              handle(e);
              if (appending && state.floorsUid == uid && state.postList.isNotEmpty) {
                // The floors stay; the end of the list offers to try again.
                emit(state.copyWith(nextStatus: ThreadEdgeStatus.failed));
                return;
              }
              emit(_failedState(uid));
            },
            (v) {
              if (_isCurrent(load)) {
                emit(_merged(v, uid: uid, merge: appending ? _Merge.append : _Merge.replace));
              }
            },
          )
          .run();
    } finally {
      if (_nextLoadOf == load && appending) {
        _nextLoadOf = null;
      }
    }
  }

  Future<void> _onThreadLoadPreviousRequested(ThreadLoadPreviousRequested event, ThreadEmitter emit) async {
    final load = _pageLoad;
    final uid = _currentUid();
    if (!state.canLoadPrevious || state.postList.isEmpty || state.floorsUid != uid || _previousLoadOf == load) {
      return;
    }
    final page = state.firstPage - 1;
    _previousLoadOf = load;
    emit(state.copyWith(previousStatus: ThreadEdgeStatus.loading));
    try {
      await _fetch(page)
          .match(
            (e) {
              if (!_showsFailure(load, e)) {
                return;
              }
              handle(e);
              if (state.floorsUid == uid && state.postList.isNotEmpty) {
                emit(state.copyWith(previousStatus: ThreadEdgeStatus.failed));
                return;
              }
              emit(_failedState(uid));
            },
            (v) {
              if (!_isCurrent(load)) {
                return;
              }
              if (v.postList.isNotEmpty && v.currentPage != state.firstPage - 1) {
                // Not the page before the first one any more (the floors on screen moved meanwhile, or the forum
                // answered another page): nothing goes above them.
                debug('drop previous page ${v.currentPage}, the first page on screen is ${state.firstPage}');
                emit(state.copyWith(previousStatus: ThreadEdgeStatus.idle));
                return;
              }
              emit(_merged(v, uid: uid, merge: _Merge.prepend));
            },
          )
          .run();
    } finally {
      if (_previousLoadOf == load) {
        _previousLoadOf = null;
      }
    }
  }

  Future<void> _onThreadLoadNewRepliesRequested(ThreadLoadNewRepliesRequested event, ThreadEmitter emit) async {
    final load = _pageLoad;
    final uid = _currentUid();
    // Only at the end of the thread: before it, the next page is what comes after the floors on screen.
    if (state.postList.isEmpty || state.floorsUid != uid || state.canLoadMore || _nextLoadOf == load) {
      return;
    }
    _nextLoadOf = load;
    final before = {for (final post in state.postList) floorKeyOf(post)};
    emit(state.copyWith(nextStatus: ThreadEdgeStatus.loading));
    try {
      await _fetch(state.currentPage)
          .match(
            (e) {
              if (!_showsFailure(load, e)) {
                return;
              }
              handle(e);
              if (state.floorsUid == uid && state.postList.isNotEmpty) {
                emit(state.copyWith(nextStatus: ThreadEdgeStatus.failed));
                return;
              }
              emit(_failedState(uid));
            },
            (v) {
              if (!_isCurrent(load)) {
                return;
              }
              final merged = _merged(v, uid: uid, merge: _Merge.append);
              final added = merged.postList.where((e) => !before.contains(floorKeyOf(e))).length;
              emit(merged.copyWith(newRepliesSerial: state.newRepliesSerial + 1, newRepliesCount: added));
            },
          )
          .run();
    } finally {
      if (_nextLoadOf == load) {
        _nextLoadOf = null;
      }
    }
  }

  Future<void> _onThreadRefreshRequested(ThreadRefreshRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    // Keep the posts: when the reload fails they go back on screen instead of a bare retry button (for the same
    // account only, see _failedState).
    final previousPosts = state.postList;
    emit(_replacing());
    await _threadRepository
        .fetchThreadPage(
          tid: state.tid,
          pid: state.pid,
          onlyVisibleUid: state.onlyVisibleUid,
          reverseOrder: state.reverseOrder,
          exactOrder: state.exactOrder,
        )
        .match(
          (e) {
            if (!_showsFailure(load, e)) {
              return;
            }
            handle(e);
            emit(_failedState(uid, previousPosts: previousPosts));
          },
          (v) {
            if (_isCurrent(load)) {
              emit(_merged(v, uid: uid, merge: _Merge.replace));
            }
          },
        )
        .run();
  }

  Future<void> _onThreadJumpPageRequested(ThreadJumpPageRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    // Keep the posts: when the reload fails they go back on screen instead of a bare retry button (for the same
    // account only, see _failedState).
    final previousPosts = state.postList;
    emit(_replacing());
    await _fetch(event.pageNumber, pageFallback: event.pageFallback)
        .match(
          (e) {
            if (!_showsFailure(load, e)) {
              return;
            }
            handle(e);
            emit(_failedState(uid, previousPosts: previousPosts));
          },
          (v) {
            if (_isCurrent(load)) {
              emit(_merged(v, uid: uid, merge: _Merge.replace));
            }
          },
        )
        .run();
  }

  /// The floor [floor] (the post [pid] when given) among the floors on screen; for a floor the thread does not have
  /// (deleted in a rush thread) between two floors on screen, the closest one after it.
  Post? _floorOnScreen(int floor, {String? pid}) {
    final posts = state.postList.where((e) => !e.hot);
    if (pid != null) {
      final byPid = posts.firstWhereOrNull((e) => e.postID == pid);
      if (byPid != null) {
        return byPid;
      }
    }
    final floors = posts.where((e) => e.postFloor != null).toList();
    final exact = floors.firstWhereOrNull((e) => e.postFloor == floor);
    // The floors on screen are the pages in a row, every floor between the lowest and the highest one: but for the
    // first floor printed on top of the first page newest first, and for one author's floors only.
    if (state.shownNewestFirst) {
      floors.removeWhere((e) => e.postFloor == 1);
    }
    if (exact != null || floors.length < 2 || state.onlyVisibleUid != null) {
      return exact;
    }
    final numbers = floors.map((e) => e.postFloor!);
    if (floor < numbers.reduce(math.min) || floor > numbers.reduce(math.max)) {
      return null;
    }
    // Between two floors on screen: the thread lacks it.
    return _closestFloor(floors, floor);
  }

  /// Of [floors], the one closest to [floor], the one after it on a tie.
  static Post? _closestFloor(Iterable<Post> floors, int floor) {
    Post? best;
    var bestDistance = 0;
    for (final post in floors) {
      final number = post.postFloor;
      if (number == null) {
        continue;
      }
      final distance = (number - floor).abs();
      if (best == null || distance < bestDistance || (distance == bestDistance && number > floor)) {
        best = post;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// The page floor [floor] is on, worked out from the floors per page ([ThreadState.postsPerPage], 10 while not
  /// known): oldest first, page N holds floors (N-1)×ppp+1 to N×ppp; newest first, page 1 holds the first floor and the
  /// latest ppp-1 replies, every later page the next ppp replies, counted from the highest floor.
  int _pageOfFloor(int floor) {
    final ppp = math.max(1, state.postsPerPage ?? 10);
    final last = math.max(1, state.totalPages);
    if (!state.shownNewestFirst) {
      return ((floor - 1) ~/ ppp + 1).clamp(1, last);
    }
    if (floor <= 1) {
      return 1;
    }
    final highestOnScreen = state.postList.map((e) => e.postFloor ?? 0).fold(0, math.max);
    final highest = math.max(highestOnScreen, (state.paginationReplies ?? state.replyCount ?? 0) + 1);
    final newer = math.max(0, highest - floor);
    final page = newer < ppp - 1 ? 1 : (newer + 1) ~/ ppp + 1;
    return page.clamp(1, last);
  }

  /// The page to ask next for floor [floor] when page [info] does not have it: before or after it, from the floors it
  /// holds; null when [floor] falls between its floors (the thread lacks it) or there is no such page.
  int? _pageTowards(ThreadPageInfo info, int floor) {
    final numbers = info.postList
        .where((e) => !e.hot && e.postFloor != null && !(state.shownNewestFirst && e.postFloor == 1))
        .map((e) => e.postFloor!)
        .toList();
    if (numbers.isEmpty) {
      return null;
    }
    final low = numbers.reduce(math.min);
    final high = numbers.reduce(math.max);
    final int step;
    if (floor < low) {
      step = state.shownNewestFirst ? 1 : -1;
    } else if (floor > high) {
      step = state.shownNewestFirst ? -1 : 1;
    } else {
      return null;
    }
    final page = info.currentPage + step;
    return page < 1 || page > info.totalPages ? null : page;
  }

  Future<void> _onThreadJumpToFloorRequested(ThreadJumpToFloorRequested event, ThreadEmitter emit) async {
    final floor = math.max(1, event.floor);
    final onScreen = state.status == ThreadStatus.success ? _floorOnScreen(floor, pid: event.pid) : null;
    if (onScreen != null) {
      emit(
        state.copyWith(
          scrollTargetPid: onScreen.postID,
          scrollTargetSerial: state.scrollTargetSerial + 1,
          jumpFloorMissed: onScreen.postFloor == floor || onScreen.postID == event.pid ? null : floor,
        ),
      );
      return;
    }
    final load = _beginPageLoad();
    final uid = _currentUid();
    final previousPosts = state.postList;
    // The page the floor was on when going on with the reading (oldest first), else the one worked out.
    var page = (!state.shownNewestFirst ? event.page : null) ?? _pageOfFloor(floor);
    emit(_replacing());
    ThreadPageInfo? found;
    Post? target;
    // A page worked out from a stale reply count or floors per page may be off: ask the page before or after it, a
    // few times at most.
    for (var attempt = 0; attempt < 3; attempt++) {
      final result = await _fetch(page).run();
      if (!_isCurrent(load)) {
        return;
      }
      final ThreadPageInfo info;
      switch (result) {
        case Left(value: final e):
          if (!_showsFailure(load, e)) {
            return;
          }
          handle(e);
          emit(_failedState(uid, previousPosts: previousPosts));
          return;
        case Right(:final value):
          info = value;
      }
      found = info;
      final floors = info.postList.where((e) => !e.hot);
      target =
          (event.pid == null ? null : floors.firstWhereOrNull((e) => e.postID == event.pid)) ??
          floors.firstWhereOrNull((e) => e.postFloor == floor);
      if (target != null || !info.havePermission || info.needLogin) {
        break;
      }
      final next = _pageTowards(info, floor);
      if (next == null || next == page) {
        break;
      }
      page = next;
    }
    final info = found;
    if (info == null) {
      return;
    }
    target ??= _closestFloor(info.postList.where((e) => !e.hot), floor);
    final merged = _merged(info, uid: uid, merge: _Merge.replace);
    emit(
      merged.copyWith(
        scrollTargetPid: target?.postID,
        scrollTargetSerial: state.scrollTargetSerial + 1,
        jumpFloorMissed: target == null || target.postFloor == floor || target.postID == event.pid ? null : floor,
      ),
    );
  }

  Future<void> _onThreadUpdateClosedState(ThreadClosedStateUpdated event, ThreadEmitter emit) async {
    emit(state.copyWith(threadClosed: event.closed));
  }

  Future<void> _onThreadOnlyViewAuthorRequested(ThreadOnlyViewAuthorRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    final page = state.currentPage;
    emit(_replacing());
    await _threadRepository
        .fetchThreadPage(
          tid: state.tid,
          pid: state.pid,
          pageNumber: page,
          // Page 1 when the page does not tell its page: the filtered thread may have fewer pages than the one
          // asked for, and a page without a pager is its only page.
          pageFallback: 1,
          onlyVisibleUid: event.uid,
          reverseOrder: state.reverseOrder,
          exactOrder: state.exactOrder,
        )
        .match(
          (e) {
            if (!_showsFailure(load, e)) {
              return;
            }
            handle(e);
            error(
              'failed to load thread page: '
              'fid=${state.tid}, pageNumber=1 : $e',
            );
            emit(_failedState(uid, changes: (s) => s.copyWith(onlyVisibleUid: event.uid)));
          },
          (v) {
            if (_isCurrent(load)) {
              emit(_merged(v, uid: uid, merge: _Merge.replace).copyWith(onlyVisibleUid: event.uid));
            }
          },
        )
        .run();
  }

  Future<void> _onThreadViewAllAuthorsRequested(ThreadViewAllAuthorsRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    final page = state.currentPage;
    emit(_replacing());
    // Switching from "only view specified author" to "view all authors"
    // will have more posts and pages so there is no page number overflow
    // risk.
    await _threadRepository
        .fetchThreadPage(
          tid: state.tid,
          pid: state.pid,
          pageNumber: page,
          reverseOrder: state.reverseOrder,
          exactOrder: state.exactOrder,
        )
        .match(
          (e) {
            if (!_showsFailure(load, e)) {
              return;
            }
            handle(e);
            error(
              'failed to load thread page:'
              ' fid=${state.tid}, pageNumber=1 : $e',
            );
            emit(_failedState(uid));
          },
          (v) {
            if (_isCurrent(load)) {
              // Every author's floors from now on: the author filter is gone (it used to be put back, and the next
              // pages were then asked for that author's floors only).
              emit(_merged(v, uid: uid, merge: _Merge.replace, clearOnlyVisibleUid: true));
            }
          },
        )
        .run();
  }

  Future<void> _onThreadChangeViewOrderRequested(ThreadChangeViewOrderRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    emit(
      _replacing(
        changes: (s) => s.copyWith(
          // Set to reverse order if is null.
          // FIXME: Some threads may set reversed order, detect that in page
          //  (though impossible if only one page).
          reverseOrder: !(state.reverseOrder ?? false),
          currentPage: 1,
          firstPage: 1,
        ),
      ),
    );
    await _threadRepository
        .fetchThreadPage(
          tid: state.tid,
          pid: state.pid,
          pageNumber: state.currentPage,
          onlyVisibleUid: state.onlyVisibleUid,
          reverseOrder: state.reverseOrder,
          exactOrder: state.exactOrder,
        )
        .match(
          (e) {
            if (!_showsFailure(load, e)) {
              return;
            }
            error(
              'failed to load thread page: '
              'fid=${state.tid}, pageNumber=1 : $e',
            );
            final reverseOrder = state.reverseOrder;
            emit(_failedState(uid, changes: (s) => s.copyWith(reverseOrder: reverseOrder)));
          },
          (v) {
            if (_isCurrent(load)) {
              emit(_merged(v, uid: uid, merge: _Merge.replace).copyWith(reverseOrder: state.reverseOrder));
            }
          },
        )
        .run();
  }

  /// The state with the page [info] the repository built (from the structured answer of the forum's app API, or
  /// parsed from the web page, or read back from its offline copy) where [merge] says.
  ///
  /// Added to floors on screen, the offline mark of either stays: the oldest time the page was saved. The pages on
  /// screen stay [threadWindowPages] at most: going on to the next page drops the first one, a page put above drops the
  /// last one (asked again when scrolled back to).
  ///
  /// [uid] is the account the load was begun for ([ThreadState.floorsUid]): floors on screen of another account are
  /// never added to.
  ThreadState _merged(
    ThreadPageInfo info, {
    required int? uid,
    required _Merge merge,
    bool clearOnlyVisibleUid = false,
  }) {
    final previousPosts = state.floorsUid == uid ? state.postList : const <Post>[];
    final keep = merge != _Merge.replace && previousPosts.isNotEmpty;
    final previousOffline = keep ? state.offlineSavedAt : null;
    final offlineSavedAt = switch ((previousOffline, info.offlineSavedAt)) {
      (final DateTime a, final DateTime b) => a.isBefore(b) ? a : b,
      (final DateTime a, null) => a,
      (null, final DateTime b) => b,
      (null, null) => null,
    };
    // The thread's author the answer names with every page: a page past the first does not show the first floor, the
    // local block list needs no extra request of the first page to tell whether the thread is hidden.
    ThreadAuthorCache.record(info.tid ?? state.tid, info.authorUid == null ? null : '${info.authorUid}');

    var posts = info.postList;
    var firstPage = info.currentPage;
    var lastPage = info.currentPage;
    if (keep) {
      switch (merge) {
        case _Merge.replace:
          break;
        case _Merge.append:
          posts = appendFloors(previousPosts, info.postList);
          firstPage = state.firstPage;
          lastPage = math.max(state.currentPage, info.currentPage);
        case _Merge.prepend:
          posts = prependFloors(info.postList, previousPosts);
          firstPage = math.min(state.firstPage, info.currentPage);
          lastPage = state.currentPage;
      }
    }
    if (lastPage - firstPage + 1 > threadWindowPages) {
      if (merge == _Merge.prepend) {
        lastPage = firstPage + threadWindowPages - 1;
        final last = lastPage;
        posts = posts.where((e) => e.page <= last).toList();
      } else {
        firstPage = lastPage - threadWindowPages + 1;
        final first = firstPage;
        posts = posts.where((e) => e.page >= first).toList();
      }
    }

    return ThreadState(
      // A login or no-permission page names no thread: keep the one asked for, or the next reload (after logging in,
      // or for another account, GitHub #184 follow-up) would ask for no thread at all.
      tid: info.tid ?? state.tid,
      pid: state.pid,
      // The side of a debate the account took, told by an earlier page loaded for the same account only.
      replyParameters: withKnownDebateStand(
        info.replyParameters,
        state.floorsUid == uid ? state.replyParameters : null,
      ),
      status: ThreadStatus.success,
      title: info.title ?? state.title,
      fid: info.fid,
      forumName: info.forumName,
      canLoadMore: lastPage < info.totalPages,
      currentPage: lastPage,
      firstPage: firstPage,
      totalPages: info.totalPages,
      havePermission: info.havePermission,
      permissionDeniedMessage: info.permissionDeniedMessage,
      needLogin: info.needLogin,
      threadSoftClosed: info.threadSoftClosed,
      threadClosed: info.threadClosed,
      postList: posts,
      threadType: info.threadType,
      onlyVisibleUid: clearOnlyVisibleUid ? null : state.onlyVisibleUid,
      reverseOrder: state.reverseOrder,
      exactOrder: state.exactOrder,
      isDraft: info.isDraft,
      latestModAct: info.latestModAct,
      breadcrumbs: info.breadcrumbs,
      // Each page prints the medal menus of its own floors: keep those of the pages on screen.
      postMedals: keep ? _mergeMedals(state.postMedals, info.postMedals) : info.postMedals,
      viewCount: info.viewCount,
      replyCount: info.replyCount,
      paginationReplies: info.paginationReplies ?? info.replyCount,
      postsPerPage: info.postsPerPage ?? (keep ? state.postsPerPage : null) ?? _postsPerPageOf(info),
      offlineSavedAt: offlineSavedAt,
      floorsUid: uid,
      generation: state.generation,
      nextStatus: merge == _Merge.prepend && keep ? state.nextStatus : ThreadEdgeStatus.idle,
      previousStatus: merge == _Merge.append && keep ? state.previousStatus : ThreadEdgeStatus.idle,
      scrollTargetPid: keep ? state.scrollTargetPid : null,
      scrollTargetSerial: state.scrollTargetSerial,
      jumpFloorMissed: keep ? state.jumpFloorMissed : null,
      newRepliesSerial: state.newRepliesSerial,
      newRepliesCount: state.newRepliesCount,
      newestFirst: info.newestFirst,
    );
  }

  /// The floors per page told by a web page [info] that is not the last page, oldest floor first, every author: its
  /// highest floor is its page number times the floors per page. Null otherwise.
  int? _postsPerPageOf(ThreadPageInfo info) {
    if (info.currentPage >= info.totalPages || state.onlyVisibleUid != null || state.shownNewestFirst) {
      return null;
    }
    final highest = info.postList.where((e) => !e.hot).map((e) => e.postFloor ?? 0).fold(0, math.max);
    if (highest <= 0 || info.currentPage <= 0 || highest % info.currentPage != 0) {
      return null;
    }
    return highest ~/ info.currentPage;
  }

  static List<PostMedalMenuItem> _mergeMedals(List<PostMedalMenuItem> kept, List<PostMedalMenuItem> loaded) {
    if (kept.isEmpty) {
      return loaded;
    }
    final byId = {for (final medal in kept) medal.id: medal};
    for (final medal in loaded) {
      byId[medal.id] = medal;
    }
    return byId.values.toList();
  }
}

/// The key a floor is told apart by in the list ([appendFloors]): a hot reply is on the first page (numbered -1) and
/// once more where it really is, both kept.
String floorKeyOf(Post post) => '${post.hot ? 'hot' : 'floor'}:${post.postID}';

/// The floors [loaded] appended to the floors [previous] on screen, without the floors already there (by pid): a page
/// loaded twice (asked again after a failure, or its floors moved to the next page by new replies or deleted ones)
/// showed its floors twice. A hot reply is kept, once as such: it is on the first page (numbered -1) and once more
/// where it really is.
List<Post> appendFloors(List<Post> previous, List<Post> loaded) {
  if (previous.isEmpty) {
    return loaded;
  }
  final seen = previous.map(floorKeyOf).toSet();
  return [...previous, ...loaded.where((e) => e.postID.isEmpty || seen.add(floorKeyOf(e)))];
}

/// The floors [loaded] (the page before the first one on screen) put before the floors [next] on screen, without
/// the floors already there (by pid, see [appendFloors]).
List<Post> prependFloors(List<Post> loaded, List<Post> next) {
  if (next.isEmpty) {
    return loaded;
  }
  final seen = next.map(floorKeyOf).toSet();
  return [...loaded.where((e) => e.postID.isEmpty || !seen.contains(floorKeyOf(e))), ...next];
}
