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
    this.visitedAt,
    this.visitedText,
  });

  /// The friend of a row [row] of the structured friends answer (plugin 2.5.0, `schema: 10`, `friends[]`): the
  /// member (`uid`, `username`), the small avatar, the user group (`grouptitle`, `groupcolor`: the color the forum
  /// prints the name and the group with) and, on another member's list ([ownList] false), the credits the page
  /// prints ("积分数: N"; none for 0, as `space_list` prints them only when not 0); the owner's own list prints none,
  /// as the page prints none there. The group icon
  /// (`groupicon`, plugin 2.6.0: an absolute url, empty when the group has none) as the page prints it beside the
  /// group. Null for a member who is not there any more (`username` empty, `anonymous` 1: the page prints "匿名"
  /// without a link), as the page parser skips a row without the member's link.
  ///
  /// On the visitors list (`view=visitor`, [visitTimeOffset] given: the `timeoffset` of the answer) the row's `dateline`
  /// is the time of the visit, kept as [visitedAt] in the forum's wall clock.
  static Friend? fromApi(Map<String, dynamic> row, {required bool ownList, num? visitTimeOffset}) {
    final uid = tsdmAppInt(row['uid']);
    final username = tsdmAppText(row['username']).trim();
    if (uid <= 0 || username.isEmpty) {
      return null;
    }
    final avatar = tsdmAppText(row['avatar']).trim();
    final groupName = tsdmAppText(row['grouptitle']).trim();
    final groupColor = tsdmAppText(row['groupcolor']).trim();
    final groupIcon = tsdmAppText(row['groupicon']).trim();
    final credits = tsdmAppInt(row['credits']);
    return Friend(
      uid: '$uid',
      username: username,
      avatarUrl: avatar.isEmpty ? null : avatar.prependHost(),
      nameColor: groupColor.isEmpty ? null : groupColor,
      groupName: groupName.isEmpty ? null : groupName,
      groupColor: groupColor.isEmpty ? null : groupColor,
      groupIconUrl: groupIcon.isEmpty ? null : groupIcon.prependHost(),
      credits: ownList || credits == 0 ? null : '$credits',
      visitedAt: visitTimeOffset == null ? null : tsdmAppWallClockTime(row['dateline'], visitTimeOffset),
    );
  }

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

  /// When this member visited the space, on the visitors list: the forum's wall clock, null elsewhere.
  final DateTime? visitedAt;

  /// The date the visitors page prints for the visit ("11月8日", no year, no time), when the list came from the web
  /// page; [visitedAt] is null then.
  final String? visitedText;
}
