part of 'latest_thread_bloc.dart';

/// Status of the latest thread feature.
enum LatestThreadStatus {
  /// Initial.
  initial,

  /// Loading.
  loading,

  /// Success.
  success,

  /// Failed to load.
  failed,
}

/// State of the latest thread feature.
@MappableClass()
final class LatestThreadState with LatestThreadStateMappable {
  /// Constructor.
  const LatestThreadState({
    this.status = LatestThreadStatus.initial,
    this.threadList = const [],
    this.pageNumber = 1,
    this.nextPageUrl,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// Status.
  final LatestThreadStatus status;

  /// All thread to display.
  final List<LatestThread> threadList;

  /// Current page number.
  final int pageNumber;

  /// Url to fetch the next page.
  final String? nextPageUrl;

  /// The first page is asked again (a pull to refresh) while the threads loaded stay on screen; they stay when it
  /// fails.
  final bool refreshing;

  /// The next page is on its way.
  final bool loadingMore;

  /// The next page failed: the threads loaded before stay, the end of the list retries.
  final bool loadMoreFailed;

  /// Why the last load failed: the first page ([LatestThreadStatus.failed]), the next page ([loadMoreFailed]), or a
  /// refresh that kept the threads shown. Null once a load succeeded.
  final LoadFailure? failure;
}
