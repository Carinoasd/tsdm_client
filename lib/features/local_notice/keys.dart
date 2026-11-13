import 'package:flutter/foundation.dart';

/// All local notification events and types.
class LocalNoticeKeys {
  LocalNoticeKeys._();

  /// Open notification page.
  ///
  /// Tab in the page is not specified. The payload of every notification while only the account in use is announced
  /// (and of the test notification of the settings page): the page of the account in use.
  static const openNotification = 'openNotification';

  /// Payload of a notification about account [uid] while every logged-in account is announced
  /// (`SettingsKeys.backgroundSyncAllAccounts`): its notice page, as that account.
  ///
  /// A tap on it switches to [uid] first when another account is in use (see `openNoticePageOfAccount`).
  static String openNotificationOf(int uid) => '$openNotification:$uid';

  /// [payload] (one of [openNotification], [openNotificationOf]) that opens [target] instead of the notice page: the
  /// floor of the notice, or the conversation, of a notification announcing a single new item.
  ///
  /// The target follows a `#` as a query (`openNotification:1000#nid=5&tid=6&pid=7`, `openNotification#peer=2000`):
  /// [parseOpenNotification] reads the account part as before, [parseTarget] the target.
  static String withTarget(String payload, LocalNoticeTarget target) {
    final query = target.toQuery();
    return query.isEmpty ? payload : '$payload#$query';
  }

  /// The target of [payload] ([withTarget]), null when it has none or is not a payload of this app.
  static LocalNoticeTarget? parseTarget(String? payload) {
    if (payload == null || parseOpenNotification(payload) == null) {
      return null;
    }
    final i = payload.indexOf('#');
    if (i < 0) {
      return null;
    }
    final Map<String, String> query;
    try {
      query = Uri.splitQueryString(payload.substring(i + 1));
      // A malformed percent encoding throws an ArgumentError, not only a FormatException: anything that is not a payload
      // of this app (a crafted intent) is no target.
    } on Object {
      return null;
    }
    int? id(String key) {
      final v = int.tryParse(query[key] ?? '');
      return v != null && v > 0 ? v : null;
    }

    final target = LocalNoticeTarget(
      nid: id('nid'),
      tid: id('tid'),
      pid: id('pid'),
      peerUid: id('peer'),
      lastPost: query['last'] == '1',
      fid: id('fid'),
      watchAlerts: query['wa'] == '1',
      draft: switch (query['draft']) {
        final String draft when draft.trim().isNotEmpty => draft,
        _ => null,
      },
      maybeSent: query['ms'] == '1',
      draftEvent: switch (query['fe']) {
        final String event when event.isNotEmpty => event,
        _ => null,
      },
      title: switch (query['tt']) {
        final String title when title.trim().isNotEmpty => LocalNoticeTarget.clipTitle(title),
        _ => null,
      },
    );
    return target.isEmpty ? null : target;
  }

  /// Whether the payload [raw] opens the notice page, and as which account: `(uid: null)` for [openNotification] (the
  /// account in use), `(uid: n)` for [openNotificationOf], null for anything else. A target ([withTarget]) does not
  /// change the account.
  static ({int? uid})? parseOpenNotification(String? raw) {
    final hash = raw?.indexOf('#') ?? -1;
    final payload = hash >= 0 ? raw!.substring(0, hash) : raw;
    if (payload == openNotification) {
      return (uid: null);
    }
    const prefix = '$openNotification:';
    if (payload == null || !payload.startsWith(prefix)) {
      return null;
    }
    final uid = int.tryParse(payload.substring(prefix.length));
    if (uid == null || uid <= 0) {
      return null;
    }
    return (uid: uid);
  }

  /// [payload] for a log line: the text of a reply that was not sent ([LocalNoticeTarget.draft]) left out.
  static String? loggable(String? payload) {
    if (payload == null) {
      return null;
    }
    return payload.replaceAllMapped(RegExp('((?:^|[#&])draft=)[^&]*'), (m) => '${m[1]}…');
  }
}

