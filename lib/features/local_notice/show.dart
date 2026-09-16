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

/// Windows 平台使用的系统预设提示音。
///
/// 可选值见 [WindowsNotificationSound] 枚举：
/// - defaultSound: 系统默认通知音
/// - im: IM 消息音（当前使用）
/// - mail: 邮件音
/// - reminder: 提醒音
/// - sms: 短信音
/// - alarm1 ~ alarm10: 10 种闹钟音
/// - call1 ~ call10: 10 种来电音
///
/// 注意：只有系统预设音才能在未 MSIX 打包时正常播放。自定义 mp3/wav 需要 MSIX，
/// 因为 Windows 只接受 `ms-appx://` 或 `ms-resource://` 协议引用音频文件。
const WindowsNotificationSound _windowsSound = WindowsNotificationSound.im;

/// Build the notification body text of [info].
String buildLocalNotificationBody(BuildContext context, NotificationAutoSyncInfo info) =>
    localNotificationBodyOf(context.t, info);

/// [buildLocalNotificationBody] for callers without a widget tree: the background message service passes the
/// translations of the locale it loaded from the settings (#80).
String localNotificationBodyOf(Translations translations, NotificationAutoSyncInfo info) {
  final tr = translations.localNotification;
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
/// Android: high importance and priority so the notification is shown (heads-up where the OEM allows it) instead of
/// landing silently in the shade, which is what a default-importance channel did on some devices (#13). The small
/// icon is not set here on purpose: the one given to `flnp.initialize` is used.
///
/// Windows: system toast with the IM preset sound (see [_windowsSound]).
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
  windows: WindowsNotificationDetails(
    audio: WindowsNotificationAudio.preset(sound: _windowsSound),
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
/// Android: logs whether the OS reports notifications as enabled for this app before showing, because
/// `NotificationManager.notify` is a silent no-op when the app has no notification permission (#13).
///
/// Windows: shows a system toast; the IM preset sound is configured in [buildLocalNotificationDetails].
Future<void> showLocalNotification(BuildContext context, NotificationAutoSyncInfo info) async {
  if (!isAndroid && !isWindows) {
    return;
  }
  // Taken before the await below: the context must not be used across it.
  final translations = context.t;
  try {
    // Android only: Windows has no per-app switch the plugin can read. Never log the body, it carries message text.
    final enabled = isAndroid
        ? await flnp
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.areNotificationsEnabled()
        : null;
    talker.info(
      'push local notification id=$localNoticeId channel=$localNoticeChannelId enabled=$enabled: ${info.runtimeType}',
    );
    await showLocalNotificationWith(plugin: flnp, translations: translations, info: info);
  } on Exception catch (e, st) {
    talker.handle(e, st, 'push local notification failed: ');
  }
}

/// Show [info] through [plugin] with the texts of [translations]: the same notification whoever fetched it.
///
/// The in-app auto sync calls it with the app's plugin and the widget tree's translations; the Android background
/// message service with its own plugin instance and the locale it loaded from the settings (#80). Same channel and
/// payload, so a tap is handled by the existing route logic in both cases.
Future<void> showLocalNotificationWith({
  required FlutterLocalNotificationsPlugin plugin,
  required Translations translations,
  required NotificationAutoSyncInfo info,
}) async {
  final tr = translations.localNotification;
  final nd = buildLocalNotificationDetails(
    channelName: tr.channelName,
    channelDescription: tr.channelDesc,
    ticker: tr.ticker,
  );
  await plugin.show(
    id: localNoticeId,
    title: tr.notice.title,
    body: localNotificationBodyOf(translations, info),
    notificationDetails: nd,
    payload: LocalNoticeKeys.openNotification,
  );
}

/// Log whether the auto sync notification is still in the shade, Android only.
///
/// Read when the app comes back to the foreground. With the tap log it narrows a report down: a tap log means the
/// tap reached Dart; no tap log while the notification is still shown means nothing was tapped; no tap log and the
/// notification gone means either the user swiped it away or the tap never reached the app, which the log alone can
/// not tell apart (#14). Failures are logged and swallowed.
Future<void> logActiveLocalNotifications() async {
  if (!isAndroid) {
    return;
  }
  try {
    final active = await flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.getActiveNotifications();
    final shown = active?.any((e) => e.id == localNoticeId) ?? false;
    talker.debug('auto sync notification in shade: $shown');
  } on Exception catch (e, st) {
    talker.handle(e, st, 'read active notifications failed: ');
  }
}
