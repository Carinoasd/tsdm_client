import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_state.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_check.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

const _forumIdBase = 0x30000000;
const _keywordIdBase = 0x40000000;
const _idMask = 0x0FFFFFFF;

/// Id of the notification of the new threads of watched forum [fid]: one per forum, a later one replacing it.
///
/// Not per account, on purpose: only the account in use is checked, and the notification left from an account used
/// before is about a forum the account in use may watch too; the latest one is what a tap should open. The 28 bits
/// of the forum id leave no room for the uid either.
///
/// Apart from the notifications of the auto sync (`localNoticeId`, `localNoticeIdOf`), of the followed threads
/// (`followedThreadNoticeId`) and the persistent one of the background message service.
int forumWatchForumNoticeId(int fid) => _forumIdBase | (fid & _idMask);

/// Id of the notification of the threads found with an alert keyword for account [uid]: one per account, a later one
/// replacing it.
int forumWatchKeywordNoticeId(int uid) => _keywordIdBase | (uid & _idMask);

/// Whether [id] is the id of a notification of the watched forums or the alert keywords.
bool isForumWatchNoticeId(int? id) =>
    id != null && ((id & ~_idMask) == _forumIdBase || (id & ~_idMask) == _keywordIdBase);

/// Longest thread title written in a notification, in characters.
const _titleLength = 30;

/// What is posted for a batch found for an account: id, title, body, payload, and the lines and summary of the
/// expanded notification (empty for a single thread).
typedef ForumWatchNoticeContent = ({
  int id,
  String title,
  String body,
  String payload,
  List<String> lines,
  String? summary,
});

/// The notification of [batch] found for account [uid].
///
/// * The new threads of a watched forum: titled with the forum; one thread is "author：title" and opens the thread,
///   several are "N 个新主题" listing them and open the forum.
/// * The threads found with a keyword: one thread is titled with its keyword, "author：title", and opens the thread;
///   several are "N 个主题含关键字" listing "「keyword」title" and open the page of the alerts.
///
/// With [hideContent] (`SettingsKeys.notificationHideContent`) no title, author, forum nor keyword is written: the
/// category and the count only. A tap acts as the account that found it, switching to it first when another one is
/// in use by then ([LocalNoticeKeys.openNotificationOf]).
ForumWatchNoticeContent forumWatchNoticeContentOf(
  Translations translations,
  ForumWatchBatch batch, {
  required int uid,
  bool hideContent = false,
}) {
  final tr = translations.forumWatch.notice;
  final channels = translations.localNotification.channels;
  final alerts = batch.alerts;
  final n = alerts.length;
  final single = n == 1 ? alerts.first : null;
  String title(WatchAlert a) => a.title.truncate(_titleLength, ellipsis: true);
  String line(WatchAlert a) => a.author.isEmpty ? title(a) : tr.thread(author: a.author, title: title(a));
  final LocalNoticeTarget target;
  final String noticeTitle;
  final String body;
  final List<String> lines;
  if (batch.keyword) {
    target = single != null ? LocalNoticeTarget(tid: single.tid) : const LocalNoticeTarget(watchAlerts: true);
    if (hideContent) {
      noticeTitle = channels.keywordAlert;
      body = tr.keywordMany(n: n);
      lines = const [];
    } else if (single != null) {
      noticeTitle = tr.keywordOne(keyword: single.keywords.join('、'));
      body = line(single);
      lines = const [];
    } else {
      noticeTitle = channels.keywordAlert;
      body = tr.keywordMany(n: n);
      lines = [for (final a in alerts) tr.keywordLine(keyword: a.keywords.join('、'), title: title(a))];
    }
  } else {
    target = single != null ? LocalNoticeTarget(tid: single.tid) : LocalNoticeTarget(fid: batch.fid);
    final forum = batch.forumName.isEmpty ? channels.forumNewThread : batch.forumName;
    if (hideContent) {
      noticeTitle = channels.forumNewThread;
      body = tr.forumMany(n: n);
      lines = const [];
    } else if (single != null) {
      noticeTitle = forum;
      body = line(single);
      lines = const [];
    } else {
      noticeTitle = forum;
      body = tr.forumMany(n: n);
      lines = [for (final a in alerts) line(a)];
    }
  }
  return (
    id: batch.keyword ? forumWatchKeywordNoticeId(uid) : forumWatchForumNoticeId(batch.fid),
    title: noticeTitle,
    body: body,
    payload: LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(uid), target),
    lines: lines,
    summary: lines.isEmpty ? null : body,
  );
}

/// Post the notification of [batch] (found for account [uid]) through [plugin], in the channel of its category.
Future<void> showForumWatchNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required Translations translations,
  required ForumWatchBatch batch,
  required int uid,
  bool hideContent = false,
}) async {
  final content = forumWatchNoticeContentOf(translations, batch, uid: uid, hideContent: hideContent);
  final details = buildLocalNotificationDetails(
    channelName: noticeChannelName(translations, batch.category),
    category: batch.category,
    channelDescription: translations.localNotification.channelDesc,
    ticker: translations.localNotification.ticker,
    title: content.title,
    body: content.body,
    lines: content.lines,
    summary: content.summary,
  );
  await plugin.show(
    id: content.id,
    title: content.title,
    body: content.body,
    notificationDetails: details,
    payload: content.payload,
  );
}
