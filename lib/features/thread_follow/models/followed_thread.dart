import 'package:flutter/foundation.dart';

/// A thread an account follows: checked for new replies in the background and announced when some came
/// (`checkFollowedThreads`).
///
/// [seenReplies] are the replies of the thread when the account last read it (opened the thread page, or followed it),
/// [knownReplies] the replies the last check found; the difference is what is new ([newReplies]). [notified] holds
/// while those new replies were announced and the thread was not read since: a thread is announced once until it is
/// read again.
///
/// The replies are the ones the forum paginates the floors by (the forum's app API `thread.replies`, the number of
/// floors after the first), not the "回复: N" of the info row, which counts the comments too: a comment brings no floor
/// to read on the last page. A web page without the plugin only tells the latter, for the check and the thread page
/// alike.
@immutable
final class FollowedThread {
  /// Constructor.
  const FollowedThread({
    required this.tid,
    required this.title,
    required this.seenReplies,
    required this.knownReplies,
    required this.followedAt,
    this.lastReplyAt,
    this.checkedAt,
    this.notified = false,
    this.fromSync = false,
  });

  /// Read one entry written by [toJson]; null when it is not one.
  static FollowedThread? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final tid = json['tid'];
    if (tid is! int || tid <= 0) {
      return null;
    }
    int count(Object? v) => v is int && v > 0 ? v : 0;
    DateTime? time(Object? v) => v is int && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    final seen = count(json['seen']);
    return FollowedThread(
      tid: tid,
      title: json['title'] is String ? json['title'] as String : '',
      seenReplies: seen,
      knownReplies: json['known'] is int ? count(json['known']) : seen,
      followedAt: time(json['followed']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      lastReplyAt: time(json['last']),
      checkedAt: time(json['checked']),
      notified: json['notified'] == true,
      fromSync: json['synced'] == true,
    );
  }

  /// Thread id.
  final int tid;

  /// Title of the thread, as it was when last read or checked.
  final String title;

  /// Replies of the thread when the account last read it.
  final int seenReplies;

  /// Replies of the thread the last check found (or when it was read, when that is later).
  final int knownReplies;

  /// When the thread was followed.
  final DateTime followedAt;

  /// Time of the newest floor the last check or read saw; null when not known.
  final DateTime? lastReplyAt;

  /// When the thread was last checked, null before its first check: the threads checked longest ago go first.
  final DateTime? checkedAt;

  /// Whether the new replies were announced and the thread not read since.
  final bool notified;

  /// Whether the thread came from another device of the account (the cross-device sync) and was neither checked nor
  /// read here since: its first check only takes the replies it has then as seen, nothing is announced.
  final bool fromSync;

  /// Replies posted since the account last read the thread.
  int get newReplies => knownReplies > seenReplies ? knownReplies - seenReplies : 0;

  /// The entry as it is stored.
  Map<String, dynamic> toJson() => {
    'tid': tid,
    'title': title,
    'seen': seenReplies,
    'known': knownReplies,
    'followed': followedAt.millisecondsSinceEpoch,
    if (lastReplyAt != null) 'last': lastReplyAt!.millisecondsSinceEpoch,
    if (checkedAt != null) 'checked': checkedAt!.millisecondsSinceEpoch,
    if (notified) 'notified': true,
    if (fromSync) 'synced': true,
  };

  /// A copy with the fields given.
  FollowedThread copyWith({
    String? title,
    int? seenReplies,
    int? knownReplies,
    DateTime? lastReplyAt,
    DateTime? checkedAt,
    bool? notified,
    bool? fromSync,
  }) => FollowedThread(
    tid: tid,
    title: title ?? this.title,
    seenReplies: seenReplies ?? this.seenReplies,
    knownReplies: knownReplies ?? this.knownReplies,
    followedAt: followedAt,
    lastReplyAt: lastReplyAt ?? this.lastReplyAt,
    checkedAt: checkedAt ?? this.checkedAt,
    notified: notified ?? this.notified,
    fromSync: fromSync ?? this.fromSync,
  );

  /// The thread read now with [replies] (null: not known, what was known stays), [title] and the newest floor seen
  /// at [lastReplyAt]: nothing is new any more, the next replies are announced again.
  FollowedThread read({int? replies, String? title, DateTime? lastReplyAt}) {
    final now = replies ?? knownReplies;
    return copyWith(
      title: title == null || title.isEmpty ? null : title,
      seenReplies: now,
      knownReplies: now,
      lastReplyAt: lastReplyAt != null && (this.lastReplyAt == null || lastReplyAt.isAfter(this.lastReplyAt!))
          ? lastReplyAt
          : null,
      notified: false,
      fromSync: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FollowedThread &&
      other.tid == tid &&
      other.title == title &&
      other.seenReplies == seenReplies &&
      other.knownReplies == knownReplies &&
      other.followedAt == followedAt &&
      other.lastReplyAt == lastReplyAt &&
      other.checkedAt == checkedAt &&
      other.notified == notified &&
      other.fromSync == fromSync;

  @override
  int get hashCode =>
      Object.hash(tid, title, seenReplies, knownReplies, followedAt, lastReplyAt, checkedAt, notified, fromSync);

  @override
  String toString() =>
      'FollowedThread(tid: $tid, seen: $seenReplies, known: $knownReplies, notified: $notified, '
      'checked: $checkedAt)';
}
