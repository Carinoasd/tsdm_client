import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
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

/// Whether the auto sync posts system notifications on this platform: Android and Windows.
///
/// Elsewhere nothing is shown ([showLocalNotification]), so nothing that only changes notifications is offered there
/// (the setting to announce every logged-in account).
bool get autoSyncPostsNotifications => isAndroid || isWindows;

/// Id of the notification of account [uid] while the auto sync announces every logged-in account
/// (`SettingsKeys.backgroundSyncAllAccounts`): one notification per account, a newer result replacing only that
/// account's. Never [localNoticeId], nor the persistent notification of the service (`backgroundSyncNotificationId`).
int localNoticeIdOf(int uid) => _accountIdBase | (uid & _accountIdMask);

const _accountIdBase = 0x10000000;
const _accountIdMask = 0x0FFFFFFF;

/// Whether [id] is the id of an auto sync notification: [localNoticeId] or one of [localNoticeIdOf].
bool isLocalNoticeId(int? id) => id == localNoticeId || (id != null && (id & ~_accountIdMask) == _accountIdBase);

/// The account a notification is about, see [showLocalNotificationWith].
final class LocalNoticeAccount {
  /// Constructor.
  const LocalNoticeAccount({required this.uid, this.username, this.named = false});

  /// The account.
  final int uid;

  /// Its name, for the title of a [named] notification.
  final String? username;

  /// Whether every saved account is announced (`SettingsKeys.backgroundSyncAllAccounts`): the title names the account,
  /// the account gets a notification of its own ([localNoticeIdOf]) and the payload names it. Otherwise the
  /// notification is exactly what it always was, one for the account in use.
  final bool named;
}

/// What is posted for an auto sync result: id, title, body and payload of the notification, and the lines and the
/// summary of its expanded form (Android's inbox style; empty for a single new item).
typedef LocalNotificationContent = ({
  int id,
  String title,
  String body,
  String payload,
  List<String> lines,
  String? summary,
});

/// Build the notification of [info] with the texts of [translations], about [account] when known.
///
/// The title and the body say who did what: "A 回复了你的帖子" and the thread, "B 发来私信" and the message, the text
/// of the notice when its kind has no sentence of its own. With several new items the body adds the counts, and the
/// expanded notification lists them (the lines of the content, newest first) with the counts as its summary.
/// A result without the details (built elsewhere, the test notification of the settings page) keeps the old texts.
///
/// A [LocalNoticeAccount.named] notification (every logged-in account announced) names its account in the title, has
/// an id of its own ([localNoticeIdOf]) and a payload naming the account ([LocalNoticeKeys.openNotificationOf]): a tap
/// opens the notice page as that account, switching to it first when another one is in use by then. Any other
/// notification is the one it always was: one id, the payload of the account in use
/// ([LocalNoticeKeys.openNotification]).
///
/// A notification of a single new item also carries what it is about ([LocalNoticeKeys.withTarget]): the floor of the
/// notice, the conversation of the message. A tap opens that instead of the notice page, as the same account.
LocalNotificationContent localNotificationContentOf(
  Translations translations,
  NotificationAutoSyncInfo info, {
  LocalNoticeAccount? account,
}) {
  final tr = translations.localNotification;
  final head = _headOf(translations, info);
  final named = account != null && account.named;
  final username = account?.username;
  final String title;
  if (named && username != null && username.isNotEmpty) {
    title = head.title == null ? tr.notice.titleOf(username: username) : '[$username] ${head.title}';
  } else {
    title = head.title ?? tr.notice.title;
  }
  final base = named ? LocalNoticeKeys.openNotificationOf(account.uid) : LocalNoticeKeys.openNotification;
  final target = info.total == 1 ? _targetOf(info) : null;
  final several = info.total > 1 && info.lines.isNotEmpty;
  final counts = _countsOf(translations, info);
  return (
    id: named ? localNoticeIdOf(account.uid) : localNoticeId,
    title: title,
    body: several ? '${head.body}\n$counts' : head.body,
    payload: target == null ? base : LocalNoticeKeys.withTarget(base, target),
    lines: several ? [for (final line in info.lines) _lineOf(translations, line)] : const [],
    summary: several
        ? (info.total > info.lines.length ? '$counts · ${tr.notice.more(n: info.total - info.lines.length)}' : counts)
        : null,
  );
}

/// Title (null for the old generic one) and body of the notification of [info].
({String? title, String body}) _headOf(Translations translations, NotificationAutoSyncInfo info) {
  final tr = translations.localNotification.notice;
  switch (info) {
    case NotificationAutoSyncInfoPm(:final user, :final msg, :final peerUid, :final lines):
      // A result without the details keeps the old body: the counts and the message.
      if (peerUid == null && lines.isEmpty) {
        return (title: null, body: localNotificationBodyOf(translations, info));
      }
      return (title: tr.pmFrom(user: user), body: msg);
    case NotificationAutoSyncInfoBm(:final msg, :final lines):
      if (lines.isEmpty) {
        return (title: null, body: localNotificationBodyOf(translations, info));
      }
      return (title: tr.bmTitle, body: msg);
    case NotificationAutoSyncInfoNotice(
      :final msg,
      :final nid,
      :final author,
      :final noticeType,
      :final fromIdType,
      :final threadTitle,
      :final quote,
      :final tid,
      :final pid,
    ):
      if (nid == null) {
        return (title: null, body: localNotificationBodyOf(translations, info));
      }
      final kind = noticeKindOf(
        type: noticeType,
        fromIdType: fromIdType,
        target: tid == null && pid == null ? null : NoticeTarget(tid: tid, pid: pid),
      );
      final action = noticeActionOf(translations, kind, author);
      if (action == null) {
        // The forum's text already says who did what.
        return (title: tr.noticeTitle, body: msg);
      }
      final detail = [if (threadTitle != null) '《$threadTitle》', ?quote].join(' ');
      return (title: action, body: detail.isEmpty ? msg : detail);
  }
}

