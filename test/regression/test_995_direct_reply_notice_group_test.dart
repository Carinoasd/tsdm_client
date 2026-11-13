/// The notifications about an account (the auto sync's, the ones offering the reply typed in the notification, the
/// one telling such a reply was not sent) are posted in a group of that account with its summary (Android): never
/// bundled by the system with the persistent notification of the background message service, which is posted without
/// a group, so the "reply" of a single notification shows without expanding anything.
///
/// Synthetic accounts only: nothing reaches a forum.
library;

import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Id of the persistent notification of the background message service (`backgroundSyncNotificationId`).
const _serviceId = 888;

StorageProvider _storage() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return StorageProvider(db, {}, {});
}

NotificationAutoSyncInfoNotice _reply({int pid = 2}) => NotificationAutoSyncInfoNotice(
  msg: 'A 回复了您的帖子',
  notice: 1,
  personalMessage: 0,
  broadcastMessage: 0,
  timestamp: 1700000000,
  nid: 5,
  author: 'A',
  noticeType: 'post',
  fromIdType: 'post',
  threadTitle: 'T',
  tid: 1,
  pid: pid,
);

typedef _Shown = ({int id, String? title, String? body, NotificationDetails? details, String? payload});

/// The shade of the app as Android keeps it: a notification is (id, tag) and tells its channel and group, as the
/// plugin reads them back (`getActiveNotifications`).
final class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];
  final shade = <(int, String?), _Shown>{};
  final cancelled = <(int, String?)>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    final n = (id: id, title: title, body: body, details: notificationDetails, payload: payload);
    shown.add(n);
    shade[(id, notificationDetails?.android?.tag)] = n;
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add((id, tag));
    shade.remove((id, tag));
  }

  /// Runs before each read of the shade: what another isolate posts meanwhile.
  void Function(int read)? beforeRead;
  int _reads = 0;

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async {
    beforeRead?.call(++_reads);
    return _active();
  }

  List<ActiveNotification> _active() => [
    for (final MapEntry(key: (id, tag), value: n) in shade.entries)
      ActiveNotification(
        id: id,
        tag: tag,
        channelId: n.details?.android?.channelId,
        groupKey: n.details?.android?.groupKey,
        title: n.title,
        body: n.body,
      ),
  ];

  /// The persistent notification of the background message service, as its plugin posts it: no group.
  void postService() => shade[(_serviceId, null)] = (
    id: _serviceId,
    title: '后台消息接收',
    body: null,
    details: const NotificationDetails(android: AndroidNotificationDetails('tsdm_foreground', 'service')),
    payload: null,
  );

  _Shown? summaryOf(int uid) => shade[(localNoticeGroupSummaryIdOf(uid), null)];

  Iterable<_Shown> get summaries => shade.values.where((e) => e.details?.android?.setAsGroupSummary ?? false);
}

