part of 'models.dart';

/// A thread record in the current user's favorites list.
///
/// Comes from `home.php?mod=space&do=favorite&type=thread`, one `<li id="fav_FAVID">` per record.
@MappableClass()
final class FavoriteThread with FavoriteThreadMappable {
  /// Constructor.
  const FavoriteThread({
    required this.favid,
    required this.tid,
    required this.title,
    required this.url,
    this.time,
    this.description,
  });

  /// Id of the favorite record, required when removing it.
  final String favid;

  /// Thread id.
  final String tid;

  /// Thread title.
  final String title;

  /// Absolute url of the thread.
  final String url;

  /// Time the thread was added to favorites.
  final DateTime? time;

  /// Optional note written when adding the favorite.
  final String? description;
}
