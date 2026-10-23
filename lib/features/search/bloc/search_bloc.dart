import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
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
  }

  final SearchRepository _searchRepository;

  /// The last search asked (a new one or another page of it), asked again by [SearchRetryRequested].
  SearchEvent? _lastEvent;

  Future<void> _onSearchRetryRequested(SearchRetryRequested event, SearchEmitter emit) async {
    final last = _lastEvent;
    if (last != null) {
      add(last);
    }
  }

  /// The state of a search that failed with [e]: the forum's own words when it gave any, and how long to wait when
  /// the search came too early ([searchRateLimitSeconds]).
  SearchState _failedState(AppException? e) {
    final message = e is ServerRespondedErrorException ? e.message : null;
    return state.copyWith(
      status: SearchStatus.failed,
      hasPreviousPage: false,
      hasNextPage: false,
      failedMessage: message,
      retryAfterSeconds: message == null ? null : searchRateLimitSeconds(message),
      failedAt: DateTime.now(),
    );
  }

  Future<void> _onSearchRequested(SearchRequested event, SearchEmitter emit) async {
    _lastEvent = event;
    emit(state.copyWith(status: SearchStatus.loading, hasPreviousPage: false, hasNextPage: false));
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
    if (state.keyword == null) {
      emit(_failedState(null));
      return;
    }

    emit(state.copyWith(status: SearchStatus.loading, hasPreviousPage: false, hasNextPage: false));
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
    emit(state.copyWith(status: SearchStatus.loading, hasPreviousPage: false, hasNextPage: false));
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
    if (state.pageNumber <= 1) {
      emit(_failedState(null));
      return;
    }

    emit(state.copyWith(status: SearchStatus.loading, hasPreviousPage: false, hasNextPage: false));
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
