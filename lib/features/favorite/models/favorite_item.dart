part of 'models.dart';

/// One record in the current user's favorites list, a thread or a forum.
///
/// Comes from `home.php?mod=space&do=favorite&type=TYPE`, one `<li id="fav_FAVID">` per record.
@MappableClass()
sealed class FavoriteItem with FavoriteItemMappable {
  /// Constructor.
  const FavoriteItem({required this.favid, required this.title, required this.url, this.time, this.description});

  /// Id of the favorite record, required when removing it.
  final String favid;

  /// Title of the thread or name of the forum.
  final String title;

  /// Absolute url of the target.
  final String url;

  /// Time the record was added to favorites.
  final DateTime? time;

  /// Optional note written when adding the favorite.
  final String? description;

  /// Kind of the record.
  FavoriteType get type;

  /// Id of the target: tid of a thread, fid of a forum.
  String get targetId;
}
