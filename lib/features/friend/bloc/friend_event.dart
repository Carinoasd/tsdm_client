part of 'friend_bloc.dart';

/// Events of the friends list page.
@MappableClass()
sealed class FriendEvent with FriendEventMappable {
  const FriendEvent();
}

/// Load the first page.
@MappableClass()
final class FriendLoadRequested extends FriendEvent with FriendLoadRequestedMappable {
  /// Constructor.
  const FriendLoadRequested();
}

/// Reload from the first page (pull to refresh).
@MappableClass()
final class FriendRefreshRequested extends FriendEvent with FriendRefreshRequestedMappable {
  /// Constructor.
  const FriendRefreshRequested();
}

/// Load the next page.
@MappableClass()
final class FriendLoadMoreRequested extends FriendEvent with FriendLoadMoreRequestedMappable {
  /// Constructor.
  const FriendLoadMoreRequested();
}