void main() {
  late Translations tr;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tr = await AppLocale.zhCn.build();
  });

  Future<_Shown> post(
    _Plugin plugin,
    StorageProvider storage,
    NotificationAutoSyncInfo info, {
    LocalNoticeAccount account = const LocalNoticeAccount(uid: 1000),
    bool android = true,
  }) async {
    await showLocalNotificationWith(
      plugin: plugin,
      translations: tr,
      info: info,
      account: account,
      directReply: true,
      storage: storage,
      android: android,
    );
    return plugin.shown.lastWhere((e) => !(e.details?.android?.setAsGroupSummary ?? false));
  }

  test('ids of the groups and their summaries: one per account, apart from every other notification', () {
    expect(localNoticeGroupOf(1000), 'tsdm.notice.1000');
    expect(localNoticeGroupOf(0), 'tsdm.notice.0');
    expect(localNoticeGroupOf(-3), 'tsdm.notice.0');
    final id = localNoticeGroupSummaryIdOf(1000);
    expect(isLocalNoticeGroupSummaryId(id), isTrue);
    expect(id, isNot(localNoticeIdOf(1000)));
    expect(isLocalNoticeId(id), isFalse, reason: 'not an auto sync notification');
    expect(isDirectReplyNoticeId(id), isFalse);
    expect(isDirectReplyResultNoticeId(id), isFalse);
    for (final other in [localNoticeId, localNoticeIdOf(1000), _serviceId, directReplyNoticeIdOf('1000:p:1:2')]) {
      expect(isLocalNoticeGroupSummaryId(other), isFalse, reason: '$other');
    }
    expect(id, greaterThan(0), reason: 'a positive Java int');
  });

  test('a reply notification goes into the group of its account, with a silent summary of that group', () async {
    final plugin = _Plugin()..postService();
    final n = await post(plugin, _storage(), _reply());
    final android = n.details!.android!;
    expect(android.actions, isNotEmpty, reason: 'it offers the reply');
    expect(android.groupKey, localNoticeGroupOf(1000));
    expect(android.setAsGroupSummary, isFalse);

    final summary = plugin.summaryOf(1000)!;
    final s = summary.details!.android!;
    expect(s.setAsGroupSummary, isTrue);
    expect(s.groupKey, localNoticeGroupOf(1000));
    expect(s.silent, isTrue, reason: 'the notification alerts, not its summary');
    expect(s.groupAlertBehavior, GroupAlertBehavior.children);
    expect(s.channelId, android.channelId, reason: 'in a channel the user left on');
    expect(s.actions, isNull);
    expect(LocalNoticeKeys.parseOpenNotification(summary.payload), (uid: 1000));
    // Posted after its notification: a summary is never alone in the shade.
    expect(plugin.shown.indexOf(summary), greaterThan(plugin.shown.indexOf(n)));

    // The persistent notification keeps no group: nothing of this group is ever bundled with it.
    final service = (await plugin.getActiveNotifications()).firstWhere((e) => e.id == _serviceId);
    expect(service.groupKey, isNull);
  });

  test('a newer item of the account: one summary still, posted once', () async {
    final plugin = _Plugin()..postService();
    final storage = _storage();
    await post(plugin, storage, _reply());
    await post(plugin, storage, _reply(pid: 3));
    expect(plugin.summaries, hasLength(1));
    expect(plugin.shown.where((e) => e.details?.android?.setAsGroupSummary ?? false), hasLength(1));
  });

  test('every account announced: a group and a summary each, never bundled together', () async {
    final plugin = _Plugin()..postService();
    final storage = _storage();
    final a = await post(
      plugin,
      storage,
      _reply(),
      account: const LocalNoticeAccount(uid: 1000, username: 'A', named: true),
    );
    final b = await post(
      plugin,
      storage,
      _reply(),
      account: const LocalNoticeAccount(uid: 2000, username: 'B', named: true),
    );
    expect(a.details!.android!.groupKey, localNoticeGroupOf(1000));
    expect(b.details!.android!.groupKey, localNoticeGroupOf(2000));
    expect(plugin.summaryOf(1000), isNotNull);
    expect(plugin.summaryOf(2000), isNotNull);
    expect(LocalNoticeKeys.parseOpenNotification(plugin.summaryOf(2000)!.payload), (uid: 2000));
  });

  test('the account in use changed: the notification of the slot moves, the summary left alone goes', () async {
    final plugin = _Plugin();
    final storage = _storage();
    // Several items: no reply offered, the one shared id of the account in use.
    const several = NotificationAutoSyncInfoNotice(
      msg: 'm',
      notice: 2,
      personalMessage: 0,
      broadcastMessage: 0,
      timestamp: 1700000000,
    );
    await post(plugin, storage, several);
    expect(plugin.summaryOf(1000), isNotNull);
    await post(plugin, storage, several, account: const LocalNoticeAccount(uid: 2000));
    expect(plugin.shade[(localNoticeId, null)]!.details!.android!.groupKey, localNoticeGroupOf(2000));
    expect(plugin.summaryOf(1000), isNull, reason: 'its group holds nothing');
    expect(plugin.summaryOf(2000), isNotNull);
  });

  test('a summary whose notifications are gone is taken back; without texts nothing is posted', () async {
    final plugin = _Plugin();
    final storage = _storage();
    final n = await post(plugin, storage, _reply());
    await plugin.cancel(id: n.id, tag: n.details!.android!.tag);
    expect(plugin.summaryOf(1000), isNotNull);
    await syncLocalNoticeGroupSummaries(plugin);
    expect(plugin.summaryOf(1000), isNull);

    final again = await post(plugin, storage, _reply(pid: 4));
    await plugin.cancel(id: localNoticeGroupSummaryIdOf(1000));
    await syncLocalNoticeGroupSummaries(plugin);
    expect(plugin.summaryOf(1000), isNull, reason: 'no texts: only taken back');
    await syncLocalNoticeGroupSummaries(plugin, translations: tr);
    expect(plugin.summaryOf(1000), isNotNull, reason: '${again.id} is still there');
  });

  test('a notification posted in the group by another isolate meanwhile: its summary stays, it is not taken '
      'back with it', () async {
    final plugin = _Plugin();
    final storage = _storage();
    final n = await post(plugin, storage, _reply());
    await plugin.cancel(id: n.id, tag: n.details!.android!.tag);
    // Android takes a group's notifications back with its summary: the background message service posts a newer item
    // of the account between the read that finds the group empty and the summary being taken back.
    final other = _Plugin();
    await post(other, _storage(), _reply(pid: 9));
    final newer = other.shown.firstWhere((e) => !(e.details?.android?.setAsGroupSummary ?? false));
    plugin.beforeRead = (read) {
      if (read == 2) {
        plugin.shade[(newer.id, newer.details!.android!.tag)] = newer;
      }
    };
    await syncLocalNoticeGroupSummaries(plugin, translations: tr);
    expect(plugin.cancelled, isNot(contains((localNoticeGroupSummaryIdOf(1000), null))));
    expect(plugin.summaryOf(1000), isNotNull);
  });

  test('a shade that can not be read: nothing happens, nothing throws', () async {
    final plugin = _UnreadablePlugin();
    await syncLocalNoticeGroupSummaries(plugin, translations: tr);
    expect(plugin.posted, isFalse);
  });

  test('not Android: no group summary', () async {
    final plugin = _Plugin();
    await post(plugin, _storage(), _reply(), android: false);
    expect(plugin.summaries, isEmpty);
  });

  group('a reply typed in the notification', () {
    const request = DirectReplyRequest(
      uid: 1000,
      target: LocalNoticeTarget(nid: 5, tid: 1, pid: 2),
      message: '好的',
    );

    test('not sent: told in the group of the account, with its summary', () async {
      final plugin = _Plugin()..postService();
      await showDirectReplyOutcome(
        plugin: plugin,
        translations: tr,
        request: request,
        outcome: const DirectReplyNotSent('x'),
        android: true,
      );
      final told = plugin.shade[(request.resultNoticeId, null)]!;
      expect(told.details!.android!.groupKey, localNoticeGroupOf(1000));
      expect(plugin.summaryOf(1000), isNotNull);
    });

    test('sent: the quiet notice that goes by itself has no group, and leaves no summary behind', () async {
      final plugin = _Plugin()..postService();
      await showDirectReplyOutcome(
        plugin: plugin,
        translations: tr,
        request: request,
        outcome: const DirectReplySent(),
        android: true,
      );
      final told = plugin.shade[(request.resultNoticeId, null)]!;
      expect(told.details!.android!.groupKey, isNull);
      expect(told.details!.android!.timeoutAfter, isNotNull);
      expect(plugin.summaries, isEmpty);
    });

    test('the notification it was typed in stays in its group while closed, the summary goes with it', () async {
      final plugin = _Plugin();
      final storage = _storage();
      final n = await post(plugin, storage, _reply());
      final replied = (await RepliedNotice.of(plugin, n.id))!;
      await replied.seal(tr, payload: n.payload);
      final sealed = plugin.shown.last;
      expect((sealed.id, sealed.details!.android!.tag), (n.id, n.details!.android!.tag));
      expect(sealed.details!.android!.actions, isNull);
      expect(sealed.details!.android!.groupKey, localNoticeGroupOf(1000));
      expect(plugin.summaryOf(1000), isNotNull);
      await replied.remove(shownFor: Duration.zero);
      expect(plugin.shade.keys.where((k) => k.$1 == n.id), isEmpty);
      expect(plugin.summaryOf(1000), isNull, reason: 'nothing left in the group');
    });

    test('closed while the shade held nothing under its id: posted again in the group its tag names', () async {
      final plugin = _Plugin();
      final storage = _storage();
      final n = await post(plugin, storage, _reply());
      final tag = n.details!.android!.tag!;
      // Taken back before the reply arrived (a newer result of its slot), the system UI may still show it.
      await plugin.cancel(id: n.id, tag: tag);
      final replied = (await RepliedNotice.of(plugin, n.id, lastTag: () async => tag))!;
      await replied.seal(tr, told: repliedNoticeToldOf(tr, request, const DirectReplyNotSent('x')));
      final sealed = plugin.shown.last;
      expect(sealed.details!.android!.tag, tag);
      expect(sealed.details!.android!.groupKey, localNoticeGroupOf(1000));
    });
  });
}

final class _UnreadablePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  bool posted = false;

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => throw StateError('no shade');

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => posted = true;
}
