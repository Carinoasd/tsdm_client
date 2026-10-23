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

    final target = LocalNoticeTarget(nid: id('nid'), tid: id('tid'), pid: id('pid'), peerUid: id('peer'));
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
}

/// What a tap on a notification announcing a single new item opens, see [LocalNoticeKeys.withTarget]: the floor
/// [pid] (or the thread [tid]) of the notice [nid], or the conversation with [peerUid].
@immutable
final class LocalNoticeTarget {
  /// Constructor.
  const LocalNoticeTarget({this.nid, this.tid, this.pid, this.peerUid});

  /// Notice to mark as read.
  final int? nid;

  /// Thread of the notice.
  final int? tid;

  /// Floor of the notice.
  final int? pid;

  /// Peer of the conversation.
  final int? peerUid;

  /// Nothing to open.
  bool get isEmpty => tid == null && pid == null && peerUid == null;

  /// The query written in a payload.
  String toQuery() => [
    if (nid != null) 'nid=$nid',
    if (tid != null) 'tid=$tid',
    if (pid != null) 'pid=$pid',
    if (peerUid != null) 'peer=$peerUid',
  ].join('&');

  @override
  bool operator ==(Object other) =>
      other is LocalNoticeTarget &&
      other.nid == nid &&
      other.tid == tid &&
      other.pid == pid &&
      other.peerUid == peerUid;

  @override
  int get hashCode => Object.hash(nid, tid, pid, peerUid);

  @override
  String toString() => 'LocalNoticeTarget(${toQuery()})';
}
