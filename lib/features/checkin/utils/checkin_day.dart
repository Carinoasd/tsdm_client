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
