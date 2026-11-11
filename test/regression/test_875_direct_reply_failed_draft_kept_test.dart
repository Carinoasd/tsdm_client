/// A reply typed in a notification that was not sent is kept the moment it fails, not when the notification telling
/// it is tapped: the failing isolate writes it down for the app (`DirectReplyDraftInbox`), the app's isolate moves it
/// into the drafts when it starts, comes back to the front, is told by the failing isolate, or the notification is
/// tapped. Swiping the notification away loses nothing; a tap after the move keeps nothing twice.
///
/// Synthetic accounts and texts only: nothing reaches a forum.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/direct_reply_drafts.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

late Translations _tr;

const _tid = 9600001;
const _pid = 9700002;
const _floor = LocalNoticeTarget(nid: 5, tid: _tid, pid: _pid);
const _pm = LocalNoticeTarget(peerUid: 2000);

final _floorKey = LocalDraftKey.floorReply('$_tid', '$_pid');
final _pmKey = LocalDraftKey.message('2000');

DirectReplyRequest _request(int uid, LocalNoticeTarget target, String text) {
  final payload = LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(uid), target);
  return DirectReplyRequest.of(
    NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      id: directReplyNoticeIdOf(directReplyTargetKey(uid, target)!),
      actionId: directReplyActionId,
      input: text,
      payload: payload,
    ),
  )!;
}

/// The target a tap on the notification telling [request] was not sent carries, kept under [event].
LocalNoticeTarget _tapped(DirectReplyRequest request, String? event, {bool unconfirmed = false}) =>
    LocalNoticeKeys.parseTarget(
      directReplyOutcomeContentOf(
        _tr,
        request,
        unconfirmed ? const DirectReplyUnconfirmed() : const DirectReplyNotSent('抱歉，您两次发表间隔少于 15 秒'),
        draftEvent: event,
      ).payload,
    )!;

var _logReady = false;

/// The log, set up by every group: the first test of the file runs without it.
void _logOnce() {
  if (!_logReady) {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    _logReady = true;
  }
}

