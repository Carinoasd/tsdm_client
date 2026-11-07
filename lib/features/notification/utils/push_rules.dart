import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The categories the system notifications of the auto sync are switched on and off by, and the Android channels they
/// are posted in.
///
/// Only what is announced follows them: the notification page lists everything whatever the settings.
enum NoticeCategory {
  /// Replies to a thread or post of the user, and posts quoting one.
  reply,

  /// The user was mentioned (`@`).
  mention,

  /// A post of the user was rated or commented.
  rate,

  /// Private messages.
  pm,

  /// Broadcast messages and every other kind of notice: the forum's system notices, moderation, friends, medals...
  system
  ;

  /// The setting that switches this category on.
  SettingsKeys<bool> get settingsKey => switch (this) {
    reply => SettingsKeys.notifyReply,
    mention => SettingsKeys.notifyMention,
    rate => SettingsKeys.notifyRate,
    pm => SettingsKeys.notifyPersonalMessage,
    system => SettingsKeys.notifySystem,
  };

  /// Id of the Android notification channel of this category.
  String get channelId => switch (this) {
    reply => 'noticeReply',
    mention => 'noticeMention',
    rate => 'noticeRate',
    pm => 'noticePm',
    system => 'noticeSystem',
  };
}

/// The category of a notice of [kind].
NoticeCategory noticeCategoryOf(NoticeKind kind) => switch (kind) {
  NoticeKind.reply || NoticeKind.quote || NoticeKind.post => NoticeCategory.reply,
  NoticeKind.mention => NoticeCategory.mention,
  NoticeKind.rate || NoticeKind.comment => NoticeCategory.rate,
  _ => NoticeCategory.system,
};

/// The category of the notice [notice], told by its `type` and `from_idtype` alone: the kinds that need more to be told
/// apart (a reply from a post, a friend from a friend request) fall in the same category.
NoticeCategory categoryOfNotice(NoticeV2 notice) =>
    noticeCategoryOf(noticeKindOf(type: notice.ignoreType, fromIdType: notice.fromIdType));

/// Whether the minute of the day [minute] is inside the quiet hours from [start] to [end] (minutes after midnight).
///
/// The window may pass midnight (23:00 to 08:00); [start] is inside, [end] is not. Equal bounds are an empty window.
bool inQuietWindow({required int minute, required int start, required int end}) {
  if (start == end) {
    return false;
  }
  return start < end ? minute >= start && minute < end : minute >= start || minute < end;
}

/// What the settings allow the auto sync to announce, see [NotificationPushRules.read].
///
/// Read fresh from the settings table by every sync, the background service runs in an isolate of its own that is told
/// nothing of a change made in the app.
final class NotificationPushRules {
  /// Constructor.
  const NotificationPushRules({
    this.enabled = const {...NoticeCategory.values},
    this.quietHours = false,
    this.quietStart = 23 * 60,
    this.quietEnd = 8 * 60,
  });

  /// Everything announced, the rules of a settings table without the keys.
  static const all = NotificationPushRules();

  /// The categories announced.
  final Set<NoticeCategory> enabled;

  /// Whether the quiet hours are on.
  final bool quietHours;

  /// Start of the quiet hours, minutes after midnight.
  final int quietStart;

  /// End of the quiet hours, minutes after midnight.
  final int quietEnd;

  /// Read the rules from [storage]; a key the table lacks (settings of an older version) keeps its default.
  static Future<NotificationPushRules> read(StorageProvider storage) async {
    final enabled = <NoticeCategory>{};
    for (final category in NoticeCategory.values) {
      final key = category.settingsKey;
      if (await storage.getBool(key.name) ?? key.defaultValue) {
        enabled.add(category);
      }
    }
    return NotificationPushRules(
      enabled: enabled,
      quietHours:
          await storage.getBool(SettingsKeys.notifyQuietHours.name) ?? SettingsKeys.notifyQuietHours.defaultValue,
      quietStart:
          await storage.getInt(SettingsKeys.notifyQuietStart.name) ?? SettingsKeys.notifyQuietStart.defaultValue,
      quietEnd: await storage.getInt(SettingsKeys.notifyQuietEnd.name) ?? SettingsKeys.notifyQuietEnd.defaultValue,
    );
  }

  /// Whether [now] is inside the quiet hours.
  bool isQuiet(DateTime now) =>
      quietHours && inQuietWindow(minute: now.hour * 60 + now.minute, start: quietStart, end: quietEnd);

  /// What of [fresh] is announced at [now]: nothing inside the quiet hours (and not afterwards either: the sync
  /// stores the notifications and moves on, what came meanwhile is on the notification page), otherwise [fresh]
  /// without the categories switched off.
  NotificationV2 apply(NotificationV2 fresh, DateTime now) {
    if (isQuiet(now)) {
      return NotificationV2.empty;
    }
    if (enabled.length == NoticeCategory.values.length) {
      return fresh;
    }
    return NotificationV2(
      status: fresh.status,
      noticeList: [
        for (final e in fresh.noticeList)
          if (enabled.contains(categoryOfNotice(e))) e,
      ],
      personalMessageList: enabled.contains(NoticeCategory.pm) ? fresh.personalMessageList : const [],
      broadcastMessageList: enabled.contains(NoticeCategory.system) ? fresh.broadcastMessageList : const [],
    );
  }
}
