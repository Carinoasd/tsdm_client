import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The time offsets (hours) the forum shows the times of each account with (`timeoffset` of the `notify` answer), by
/// uid; 8 for an account not seen yet.
///
/// The stored notification times are the member's wall clock read as the device's local time (see [apiTimeOf]), so
/// "now" has to be the member's wall clock too ([memberNowOf]): with the device's own clock a device in New York
/// showed every notice as "just now" and one in Tokyo a notice that just came as "1 hour ago".
final class NotificationTimeOffsets {
  NotificationTimeOffsets._();

  static final _offsets = <int, num>{};

  static String _key(int uid) => 'notificationTimeOffset.$uid';

  /// The offset of [uid], 8 when unknown.
  static num of(int? uid) => _offsets[uid] ?? 8;

  /// Remember the offset [hours] of [uid], also in [storage] for the next start.
  static Future<void> remember(StorageProvider? storage, int uid, num hours) async {
    if (_offsets[uid] == hours) {
      return;
    }
    _offsets[uid] = hours;
    await storage?.saveString(_key(uid), '$hours');
  }

  /// Load the stored offset of [uid] from [storage], when not known yet in this run.
  static Future<void> load(StorageProvider storage, int uid) async {
    if (_offsets.containsKey(uid)) {
      return;
    }
    final stored = num.tryParse(await storage.getString(_key(uid)) ?? '');
    if (stored != null) {
      _offsets[uid] = stored;
    }
  }

  /// Forget every offset, for tests.
  static void reset() => _offsets.clear();
}

/// The member's wall clock at [deviceNow] for the offset [offsetHours], read as the device's local time like the
/// stored notification times ([apiTimeOf]).
DateTime memberNowOf(DateTime deviceNow, num offsetHours) =>
    DateTime.fromMillisecondsSinceEpoch(apiTimeOf(deviceNow.millisecondsSinceEpoch ~/ 1000, offsetHours) * 1000);

/// A time ahead of "now" by up to this much is "just now": the minutes the forum's clock and the device's differ.
const _clockSkew = Duration(minutes: 5);

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
/// [now] is the member's wall clock ([memberNowOf]) like [time]. A time ahead of it by a few minutes (the clocks of
/// the forum and the device differ) is "just now"; further ahead, the time itself.
String relativeTimeOf(Translations tr, DateTime time, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final t = tr.noticePage.time;
  final diff = at.difference(time);
  final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (diff.isNegative && -diff > _clockSkew) {
    return time.year == at.year ? '${time.month}-${time.day} $hm' : time.yyyyMMDDHHMM();
  }
  if (diff.inMinutes < 1) {
    return t.justNow;
  }
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
