import 'package:tsdm_client/features/points/models/models.dart';

/// Whether the changelog record [change] is the reward of a check-in.
///
/// The check-in plugin writes its reward as a record without an operation code, titled with the plugin's name and
/// worded as a check-in ("每日签到", detail "恭喜你签到成功！…" / "签到额外奖励"), so the record is told by the word.
///
/// Marked as public for testing.
bool isCheckinRecord(PointsChange change) => change.operation.contains('签到') || change.detail.contains('签到');

/// The calendar days (date only) of [changes] on which the account checked in. A check-in may write two records (the
/// reward and a bonus), so the days are a set.
///
/// Marked as public for testing.
Set<DateTime> checkinDaysOf(Iterable<PointsChange> changes) => {
  for (final change in changes)
    if (isCheckinRecord(change)) DateTime(change.time.year, change.time.month, change.time.day),
};

/// The number of days in a row ending at [today] (or at the day before when [today] is not checked yet) that are in
/// [days], and the first day that is not (the day before the row), which the caller reads further back when the row
/// reached the oldest day it knows.
///
/// Marked as public for testing.
({int length, DateTime before}) checkinStreakOf(Set<DateTime> days, DateTime today) {
  var day = DateTime(today.year, today.month, today.day);
  if (!days.contains(day)) {
    day = DateTime(day.year, day.month, day.day - 1);
  }
  var length = 0;
  while (days.contains(day)) {
    length += 1;
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return (length: length, before: day);
}

/// Today as the forum counts it: the calendar day of UTC+8, whatever the zone of the device. The records of the
/// changelog are the forum's wall clock of the offset the member set (+8 unless changed), which this assumes.
DateTime forumToday([DateTime? now]) {
  final t = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 8));
  return DateTime(t.year, t.month, t.day);
}
