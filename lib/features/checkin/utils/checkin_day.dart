/// Whether [lastCheckin] falls on the same calendar day as [now] (the device's local day, `DateTime.now()` when
/// omitted).
///
/// The forum counts check-ins per day, so "checked in today" is a day comparison, not a 24 hour window: a check-in at
/// 23:59 is over one minute later. Both the auto check-in skip list and the manage accounts page use this, so the two
/// always agree. Null means the account never checked in from this device.
bool isCheckedInToday(DateTime? lastCheckin, {DateTime? now}) {
  if (lastCheckin == null) {
    return false;
  }
  final today = now ?? DateTime.now();
  return lastCheckin.year == today.year && lastCheckin.month == today.month && lastCheckin.day == today.day;
}

/// Hour (device-local) from which the forum takes check-ins: it opens at 1:00 and closes at 23:59 (see doc 50).
const checkinOpenHour = 1;

/// The next moment after [now] at which the check-in state of a running app changes: just after midnight, when
/// yesterday's "checked in" is over, and just after check-in opens at [checkinOpenHour], when the auto check-in of
/// the day can run.
DateTime nextCheckinDayBoundary(DateTime now) {
  final candidates = [
    DateTime(now.year, now.month, now.day, 0, 0, 5),
    DateTime(now.year, now.month, now.day, checkinOpenHour, 0, 30),
    DateTime(now.year, now.month, now.day + 1, 0, 0, 5),
  ];
  return candidates.firstWhere((t) => t.isAfter(now));
}

/// Whether the auto check-in of an app that kept running should start at [now], [lastRun] being when it last
/// started in this run (null: not yet).
///
/// Due once check-in is open, unless it already ran today after check-in opened: a run before 1:00 only got "not open
/// yet" and recorded nothing, so it does not count.
bool autoCheckinDue(DateTime? lastRun, DateTime now) {
  if (now.hour < checkinOpenHour) {
    return false;
  }
  return lastRun == null || !isCheckedInToday(lastRun, now: now) || lastRun.hour < checkinOpenHour;
}
