import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'search_bloc.mapper.dart';

part 'search_event.dart';

part 'search_state.dart';

/// Emitter
typedef SearchEmitter = Emitter<SearchState>;

/// Bloc of search page of the app.
class SearchBloc extends Bloc<SearchEvent, SearchState> with LoggerMixin {
  /// Constructor.
  SearchBloc({required SearchRepository searchRepository})
    : _searchRepository = searchRepository,
      super(const SearchState()) {
    on<SearchRequested>(_onSearchRequested);
    on<SearchJumpPageRequested>(_onSearchJumpPageRequested);
    on<SearchGotoNextPageRequested>(_onSearchGotoNextPageRequested);
    on<SearchGotoPreviousPageRequested>(_onSearchGotoPreviousPageRequested);
    on<SearchRetryRequested>(_onSearchRetryRequested);
    on<SearchLoadMoreRequested>(_onSearchLoadMoreRequested);
  }

  final SearchRepository _searchRepository;

  /// The last search asked (a new one or another page of it), asked again by [SearchRetryRequested].
  SearchEvent? _lastEvent;

  /// Bumped by every search that replaces the results (a new one, another page of it): a next page asked for the
  /// results before is dropped instead of being appended to the new ones.
  int _generation = 0;

  Future<void> _onSearchRetryRequested(SearchRetryRequested event, SearchEmitter emit) async {
    final last = _lastEvent;
    if (last != null) {
      add(last);
    }
  }

  /// How the user is told the failure [e] of a search: the forum's limit when the search came too early (its
  /// message and the wait of [searchRateLimitSeconds], counted from now), else as any failed load.
  LoadFailure _failureOf(AppException? e) {
    final message = e is ServerRespondedErrorException ? e.message : null;
    final wait = message == null ? null : searchRateLimitSeconds(message);
    if (wait != null) {
      return LoadFailure(LoadFailureKind.rateLimited, message: message, retryAfterSeconds: wait);
    }
    return LoadFailure.of(e);
  }

  /// The state of a search that failed with [e]: the forum's own words when it gave any, and how long to wait when
  /// the search came too early ([searchRateLimitSeconds]).
  SearchState _failedState(AppException? e) {
    final message = e is ServerRespondedErrorException ? e.message : null;
    final failure = _failureOf(e);
    return state.copyWith(
      status: SearchStatus.failed,
      hasPreviousPage: false,
      hasNextPage: false,
      failedMessage: message,
      retryAfterSeconds: message == null ? null : searchRateLimitSeconds(message),
      failedAt: failure.at,
      loadingMore: false,
      loadMoreFailed: false,
      failure: failure,
    );
  }

