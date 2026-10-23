part of 'favorite_bloc.dart';

/// Status of the favorites page.
enum FavoriteStatus {
  /// Initial.
  initial,

  /// Loading the first page for the first time.
  loading,

  /// No user logged in, or the server asked to login.
  needLogin,

  /// The list is available.
  success,

  /// Failed to load the first page.
  failure,
}

/// State of the favorites page.
@MappableClass()
final class FavoriteState with FavoriteStateMappable {
  /// Constructor.
  const FavoriteState({
    this.status = FavoriteStatus.initial,
    this.items = const [],
    this.nextPageUrl,
    this.pageNumber = 1,
    this.refreshing = false,
    this.loadingMore = false,
    this.removing = const [],
    this.removedCount = 0,
    this.failureCount = 0,
    this.lastFailure,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// Status.
  final FavoriteStatus status;

  /// All loaded records, threads or forums depending on the bloc's type.
  final List<FavoriteItem> items;

  /// Url of the next page, null when all pages are loaded.
  final String? nextPageUrl;

  /// Number of the last loaded page.
  final int pageNumber;

  /// Reloading the first page.
  final bool refreshing;

  /// Loading the next page.
  final bool loadingMore;

  /// Favids of the records being removed.
  final List<String> removing;

  /// Counts successful removals, so the page can react to each one.
  final int removedCount;

  /// Counts failed removals, so the page can react to each one.
  final int failureCount;

  /// Reason of the last failed removal, if the server told any.
  final String? lastFailure;

  /// The next page failed: the records loaded before stay, the end of the list retries.
  final bool loadMoreFailed;

  /// Why the last load failed: the first page ([FavoriteStatus.failure]), the next page ([loadMoreFailed]), or a
  /// refresh that kept the records shown. Null once a load succeeded.
  final LoadFailure? failure;
}
