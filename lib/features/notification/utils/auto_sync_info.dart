import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:universal_html/parsing.dart';

/// What to announce for the [fresh] part of a sync, null when there is nothing new.
///
/// One notification per sync: a private message first, then a broadcast message, then a notice, each carrying the
/// counts of everything new. Shared by the in-app auto sync (`NotificationBloc`) and the Android background message
/// service so both announce the same thing for the same fetch (#80).
NotificationAutoSyncInfo? autoSyncInfoOf(NotificationV2 fresh) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (fresh.personalMessageList.isNotEmpty) {
    final last = fresh.personalMessageList.last;
    return NotificationAutoSyncInfoPm(
      user: last.peerUsername,
      msg: last.data.truncate(40, ellipsis: true),
      notice: fresh.noticeList.length,
      personalMessage: fresh.personalMessageList.length,
      broadcastMessage: fresh.broadcastMessageList.length,
      timestamp: now,
    );
  }
  if (fresh.broadcastMessageList.isNotEmpty) {
    return NotificationAutoSyncInfoBm(
      msg: fresh.broadcastMessageList.last.data.truncate(40, ellipsis: true),
      notice: fresh.noticeList.length,
      personalMessage: fresh.personalMessageList.length,
      broadcastMessage: fresh.broadcastMessageList.length,
      timestamp: now,
    );
  }
  if (fresh.noticeList.isNotEmpty) {
    return NotificationAutoSyncInfoNotice(
      msg: parseHtmlDocument(fresh.noticeList.last.data).body?.innerText.truncate(40, ellipsis: true) ?? '<null>',
      notice: fresh.noticeList.length,
      personalMessage: fresh.personalMessageList.length,
      broadcastMessage: fresh.broadcastMessageList.length,
      timestamp: now,
    );
  }
  return null;
}
