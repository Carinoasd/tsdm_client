/// The notification a reply was typed in leaves the shade once the reply is dealt with (`RepliedNotice`).
///
/// Seen on the Android 14 emulator: the plugin cancelled the notification as soon as the text was sent
/// (`cancelNotification`), and the system UI kept it (`lifetimeExtenders=[RemoteInputHistory]`,
/// `cancellationReason=8`): a notification cancelled by its app while its text input is "sending" stays, with the
/// text under it and the action offered again; a few replies in a row piled up. The system lets go of it once the app
/// has posted it again: it is posted once more without the action, then cancelled.
///
/// A notification the app took back while the user was still typing in it (a newer result of its slot arrived) is
/// kept the same way once the text is sent, and is not among the app's notifications any more: its tag comes from
/// what its id was last posted with (`DirectReplyPins.tagOf`).
///
/// The plugin of this test keeps the shade as that system UI does. Synthetic accounts only.
library;

import 'dart:convert';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

typedef _Shown = ({int id, String? title, String? body, NotificationDetails? details, String? payload});

/// The shade of an Android 14 device, as far as a reply typed in a notification goes: a notification is (id, tag);
/// [type] opens its input, [reply] puts it in the "sending" state, which lasts until the app posts it again;
/// cancelled by the app in either state it is [kept] by the system UI (shown, but no longer among the active
/// notifications of the app).
final class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];
  final shade = <(int, String?), _Shown>{};
  final typing = <(int, String?)>{};
  final sending = <(int, String?)>{};
  final kept = <(int, String?), _Shown>{};
  final cancelled = <(int, String?)>[];
  bool unreadable = false;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    final n = (id: id, title: title, body: body, details: notificationDetails, payload: payload);
    final key = (id, notificationDetails?.android?.tag);
    shown.add(n);
    shade[key] = n;
    // Posted again by its app: the input is closed, the system UI keeps it no longer.
    typing.remove(key);
    sending.remove(key);
    kept.remove(key);
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    final key = (id, tag);
    cancelled.add(key);
    final n = shade.remove(key);
    if (n != null && (typing.contains(key) || sending.contains(key))) {
      kept[key] = n;
    }
  }

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async {
    if (unreadable) {
      throw StateError('no shade');
    }
    return [
      for (final MapEntry(key: (id, tag), value: n) in shade.entries)
        ActiveNotification(
          id: id,
          tag: tag,
          channelId: n.details?.android?.channelId,
          title: n.title,
          body: n.body,
        ),
    ];
  }

  /// The user opens the input of notification [n].
  void type(_Shown n) => typing.add((n.id, n.details?.android?.tag));

  /// The user sends a text from notification [n].
  void reply(_Shown n) {
    final key = (n.id, n.details?.android?.tag);
    typing.remove(key);
    sending.add(key);
  }

  /// What the user sees: the notifications of the app and the ones the system UI keeps.
  Iterable<_Shown> get visible => [...shade.values, ...kept.values];
}

StorageProvider _storage() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return StorageProvider(db, {}, {});
}

NotificationAutoSyncInfoNotice _quote({int tid = 9600001, int pid = 9700002, String author = 'A'}) =>
    NotificationAutoSyncInfoNotice(
      msg: '$author 引用了您的帖子',
      notice: 1,
      personalMessage: 0,
      broadcastMessage: 0,
      timestamp: 1700000000,
      nid: 5,
      author: author,
      noticeType: 'post',
      fromIdType: 'quote',
      threadTitle: 'T',
      tid: tid,
      pid: pid,
    );

NotificationAutoSyncInfoPm _pm({int peer = 2000, String msg = 'hi'}) => NotificationAutoSyncInfoPm(
  user: 'P$peer',
  msg: msg,
  notice: 0,
  personalMessage: 1,
  broadcastMessage: 0,
  timestamp: 1700000000,
  peerUid: peer,
);

