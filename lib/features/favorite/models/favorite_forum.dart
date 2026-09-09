part of 'models.dart';

/// A forum record in the current user's favorites list.
///
/// Comes from `home.php?mod=space&do=favorite&type=forum`, one `<li id="fav_FAVID">` per record.
@MappableClass()
final class FavoriteForum extends FavoriteItem with FavoriteForumMappable {
  /// Constructor.
  const FavoriteForum({
    required super.favid,
    required this.fid,
    required super.title,
    required super.url,
    super.time,
    super.description,
  });

  /// Forum id.
  final String fid;

  @override
  FavoriteType get type => FavoriteType.forum;

  @override
  String get targetId => fid;
}
