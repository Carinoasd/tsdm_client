part of 'models.dart';

/// A group of [Forum].
@MappableClass()
final class ForumGroup with ForumGroupMappable {
  /// Constructor.
  const ForumGroup({required this.name, required this.url, required this.forumList, this.moderators = const []});

  /// Forum name.
  final String name;

  /// Forum url.
  final String url;

  /// All subreddit in the forum.
  final List<Forum> forumList;

  /// Names of the group moderators ("分区版主" in the group header on `forum.php`), empty when the site lists none.
  final List<String> moderators;

  /// True for the "我收藏的版块" panel Discuz! renders on `forum.php` for a member with favorite forums.
  ///
  /// Its header links to the favorites list (`home.php?mod=space&do=favorite&type=forum`) instead of a
  /// `forum.php?gid=N` page.
  bool get isFavorites => url.contains('do=favorite');
}
