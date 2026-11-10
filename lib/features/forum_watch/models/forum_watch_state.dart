import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';

/// Most alerts kept per account ([ForumWatchState.alerts]): the threads announced are never announced again while
/// they are kept; the oldest go first.
const forumWatchAlertsKept = 300;

int _int(Object? v) => v is int ? v : 0;

/// A new thread the check found for the account: announced (when the rules allowed it) and kept so it is never
/// announced again.
///
/// [keywords] are the alert keywords its title contains, empty for a thread announced as new in a forum watched.
@immutable
final class WatchAlert {
  /// Constructor.
  const WatchAlert({
    required this.tid,
    required this.fid,
    required this.title,
    required this.author,
    required this.at,
    this.forumName = '',
    this.keywords = const [],
  });

  /// Read one entry written by [toJson]; null when it is not one.
  static WatchAlert? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final tid = json['tid'];
    if (tid is! int || tid <= 0) {
      return null;
    }
    String text(Object? v) => v is String ? v : '';
    return WatchAlert(
      tid: tid,
      fid: _int(json['fid']),
      title: text(json['title']),
      author: text(json['author']),
      forumName: text(json['forum']),
      at: DateTime.fromMillisecondsSinceEpoch(_int(json['at'])),
      keywords: [
        for (final k in json['keywords'] is List ? json['keywords'] as List : const [])
          if (k is String && k.isNotEmpty) k,
      ],
    );
  }

  /// Thread id.
  final int tid;

  /// Forum of the thread, 0 when not known.
  final int fid;

  /// Name of the forum, empty when not known.
  final String forumName;

  /// Title of the thread.
  final String title;

  /// Name of the author, empty for an anonymous one.
  final String author;

  /// When it was found.
  final DateTime at;

  /// The alert keywords the title contains, as entered.
  final List<String> keywords;

  /// The entry as stored.
  Map<String, dynamic> toJson() => {
    'tid': tid,
    'fid': fid,
    'title': title,
    'author': author,
    if (forumName.isNotEmpty) 'forum': forumName,
    'at': at.millisecondsSinceEpoch,
    if (keywords.isNotEmpty) 'keywords': keywords,
  };

  @override
  bool operator ==(Object other) =>
      other is WatchAlert &&
      other.tid == tid &&
      other.fid == fid &&
      other.forumName == forumName &&
      other.title == title &&
      other.author == author &&
      other.at == at &&
      listEquals(other.keywords, keywords);

  @override
  int get hashCode => Object.hash(tid, fid, forumName, title, author, at, Object.hashAll(keywords));
}

/// What the check of one account knows: per source the highest thread id seen ([marks], the threads above it are new),
/// and the threads found ([alerts]).
@immutable
final class ForumWatchState {
  /// Constructor.
  const ForumWatchState({this.marks = const {}, this.alerts = const []});

  /// Read what [toJson] wrote; nothing known for anything else.
  factory ForumWatchState.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const ForumWatchState();
    }
    final marks = <String, int>{};
    if (json['marks'] case final Map<String, dynamic> m) {
      for (final MapEntry(:key, :value) in m.entries) {
        if (value is int && value > 0) {
          marks[key] = value;
        }
      }
    }
    return ForumWatchState(
      marks: marks,
      alerts: forumWatchEntriesOf(json['alerts'], WatchAlert.fromJson, (a) => a.tid),
    );
  }

  /// Per source (`forumWatchForumSource`, `forumWatchLatestSource`) the highest thread id seen; a source without one
  /// was never read: its first reading only sets it.
  final Map<String, int> marks;

  /// The threads found, the latest first, at most [forumWatchAlertsKept].
  final List<WatchAlert> alerts;

  /// Whether thread [tid] was found already.
  bool alerted(int tid) => alerts.any((a) => a.tid == tid);

  /// This state with [found] put first (the oldest beyond [forumWatchAlertsKept] dropped).
  ForumWatchState withAlerts(List<WatchAlert> found) {
    if (found.isEmpty) {
      return this;
    }
    final tids = {for (final a in found) a.tid};
    return ForumWatchState(
      marks: marks,
      alerts: [...found, ...alerts.where((a) => !tids.contains(a.tid))].take(forumWatchAlertsKept).toList(),
    );
  }

  /// This state with the mark of [source] set to [tid] (removed when null).
  ForumWatchState withMark(String source, int? tid) => ForumWatchState(
    marks: {
      for (final MapEntry(:key, :value) in marks.entries)
        if (key != source) key: value,
      source: ?tid,
    },
    alerts: alerts,
  );

  /// This state with only the marks of [sources].
  ForumWatchState onlyMarks(Iterable<String> sources) {
    final keep = sources.toSet();
    return ForumWatchState(
      marks: {
        for (final MapEntry(:key, :value) in marks.entries)
          if (keep.contains(key)) key: value,
      },
      alerts: alerts,
    );
  }

  /// The state as stored.
  Map<String, dynamic> toJson() => {
    'marks': marks,
    'alerts': [for (final a in alerts) a.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is ForumWatchState && mapEquals(other.marks, marks) && listEquals(other.alerts, alerts);

  @override
  int get hashCode => Object.hash(Object.hashAll(marks.entries.map((e) => (e.key, e.value))), Object.hashAll(alerts));
}
