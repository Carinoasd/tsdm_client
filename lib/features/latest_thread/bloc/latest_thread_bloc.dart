import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/utils/guide_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'latest_thread_bloc.mapper.dart';

part 'latest_thread_event.dart';

part 'latest_thread_state.dart';

/// Emitter
typedef LatestThreadEmitter = Emitter<LatestThreadState>;

/// Bloc the the latest thread feature.
final class LatestThreadBloc extends Bloc<LatestThreadEvent, LatestThreadState> with LoggerMixin {
  /// Constructor.
  LatestThreadBloc({required LatestThreadRepository latestThreadRepository})
    : _latestThreadRepository = latestThreadRepository,
      super(const LatestThreadState()) {
    on<LatestThreadLoadMoreRequested>(_onLatestThreadLoadMoreRequested);
    on<LatestThreadRefreshRequested>(_onLatestThreadRefreshRequested);
  }

  final LatestThreadRepository _latestThreadRepository;

  /// Bumped by every refresh: a next page asked for the list before is dropped instead of being added to the new one.
  int _generation = 0;

  Future<void> _onLatestThreadLoadMoreRequested(LatestThreadLoadMoreRequested event, LatestThreadEmitter emit) async {
    // Nothing more, or already on its way: the end of the list may ask more than once.
    if (state.nextPageUrl == null || state.loadingMore || state.refreshing) {
      return;
    }
    final url = state.nextPageUrl!;
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    await _latestThreadRepository
        .fetchPage(url)
        .match(
          (e) {
            handle(e);
            error('failed to load latest thread next page: $e');
            if (generation != _generation) {
              return;
            }
            // The threads loaded before stay, the end of the list tells the failure and retries.
            emit(state.copyWith(loadingMore: false, loadMoreFailed: true, failure: LoadFailure.of(e)));
          },
          (v) {
            if (generation != _generation) {
              return;
            }
            final (threadList, nextPageUrl) = _parsePage(v, url);
            emit(
              state.copyWith(
                status: LatestThreadStatus.success,
                threadList: [...state.threadList, ...?threadList],
                pageNumber: state.pageNumber + 1,
                nextPageUrl: nextPageUrl,
                loadingMore: false,
                loadMoreFailed: false,
                failure: null,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onLatestThreadRefreshRequested(LatestThreadRefreshRequested event, LatestThreadEmitter emit) async {
    // The threads on screen stay while the first page is asked again, and when that fails (the page says so).
    final shown = state.status == LatestThreadStatus.success && state.threadList.isNotEmpty;
    if (shown && state.refreshing) {
      return;
    }
    final generation = ++_generation;
    emit(
      shown
          ? state.copyWith(refreshing: true, loadingMore: false, loadMoreFailed: false, failure: null)
          : state.copyWith(
              status: LatestThreadStatus.loading,
              threadList: [],
              loadingMore: false,
              loadMoreFailed: false,
              failure: null,
            ),
    );
    await _latestThreadRepository
        .fetchPage(event.url)
        .match(
          (e) {
            handle(e);
            error('failed to load latest thread page: $e');
            if (generation != _generation) {
              return;
            }
            emit(
              shown
                  ? state.copyWith(refreshing: false, failure: LoadFailure.of(e))
                  : state.copyWith(status: LatestThreadStatus.failed, failure: LoadFailure.of(e)),
            );
          },
          (v) {
            if (generation != _generation) {
              return;
            }
            final (threadList, nextPageUrl) = _parsePage(v, event.url);
            emit(
              state.copyWith(
                status: LatestThreadStatus.success,
                threadList: threadList ?? const [],
                pageNumber: 1,
                nextPageUrl: nextPageUrl,
                refreshing: false,
                failure: null,
              ),
            );
          },
        )
        .run();
  }

  /// The thread list and the next page url of the page [answer] fetched from [url]: the structured answer of the
  /// forum's app API built from its fields (`latestThreadsFromApi`), the web page parsed as before
  /// ([_parseThreadList]).
  (List<LatestThread>?, String? nextPageUrl) _parsePage(TsdmAppPageAnswer answer, String url) => switch (answer) {
    TsdmAppWebPage(:final document) => _parseThreadList(document),
    TsdmAppStructuredPage(:final json) => latestThreadsFromApi(json, url),
  };

  /// Parse thread list and next page url from [document].
  ///
  /// * X5: standard guide page `forum.php?mod=guide&view=new|newthread`, threads are in
  ///   `<tbody id="normalthread_xxx">` rows, pagination in `<div class="pg">` with `<a class="nxt">`.
  /// * Legacy: `<div id="threadlist"><ul><li>` rows from the vanished plugin page.
  (List<LatestThread>?, String? nextPageUrl) _parseThreadList(uh.Document document) {
    final tbodyList = document.querySelectorAll('tbody[id^="normalthread_"]');
    final List<LatestThread> data;
    if (tbodyList.isNotEmpty) {
      data = tbodyList.map(LatestThread.fromTBody).where((e) => e.isValid).toList();
    } else {
      data =
          document
              .querySelector('div#threadlist > ul')
              ?.querySelectorAll('li')
              .map(LatestThread.fromLi)
              .where((e) => e.isValid)
              .toList() ??
          const [];
    }
    final nextPageUrl =
        (document.querySelector('div#ct_shell div.pg > a.nxt') ?? document.querySelector('div.pg > a.nxt'))
            ?.firstHref()
            ?.prependHost();
    return (data, nextPageUrl);
  }
}