/// What a tap on a notification announcing a single new item opens, see [LocalNoticeKeys.withTarget]: the floor
/// [pid] (or the thread [tid]) of the notice [nid], or the conversation with [peerUid]; the last floor of the thread
/// [tid] with [lastPost] (new replies of a followed thread); the forum [fid] (new threads of a watched forum) or the
/// page of the alerts of the watched forums and keywords with [watchAlerts].
///
/// A notification telling that a reply typed in a notification was not sent (`direct_reply.dart`) also carries its
/// text, [draft]: a tap keeps it as the local draft of the floor or the conversation before opening it.
@immutable
final class LocalNoticeTarget {
  /// Constructor.
  const LocalNoticeTarget({
    this.nid,
    this.tid,
    this.pid,
    this.peerUid,
    this.lastPost = false,
    this.fid,
    this.watchAlerts = false,
    this.draft,
    this.maybeSent = false,
    this.draftEvent,
    this.title,
  });

  /// Longest [title] carried, in characters: a thread title of the forum is shorter; anything longer is cut.
  static const titleLength = 100;

  /// [title] cut to [titleLength].
  static String clipTitle(String title) => title.length <= titleLength ? title : title.substring(0, titleLength);

  /// Notice to mark as read.
  final int? nid;

  /// Thread of the notice.
  final int? tid;

  /// Floor of the notice.
  final int? pid;

  /// Peer of the conversation.
  final int? peerUid;

  /// Open the last floor of [tid] (`goto=lastpost`) instead of its first page.
  final bool lastPost;

  /// Forum to open, when nothing else is named.
  final int? fid;

  /// Open the page of the alerts of the watched forums and keywords, when nothing else is named.
  final bool watchAlerts;

  /// The text of a reply typed in a notification that was not sent, null for every other notification.
  final String? draft;

  /// Whether the reply of [draft] may have reached the forum after all (nothing came back after it was posted): the
  /// draft kept from it says so.
  final bool maybeSent;

  /// The id the failing isolate kept [draft] under for the app (`DirectReplyDraftInbox`), null when it could not
  /// keep it (or the notification is of an older version): a tap keeps [draft] once, never again after the app moved
  /// that failure into the drafts.
  final String? draftEvent;

  /// A name of the target, for the local draft kept from a reply typed in the notification that was not sent: the
  /// title of the thread of the floor, the name of the peer of the conversation; null when the notification named none.
  /// The account of the notification may never have opened the thread, so the app may know no title of its own.
  final String? title;

  /// Nothing to open.
  bool get isEmpty => tid == null && pid == null && peerUid == null && fid == null && !watchAlerts;

  /// The query written in a payload.
  String toQuery() => [
    if (nid != null) 'nid=$nid',
    if (tid != null) 'tid=$tid',
    if (pid != null) 'pid=$pid',
    if (peerUid != null) 'peer=$peerUid',
    if (lastPost) 'last=1',
    if (fid != null) 'fid=$fid',
    if (watchAlerts) 'wa=1',
    if (draft case final draft?) 'draft=${Uri.encodeQueryComponent(draft)}',
    if (maybeSent) 'ms=1',
    if (draftEvent case final event?) 'fe=${Uri.encodeQueryComponent(event)}',
    if (title case final title? when title.trim().isNotEmpty) 'tt=${Uri.encodeQueryComponent(clipTitle(title))}',
  ].join('&');

  @override
  bool operator ==(Object other) =>
      other is LocalNoticeTarget &&
      other.nid == nid &&
      other.tid == tid &&
      other.pid == pid &&
      other.peerUid == peerUid &&
      other.lastPost == lastPost &&
      other.fid == fid &&
      other.watchAlerts == watchAlerts &&
      other.draft == draft &&
      other.maybeSent == maybeSent &&
      other.draftEvent == draftEvent &&
      other.title == title;

  @override
  int get hashCode =>
      Object.hash(nid, tid, pid, peerUid, lastPost, fid, watchAlerts, draft, maybeSent, draftEvent, title);

  @override
  String toString() => 'LocalNoticeTarget(${LocalNoticeKeys.loggable(toQuery())})';
}
