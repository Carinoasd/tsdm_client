import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Id of the notification channel carrying auto sync results.
///
/// Keep it stable: Android creates the channel on the first show and never updates it from code afterwards.
const localNoticeChannelId = 'newNoticeChannel';

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

/// Show the auto sync result [info] as a local notification.
///
/// Android only. Logs whether the OS reports notifications as enabled for this app before showing, because
/// `NotificationManager.notify` is a silent no-op when the app has no notification permission (#13).
Future<void> showLocalNotification(BuildContext context, NotificationAutoSyncInfo info) async {
  if (!isAndroid) {
    return;
  }
  final tr = context.t.localNotification;
  final and = AndroidNotificationDetails(
    localNoticeChannelId,
    tr.channelName,
    channelDescription: tr.channelDesc,
    ticker: tr.ticker,
  );
  final nd = NotificationDetails(android: and);
  final body = buildLocalNotificationBody(context, info);
  final title = tr.notice.title;
  try {
    final enabled = await flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled();
    talker.info('push local notification enabled=$enabled: ${info.runtimeType}');
    await flnp.show(
      id: 0,
      title: title,
      body: body,
      notificationDetails: nd,
      payload: LocalNoticeKeys.openNotification,
    );
  } on Exception catch (e, st) {
    talker.handle(e, st, 'push local notification failed: ');
  }
}
