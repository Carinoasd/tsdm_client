part of 'models.dart';

/// One friend in a user's friends list (`home.php?mod=space&uid=UID&do=friend`).
@MappableClass()
final class Friend with FriendMappable {
  /// Constructor.
  const Friend({
    required this.uid,
    required this.username,
    this.avatarUrl,
    this.nameColor,
    this.groupName,
    this.groupColor,
    this.groupIconUrl,
    this.credits,
  });

  /// User id.
  final String uid;

  /// Username.
  final String username;

  /// Absolute avatar url, null when the user has no avatar.
  final String? avatarUrl;

  /// Css color of the username (user group color), e.g. `Red`, `blue`, `#ff0000`; null for the default color.
  final String? nameColor;

  /// Name of the user group.
  final String? groupName;

  /// Css color of the user group name, if the forum colors it.
  final String? groupColor;

  /// Absolute url of the user group icon.
  final String? groupIconUrl;

  /// Credits (积分数) as shown by the forum.
  final String? credits;
}
