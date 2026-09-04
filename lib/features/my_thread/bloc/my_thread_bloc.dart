import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

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

  Future<void> _onMyThreadLoadInitialDataRequested(MyThreadLoadInitialDataRequested event, MyThreadEmitter emit) async {
    // Only emit loading state when loading initial data.
    emit(
      state.copyWith(
        status: MyThreadStatus.loading,
        threadList: [],
        replyList: [],
        refreshingThread: true,
        refreshingReply: true,
      ),
    );
    final data = await Future.wait([
      _myThreadRepository.fetchDocument(myThreadThreadUrl).run(),
      _myThreadRepository.fetchDocument(myThreadReplyUrl).run(),
    ]);
    switch ((data[0], data[1])) {
      case (Right(value: final v1), Right(value: final v2)):
        final (threadList, threadNextPageUrl) = _parseThreadList(v1);
        final (replyList, replyNextPageUrl) = _parseReplyList(v2);
        emit(
          state.copyWith(
            status: MyThreadStatus.success,
            threadList: threadList,
            threadPageNumber: 1,
            nextThreadPageUrl: threadNextPageUrl,
            replyList: replyList,
            replyPageNumber: 1,
            nextReplyPageUrl: replyNextPageUrl,
            refreshingThread: false,
            refreshingReply: false,
          ),
        );
      default:
        error('failed to initial my thread page data: ${data[0]}/${data[1]}');
        emit(state.copyWith(status: MyThreadStatus.failed, refreshingThread: false, refreshingReply: false));
    }
  }

  Future<void> _onMyThreadLoadMoreThreadRequested(MyThreadLoadMoreThreadRequested event, MyThreadEmitter emit) async {
    // Do nothing because this part should be avoided by ui.
    if (state.nextThreadPageUrl == null) {
      return;
    }
    await _myThreadRepository
        .fetchDocument(state.nextThreadPageUrl!)
        .match(
          (e) {
            handle(e);
            error('failed to load next page of thread tab: $e');
            emit(state.copyWith(status: MyThreadStatus.failed));
          },
          (v) {
            final (threadList, nextThreadPageUrl) = _parseThreadList(v);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                threadList: [...state.threadList, ...threadList],
                threadPageNumber: state.threadPageNumber + 1,
                nextThreadPageUrl: nextThreadPageUrl,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onMyThreadLoadMoreReplyRequested(MyThreadLoadMoreReplyRequested event, MyThreadEmitter emit) async {
    // Do nothing because this part should be avoided by ui.
    if (state.nextReplyPageUrl == null) {
      return;
    }
    await _myThreadRepository
        .fetchDocument(state.nextReplyPageUrl!)
        .match(
          (e) {
            handle(e);
            error('failed to load next page of reply tab: $e');
            emit(state.copyWith(status: MyThreadStatus.failed));
          },
          (v) {
            final (replyList, nextReplyPageUrl) = _parseReplyList(v);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                replyList: [...state.replyList, ...replyList],
                replyPageNumber: state.replyPageNumber + 1,
                nextReplyPageUrl: nextReplyPageUrl,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onMyThreadRefreshThreadRequested(MyThreadRefreshThreadRequested event, MyThreadEmitter emit) async {
    emit(state.copyWith(refreshingThread: true));
    await _myThreadRepository
        .fetchDocument(myThreadThreadUrl)
        .match(
          (e) {
            handle(e);
            error('failed to load next page of thread tab: $e');
            emit(state.copyWith(status: MyThreadStatus.failed, refreshingThread: false));
          },
          (v) {
            final (threadList, nextThreadPageUrl) = _parseThreadList(v);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                threadList: threadList,
                threadPageNumber: 1,
                nextThreadPageUrl: nextThreadPageUrl,
                refreshingThread: false,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onMyThreadRefreshReplyRequested(MyThreadRefreshReplyRequested event, MyThreadEmitter emit) async {
    emit(state.copyWith(refreshingReply: true));
    await _myThreadRepository
        .fetchDocument(myThreadReplyUrl)
        .match(
          (e) {
            handle(e);
            error('failed to load next page of reply tab: $e');
            emit(state.copyWith(status: MyThreadStatus.failed, refreshingReply: false));
          },
          (v) {
            final (replyList, nextReplyPageUrl) = _parseReplyList(v);
            emit(
              state.copyWith(
                status: MyThreadStatus.success,
                replyList: replyList,
                replyPageNumber: 1,
                nextReplyPageUrl: nextReplyPageUrl,
                refreshingReply: false,
              ),
            );
          },
        )
        .run();
  }

  /// Parse thread list and next page url.
  ///
  /// X5: `<div class="tl"><form id="delform"><table><tr class="th">header</tr><tr>thread</tr>...</table></form></div>`
  /// followed by `<div class="pgs cl mtm"><div class="pg"><a class="nxt">下一页</a></div></div>`.
  (List<MyThread>, String? nextPageurl) _parseThreadList(uh.Document document) {
    final data = _threadRows(document)
        // Skip the header row.
        .where((e) => !e.classes.contains('th'))
        .map(MyThread.fromTr)
        .whereType<MyThread>()
        .toList();

    return (data, _nextPageUrl(document));
  }

  /// Parse reply list and next page url.
  ///
  /// Each `<tr class="bw0_all">` thread row is followed by one or more reply rows, every reply becomes an item.
  (List<MyThread>, String? nextPageUrl) _parseReplyList(uh.Document document) {
    final data = _threadRows(
      document,
    ).where((e) => e.classes.contains('bw0_all')).map(MyThread.buildReplyListFromTr).flattened.toList();
    return (data, _nextPageUrl(document));
  }

  static List<uh.Element> _threadRows(uh.Document document) {
    var rows = document.querySelectorAll('div.bm.bw0 > div.tl > form > table > tbody > tr');
    if (rows.isEmpty) {
      // X5.
      rows = document.querySelectorAll('div.tl > form#delform > table > tbody > tr');
    }
    return rows.toList();
  }

  static String? _nextPageUrl(uh.Document document) =>
      (document.querySelector('div.pgs.cl.mtm > div.pg > a.nxt') ?? document.querySelector('div.pgs > div.pg > a.nxt'))
          ?.firstHref()
          ?.prependHost();
}