void main() {
  late Directory dir;
  late LocalDraftStore store;
  late DateTime now;
  late DirectReplyDraftInbox inbox;

  Future<Set<int>?> both() async => {1000, 3000};

  Future<List<String>> collect({Future<Set<int>?> Function()? accounts}) =>
      collectDirectReplyDrafts(inbox: inbox, store: store, accounts: accounts ?? both);

  List<String> names() => dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  setUpAll(() async {
    _tr = await AppLocale.zhCn.build();
  });

  // First of the file, before any group sets the log up: the failing isolate whose log could not be set up.
  test('no log set up and a directory that can not be written: no id, never an error', () async {
    expect(() => talker, throwsA(isA<Error>()), reason: 'not set up yet in this test');
    final file = File('${dir.path}/not_a_dir')..writeAsStringSync('');
    final broken = DirectReplyDraftInbox(directory: () async => Directory(file.path));
    expect(await broken.put(uid: 1000, target: _floor, text: 'x'), isNull);
    tellAppOfDirectReplyDraft('1000-1-0000abcd');
    await broken.markHandled('1000-1-0000abcd');
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsdm_875_');
    store = LocalDraftStore.memory();
    now = DateTime(2026, 11, 11, 10);
    inbox = DirectReplyDraftInbox(directory: () async => dir, now: () => now, random: Random(875));
  });

  tearDown(() async {
    await store.dispose();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  group('the failing isolate keeps the text at once', () {
    setUpAll(_logOnce);

    test('one file per failure, written whole, naming the account, the target, the text and the time', () async {
      final id = await inbox.put(uid: 1000, target: _floor, text: '第一句', maybeSent: true);
      expect(id, isNotNull);
      expect(DirectReplyDraftInbox.validId(id!), isTrue);
      expect(id, startsWith('1000-${now.millisecondsSinceEpoch}-'));
      expect(names(), ['$id.json'], reason: 'no temporary file left');
      final json = jsonDecode(File('${dir.path}/$id.json').readAsStringSync()) as Map<String, dynamic>;
      expect(json, {
        'v': 1,
        'id': id,
        'uid': 1000,
        'tid': _tid,
        'pid': _pid,
        'text': '第一句',
        'ms': true,
        'at': now.millisecondsSinceEpoch,
      });

      final pm = await inbox.put(uid: 1000, target: _pm, text: '私信');
      final pmJson = jsonDecode(File('${dir.path}/$pm.json').readAsStringSync()) as Map<String, dynamic>;
      expect(pmJson['peer'], 2000);
      expect(pmJson.containsKey('tid'), isFalse);
    });

    test('several failures at once stand side by side', () async {
      final ids = await Future.wait([
        for (var i = 0; i < 5; i++)
          inbox.put(
            uid: 1000,
            target: LocalNoticeTarget(tid: _tid, pid: _pid + i),
            text: '$i',
          ),
      ]);
      expect(ids.nonNulls.toSet(), hasLength(5));
      expect(names().where((e) => e.endsWith('.json')), hasLength(5));
    });

    test('nothing for an empty text, no target or no account', () async {
      expect(await inbox.put(uid: 1000, target: _floor, text: '  '), isNull);
      expect(
        await inbox.put(
          uid: 1000,
          target: const LocalNoticeTarget(tid: _tid),
          text: 'x',
        ),
        isNull,
      );
      expect(await inbox.put(uid: 0, target: _floor, text: 'x'), isNull);
      expect(dir.listSync(), isEmpty);
    });

    test('a directory that can not be written gives no id, never an error', () async {
      final file = File('${dir.path}/not_a_dir')..writeAsStringSync('');
      final broken = DirectReplyDraftInbox(directory: () async => Directory(file.path));
      expect(await broken.put(uid: 1000, target: _floor, text: 'x'), isNull);
    });

    test('the notification telling it was not sent names the failure', () async {
      final request = _request(1000, _floor, '第一句');
      final target = _tapped(request, '1000-1-0000abcd');
      expect(target.draftEvent, '1000-1-0000abcd');
      expect(target.draft, '第一句');
      expect(_tapped(request, '1000-1-0000abcd', unconfirmed: true).maybeSent, isTrue);
      expect(_tapped(request, null).draftEvent, isNull);
      expect(LocalNoticeKeys.parseTarget(request.failedPayload)!.draftEvent, isNull);
    });

    // Guards the order of the failing isolate: the text is kept (`put`) before the notification telling it was not
    // sent is shown, and the id of what was kept is what that notification carries.
    test('the isolate keeps the text before it shows the outcome, and wakes the app', () {
      final entry = File('lib/features/local_notice/direct_reply_entry.dart').readAsStringSync();
      final handle = entry.substring(entry.indexOf('Future<void> _handle('));
      final keep = handle.indexOf('await _keepForApp(request, outcome)');
      expect(keep, greaterThan(0));
      expect(keep, lessThan(handle.indexOf('await showDirectReplyOutcome(')));
      expect(RegExp('draftEvent: draftEvent').allMatches(handle), hasLength(2));
      final unsent = entry.substring(entry.indexOf('Future<void> _showUnsent('));
      expect(unsent, contains('draftEvent: await _keepForApp(request, outcome)'));
      expect(entry, contains('tellAppOfDirectReplyDraft(id)'));
      expect(
        File('lib/features/home/view/home_page.dart').readAsStringSync(),
        contains('watchDirectReplyDrafts()'),
        reason: 'collected once the app runs, at every resume, and when told',
      );
    });

    test('the app is woken through its port', () async {
      final port = ReceivePort();
      IsolateNameServer.removePortNameMapping(DirectReplyDraftInbox.portName);
      expect(IsolateNameServer.registerPortWithName(port.sendPort, DirectReplyDraftInbox.portName), isTrue);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(DirectReplyDraftInbox.portName);
        port.close();
      });
      tellAppOfDirectReplyDraft('1000-1-0000abcd');
      expect(await port.first, '1000-1-0000abcd');
    });
  });

  group("the app's isolate moves them into the drafts", () {
    setUpAll(_logOnce);

    test('a failure swiped away is the draft of its floor all the same', () async {
      final id = await inbox.put(uid: 1000, target: _floor, text: '第一句');
      expect(await collect(), [id]);
      final draft = (await store.load(1000, _floorKey))!;
      expect(draft.body, '第一句');
      expect(draft.updatedAt, now);
      expect(draft.replyAction, directReplyActionUrl(tid: _tid, pid: _pid));
      expect(draft.tid, '$_tid');
      expect(draft.maybeSent, isFalse);
      expect(names(), ['$id.done']);
      expect(await inbox.handled(id!), isTrue);

      expect(await collect(), isEmpty, reason: 'moved once');
      expect(await store.list(1000), hasLength(1));
    });

    test('a private message, and one that may have been sent', () async {
      await inbox.put(uid: 1000, target: _pm, text: '私信', maybeSent: true);
      await collect();
      final draft = (await store.load(1000, _pmKey))!;
      expect(draft.body, '私信');
      expect(draft.maybeSent, isTrue);
      expect(draft.replyAction, isNull);
      expect(draft.tid, isNull);
    });

    test('each account gets its own, whichever account is in use', () async {
      await inbox.put(uid: 1000, target: _floor, text: '甲');
      await inbox.put(uid: 3000, target: _floor, text: '乙');
      await collect();
      expect((await store.load(1000, _floorKey))!.body, '甲');
      expect((await store.load(3000, _floorKey))!.body, '乙');
    });

    test('an account no longer on this device gets nothing, and a tap does not bring it back', () async {
      final id = await inbox.put(uid: 4000, target: _floor, text: '丙');
      expect(await collect(), isEmpty);
      expect(await store.list(4000), isEmpty);
      expect(names(), ['$id.done']);
      await keepDirectReplyDraftOfTap(
        4000,
        _tapped(_request(4000, _floor, '丙'), id),
        inbox: inbox,
        store: store,
        accounts: both,
      );
      expect(await store.list(4000), isEmpty);
    });

    test('accounts not known: the failures wait for the next time', () async {
      final id = await inbox.put(uid: 1000, target: _floor, text: '甲');
      expect(await collect(accounts: () async => throw StateError('db')), isEmpty);
      expect(names(), ['$id.json']);
      expect(await collect(), [id]);
    });

    test('several failures of one floor: the newest in front, the others aside, none lost', () async {
      await inbox.put(uid: 1000, target: _floor, text: '一');
      now = now.add(const Duration(minutes: 1));
      await inbox.put(uid: 1000, target: _floor, text: '二');
      now = now.add(const Duration(minutes: 1));
      await inbox.put(uid: 1000, target: _pm, text: '三');
      await collect();
      final drafts = await store.list(1000);
      expect(drafts.where((e) => e.key == _floorKey).single.body, '二');
      expect(drafts.where((e) => e.key.isBackup && e.key.target == _floorKey).single.body, '一');
      expect(drafts.where((e) => e.key == _pmKey).single.body, '三');
    });

    test('a draft of the floor already there: older moved aside, newer kept in front', () async {
      store.save(1000, LocalDraft(key: _floorKey, body: '旧', updatedAt: now.subtract(const Duration(hours: 1))));
      await inbox.put(uid: 1000, target: _floor, text: '失败的');
      await collect();
      var drafts = await store.list(1000);
      expect(drafts.where((e) => e.key == _floorKey).single.body, '失败的');
      expect(drafts.where((e) => e.key.isBackup).single.body, '旧');

      await store.applySynced(
        3000,
        save: [LocalDraft(key: _floorKey, body: '刚打的', updatedAt: now.add(const Duration(minutes: 1)))],
      );
      await inbox.put(uid: 3000, target: _floor, text: '失败的');
      await collect();
      drafts = await store.list(3000);
      expect(drafts.where((e) => e.key == _floorKey).single.body, '刚打的');
      expect(drafts.where((e) => e.key.isBackup).single.body, '失败的');
    });

    test('the same text there already: nothing added', () async {
      store.save(1000, LocalDraft(key: _floorKey, body: '同一句', updatedAt: now.subtract(const Duration(hours: 1))));
      await inbox.put(uid: 1000, target: _floor, text: '同一句');
      await collect();
      expect(await store.list(1000), hasLength(1));
    });
  });

  group('one draft per failure, tapped or not', () {
    setUpAll(_logOnce);

    test('tapped after it was moved: nothing kept again, whatever became of the draft', () async {
      final request = _request(1000, _floor, '第一句');
      final id = await inbox.put(uid: 1000, target: _floor, text: '第一句');
      await collect();
      // Changed in the app since.
      store.save(1000, LocalDraft(key: _floorKey, body: '第一句，改过', updatedAt: now.add(const Duration(minutes: 2))));
      await keepDirectReplyDraftOfTap(1000, _tapped(request, id), inbox: inbox, store: store, accounts: both);
      final drafts = await store.list(1000);
      expect(drafts, hasLength(1));
      expect(drafts.single.body, '第一句，改过');

      // Sent from the app and gone: not brought back.
      store.delete(1000, _floorKey);
      await keepDirectReplyDraftOfTap(1000, _tapped(request, id), inbox: inbox, store: store, accounts: both);
      expect(await store.list(1000), isEmpty);
    });

    test('tapped before it was moved: moved by the tap, once', () async {
      final request = _request(1000, _floor, '第一句');
      final id = await inbox.put(uid: 1000, target: _floor, text: '第一句');
      await keepDirectReplyDraftOfTap(1000, _tapped(request, id), inbox: inbox, store: store, accounts: both);
      expect((await store.list(1000)).single.body, '第一句');
      expect(await inbox.handled(id!), isTrue);
      expect(await collect(), isEmpty);
      expect(await store.list(1000), hasLength(1));
    });

    test('a tap and a collect at the same moment: one draft', () async {
      final request = _request(1000, _floor, '第一句');
      final id = await inbox.put(uid: 1000, target: _floor, text: '第一句');
      await Future.wait([
        collect(),
        keepDirectReplyDraftOfTap(1000, _tapped(request, id), inbox: inbox, store: store, accounts: both),
        collect(),
      ]);
      expect(await store.list(1000), hasLength(1));
    });

    test('no failure named (not written, an older version): the text of the payload, as before', () async {
      final request = _request(1000, _pm, '私信');
      await keepDirectReplyDraftOfTap(1000, _tapped(request, null), inbox: inbox, store: store, accounts: both);
      expect((await store.load(1000, _pmKey))!.body, '私信');
    });

    test('a failure named but gone without a mark (dropped past the limit): the text of the payload', () async {
      final request = _request(1000, _floor, '第一句');
      await keepDirectReplyDraftOfTap(
        1000,
        _tapped(request, '1000-1-0000abcd'),
        inbox: inbox,
        store: store,
        accounts: both,
      );
      expect((await store.load(1000, _floorKey))!.body, '第一句');
    });

    test('kept from the payload while its file could not be moved: never moved again later', () async {
      final request = _request(1000, _floor, '第一句');
      final id = await inbox.put(uid: 1000, target: _floor, text: '第一句');
      await keepDirectReplyDraftOfTap(
        1000,
        _tapped(request, id),
        inbox: inbox,
        store: store,
        accounts: () async => throw StateError('db'),
      );
      expect((await store.load(1000, _floorKey))!.body, '第一句');
      expect(await inbox.handled(id!), isTrue);
      // Sent from the app: the next collect does not bring it back.
      store.delete(1000, _floorKey);
      expect(await collect(), isEmpty);
      expect(await store.list(1000), isEmpty);
      expect(names(), ['$id.done']);
    });

    test('a crafted failure id reaches no file', () async {
      File('${dir.parent.path}/x.done').writeAsStringSync('');
      addTearDown(() => File('${dir.parent.path}/x.done').deleteSync());
      for (final id in ['../x', '1000-1-0000abcd/../../x', '', '1000-1-ABCDEFGH']) {
        expect(DirectReplyDraftInbox.validId(id), isFalse, reason: id);
        expect(await inbox.handled(id), isFalse);
      }
      final request = _request(1000, _floor, '第一句');
      await keepDirectReplyDraftOfTap(1000, _tapped(request, '../x'), inbox: inbox, store: store, accounts: both);
      expect((await store.load(1000, _floorKey))!.body, '第一句');
    });

    test("another account's failure id is not taken for this one", () async {
      final id = await inbox.put(uid: 3000, target: _floor, text: '乙');
      await collect();
      await keepDirectReplyDraftOfTap(
        1000,
        _tapped(_request(1000, _floor, '甲'), id),
        inbox: inbox,
        store: store,
        accounts: both,
      );
      expect((await store.load(1000, _floorKey))!.body, '甲');
    });
  });

  group('limits and broken files', () {
    setUpAll(_logOnce);

    test(
      'a file that does not parse, of another version or naming another account is deleted, the rest moved',
      () async {
        final good = await inbox.put(uid: 1000, target: _floor, text: '好的');
        File('${dir.path}/1000-1-00000001.json').writeAsStringSync('{not json');
        File('${dir.path}/1000-2-00000002.json').writeAsStringSync(
          jsonEncode({'v': 2, 'id': '1000-2-00000002', 'uid': 1000, 'peer': 2, 'text': 'x', 'at': 1}),
        );
        File('${dir.path}/1000-3-00000003.json').writeAsStringSync(
          jsonEncode({'v': 1, 'id': '1000-3-00000003', 'uid': 3000, 'peer': 2, 'text': 'x', 'at': 1}),
        );
        File('${dir.path}/evil.json').writeAsStringSync('{}');
        File('${dir.path}/1000-4-00000004.json.tmp').writeAsStringSync('{half');
        expect(await collect(), [good]);
        expect(names(), ['$good.done', '1000-4-00000004.json.tmp'], reason: 'a file being written is left alone');
        expect(await store.list(3000), isEmpty);
      },
    );

    test('a failure older than 30 days is dropped', () async {
      await inbox.put(uid: 1000, target: _floor, text: '很久以前');
      now = now.add(DirectReplyDraftInbox.keepFor + const Duration(minutes: 1));
      expect(await collect(), isEmpty);
      expect(await store.list(1000), isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('at most 50 wait, the oldest go first', () async {
      for (var i = 0; i < DirectReplyDraftInbox.maxPending + 3; i++) {
        now = now.add(const Duration(seconds: 1));
        await inbox.put(
          uid: 1000,
          target: LocalNoticeTarget(peerUid: 10 + i),
          text: '$i',
        );
      }
      expect(await collect(), hasLength(DirectReplyDraftInbox.maxPending));
      final peers = (await store.list(1000)).map((e) => int.parse(e.key.peerUid!)).toSet();
      expect(peers.contains(10), isFalse);
      expect(peers.contains(12), isFalse);
      expect(peers.contains(13), isTrue);
    });

    test('marks are kept for 30 days', () async {
      final id = await inbox.put(uid: 1000, target: _floor, text: '一');
      await collect();
      expect(names(), ['$id.done']);
      now = now.add(DirectReplyDraftInbox.keepFor + const Duration(days: 1));
      await collect();
      expect(dir.listSync(), isEmpty);
    });

    test('a failure marked but not deleted (the app stopped in between) is not moved again', () async {
      final id = await inbox.put(uid: 1000, target: _floor, text: '一');
      File('${dir.path}/$id.done').writeAsStringSync('');
      expect(await collect(), isEmpty);
      expect(await store.list(1000), isEmpty);
      expect(names(), ['$id.done']);
    });

    test('no directory, or one that can not be listed: nothing, never an error', () async {
      await dir.delete(recursive: true);
      expect(await collect(), isEmpty);
      final broken = DirectReplyDraftInbox(directory: () async => throw const FileSystemException('gone'));
      expect(await collectDirectReplyDrafts(inbox: broken, store: store, accounts: both), isEmpty);
      expect(await broken.handled('1000-1-0000abcd'), isFalse);
    });
  });

  group('the tap keeps going through it', () {
    setUpAll(_logOnce);

    test('openNoticePageOfAccount keeps the text through the inbox', () {
      final tap = File('lib/features/local_notice/tap.dart').readAsStringSync();
      final open = tap.substring(tap.indexOf('openNoticePageOfAccount('));
      expect(open, contains('await keepDirectReplyDraftOfTap(uid, target);'));
    });
  });
}
