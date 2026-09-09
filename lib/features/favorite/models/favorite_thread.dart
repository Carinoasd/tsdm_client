part of 'models.dart';

/// A thread record in the current user's favorites list.
///
/// Comes from `home.php?mod=space&do=favorite&type=thread`, one `<li id="fav_FAVID">` per record.
@MappableClass()
final class FavoriteThread extends FavoriteItem with FavoriteThreadMappable {
  /// Constructor.
  const FavoriteThread({
    required super.favid,
    required this.tid,
    required super.title,
    required super.url,
    super.time,
    super.description,
  });

  /// Thread id.
  final String tid;

  @override
  FavoriteType get type => FavoriteType.thread;

  @override
  String get targetId => tid;
}