/// What a tap on the notification of [info], a single new item, opens; null when it names nothing.
LocalNoticeTarget? _targetOf(NotificationAutoSyncInfo info) {
  final target = switch (info) {
    NotificationAutoSyncInfoNotice(:final nid, :final tid, :final pid) => LocalNoticeTarget(
      nid: nid,
      tid: tid,
      pid: pid,
    ),
    NotificationAutoSyncInfoPm(:final peerUid) => LocalNoticeTarget(peerUid: peerUid),
    NotificationAutoSyncInfoBm() => null,
  };
  return target == null || target.isEmpty ? null : target;
}

/// The counts of new items of [info], the kinds with none left out: "2 条提醒 · 1 条私信".
String _countsOf(Translations translations, NotificationAutoSyncInfo info) {
  final tr = translations.localNotification.notice;
  return [
    if (info.notice > 0) tr.noticeCount(n: info.notice),
    if (info.personalMessage > 0) tr.pmCount(n: info.personalMessage),
    if (info.broadcastMessage > 0) tr.bmCount(n: info.broadcastMessage),
  ].join(' · ');
}

/// One line of the expanded notification.
String _lineOf(Translations translations, NotificationAutoSyncLine line) {
  final tr = translations.localNotification.notice;
  return switch (line.kind) {
    NotificationAutoSyncLineKind.notice => line.text,
    NotificationAutoSyncLineKind.personalMessage => tr.pmLine(user: line.user ?? '', msg: line.text),
    NotificationAutoSyncLineKind.broadcastMessage => tr.bmLine(msg: line.text),
  };
}

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
///
/// [title], [body], [lines] and [summary] are the texts of the notification ([LocalNotificationContent]): Android
/// shows [lines] in the inbox style when there are any, the whole [body] otherwise.
NotificationDetails buildLocalNotificationDetails({
  required String channelName,
  required String channelDescription,
  required String ticker,
  String? title,
  String? body,
  List<String> lines = const [],
  String? summary,
}) => NotificationDetails(
  android: AndroidNotificationDetails(
    localNoticeChannelId,
    channelName,
    channelDescription: channelDescription,
    ticker: ticker,
    importance: Importance.high,
    priority: Priority.high,
    // Several new items are listed one per line when expanded; a single one shows its whole text.
    styleInformation: lines.isNotEmpty
        ? InboxStyleInformation(lines, contentTitle: title, summaryText: summary)
        : (body != null ? BigTextStyleInformation(body, contentTitle: title) : null),
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
///
/// [account] is the account the result is about (the account in use for the in-app auto sync), see
/// [localNotificationContentOf].
Future<void> showLocalNotification(
  BuildContext context,
  NotificationAutoSyncInfo info, {
  LocalNoticeAccount? account,
}) async {
  if (!autoSyncPostsNotifications) {
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
    final id = account != null && account.named ? localNoticeIdOf(account.uid) : localNoticeId;
    talker.info(
      'push local notification id=$id channel=$localNoticeChannelId enabled=$enabled: ${info.runtimeType}',
    );
    await showLocalNotificationWith(plugin: flnp, translations: translations, info: info, account: account);
  } on Exception catch (e, st) {
    talker.handle(e, st, 'push local notification failed: ');
  }
}

/// Show [info] through [plugin] with the texts of [translations]: the same notification whoever fetched it.
///
/// The in-app auto sync calls it with the app's plugin and the widget tree's translations; the Android background
/// message service with its own plugin instance and the locale it loaded from the settings (#80). Same channel and
/// payload, so a tap is handled by the existing route logic in both cases. What is posted for [account] is
/// [localNotificationContentOf].
Future<void> showLocalNotificationWith({
  required FlutterLocalNotificationsPlugin plugin,
  required Translations translations,
  required NotificationAutoSyncInfo info,
  LocalNoticeAccount? account,
}) async {
  final tr = translations.localNotification;
  final content = localNotificationContentOf(translations, info, account: account);
  final nd = buildLocalNotificationDetails(
    channelName: tr.channelName,
    channelDescription: tr.channelDesc,
    ticker: tr.ticker,
    title: content.title,
    body: content.body,
    lines: content.lines,
    summary: content.summary,
  );
  await plugin.show(
    id: content.id,
    title: content.title,
    body: content.body,
    notificationDetails: nd,
    payload: content.payload,
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
    final shown = active?.any((e) => isLocalNoticeId(e.id)) ?? false;
    talker.debug('auto sync notification in shade: $shown');
  } on Exception catch (e, st) {
    talker.handle(e, st, 'read active notifications failed: ');
  }
}
