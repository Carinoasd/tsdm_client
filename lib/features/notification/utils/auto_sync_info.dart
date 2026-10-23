import 'package:collection/collection.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:universal_html/parsing.dart';

/// Length of the texts of a notification.
const _msgLength = 40;

/// What to announce for the [fresh] part of a sync, null when there is nothing new.
///
/// One notification per sync: a private message first, then a broadcast message, then a notice, each carrying the
/// counts of everything new, and one line per new notification, newest first ([NotificationAutoSyncInfo.lines]).
/// Shared by the in-app auto sync (`NotificationBloc`) and the Android background message service so both announce
/// the same thing for the same fetch (#80).
///
/// The one announced of its kind is the newest: the forum lists notices, conversations and broadcast messages newest
/// first, so the last of a list is the oldest one; the time decides, whatever the order of the lists.
NotificationAutoSyncInfo? autoSyncInfoOf(NotificationV2 fresh) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lines = _linesOf(fresh);
  final notice = fresh.noticeList.length;
  final personalMessage = fresh.personalMessageList.length;
  final broadcastMessage = fresh.broadcastMessageList.length;
  final pm = _newest(fresh.personalMessageList, (e) => e.timestamp);
  if (pm != null) {
    return NotificationAutoSyncInfoPm(
      user: pm.peerUsername,
      msg: _summary(pm.data),
      peerUid: pm.peerUid > 0 ? pm.peerUid : null,
      notice: notice,
      personalMessage: personalMessage,
      broadcastMessage: broadcastMessage,
      timestamp: now,
      lines: lines,
    );
  }
  final bm = _newest(fresh.broadcastMessageList, (e) => e.timestamp);
  if (bm != null) {
    return NotificationAutoSyncInfoBm(
      msg: _summary(bm.data),
      notice: notice,
      personalMessage: personalMessage,
      broadcastMessage: broadcastMessage,
      timestamp: now,
      lines: lines,
    );
  }
  final n = _newest(fresh.noticeList, (e) => e.timestamp);
  if (n != null) {
    final info = NoticeInfo.of(n);
    return NotificationAutoSyncInfoNotice(
      msg: info.text.truncate(_msgLength, ellipsis: true),
      nid: n.id,
      author: info.author,
      noticeType: n.ignoreType,
      fromIdType: n.fromIdType,
      threadTitle: info.threadTitle,
      quote: info.quote?.truncate(_msgLength, ellipsis: true),
      tid: info.target?.tid,
      pid: info.target?.pid,
      notice: notice,
      personalMessage: personalMessage,
      broadcastMessage: broadcastMessage,
      timestamp: now,
      lines: lines,
    );
  }
  return null;
}

/// The newest of [list] by [timeOf], the first of the newest when several share the time (the forum's order).
T? _newest<T>(List<T> list, int Function(T) timeOf) =>
    list.isEmpty ? null : list.reduce((a, b) => timeOf(b) > timeOf(a) ? b : a);

/// The text of a message summary [data], in one line and truncated; the summary may carry markup, only its text is
/// kept.
String _summary(String data) => (parseHtmlDocument('<html><body>$data</body></html>').body?.text ?? data)
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .truncate(_msgLength, ellipsis: true);

/// One line per new notification of [fresh], newest first, at most [NotificationAutoSyncInfo.maxLines].
List<NotificationAutoSyncLine> _linesOf(NotificationV2 fresh) {
  final all = <(int, NotificationAutoSyncLine Function())>[
    for (final e in fresh.personalMessageList)
      (
        e.timestamp,
        () => NotificationAutoSyncLine(
          kind: NotificationAutoSyncLineKind.personalMessage,
          text: _summary(e.data),
          user: e.peerUsername,
        ),
      ),
    for (final e in fresh.broadcastMessageList)
      (
        e.timestamp,
        () => NotificationAutoSyncLine(kind: NotificationAutoSyncLineKind.broadcastMessage, text: _summary(e.data)),
      ),
    for (final e in fresh.noticeList)
      (
        e.timestamp,
        () => NotificationAutoSyncLine(
          kind: NotificationAutoSyncLineKind.notice,
          text: noticePlainTextOfHtml(e.data).truncate(_msgLength, ellipsis: true),
        ),
      ),
  ];
  // Stable: the forum's order among the same time.
  return all
      .sortedByCompare((e) => e.$1, (a, b) => b.compareTo(a))
      .take(NotificationAutoSyncInfo.maxLines)
      .map((e) => e.$2())
      .toList();
}
