import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_parser.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'my_thread_bloc.mapper.dart';

part 'my_thread_event.dart';

part 'my_thread_state.dart';

/// Emitter
typedef MyThreadEmitter = Emitter<MyThreadState>;

/// Bloc of my thread page.
final class MyThreadBloc extends Bloc<MyThreadEvent, MyThreadState> with LoggerMixin {
  /// Constructor.
  MyThreadBloc({required MyThreadRepository myThreadRepository})
    : _myThreadRepository = myThreadRepository,
      super(const MyThreadState()) {
    on<MyThreadLoadMoreThreadRequested>(_onMyThreadLoadMoreThreadRequested);
    on<MyThreadLoadMoreReplyRequested>(_onMyThreadLoadMoreReplyRequested);
    on<MyThreadRefreshThreadRequested>(_onMyThreadRefreshThreadRequested);
    on<MyThreadRefreshReplyRequested>(_onMyThreadRefreshReplyRequested);
    on<MyThreadLoadInitialDataRequested>(_onMyThreadLoadInitialDataRequested);
  }

  final MyThreadRepository _myThreadRepository;

  /// Bumped by every load of the first page of the thread tab: a next page asked for the list before is dropped
  /// instead of being added to the new one.
  int _threadGeneration = 0;

  /// Bumped by every load of the first page of the reply tab, see [_threadGeneration].
  int _replyGeneration = 0;

  Future<void> _onMyThreadLoadInitialDataRequested(MyThreadLoadInitialDataRequested event, MyThreadEmitter emit) async {
    // Only emit loading state when loading initial data.
    emit(
      state.copyWith(
        status: MyThreadStatus.loading,
        threadList: [],
        replyList: [],
        refreshingThread: true,
        refreshingReply: true,
        threadFailed: false,
        threadLoadMoreFailed: false,
        replyFailed: false,
        replyLoadMoreFailed: false,
        loadingMoreThread: false,
        loadingMoreReply: false,
        threadFailure: null,
        replyFailure: null,
      ),
    );
    _threadGeneration++;
    _replyGeneration++;
    final data = await Future.wait([
      _myThreadRepository.fetchPage(myThreadThreadUrl).run(),
      _myThreadRepository.fetchPage(myThreadReplyUrl).run(),
    ]);
    // Each tab on its own: one that failed offers its retry, the other one shows what it got.
    var next = state.copyWith(status: MyThreadStatus.success, refreshingThread: false, refreshingReply: false);
    switch (data[0]) {
      case Right(value: final v):
        final (threadList, threadNextPageUrl) = _parseThreadPage(v, myThreadThreadUrl);
        next = next.copyWith(threadList: threadList, threadPageNumber: 1, nextThreadPageUrl: threadNextPageUrl);
      case Left(value: final e):
        handle(e);
        error('failed to load the thread tab of my thread page: $e');
        next = next.copyWith(threadFailed: true, threadFailure: LoadFailure.of(e));
    }
    switch (data[1]) {
      case Right(value: final v):
        final (replyList, replyNextPageUrl) = _parseReplyPage(v, myThreadReplyUrl);
        next = next.copyWith(replyList: replyList, replyPageNumber: 1, nextReplyPageUrl: replyNextPageUrl);
      case Left(value: final e):
        handle(e);
        error('failed to load the reply tab of my thread page: $e');
        next = next.copyWith(replyFailed: true, replyFailure: LoadFailure.of(e));
    }
    if (next.threadFailed && next.replyFailed) {
      next = next.copyWith(status: MyThreadStatus.failed);
    }
    emit(next);
  }