void main() {
  late Translations tr;
  const account = LocalNoticeAccount(uid: 1000);

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tr = await AppLocale.zhCn.build();
  });

  Future<_Shown> post(_Plugin plugin, StorageProvider storage, NotificationAutoSyncInfo info) async {
    await showLocalNotificationWith(
      plugin: plugin,
      translations: tr,
      info: info,
      account: account,
      directReply: true,
      storage: storage,
      android: true,
    );
    return plugin.shown.last;
  }

  test('the plugin does not cancel the notification when the text is sent', () {
    expect(directReplyActionOf(tr).cancelNotification, isFalse);
    expect(directReplyActionOf(tr).inputs, hasLength(1));
  });

  test('what it guards against: cancelled while its input is sending, the notification stays', () async {
    final plugin = _Plugin();
    final first = await post(plugin, _storage(), _quote());
    plugin.reply(first);
    await plugin.cancel(id: first.id, tag: first.details!.android!.tag);
    expect(await plugin.getActiveNotifications(), isEmpty);
    expect(plugin.visible.single.details!.android!.actions, hasLength(1), reason: 'kept, and can be answered again');
  });

  test('posted again without the action, as it was, then taken back: nothing stays', () async {
    final plugin = _Plugin();
    final first = await post(plugin, _storage(), _quote());
    final tag = first.details!.android!.tag;
    expect(tag, startsWith('dr:0:1000:p:'));
    plugin.reply(first);

    final replied = (await RepliedNotice.of(plugin, first.id))!;
    await replied.seal(tr, payload: 'openNotification:1000#tid=9600001&pid=9700002');
    final sealed = plugin.shown.last;
    expect(sealed.id, first.id);
    expect(sealed.details!.android!.tag, tag);
    expect(sealed.details!.android!.channelId, NoticeCategory.reply.channelId);
    expect(sealed.title, first.title);
    expect(sealed.body, first.body);
    expect(sealed.details!.android!.actions, isNull, reason: 'nothing more can be typed in it');
    expect(sealed.details!.android!.onlyAlertOnce, isTrue);
    expect(sealed.details!.android!.silent, isFalse, reason: 'an update of a notification that is shown');
    expect(sealed.details!.android!.timeoutAfter, isNull);
    expect(plugin.shade, hasLength(1), reason: 'the same notification, not a second one');

    await replied.remove(shownFor: Duration.zero);
    expect(plugin.cancelled, [(first.id, tag)]);
    expect(plugin.visible, isEmpty);
  });

  test('it stays for a moment before it is taken back, and is sealed only once', () async {
    final plugin = _Plugin();
    final first = await post(plugin, _storage(), _pm());
    plugin.reply(first);
    final replied = (await RepliedNotice.of(plugin, first.id))!;
    await replied.seal(tr);
    await replied.seal(tr);
    expect(plugin.shown, hasLength(2), reason: 'the notification and its closed form');
    expect(plugin.shown.last.details!.android!.channelId, NoticeCategory.pm.channelId);

    final watch = Stopwatch()..start();
    await replied.remove(shownFor: const Duration(milliseconds: 120));
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100));
    expect(plugin.visible, isEmpty);
    expect(directReplySealedFor, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
  });

  test('a newer item of the same target, posted while the reply was sent, is left alone', () async {
    final storage = _storage();
    final plugin = _Plugin();
    final first = await post(plugin, storage, _pm());
    plugin.reply(first);
    final replied = (await RepliedNotice.of(plugin, first.id))!;

    final newer = await post(plugin, storage, _pm(msg: 'still there?'));
    expect(newer.id, first.id);
    await replied.seal(tr);
    await replied.remove(shownFor: Duration.zero);
    expect(plugin.shown.last, newer, reason: 'not posted over');
    expect(plugin.cancelled, isEmpty);
    expect(plugin.visible.single.body, 'still there?');
    expect(plugin.visible.single.details!.android!.actions, hasLength(1));
  });

  test('a newer item of the same target, posted after it was closed, is not taken back', () async {
    final storage = _storage();
    final plugin = _Plugin();
    final first = await post(plugin, storage, _pm());
    plugin.reply(first);
    final replied = (await RepliedNotice.of(plugin, first.id))!;
    await replied.seal(tr);

    await post(plugin, storage, _pm(msg: 'one more'));
    await replied.remove(shownFor: Duration.zero);
    expect(plugin.cancelled, isEmpty);
    expect(plugin.visible.single.body, 'one more');
  });

  test('taken back by a newer result of its slot while the reply was sent: posted silently, then gone', () async {
    final storage = _storage();
    final plugin = _Plugin();
    final first = await post(plugin, storage, _quote());
    final tag = first.details!.android!.tag;
    plugin.reply(first);
    final replied = (await RepliedNotice.of(plugin, first.id))!;

    // The next sync announces another floor: the slot stays one notification, the first is cancelled while sending.
    final second = await post(plugin, storage, _quote(pid: 9700003, author: 'B'));
    expect(second.id, isNot(first.id));
    expect(plugin.kept.keys, [(first.id, tag)], reason: 'the system UI keeps the one being answered');

    await replied.seal(tr);
    final sealed = plugin.shown.last;
    expect((sealed.id, sealed.details!.android!.tag), (first.id, tag));
    expect(sealed.details!.android!.silent, isTrue, reason: 'never announced a second time');
    expect(sealed.details!.android!.actions, isNull);
    await replied.remove(shownFor: Duration.zero);
    expect(plugin.visible.single, second, reason: 'only the newer result is left, untouched');
    expect(plugin.visible.single.details!.android!.actions, hasLength(1));
  });

  group('taken back while the user was still typing', () {
    Future<(_Plugin, StorageProvider, _Shown, _Shown)> typedThenReplaced() async {
      final storage = _storage();
      final plugin = _Plugin();
      final first = await post(plugin, storage, _quote());
      plugin.type(first);
      // The next sync announces another floor while the user types: the first is cancelled, the system UI keeps it.
      final second = await post(plugin, storage, _quote(pid: 9700003, author: 'B'));
      expect(plugin.kept.keys, [(first.id, first.details!.android!.tag)]);
      plugin.reply(first);
      return (plugin, storage, first, second);
    }

    const told = (title: '已回复', body: '好的', category: NoticeCategory.reply);

    test('its id tells its tag: posted silently saying the outcome, then gone', () async {
      final (plugin, storage, first, second) = await typedThenReplaced();
      final tag = first.details!.android!.tag;
      expect(await DirectReplyPins(storage).tagOf(first.id), tag);

      final replied = (await RepliedNotice.of(
        plugin,
        first.id,
        lastTag: () => DirectReplyPins(storage).tagOf(first.id),
      ))!;
      await replied.seal(tr, payload: 'openNotification:1000#tid=9600001&pid=9700002', told: told);
      final sealed = plugin.shown.last;
      expect((sealed.id, sealed.details!.android!.tag), (first.id, tag));
      expect((sealed.title, sealed.body), ('已回复', '好的'));
      expect(sealed.details!.android!.channelId, NoticeCategory.reply.channelId);
      expect(sealed.details!.android!.silent, isTrue);
      expect(sealed.details!.android!.actions, isNull);
      expect(plugin.kept, isEmpty, reason: 'posted again: the system UI lets go of it');

      await replied.remove(shownFor: Duration.zero);
      expect(plugin.visible.single, second, reason: 'only the newer result is left, untouched');
    });

    test('nothing is posted without an outcome to say, a known tag, or when the tag is shown again', () async {
      final (plugin, storage, first, _) = await typedThenReplaced();
      final count = plugin.shown.length;
      Future<String?> lastTag() => DirectReplyPins(storage).tagOf(first.id);

      // A response that is no reply to send.
      final silent = (await RepliedNotice.of(plugin, first.id, lastTag: lastTag))!;
      await silent.seal(tr);
      await silent.remove(shownFor: Duration.zero);
      expect(plugin.shown, hasLength(count));

      // The tag was not kept (posted by an older version).
      final unknown = (await RepliedNotice.of(plugin, first.id, lastTag: () async => null))!;
      await unknown.seal(tr, told: told);
      expect(plugin.shown, hasLength(count));
      final noPins = (await RepliedNotice.of(plugin, first.id))!;
      await noPins.seal(tr, told: told);
      expect(plugin.shown, hasLength(count));

      // A newer item of the same target arrived after the reply did: it is the notification now.
      final late = (await RepliedNotice.of(plugin, first.id, lastTag: lastTag))!;
      final newer = await post(plugin, storage, _quote(author: 'C'));
      expect(newer.id, first.id);
      await late.seal(tr, told: told);
      await late.remove(shownFor: Duration.zero);
      expect(plugin.shown.last, newer);
      expect(plugin.visible.map((e) => e.title), contains(newer.title));
      expect(
        plugin.cancelled.where((e) => e.$1 == first.id),
        hasLength(1),
        reason: 'only when the second result replaced it',
      );
    });

    test('the pins keep the slot of the tag, and stay readable without one', () async {
      final storage = _storage();
      final pins = DirectReplyPins(storage);
      expect(await pins.tagOf(42), isNull);
      expect(await pins.claim(42, '1000:m:1', slot: 1000), isTrue);
      expect(await pins.tagOf(42), directReplyTag(1000, '1000:m:1'));
      expect(await pins.claim(42, '1000:m:1'), isTrue);
      expect(await pins.tagOf(42), directReplyTag(1000, '1000:m:1'), reason: 'a claim naming no slot keeps it');
      expect(await pins.claim(42, '1000:m:1', slot: 0), isTrue);
      expect(await pins.tagOf(42), directReplyTag(0, '1000:m:1'));

      // As an older version wrote it: no slot.
      await storage.saveString(
        DirectReplyPins.settingsKey,
        jsonEncode({
          '43': {'k': '1000:m:2', 'at': DateTime.now().millisecondsSinceEpoch},
        }),
      );
      expect(await pins.holds(43, '1000:m:2'), isTrue);
      expect(await pins.tagOf(43), isNull);
      expect(await pins.claim(43, '1000:m:2', slot: 0), isTrue);
      expect(await pins.tagOf(43), directReplyTag(0, '1000:m:2'));
    });
  });

  test('a shade that could not be read when the reply arrived: what is under the id is closed all the same', () async {
    final plugin = _Plugin();
    final first = await post(plugin, _storage(), _quote());
    plugin
      ..reply(first)
      ..unreadable = true;
    final replied = (await RepliedNotice.of(plugin, first.id))!;
    plugin.unreadable = false;
    await replied.seal(tr);
    await replied.remove(shownFor: Duration.zero);
    expect(plugin.visible, isEmpty);
  });

  test('a shade that can not be read at all: nothing thrown', () async {
    final plugin = _Plugin();
    final first = await post(plugin, _storage(), _quote());
    plugin
      ..reply(first)
      ..unreadable = true;
    final replied = (await RepliedNotice.of(plugin, first.id))!;
    await replied.seal(tr);
    await replied.remove(shownFor: Duration.zero);
    expect(plugin.shown.single, first);
    expect(plugin.cancelled, isEmpty);
  });

  test(
    'only the notification of the reply: no other id, no notification without the tag of the direct reply',
    () async {
      final plugin = _Plugin();
      expect(await RepliedNotice.of(plugin, null), isNull);
      expect(await RepliedNotice.of(plugin, localNoticeId), isNull);
      expect(await RepliedNotice.of(plugin, localNoticeIdOf(1000)), isNull);

      // Under the id of a target, but posted without the tag: not one of these.
      final id = directReplyNoticeIdOf(directReplyTargetKey(1000, const LocalNoticeTarget(peerUid: 2000))!);
      await plugin.show(id: id, title: 't', body: 'b');
      final replied = (await RepliedNotice.of(plugin, id))!;
      await replied.seal(tr);
      await replied.remove(shownFor: Duration.zero);
      expect(plugin.shown, hasLength(1));
      expect(plugin.cancelled, isEmpty);
    },
  );

  test('the isolate of the reply is what closes the notification', () {
    final entry = File('lib/features/local_notice/direct_reply_entry.dart').readAsStringSync();
    expect(entry, contains('RepliedNotice.of('));
    expect(entry, contains('DirectReplyPins(runtime.base.storage).tagOf(response.id!)'));
    expect(entry, contains('replied?.remove()'));
  });
}
