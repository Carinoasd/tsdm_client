import 'package:flutter/foundation.dart';

/// The day `yyyyMMdd` of [time], as the reading time rows key it.
int readingDayKey(DateTime time) => time.year * 10000 + time.month * 100 + time.day;

/// The date a [readingDayKey] stands for.
DateTime readingDayOf(int key) => DateTime(key ~/ 10000, key ~/ 100 % 100, key % 100);

/// Seconds spent reading one forum on one day.
@immutable
final class ReadingTimeRow {
  /// Constructor.
  const ReadingTimeRow({required this.day, required this.fid, required this.forumName, required this.seconds});

  /// The day as [readingDayKey].
  final int day;

  /// The forum.
  final int fid;

  /// The name of the forum.
  final String forumName;

  /// Seconds read.
  final int seconds;
}

/// The share of one forum in the reading time.
@immutable
final class ReadingForumShare {
  /// Constructor.
  const ReadingForumShare({required this.fid, required this.forumName, required this.seconds});

  /// The forum; null for the forums past the first ones, summed up.
  final int? fid;

  /// The name of the forum; empty for [fid] null.
  final String forumName;

  /// Seconds read.
  final int seconds;
}

/// What the reading statistics page shows.
@immutable
final class ReadingTimeSummary {
  const ReadingTimeSummary._({
    required this.today,
    required this.week,
    required this.month,
    required this.days,
    required this.forums,
  });

  /// Sum [rows] as of [now]: today, this week (from Monday), this month, the last [dayCount] days (oldest first, the
  /// last one is today) and the [forumCount] forums read the longest over those days.
  factory ReadingTimeSummary.of(
    Iterable<ReadingTimeRow> rows, {
    required DateTime now,
    int dayCount = 14,
    int forumCount = 5,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - DateTime.monday));
    final monthStart = DateTime(today.year, today.month);
    final todayKey = readingDayKey(today);
    final weekKey = readingDayKey(weekStart);
    final monthKey = readingDayKey(monthStart);

    final dayList = [for (var i = dayCount - 1; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
    final firstKey = readingDayKey(dayList.first);
    final perDay = <int, int>{for (final d in dayList) readingDayKey(d): 0};
    final perForum = <int, ({String name, int seconds})>{};

    var todaySeconds = 0;
    var weekSeconds = 0;
    var monthSeconds = 0;
    for (final row in rows) {
      if (row.day > todayKey || row.seconds <= 0) {
        continue;
      }
      if (row.day == todayKey) {
        todaySeconds += row.seconds;
      }
      if (row.day >= weekKey) {
        weekSeconds += row.seconds;
      }
      if (row.day >= monthKey) {
        monthSeconds += row.seconds;
      }
      if (row.day >= firstKey) {
        perDay.update(row.day, (v) => v + row.seconds, ifAbsent: () => row.seconds);
        final old = perForum[row.fid];
        perForum[row.fid] = (
          name: row.forumName.isEmpty ? (old?.name ?? '') : row.forumName,
          seconds: (old?.seconds ?? 0) + row.seconds,
        );
      }
    }

    final ranked = perForum.entries.toList()
      ..sort((a, b) {
        final byTime = b.value.seconds.compareTo(a.value.seconds);
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });
    final forums = [
      for (final e in ranked.take(forumCount))
        ReadingForumShare(fid: e.key, forumName: e.value.name, seconds: e.value.seconds),
    ];
    final rest = ranked.skip(forumCount).fold<int>(0, (sum, e) => sum + e.value.seconds);
    if (rest > 0) {
      forums.add(ReadingForumShare(fid: null, forumName: '', seconds: rest));
    }

    return ReadingTimeSummary._(
      today: todaySeconds,
      week: weekSeconds,
      month: monthSeconds,
      days: [for (final d in dayList) (day: d, seconds: perDay[readingDayKey(d)] ?? 0)],
      forums: forums,
    );
  }

  /// Seconds read today.
  final int today;

  /// Seconds read this week.
  final int week;

  /// Seconds read this month.
  final int month;

  /// Seconds read each of the last days, oldest first.
  final List<({DateTime day, int seconds})> days;

  /// The forums read the longest over [days], longest first; the rest summed up last.
  final List<ReadingForumShare> forums;

  /// Whether nothing was read over [days].
  bool get isEmpty => days.every((d) => d.seconds == 0);

  /// Seconds read over [days].
  int get total => days.fold(0, (sum, d) => sum + d.seconds);
}
