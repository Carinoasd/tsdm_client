import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:universal_html/html.dart' as uh;

/// A member in a list of the followed or of the followers (`home.php?mod=follow&do=following|follower`).
final class FollowUser {
  /// Constructor.
  const FollowUser({
    required this.uid,
    required this.username,
    this.avatarUrl,
    this.remark,
    this.recentNote,
    this.followerCount,
    this.followingCount,
    this.following,
    this.mutual = false,
    this.canRemark = false,
  });

  /// The member.
  final int uid;

  /// Their name.
  final String username;

  /// Their avatar.
  final String? avatarUrl;

  /// The name the viewer noted for them (备注), in the viewer's own list of the followed.
  final String? remark;

  /// What they did last ("最近动作").
  final String? recentNote;

  /// How many follow them.
  final int? followerCount;

  /// How many they follow.
  final int? followingCount;

  /// Whether the viewer follows them, as the forum printed its link (取消关注 or 关注); null when it printed none (the
  /// viewer in another member's list, a list of another member).
  final bool? following;

  /// They and the viewer follow each other ("互相关注").
  final bool mutual;

  /// The forum printed the link to note a name for them.
  final bool canRemark;
}

/// What the viewer is to a member, read from the head of that member's follow pages.
final class FollowRelation {
  /// Constructor.
  const FollowRelation({
    required this.session,
    required this.uid,
    required this.following,
    required this.followsViewer,
    this.username,
    this.remark,
    this.feedCount,
    this.followingCount,
    this.followerCount,
  });

  /// The account the page was served to and its form hash.
  final SpaceSession session;

  /// The member.
  final int uid;

  /// Their name.
  final String? username;

  /// The viewer follows them.
  final bool following;

  /// They follow the viewer ("TA已关注您", or "互相关注" once followed back).
  final bool followsViewer;

  /// The name the viewer noted for them.
  final String? remark;

  /// How many broadcasts they have.
  final int? feedCount;

  /// How many they follow.
  final int? followingCount;

  /// How many follow them.
  final int? followerCount;

  /// With the given fields changed, after a post the forum took.
  FollowRelation copyWith({bool? following, String? remark, int? followerCount}) => FollowRelation(
    session: session,
    uid: uid,
    username: username,
    following: following ?? this.following,
    followsViewer: followsViewer,
    // No name is noted for a member no longer followed.
    remark: (following ?? this.following) ? (remark ?? this.remark) : null,
    feedCount: feedCount,
    followingCount: followingCount,
    followerCount: followerCount ?? this.followerCount,
  );
}

/// Which broadcasts a page lists.
enum FollowFeedView {
  /// Of the members the account follows, and its own (`view=follow`).
  follow,

  /// Of everyone (`view=other`, "广播大厅").
  hall,
}

/// A broadcast (`home.php?mod=follow`): a member posted a thread, replied to one, or relayed one with a note.
final class FollowFeed {
  /// Constructor.
  const FollowFeed({
    required this.feedId,
    required this.uid,
    required this.username,
    this.time,
    this.note,
    this.threadId,
    this.threadTitle,
    this.content,
    this.threadMissing = false,
    this.origin,
    this.forumName,
    this.relayCount,
    this.replyCount,
    this.canRelay = false,
    this.canDelete = false,
  });

  /// Its id.
  final int feedId;

  /// Who broadcast.
  final int uid;

  /// Their name.
  final String username;

  /// When, as the forum wrote it.
  final String? time;

  /// What they said with it (a reply, the note of a relay), as the forum rendered it; null for a new thread.
  final uh.Element? note;

  /// The thread.
  final int? threadId;

  /// Its title; none for a broadcast posted without one.
  final String? threadTitle;

  /// The beginning of the thread as the forum rendered it.
  final uh.Element? content;

  /// The thread is gone ("内容已被删除").
  final bool threadMissing;

  /// Under a note: who posted the thread and when ("NAME 发表于 2026-11-7 22:05").
  final String? origin;

  /// The forum of the thread.
  final String? forumName;

  /// How many times the thread was relayed.
  final int? relayCount;

  /// How many replies the thread has.
  final int? replyCount;

  /// The forum printed its relay link.
  final bool canRelay;

  /// The forum printed its delete link: the member's own broadcast (or an administrator).
  final bool canDelete;
}