  Future<void> _onMyThreadLoadMoreThreadRequested(MyThreadLoadMoreThreadRequested event, MyThreadEmitter emit) async {
    // Nothing more, or already on its way: the end of the list may ask more than once.
    if (state.nextThreadPageUrl == null || state.loadingMoreThread || state.refreshingThread) {
      return;
    }
    final url = state.nextThreadPageUrl!;
    final generation = _threadGeneration;
    emit(state.copyWith(threadLoadMoreFailed: false, loadingMoreThread: true));
    await _myThreadRepository
        .fetchPage(url)
        .match(
          (e) {
            handle(e);
            error('failed to load next page of thread tab: $e');
            if (generation != _threadGeneration) {
              return;
            }
            // The threads loaded before stay on screen.
            emit(
              state.copyWith(threadLoadMoreFailed: true, loadingMoreThread: false, threadFailure: LoadFailure.of(e)),
            );
          },
          (v) {
            if (generation != _threadGeneration) {
              return;
            }
            final (threadList, nextThreadPageUrl) = _parseThreadPage(v, url);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                threadList: [...state.threadList, ...threadList],
                threadPageNumber: state.threadPageNumber + 1,
                nextThreadPageUrl: nextThreadPageUrl,
                threadLoadMoreFailed: false,
                loadingMoreThread: false,
                threadFailure: null,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onMyThreadLoadMoreReplyRequested(MyThreadLoadMoreReplyRequested event, MyThreadEmitter emit) async {
    // Nothing more, or already on its way: the end of the list may ask more than once.
    if (state.nextReplyPageUrl == null || state.loadingMoreReply || state.refreshingReply) {
      return;
    }
    final url = state.nextReplyPageUrl!;
    final generation = _replyGeneration;
    emit(state.copyWith(replyLoadMoreFailed: false, loadingMoreReply: true));
    await _myThreadRepository
        .fetchPage(url)
        .match(
          (e) {
            handle(e);
            error('failed to load next page of reply tab: $e');
            if (generation != _replyGeneration) {
              return;
            }
            // The replies loaded before stay on screen.
            emit(state.copyWith(replyLoadMoreFailed: true, loadingMoreReply: false, replyFailure: LoadFailure.of(e)));
          },
          (v) {
            if (generation != _replyGeneration) {
              return;
            }
            final (replyList, nextReplyPageUrl) = _parseReplyPage(v, url);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                replyList: [...state.replyList, ...replyList],
                replyPageNumber: state.replyPageNumber + 1,
                nextReplyPageUrl: nextReplyPageUrl,
                replyLoadMoreFailed: false,
                loadingMoreReply: false,
                replyFailure: null,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onMyThreadRefreshThreadRequested(MyThreadRefreshThreadRequested event, MyThreadEmitter emit) async {
    _threadGeneration++;
    emit(state.copyWith(refreshingThread: true, loadingMoreThread: false));
    await _myThreadRepository
        .fetchPage(myThreadThreadUrl)
        .match(
          (e) {
            handle(e);
            error('failed to refresh thread tab: $e');
            // The threads shown before stay; an empty tab offers the retry.
            emit(state.copyWith(refreshingThread: false, threadFailed: true, threadFailure: LoadFailure.of(e)));
          },
          (v) {
            final (threadList, nextThreadPageUrl) = _parseThreadPage(v, myThreadThreadUrl);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                threadList: threadList,
                threadPageNumber: 1,
                nextThreadPageUrl: nextThreadPageUrl,
                refreshingThread: false,
                threadFailed: false,
                threadLoadMoreFailed: false,
                threadFailure: null,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onMyThreadRefreshReplyRequested(MyThreadRefreshReplyRequested event, MyThreadEmitter emit) async {
    _replyGeneration++;
    emit(state.copyWith(refreshingReply: true, loadingMoreReply: false));
    await _myThreadRepository
        .fetchPage(myThreadReplyUrl)
        .match(
          (e) {
            handle(e);
            error('failed to refresh reply tab: $e');
            // The replies shown before stay; an empty tab offers the retry.
            emit(state.copyWith(refreshingReply: false, replyFailed: true, replyFailure: LoadFailure.of(e)));
          },
          (v) {
            final (replyList, nextReplyPageUrl) = _parseReplyPage(v, myThreadReplyUrl);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                replyList: replyList,
                replyPageNumber: 1,
                nextReplyPageUrl: nextReplyPageUrl,
                refreshingReply: false,
                replyFailed: false,
                replyLoadMoreFailed: false,
                replyFailure: null,
              ),
            );
          },
        )
        .run();
  }

  (List<MyThread>, String? nextPageUrl) _parseThreadPage(TsdmAppPageAnswer answer, String url) =>
      myThreadPageOf(answer, url, reply: false);

  /// The reply list and the next page url of the reply page [answer] fetched from [url] ([myThreadPageOf]).
  (List<MyThread>, String? nextPageUrl) _parseReplyPage(TsdmAppPageAnswer answer, String url) =>
      myThreadPageOf(answer, url, reply: true);
}
