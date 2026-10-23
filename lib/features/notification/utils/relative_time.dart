import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The day a notification belongs to in the lists: today, yesterday or earlier, by the device's calendar.
enum NotificationDay {
  /// Today, or a time ahead of the device's clock.
  today,

  /// Yesterday.
  yesterday,

  /// Any day before yesterday.
  earlier,
}

/// The day of [time] seen at [now], see [NotificationDay].
NotificationDay notificationDayOf(DateTime time, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  if (!time.isBefore(today)) {
    return NotificationDay.today;
  }
  // Calendar days, not 24 hours: daylight saving time makes a day 23 or 25 hours long.
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  return time.isBefore(yesterday) ? NotificationDay.earlier : NotificationDay.yesterday;
}

/// Title of the group [day] in the lists.
String notificationDayLabel(Translations tr, NotificationDay day) => switch (day) {
  NotificationDay.today => tr.noticePage.time.today,
  NotificationDay.yesterday => tr.noticePage.time.yesterday,
  NotificationDay.earlier => tr.noticePage.time.earlier,
};

/// [time] relative to [now], as a card shows it: "刚刚", "3 分钟前", "2 小时前" today, "昨天 12:30", "9-3 08:15" this
/// year, the full date before.
///
/// A time ahead of the device's clock (a few minutes of skew with the forum) is "just now".
String relativeTimeOf(Translations tr, DateTime time, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final t = tr.noticePage.time;
  final diff = at.difference(time);
  if (diff.inMinutes < 1) {
    return t.justNow;
  }
  final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  switch (notificationDayOf(time, at)) {
    case NotificationDay.today:
      if (diff.inHours < 1) {
        return t.minutesAgo(n: diff.inMinutes);
      }
      return t.hoursAgo(n: diff.inHours);
    case NotificationDay.yesterday:
      return t.yesterdayAt(time: hm);
    case NotificationDay.earlier:
      if (time.year == at.year) {
        return '${time.month}-${time.day} $hm';
      }
      return time.yyyyMMDDHHMM();
  }
}
