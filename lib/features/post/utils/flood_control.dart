/// The forum's refusal of a post sent too soon after the previous one (`post_flood_ctrl`): `抱歉，您两次发表间隔少于 15 秒，
/// 请稍候再发表` in the simplified pack, `抱歉，您兩次發表間隔少於 15 秒，請稍候再發表` in the traditional one.
final _floodRe = RegExp(r'(?:间隔|間隔)\s*(?:少于|少於)\s*(\d+)\s*秒');

/// The interval the forum asks between two posts, in seconds, when [message] is its refusal of a post sent too soon
/// (`post_flood_ctrl`); null for any other message. The interval is the forum's setting, not the time left.
int? floodControlSeconds(String? message) {
  if (message == null) {
    return null;
  }
  final seconds = int.tryParse(_floodRe.firstMatch(message)?.group(1) ?? '');
  return seconds != null && seconds > 0 ? seconds : null;
}

/// When each account last posted from the app in this run, to tell how long the forum still refuses the next post.
abstract final class FloodControl {
  static final _postedAt = <int, DateTime>{};

  /// The clock, replaced by tests.
  static DateTime Function() now = DateTime.now;

  /// Account [uid] just posted.
  static void notePosted(int? uid) {
    if (uid != null && uid > 0) {
      _postedAt[uid] = now();
    }
  }

  /// When account [uid] may post again after the forum refused a post for an interval of [seconds]: [seconds] after
  /// the last post the app knows of, or after now when it knows none (the last post was made elsewhere; the forum
  /// counts from that one, so this is never too early).
  static DateTime retryAt(int? uid, int seconds) {
    final current = now();
    final posted = uid == null ? null : _postedAt[uid];
    final interval = Duration(seconds: seconds);
    if (posted != null && current.difference(posted) < interval && !posted.isAfter(current)) {
      return posted.add(interval);
    }
    return current.add(interval);
  }

  /// Forget every post (tests).
  static void reset() {
    _postedAt.clear();
    now = DateTime.now;
  }
}
