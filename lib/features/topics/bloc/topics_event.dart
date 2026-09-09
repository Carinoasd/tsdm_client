part of 'topics_bloc.dart';

/// Event of topics page.
@MappableClass()
sealed class TopicsEvent with TopicsEventMappable {
  const TopicsEvent();
}

/// User requested to load page.
///
/// Load from cache if available.
@MappableClass()
final class TopicsLoadRequested extends TopicsEvent with TopicsLoadRequestedMappable {}

/// User requested to refresh page.
///
/// Directly load from server.
@MappableClass()
final class TopicsRefreshRequested extends TopicsEvent with TopicsRefreshRequestedMappable {
  /// Constructor.
  const TopicsRefreshRequested({this.silent = false});

  /// Keep showing the current groups while loading, and keep them when the fetch fails.
  ///
  /// Used for reloads the user did not ask for (auth change, favorite forum change).
  final bool silent;
}

/// User changed the current tab.
@MappableClass()
final class TopicsTabSelected extends TopicsEvent with TopicsTabSelectedMappable {
  /// Constructor.
  const TopicsTabSelected(this.tabIndex) : super();

  /// Current tab index.
  final int tabIndex;
}

/// A fresh `forum.php` document was fetched, by this bloc or by the homepage.
@MappableClass()
final class TopicsDocumentUpdated extends TopicsEvent with TopicsDocumentUpdatedMappable {
  /// Constructor.
  const TopicsDocumentUpdated(this.document);

  /// The new document.
  final uh.Document document;
}

/// Authentication status changed.
@MappableClass()
final class TopicsAuthChanged extends TopicsEvent with TopicsAuthChangedMappable {
  /// Constructor.
  const TopicsAuthChanged({required this.prev, required this.curr});

  /// Previous status.
  final AuthStatus prev;

  /// Current status.
  final AuthStatus curr;
}
