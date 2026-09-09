import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Id of the notification channel carrying auto sync results.
///
/// Android creates a channel on the first show with the importance given then and never lets the app raise it
/// afterwards, so the first channel (`newNoticeChannel`, default importance, see [legacyLocalNoticeChannelId]) could
/// not be fixed in place: this is its replacement with high importance (#13). Keep the id stable from now on; a new
/// id is only worth it together with deleting the old channel at boot ([deleteLegacyLocalNoticeChannel]).
const localNoticeChannelId = 'newNoticeChannelV2';

/// Id of the channel used before [localNoticeChannelId].
///
/// Deleted at boot so the user does not keep a dead channel in the system notification settings.
const legacyLocalNoticeChannelId = 'newNoticeChannel';

/// Id of the notification carrying the auto sync result.
///
/// One id: a newer result replaces the previous notification instead of piling up.
const localNoticeId = 0;

/// Build the notification body text of [info].
String buildLocalNotificationBody(BuildContext context, NotificationAutoSyncInfo info) {
  final tr = context.t.localNotification;
  return switch (info) {
    NotificationAutoSyncInfoNotice(:final msg, :final notice, :final personalMessage, :final broadcastMessage) =>
      tr.notice.detail.notice(noticeCount: notice, pmCount: personalMessage, bmCount: broadcastMessage, msg: msg),
    NotificationAutoSyncInfoPm(
      :final user,
      :final msg,
      :final notice,
      :final personalMessage,
      :final broadcastMessage,
    ) =>
      tr.notice.detail.pm(
        noticeCount: notice,
        pmCount: personalMessage,
        bmCount: broadcastMessage,
        user: user,
        msg: msg,
      ),
    NotificationAutoSyncInfoBm(:final msg, :final notice, :final personalMessage, :final broadcastMessage) =>
      tr.notice.detail.bm(noticeCount: notice, pmCount: personalMessage, bmCount: broadcastMessage, msg: msg),
  };
}

/// Build the platform details of the auto sync notification.
///
/// High importance and priority so the notification is shown (heads-up where the OEM allows it) instead of landing
/// silently in the shade, which is what a default-importance channel did on some devices (#13). The small icon is not
/// set here on purpose: the one given to `flnp.initialize` is used.
NotificationDetails buildLocalNotificationDetails({
  required String channelName,
  required String channelDescription,
  required String ticker,
}) => NotificationDetails(
  android: AndroidNotificationDetails(
    localNoticeChannelId,
    channelName,
    channelDescription: channelDescription,
    ticker: ticker,
    importance: Importance.high,
    priority: Priority.high,
  ),
);

/// Delete the channel that carried the notifications before [localNoticeChannelId] existed.
///
/// Android only, call once at boot after the plugin is initialized. Deleting a channel that does not exist is a no-op
/// on the platform; any failure is logged and swallowed because it must not block the boot.
Future<void> deleteLegacyLocalNoticeChannel() async {
  if (!isAndroid) {
    return;
  }
  try {
    await flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.deleteNotificationChannel(channelId: legacyLocalNoticeChannelId);
    talker.debug('deleted legacy local notification channel $legacyLocalNoticeChannelId');
  } on Exception catch (e, st) {
    talker.handle(e, st, 'delete legacy local notification channel $legacyLocalNoticeChannelId failed: ');
  }
}

/// Show the auto sync result [info] as a local notification.
///
/// Android only. Logs whether the OS reports notifications as enabled for this app before showing, because
/// `NotificationManager.notify` is a silent no-op when the app has no notification permission (#13).
Future<void> showLocalNotification(BuildContext context, NotificationAutoSyncInfo info) async {
  if (!isAndroid) {
    return;
  }
  final tr = context.t.localNotification;
  final nd = buildLocalNotificationDetails(
    channelName: tr.channelName,
    channelDescription: tr.channelDesc,
    ticker: tr.ticker,
  );
  final body = buildLocalNotificationBody(context, info);
  final title = tr.notice.title;
  try {
    final enabled = await flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled();
    talker.info(
      'push local notification id=$localNoticeId channel=$localNoticeChannelId enabled=$enabled: ${info.runtimeType}',
    );
    await flnp.show(
      id: localNoticeId,
      title: title,
      body: body,
      notificationDetails: nd,
      payload: LocalNoticeKeys.openNotification,
    );
  } on Exception catch (e, st) {
    talker.handle(e, st, 'push local notification failed: ');
  }
}