  /// Append the page after the last one shown to the results: the same search (its keyword, author and forum, the
  /// search id the repository keeps), so the forum's limit on new searches does not apply.
  Future<void> _onSearchLoadMoreRequested(SearchLoadMoreRequested event, SearchEmitter emit) async {
    final result = state.searchResult;
    final keyword = state.keyword;
    if (state.status != SearchStatus.success ||
        result == null ||
        keyword == null ||
        state.loadingMore ||
        result.currentPage >= result.totalPages) {
      return;
    }
    final generation = _generation;
    final page = result.currentPage + 1;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    await _searchRepository
        .searchWithParameters(
          keyword: keyword,
          fid: state.fid,
          uid: state.uid,
          authorName: state.authorName,
          pageNumber: page,
        )
        .match(
          (e) {
            handle(e);
            error('failed to load page $page of the search: $e');
            if (generation == _generation) {
              // The results shown stay, the end of the list tells the failure and retries.
              emit(state.copyWith(loadingMore: false, loadMoreFailed: true, failure: _failureOf(e)));
            }
          },
          (more) {
            if (generation != _generation) {
              return;
            }
            // A thread may show up twice when new posts moved the results between two pages.
            final known = {for (final e in result.data ?? const <SearchedThread>[]) e.tid};
            emit(
              state.copyWith(
                loadingMore: false,
                failure: null,
                pageNumber: more.currentPage,
                searchResult: SearchResult(
                  currentPage: more.currentPage,
                  totalPages: more.totalPages,
                  count: more.count ?? result.count,
                  data: [...?result.data, ...?more.data?.where((e) => !known.contains(e.tid))],
                ),
                hasPreviousPage: more.currentPage > 1,
                hasNextPage: more.currentPage < more.totalPages,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onSearchRequested(SearchRequested event, SearchEmitter emit) async {
    _lastEvent = event;
    _generation++;
    emit(
      state.copyWith(
        status: SearchStatus.loading,
        hasPreviousPage: false,
        hasNextPage: false,
        loadingMore: false,
        loadMoreFailed: false,
        failure: null,
      ),
    );
    await await _searchRepository
        .searchWithParameters(
          keyword: event.keyword,
          fid: event.fid,
          uid: event.uid,
          authorName: event.authorName,
          pageNumber: event.pageNumer,
        )
        .match(
          (e) {
            handle(e);
            error('failed to search: $e');
            emit(_failedState(e));
          },
          (searchResult) async {
            emit(
              state.copyWith(
                status: SearchStatus.success,
                keyword: event.keyword,
                fid: event.fid,
                uid: event.uid,
                authorName: event.authorName,
                searchResult: searchResult,
                pageNumber: event.pageNumer,
                hasPreviousPage: searchResult.currentPage > 1,
                hasNextPage: searchResult.currentPage < searchResult.totalPages,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onSearchJumpPageRequested(SearchJumpPageRequested event, SearchEmitter emit) async {
    _lastEvent = event;
    _generation++;
    if (state.keyword == null) {
      emit(_failedState(null));
      return;
    }

    emit(
      state.copyWith(
        status: SearchStatus.loading,
        hasPreviousPage: false,
        hasNextPage: false,
        loadingMore: false,
        loadMoreFailed: false,
        failure: null,
      ),
    );
    await await _searchRepository
        .searchWithParameters(keyword: state.keyword!, fid: state.fid, uid: state.uid, pageNumber: event.pageNumber)
        .match(
          (e) {
            handle(e);
            error('failed to search: $e');
            emit(_failedState(e));
          },
          (searchResult) async {
            emit(
              state.copyWith(
                status: SearchStatus.success,
                pageNumber: event.pageNumber,
                searchResult: searchResult,
                hasPreviousPage: searchResult.currentPage > 1,
                hasNextPage: searchResult.currentPage < searchResult.totalPages,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onSearchGotoNextPageRequested(SearchGotoNextPageRequested event, SearchEmitter emit) async {
    _lastEvent = event;
    _generation++;
    emit(
      state.copyWith(
        status: SearchStatus.loading,
        hasPreviousPage: false,
        hasNextPage: false,
        loadingMore: false,
        loadMoreFailed: false,
        failure: null,
      ),
    );
    await await _searchRepository
        .searchWithParameters(keyword: state.keyword!, fid: state.fid, uid: state.uid, pageNumber: state.pageNumber + 1)
        .match(
          (e) {
            handle(e);
            error('failed to search: $e');
            emit(_failedState(e));
          },
          (searchResult) async {
            emit(
              state.copyWith(
                status: SearchStatus.success,
                pageNumber: state.pageNumber + 1,
                searchResult: searchResult,
                hasPreviousPage: searchResult.currentPage > 1,
                hasNextPage: searchResult.currentPage < searchResult.totalPages,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onSearchGotoPreviousPageRequested(SearchGotoPreviousPageRequested event, SearchEmitter emit) async {
    _lastEvent = event;
    _generation++;
    if (state.pageNumber <= 1) {
      emit(_failedState(null));
      return;
    }

    emit(
      state.copyWith(
        status: SearchStatus.loading,
        hasPreviousPage: false,
        hasNextPage: false,
        loadingMore: false,
        loadMoreFailed: false,
        failure: null,
      ),
    );
    await await _searchRepository
        .searchWithParameters(keyword: state.keyword!, fid: state.fid, uid: state.uid, pageNumber: state.pageNumber - 1)
        .match(
          (e) {
            handle(e);
            error('failed to search: $e');
            emit(_failedState(e));
          },
          (searchResult) async {
            emit(
              state.copyWith(
                status: SearchStatus.success,
                pageNumber: state.pageNumber - 1,
                searchResult: searchResult,
                hasPreviousPage: searchResult.currentPage > 1,
                hasNextPage: searchResult.currentPage < searchResult.totalPages,
              ),
            );
          },
        )
        .run();
  }
}
