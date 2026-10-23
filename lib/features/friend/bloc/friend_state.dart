part of 'friend_bloc.dart';

/// Status of the friends list page.
enum FriendStatus {
  /// Initial.
  initial,

  /// Loading the first page.
  loading,

  /// The server asked to login.
  needLogin,

  /// The server answered a notice instead of the list, e.g. the list is private.
  notice,

  /// The list is available.
  success,

  /// Failed to load the first page.
  failure,
}

/// State of the friends list page.
@MappableClass()
final class FriendState with FriendStateMappable {
  /// Constructor.
  const FriendState({
    this.status = FriendStatus.initial,
    this.items = const [],
    this.nextPageUrl,
    this.totalCount,
    this.ownerName,
    this.message,
    this.pageNumber = 1,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// Status.
  final FriendStatus status;

  /// All loaded friends.
  final List<Friend> items;

  /// Url of the next page, null when all pages are loaded.
  final String? nextPageUrl;

  /// Total friends count told by the page.
  final int? totalCount;

  /// Name of the user whose friends are listed.
  final String? ownerName;

  /// Notice shown instead of the list.
  final String? message;

  /// Number of the last loaded page.
  final int pageNumber;

  /// Reloading the first page.
  final bool refreshing;

  /// Loading the next page.
  final bool loadingMore;

  /// The next page failed: the friends loaded before stay, the end of the list retries.
  final bool loadMoreFailed;

  /// Why the last load failed: the first page ([FriendStatus.failure]), the next page ([loadMoreFailed]), or a refresh
  /// that kept the friends shown. Null once a load succeeded.
  final LoadFailure? failure;
}
