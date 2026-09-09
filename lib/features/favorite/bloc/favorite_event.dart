part of 'favorite_bloc.dart';

/// Events of the favorites page.
@MappableClass()
sealed class FavoriteEvent with FavoriteEventMappable {
  const FavoriteEvent();
}

/// Load the first page, used when entering the page and when retrying after a failure.
@MappableClass()
final class FavoriteLoadRequested extends FavoriteEvent with FavoriteLoadRequestedMappable {
  /// Constructor.
  const FavoriteLoadRequested();
}

/// Reload from the first page (pull to refresh).
@MappableClass()
final class FavoriteRefreshRequested extends FavoriteEvent with FavoriteRefreshRequestedMappable {
  /// Constructor.
  const FavoriteRefreshRequested();
}

/// Load the next page.
@MappableClass()
final class FavoriteLoadMoreRequested extends FavoriteEvent with FavoriteLoadMoreRequestedMappable {
  /// Constructor.
  const FavoriteLoadMoreRequested();
}

/// Remove [item] from favorites.
@MappableClass()
final class FavoriteRemoveRequested extends FavoriteEvent with FavoriteRemoveRequestedMappable {
  /// Constructor.
  const FavoriteRemoveRequested(this.item);

  /// Record to remove.
  final FavoriteItem item;
}
