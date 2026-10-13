import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/shared/models/models.dart';
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
  }) : _threadRepository = threadRepository,
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
    if (state.status == ThreadStatus.failure) {
      // Restoring from failure.
      emit(state.copyWith(status: ThreadStatus.loading));
    }
    await _threadRepository
        .fetchThread(
          tid: state.tid,
          pid: state.pid,
          pageNumber: event.pageNumber,
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
            emit(state.copyWith(status: ThreadStatus.failure));
          },
          (v) {
            if (_isCurrent(load)) {
              _parseFromDocument(v, event.pageNumber).map((v) => emit(v)).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadRefreshRequested(ThreadRefreshRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    // Keep the posts: when the reload fails they go back on screen instead of a bare retry button.
    final previousPosts = state.postList;
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    await _threadRepository
        .fetchThread(
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
            emit(state.copyWith(status: ThreadStatus.failure, postList: previousPosts));
          },
          (v) {
            if (_isCurrent(load)) {
              _parseFromDocument(v, 1).map((v) => emit(v)).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadJumpPageRequested(ThreadJumpPageRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    // Keep the posts: when the reload fails they go back on screen instead of a bare retry button.
    final previousPosts = state.postList;
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    await _threadRepository
        .fetchThread(
          tid: state.tid,
          pid: state.pid,
          pageNumber: event.pageNumber,
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
            emit(state.copyWith(status: ThreadStatus.failure, postList: previousPosts));
          },
          (v) {
            if (_isCurrent(load)) {
              _parseFromDocument(v, event.pageNumber).map((v) => emit(v)).run();
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
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    await _threadRepository
        .fetchThread(
          tid: state.tid,
          pid: state.pid,
          pageNumber: state.currentPage,
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
            emit(state.copyWith(status: ThreadStatus.failure, onlyVisibleUid: event.uid));
          },
          // Use "1" as current page number to prevent page number overflow.
          (v) {
            if (_isCurrent(load)) {
              _parseFromDocument(v, 1).map((v) => emit(v.copyWith(onlyVisibleUid: event.uid))).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadViewAllAuthorsRequested(ThreadViewAllAuthorsRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    // Switching from "only view specified author" to "view all authors"
    // will have more posts and pages so there is no page number overflow
    // risk.
    await _threadRepository
        .fetchThread(
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
            emit(state.copyWith(status: ThreadStatus.failure));
          },
          (v) {
            if (_isCurrent(load)) {
              _parseFromDocument(
                v,
                state.currentPage,
                clearOnlyVisibleUid: true,
              ).map((v) => emit(v.copyWith(onlyVisibleUid: state.onlyVisibleUid))).run();
            }
          },
        )
        .run();
  }

  Future<void> _onThreadChangeViewOrderRequested(ThreadChangeViewOrderRequested event, ThreadEmitter emit) async {
    final load = _beginPageLoad();
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
        .fetchThread(
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
            emit(state.copyWith(status: ThreadStatus.failure, reverseOrder: state.reverseOrder));
          },
          (v) {
            if (_isCurrent(load)) {
              _parseFromDocument(
                v,
                state.currentPage,
              ).map((v) => emit(v.copyWith(reverseOrder: state.reverseOrder))).run();
            }
          },
        )
        .run();
  }

  IO<ThreadState> _parseFromDocument(uh.Document document, int pageNumber, {bool? clearOnlyVisibleUid}) => IO(() {
    final info = parseThreadDocument(document, pageNumber);

    final threadState = ThreadState(
      // A login or no-permission page names no thread: keep the one asked for, or the next reload (after logging in,
      // or for another account, GitHub #184 follow-up) would ask for no thread at all.
      tid: info.tid ?? state.tid,
      pid: state.pid,
      replyParameters: info.replyParameters,
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
      postList: [...state.postList, ...info.postList],
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
    );

    return threadState;
  });
}
