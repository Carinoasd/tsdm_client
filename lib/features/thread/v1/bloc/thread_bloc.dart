import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
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

  Future<void> _onThreadLoadMoreRequested(ThreadLoadMoreRequested event, ThreadEmitter emit) async {
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
        .match((e) {
          handle(e);
          emit(state.copyWith(status: ThreadStatus.failure));
        }, (v) => _parseFromDocument(v, event.pageNumber).map((v) => emit(v)).run())
        .run();
  }

  Future<void> _onThreadRefreshRequested(ThreadRefreshRequested event, ThreadEmitter emit) async {
    emit(state.copyWith(status: ThreadStatus.loading, postList: []));
    await _threadRepository
        .fetchThread(
          tid: state.tid,
          pid: state.pid,
          onlyVisibleUid: state.onlyVisibleUid,
          reverseOrder: state.reverseOrder,
          exactOrder: state.exactOrder,
        )
        .match((e) {
          handle(e);
          emit(state.copyWith(status: ThreadStatus.failure));
        }, (v) => _parseFromDocument(v, 1).map((v) => emit(v)).run())
        .run();
  }

  Future<void> _onThreadJumpPageRequested(ThreadJumpPageRequested event, ThreadEmitter emit) async {
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
        .map((v) => _parseFromDocument(v, event.pageNumber).map((v) => emit(v)).run())
        .mapLeft((e) {
          handle(e);
          emit(state.copyWith(status: ThreadStatus.failure));
        })
        .run();
  }

  Future<void> _onThreadUpdateClosedState(ThreadClosedStateUpdated event, ThreadEmitter emit) async {
    emit(state.copyWith(threadClosed: event.closed));
  }

  Future<void> _onThreadOnlyViewAuthorRequested(ThreadOnlyViewAuthorRequested event, ThreadEmitter emit) async {
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
            handle(e);
            error(
              'failed to load thread page: '
              'fid=${state.tid}, pageNumber=1 : $e',
            );
            emit(state.copyWith(status: ThreadStatus.failure, onlyVisibleUid: event.uid));
          },
          // Use "1" as current page number to prevent page number overflow.
          (v) => _parseFromDocument(v, 1).map((v) => emit(v.copyWith(onlyVisibleUid: event.uid))).run(),
        )
        .run();
  }

  Future<void> _onThreadViewAllAuthorsRequested(ThreadViewAllAuthorsRequested event, ThreadEmitter emit) async {
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
            handle(e);
            error(
              'failed to load thread page:'
              ' fid=${state.tid}, pageNumber=1 : $e',
            );
            emit(state.copyWith(status: ThreadStatus.failure));
          },
          (v) => _parseFromDocument(
            v,
            state.currentPage,
            clearOnlyVisibleUid: true,
          ).map((v) => emit(v.copyWith(onlyVisibleUid: state.onlyVisibleUid))).run(),
        )
        .run();
  }

  Future<void> _onThreadChangeViewOrderRequested(ThreadChangeViewOrderRequested event, ThreadEmitter emit) async {
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
            error(
              'failed to load thread page: '
              'fid=${state.tid}, pageNumber=1 : $e',
            );
            emit(state.copyWith(status: ThreadStatus.failure, reverseOrder: state.reverseOrder));
          },
          (v) => _parseFromDocument(
            v,
            state.currentPage,
          ).map((v) => emit(v.copyWith(reverseOrder: state.reverseOrder))).run(),
        )
        .run();
  }

  IO<ThreadState> _parseFromDocument(uh.Document document, int pageNumber, {bool? clearOnlyVisibleUid}) => IO(() {
    final info = parseThreadDocument(document, pageNumber);

    final threadState = ThreadState(
      tid: info.tid,
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
