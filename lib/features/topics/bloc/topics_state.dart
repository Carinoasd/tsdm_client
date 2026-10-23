part of 'topics_bloc.dart';

/// Data status of the homepage of the app (the first tab in home).
enum TopicsStatus {
  /// Initial state.
  initial,

  /// Loading the page.
  loading,

  /// Load data finished.
  success,

  /// Failed to load data.
  failed
  ;

  /// Is [initial].
  bool get isInitial => this == TopicsStatus.initial;

  /// Is [loading].
  bool get isLoading => this == TopicsStatus.loading;

  /// Is [success].
  bool get isSuccess => this == TopicsStatus.success;

  /// Is [failed].
  bool get isFailed => this == TopicsStatus.failed;
}

/// State of topics page.
@MappableClass()
final class TopicsState with TopicsStateMappable {
  /// Constructor.
  const TopicsState({
    this.status = TopicsStatus.initial,
    this.topicsTab = 0,
    this.forumGroupList = const [],
    this.refreshing = false,
    this.failure,
  });

  /// Status.
  final TopicsStatus status;

  /// Current tab index.
  final int topicsTab;

  /// All forums to show.
  final List<ForumGroup> forumGroupList;

  /// A refresh the user asked for is on its way while the groups loaded stay on screen; they stay when it fails.
  final bool refreshing;

  /// Why the last load failed ([TopicsStatus.failed]), or the refresh that kept the groups shown; null once a load
  /// succeeded.
  final LoadFailure? failure;
}
