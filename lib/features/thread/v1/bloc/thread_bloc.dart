import 'package:bloc/bloc.dart';
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
      return apply(state.copyWith(status: ThreadStatus.failure, postList: previousPosts ?? state.postList));
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

  Future<void> _onThreadLoadMoreRequested(ThreadLoadMoreRequested event, ThreadEmitter emit) async {
    // Appends to the floors of the current load: begins none of its own.
    final load = _pageLoad;
    final uid = _currentUid();
    if (state.status == ThreadStatus.failure) {
      // Restoring from failure.
      emit(state.copyWith(status: ThreadStatus.loading));
    }
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
            emit(_failedState(uid));
          },
          (v) {
            if (_isCurrent(load)) {
              _stateOf(v, uid: uid).map((v) => emit(v)).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadRefreshRequested(ThreadRefreshRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    // Keep the posts: when the reload fails they go back on screen instead of a bare retry button (for the same
    // account only, see _failedState).
    final previousPosts = state.postList;
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
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
              _stateOf(v, uid: uid).map((v) => emit(v)).run();
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
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
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
            emit(_failedState(uid, previousPosts: previousPosts));
          },
          (v) {
            if (_isCurrent(load)) {
              _stateOf(v, uid: uid).map((v) => emit(v)).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadUpdateClosedState(ThreadClosedStateUpdated event, ThreadEmitter emit) async {
    emit(state.copyWith(threadClosed: event.closed));
  }

  Future<void> _onThreadOnlyViewAuthorRequested(ThreadOnlyViewAuthorRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    await _threadRepository
        .fetchThreadPage(
          tid: state.tid,
          pid: state.pid,
          pageNumber: state.currentPage,
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
              _stateOf(v, uid: uid).map((v) => emit(v.copyWith(onlyVisibleUid: event.uid))).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadViewAllAuthorsRequested(ThreadViewAllAuthorsRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    // Switching from "only view specified author" to "view all authors"
    // will have more posts and pages so there is no page number overflow
    // risk.
    await _threadRepository
        .fetchThreadPage(
          tid: state.tid,
          pid: state.pid,
          pageNumber: state.currentPage,
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
              _stateOf(
                v,
                uid: uid,
                clearOnlyVisibleUid: true,
              ).map((v) => emit(v.copyWith(onlyVisibleUid: state.onlyVisibleUid))).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadChangeViewOrderRequested(ThreadChangeViewOrderRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    final uid = _currentUid();
    emit(
      state.copyWith(
        status: ThreadStatus.loading,
        postList: [],
        // Set to reverse order if is null.
        // FIXME: Some threads may set reversed order, detect that in page
        //  (though impossible if only one page).
        reverseOrder: !(state.reverseOrder ?? false),
        currentPage: 1,
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
              _stateOf(v, uid: uid).map((v) => emit(v.copyWith(reverseOrder: state.reverseOrder))).run();
            }
          },
        )
        .run();
  }

  /// The state of the page [info] the repository built (from the structured answer of the forum's app API, or
  /// parsed from the web page, or read back from its offline copy).
  ///
  /// Appended to floors on screen, the offline mark of either stays: the oldest time the page was saved.
  ///
  /// [uid] is the account the load was begun for ([ThreadState.floorsUid]): floors on screen of another account are
  /// never appended to.
  IO<ThreadState> _stateOf(ThreadPageInfo info, {required int? uid, bool? clearOnlyVisibleUid}) => IO(() {
    final previousPosts = state.floorsUid == uid ? state.postList : const <Post>[];
    final previousOffline = previousPosts.isEmpty ? null : state.offlineSavedAt;
    final offlineSavedAt = switch ((previousOffline, info.offlineSavedAt)) {
      (final DateTime a, final DateTime b) => a.isBefore(b) ? a : b,
      (final DateTime a, null) => a,
      (null, final DateTime b) => b,
      (null, null) => null,
    };
    // The thread's author the answer names with every page: a page past the first does not show the first floor, the
    // local block list needs no extra request of the first page to tell whether the thread is hidden.
    ThreadAuthorCache.record(info.tid ?? state.tid, info.authorUid == null ? null : '${info.authorUid}');
    final threadState = ThreadState(
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
      canLoadMore: info.currentPage < info.totalPages,
      currentPage: info.currentPage,
      totalPages: info.totalPages,
      havePermission: info.havePermission,
      permissionDeniedMessage: info.permissionDeniedMessage,
      needLogin: info.needLogin,
      threadSoftClosed: info.threadSoftClosed,
      threadClosed: info.threadClosed,
      postList: appendFloors(previousPosts, info.postList),
      threadType: info.threadType,
      onlyVisibleUid: (clearOnlyVisibleUid ?? false) ? null : state.onlyVisibleUid,
      reverseOrder: state.reverseOrder,
      exactOrder: state.exactOrder,
      isDraft: info.isDraft,
      latestModAct: info.latestModAct,
      breadcrumbs: info.breadcrumbs,
      postMedals: info.postMedals,
      viewCount: info.viewCount,
      replyCount: info.replyCount,
      offlineSavedAt: offlineSavedAt,
      floorsUid: uid,
      newestFirst: info.newestFirst,
    );

    return threadState;
  });
}

/// The floors [loaded] appended to the floors [previous] on screen, without the floors already there (by pid): a page
/// loaded twice (asked again after a failure, or its floors moved to the next page by new replies or deleted ones)
/// showed its floors twice. A hot reply is kept, once as such: it is on the first page (numbered -1) and once more
/// where it really is.
List<Post> appendFloors(List<Post> previous, List<Post> loaded) {
  if (previous.isEmpty) {
    return loaded;
  }
  String keyOf(Post post) => '${post.hot ? 'hot' : 'floor'}:${post.postID}';
  final seen = previous.map(keyOf).toSet();
  return [...previous, ...loaded.where((e) => e.postID.isEmpty || seen.add(keyOf(e)))];
}
