part of 'search_bloc.dart';

/// Status of search.
enum SearchStatus {
  /// Initial.
  initial,

  /// Loading.
  loading,

  /// Load succeed.
  success,

  /// Load failed.
  failed
  ;

  /// Is in searching.
  bool isSearching() => this == SearchStatus.loading;
}

/// State of search page.
@MappableClass()
class SearchState with SearchStateMappable {
  /// Constructor.
  const SearchState({
    this.status = SearchStatus.initial,
    this.keyword,
    this.fid = '0',
    this.uid = '0',
    this.authorName = '',
    this.searchResult,
    this.pageNumber = 1,
    this.hasNextPage = false,
    this.hasPreviousPage = false,
    this.failedMessage,
    this.retryAfterSeconds,
    this.failedAt,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// Status.
  final SearchStatus status;

  /// Search keyword;
  final String? keyword;

  /// Search in which forum;
  final String fid;

  /// Search for which user.
  final String uid;

  /// Search for which user, by name. Empty for any user.
  final String authorName;

  /// Current search page number.
  final int pageNumber;

  /// Flag indicating have a previous page to jump to or not.
  final bool hasPreviousPage;

  /// Flag indicating have a next page to jump to or not.
  final bool hasNextPage;

  /// Search result.
  final SearchResult? searchResult;

  /// The forum's own words when the last search failed with them (too frequent, expired, no permission), null for
  /// any other failure (the network).
  final String? failedMessage;

  /// The forum allows one search in so many seconds and the last one came too early ([searchRateLimitSeconds]): the
  /// seconds to wait from [failedAt]. Null for any other failure.
  final int? retryAfterSeconds;

  /// When the last search failed.
  final DateTime? failedAt;

  /// The next page of the results is on its way, appended to them once it came.
  final bool loadingMore;

  /// The next page of the results failed: the results shown stay, the end of the list retries.
  final bool loadMoreFailed;

  /// Why the last search ([SearchStatus.failed]) or the next page of it ([loadMoreFailed]) failed, as the user is
  /// told; null once one succeeded.
  final LoadFailure? failure;
}
