part of 'models.dart';

/// Kind of a favorite record, the `type` query parameter of the favorite pages (`type=thread`, `type=forum`).
///
/// Discuz! also knows group, blog, album and article; the forum only uses threads and forums.
enum FavoriteType {
  /// A thread (帖子).
  thread,

  /// A forum (版块).
  forum
  ;

  /// Value of the `type` query parameter.
  String get queryValue => name;
}
