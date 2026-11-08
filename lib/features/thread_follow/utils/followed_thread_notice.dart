import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

const _followedIdBase = 0x20000000;
const _followedIdMask = 0x0FFFFFFF;

/// Id of the notification of the new replies of followed thread [tid]: one per thread, a later one replacing it.
///
/// Apart from the notifications of the auto sync ([localNoticeId], [localNoticeIdOf]) and the persistent one of the
/// background message service.
int followedThreadNoticeId(int tid) => _followedIdBase | (tid & _followedIdMask);

/// Longest thread title written in a notification, in characters.
const _titleLength = 24;

/// What is posted for the new replies of [thread], followed by account [uid]: id, title, body, payload.
///
/// The body says "《title》有 N 条新回复"; with [hideContent] (`SettingsKeys.notificationHideContent`) the thread is
/// not named. A tap opens the last floor of the thread as that account ([LocalNoticeTarget.lastPost]), switching to
/// it first when another one is in use by then, as a notification of a single notice does.
({int id, String title, String body, String payload}) followedThreadNoticeContentOf(
  Translations translations,
  FollowedThread thread, {
  required int uid,
  bool hideContent = false,
}) {
  final tr = translations.followedThreads.notice;
  final n = thread.newReplies;
  return (
    id: followedThreadNoticeId(thread.tid),
    title: translations.localNotification.channels.followedThread,
    body: hideContent || thread.title.isEmpty
        ? tr.hidden(n: n)
        : tr.body(title: thread.title.truncate(_titleLength, ellipsis: true), n: n),
    payload: LocalNoticeKeys.withTarget(
      LocalNoticeKeys.openNotificationOf(uid),
      LocalNoticeTarget(tid: thread.tid, lastPost: true),
    ),
  );
}

/// Post the notification of the new replies of [thread] (followed by account [uid]) through [plugin], in the channel
/// of [NoticeCategory.followedThread].
Future<void> showFollowedThreadNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required Translations translations,
  required FollowedThread thread,
  required int uid,
  bool hideContent = false,
}) async {
  final content = followedThreadNoticeContentOf(translations, thread, uid: uid, hideContent: hideContent);
  final details = buildLocalNotificationDetails(
    channelName: noticeChannelName(translations, NoticeCategory.followedThread),
    category: NoticeCategory.followedThread,
    channelDescription: translations.localNotification.channelDesc,
    ticker: translations.localNotification.ticker,
    title: content.title,
    body: content.body,
  );
  await plugin.show(
    id: content.id,
    title: content.title,
    body: content.body,
    notificationDetails: details,
    payload: content.payload,
  );
}
