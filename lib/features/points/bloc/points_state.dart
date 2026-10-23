part of 'points_bloc.dart';

/// State of current user points.
enum PointsStatus {
  /// Initial.
  initial,

  /// Loading data.
  loading,

  /// Load succeed.
  success,

  /// Load failed.
  failed,
}

/// State of user points statistics page.
///
/// This page has no pagination and the length of points changelog is expected
/// to no more than 10.
@MappableClass()
final class PointsStatisticsState with PointsStatisticsStateMappable {
  /// Constructor.
  const PointsStatisticsState({
    this.status = PointsStatus.initial,
    this.pointsMap = const {},
    this.recentChangelog = const [],
    this.refreshing = false,
    this.failure,
  });

  /// The page is asked again while the points shown stay; they stay when it fails.
  final bool refreshing;

  /// Why the last load failed ([PointsStatus.failed], or a refresh that kept the points shown); null once one
  /// succeeded.
  final LoadFailure? failure;

  /// Status.
  final PointsStatus status;

  /// Map of user's different attributes points.
  ///
  /// With `name` and `value`.
  final Map<String, String> pointsMap;

  /// A list of changes event on user's points.
  ///
  /// But this field only contains recent changes that shows in user's points
  /// page.
  ///
  /// The length is expected to be no more than 10.
  ///
  /// For full changelog, see [PointsChangelogState.fullChangelog].
  final List<PointsChange> recentChangelog;
}

/// State of points changelog page.
@MappableClass()
final class PointsChangelogState with PointsChangelogStateMappable {
  /// Constructor.
  const PointsChangelogState({
    this.status = PointsStatus.initial,
    this.parameter = const ChangelogParameter.empty(),
    this.fullChangelog = const [],
    this.allParameters = const ChangelogAllParameters.empty(),
    this.currentPage = 1,
    this.totalPages = 1,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// The first page is asked again (a pull to refresh) while the records shown stay; they stay when it fails.
  final bool refreshing;

  /// The next page is on its way.
  final bool loadingMore;

  /// The next page failed: the records loaded before stay, the end of the list retries.
  final bool loadMoreFailed;

  /// Why the last load failed: the first page ([PointsStatus.failed]), the next page ([loadMoreFailed]), or a refresh
  /// that kept the records shown. Null once a load succeeded.
  final LoadFailure? failure;

  /// Status.
  final PointsStatus status;

  /// A list of changes event on user's points.
  ///
  /// This field contains all queried changes on user's points, may contains
  /// a long period.
  ///
  /// For recent changes, see [PointsStatisticsState.recentChangelog].
  final List<PointsChange> fullChangelog;

  /// Current page number of user's points changelog page.
  final int currentPage;

  /// Total pages count of user's points changelog page.
  final int totalPages;

  /// Parameters used to do the changelog query.
  final ChangelogParameter parameter;

  /// All available parameters that can fill in the query filter.
  ///
  /// Some parameters in query filters are choices provided by the server side.
  /// This parameter holds those parameters.
  ///
  /// e.g. points type, operation type, points change type.
  ///
  /// Also there are some parameters that not came from the server side.
  ///
  /// e.g. start time, end time.
  final ChangelogAllParameters allParameters;
}
