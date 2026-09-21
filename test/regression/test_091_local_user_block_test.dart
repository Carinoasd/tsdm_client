import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/notice_block_filter.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

/// Local, silent user block: per-account list in the settings table, no network, filters by uid only.
const _alice = 1000;
const _bob = 2000;
const _troll = 3000;

StorageProvider _memoryStorage() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return StorageProvider(db, {}, {});
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('UserBlockRepository', () {
    test('blocking never needs the network', () async {
      // No NetClientProvider is registered: any request would throw.
      expect(getIt.isRegistered<NetClientProvider>(), isFalse);
      final repo = UserBlockRepository(_memoryStorage());
      addTearDown(repo.dispose);
      expect(await repo.block(ownerUid: _alice, uid: _troll, username: 'troll'), UserBlockResult.ok);
      expect(await repo.blockedUidsOf(_alice), {_troll});
      expect(await repo.unblock(ownerUid: _alice, uid: _troll), UserBlockResult.ok);
      expect(await repo.blockedUidsOf(_alice), isEmpty);
    });

    test('self block, guests and invalid uids are refused', () async {
      final repo = UserBlockRepository(_memoryStorage());
      addTearDown(repo.dispose);
      expect(await repo.block(ownerUid: _alice, uid: _alice, username: 'me'), UserBlockResult.selfBlock);
      expect(await repo.block(ownerUid: null, uid: _troll, username: 't'), UserBlockResult.invalid);
      expect(await repo.block(ownerUid: _alice, uid: 0, username: 't'), UserBlockResult.invalid);
      expect(await repo.blockedUidsOf(_alice), isEmpty);
      expect(await repo.unblock(ownerUid: _alice, uid: _troll), UserBlockResult.notBlocked);
      expect(await repo.block(ownerUid: _alice, uid: _troll, username: 't'), UserBlockResult.ok);
      expect(await repo.block(ownerUid: _alice, uid: _troll, username: 't'), UserBlockResult.alreadyBlocked);
    });

    test('each account owns its own list', () async {
      final storage = _memoryStorage();
      final repo = UserBlockRepository(storage);
      addTearDown(repo.dispose);
      await repo.block(ownerUid: _alice, uid: _troll, username: 'troll');
      expect(await repo.blockedUidsOf(_bob), isEmpty);
      await repo.block(ownerUid: _bob, uid: _alice, username: 'alice');
      expect(await repo.blockedUidsOf(_alice), {_troll});
      expect(await repo.blockedUidsOf(_bob), {_alice});
      expect(await storage.getStringList(UserBlockRepository.keyOf(_alice)), hasLength(1));
    });

    test('concurrent blocks are all kept', () async {
      final repo = UserBlockRepository(_memoryStorage());
      addTearDown(repo.dispose);
      await Future.wait([
        for (var i = 1; i <= 5; i++) repo.block(ownerUid: _alice, uid: _troll + i, username: 'u$i'),
      ]);
      expect(await repo.blockedUidsOf(_alice), {for (var i = 1; i <= 5; i++) _troll + i});
    });

    test('the list survives closing and reopening the database', () async {
      final dir = Directory.systemTemp.createTempSync('tsdm_block_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/db.sqlite');

      final db1 = AppDatabase(NativeDatabase(file));
      final repo1 = UserBlockRepository(StorageProvider(db1, {}, {}));
      await repo1.block(ownerUid: _alice, uid: _troll, username: 'troll');
      await repo1.dispose();
      await db1.close();

      final db2 = AppDatabase(NativeDatabase(file));
      addTearDown(db2.close);
      final list = await UserBlockRepository(StorageProvider(db2, {}, {})).load(_alice);
      expect(list.uids, {_troll});
      expect(list.users.single.username, 'troll');
    });

    test('entries this version can not read are kept and written back unchanged', () async {
      final storage = _memoryStorage();
      final repo = UserBlockRepository(storage);
      addTearDown(repo.dispose);
      const unreadable = ['not json', '{"uid":"x"}', '{"uid":4000,"username":"bad time","at":9223372036854775807}'];
      await storage.saveStringList(UserBlockRepository.keyOf(_alice), [
        ...unreadable,
        '{"uid":3000,"username":"t","at":1}',
      ]);
      final list = await repo.load(_alice);
      expect(list.uids, {_troll});
      expect(list.unreadableEntries, unreadable);

      await repo.block(ownerUid: _alice, uid: _troll + 1, username: 'x');
      await repo.unblock(ownerUid: _alice, uid: _troll);
      final raw = await storage.getStringList(UserBlockRepository.keyOf(_alice));
      expect(raw, containsAll(unreadable), reason: 'never dropped by a rewrite');
      expect((await repo.load(_alice)).uids, {_troll + 1});

      // Unblocking the last readable user keeps the row for the unreadable entries.
      await repo.unblock(ownerUid: _alice, uid: _troll + 1);
      expect(await storage.getStringList(UserBlockRepository.keyOf(_alice)), unreadable);
    });
  });

  group('UserBlockList', () {
    test('an unknown list holds back identified authors only, guests are never unknown', () {
      const loading = UserBlockList.unknown(_alice, status: UserBlockListStatus.loading);
      expect(loading.isKnown, isFalse);
      expect(loading.hides(_bob), isTrue);
      expect(loading.hides(null), isFalse);
      expect(loading.hides(0), isFalse, reason: 'system notices have author 0');
      expect(const UserBlockList.unknown(null, status: UserBlockListStatus.failed).hides(_bob), isFalse);
      final known = UserBlockList(
        ownerUid: _alice,
        users: [BlockedUser(uid: _troll, username: 't', blockedAt: DateTime(2026))],
      );
      expect(known.hides(_troll), isTrue);
      expect(known.hides(_bob), isFalse);
    });
  });

  group('UserBlockCubit', () {
    test('follows account switches and never shows the previous account list', () async {
      final storage = _memoryStorage();
      final repo = UserBlockRepository(storage);
      addTearDown(repo.dispose);
      await repo.block(ownerUid: _alice, uid: _troll, username: 'troll');

      var current = _alice;
      final auth = StreamController<AuthStatus>.broadcast(sync: true);
      addTearDown(auth.close);
      var changes = 0;
      final cubit = UserBlockCubit(
        repository: repo,
        currentUid: () => current,
        authStatus: auth.stream,
        onListChanged: () => changes++,
      );
      addTearDown(cubit.close);
      // Not known before the list is read: nothing identified is shown as "not blocked".
      expect(cubit.state.status, UserBlockListStatus.loading);
      expect(cubit.state.hides(_bob), isTrue);
      await pumpEventQueue();
      expect(cubit.state.ownerUid, _alice);
      expect(cubit.state.isBlocked(_troll), isTrue);
      expect(changes, 1, reason: 'the first known list is reported once');

      current = _bob;
      auth.add(const AuthStatusNotAuthed());
      expect(cubit.state.ownerUid, _bob, reason: 'switched at once');
      expect(cubit.state.isKnown, isFalse, reason: "neither alice's list nor an empty one while loading");
      await pumpEventQueue();
      expect(cubit.state.ownerUid, _bob);
      expect(cubit.state.isBlocked(_troll), isFalse);
      expect(changes, 2);

      // A change to alice's list made elsewhere (e.g. a late write) does not leak into bob's state.
      await repo.block(ownerUid: _alice, uid: _troll + 1, username: 'x');
      await pumpEventQueue();
      expect(cubit.state.ownerUid, _bob);
      expect(cubit.state.uids, isEmpty);
      expect(changes, 2);

      // A choice made while alice was current is dropped.
      expect(
        await cubit.block(uid: _troll + 2, username: 'late', expectedOwner: _alice),
        UserBlockResult.accountChanged,
      );
      expect(await repo.blockedUidsOf(_alice), {_troll, _troll + 1});
      expect(await repo.blockedUidsOf(_bob), isEmpty);

      // Actions act for the account current at that time.
      expect(await cubit.block(uid: _troll, username: 'troll', expectedOwner: _bob), UserBlockResult.ok);
      await pumpEventQueue();
      expect(cubit.state.uids, {_troll});
      expect(changes, 3);
    });
  });

  group('quotes', () {
    const quoted =
        '<div class="quote"><blockquote><font size="2"><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=11&amp;ptid=5"> '
        '<font color="#999999">troll 发表于 2026-9-5 17:38</font></a></font><br>secret words</blockquote></div>reply body';

    int? authorOf(int pid) => pid == 11 ? _troll : null;

    test('quote of a loaded post of a blocked author is replaced', () {
      final out = redactBlockedQuotes(quoted, blockedUids: {_troll}, authorOfPost: authorOf, placeholder: 'HIDDEN');
      expect(out, isNot(contains('secret words')));
      expect(out, contains('HIDDEN'));
      expect(out, contains('reply body'));
    });

    test('unknown quoted post is kept: its author can not be identified', () {
      final out = redactBlockedQuotes(quoted, blockedUids: {_troll}, authorOfPost: (_) => null, placeholder: 'HIDDEN');
      expect(out, same(quoted));
    });

    test('nothing blocked leaves the html untouched', () {
      expect(redactBlockedQuotes(quoted, blockedUids: {}, authorOfPost: authorOf, placeholder: 'H'), same(quoted));
    });

    test('only the forum findpost redirect is trusted, never user links in the quote', () {
      String? pidOf(String html) {
        final doc = parseHtmlDocument('<div class="quote">$html</div>');
        return quotedPostId(doc.querySelector('div.quote')!)?.toString();
      }

      expect(pidOf('<a href="forum.php?mod=redirect&goto=findpost&pid=11&ptid=5">x</a>'), '11');
      expect(pidOf('<a href="https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&pid=12">x</a>'), '12');
      expect(pidOf('<a href="https://evil.example/forum.php?mod=redirect&goto=findpost&pid=11">x</a>'), isNull);
      expect(pidOf('<a href="//evil.example/forum.php?mod=redirect&goto=findpost&pid=11">x</a>'), isNull);
      expect(pidOf('<a href="javascript:forum.php?mod=redirect&goto=findpost&pid=11">x</a>'), isNull);
      expect(pidOf('<a href="home.php?mod=space&uid=3000">troll</a>'), isNull);
      expect(pidOf('<a href="forum.php?mod=redirect&goto=findpost&pid=abc">x</a>'), isNull);
      expect(pidOf('<a href="evilforum.php?mod=redirect&goto=findpost&pid=11">x</a>'), isNull);
      expect(pidOf('<a href="x/forum.php?mod=redirect&goto=findpost&pid=11">x</a>'), isNull);
      expect(pidOf('<a href="https://www.tsdm39.com:444/forum.php?mod=redirect&goto=findpost&pid=11">x</a>'), isNull);
      expect(pidOf('<a href="forum.php?mod=redirect&goto=findpost&pid=11&x=%E0%A4%A">x</a>'), isNull);
    });

    test('profile links give a uid only for the forum profile of that uid', () {
      expect(uidOfProfileUrl('home.php?mod=space&amp;uid=3000'), _troll);
      expect(uidOfProfileUrl('https://tsdm39.com/space-uid-3000.html'), _troll);
      expect(uidOfProfileUrl('home.php?mod=space&username=troll'), isNull, reason: 'names are never matched');
      expect(uidOfProfileUrl('https://evil.example/home.php?mod=space&uid=3000'), isNull);
      expect(uidOfProfileUrl('evilhome.php?mod=space&uid=3000'), isNull);
      expect(uidOfProfileUrl('home.php?mod=space&uid=0'), isNull);
    });
  });

  group('notices', () {
    NoticeV2 notice(int nid, {int? author, bool read = false, int? timestamp, String? data}) => NoticeV2(
      id: nid,
      timestamp: timestamp ?? 100 + nid,
      data: data ?? 'n$nid',
      alreadyRead: read,
      ignoreType: author == null ? null : 'post',
      authorId: author,
    );

    NotificationV2 notices(List<NoticeV2> list) =>
        NotificationV2(status: 0, noticeList: list, personalMessageList: const [], broadcastMessageList: const []);

    test('only the author from the ignore link hides a notice', () {
      final list = UserBlockList(
        ownerUid: _alice,
        users: [BlockedUser(uid: _troll, username: 't', blockedAt: DateTime(2026))],
      );
      expect(isBlockedNoticeAuthor(_troll, list), isTrue);
      expect(isBlockedNoticeAuthor(null, list), isFalse);
      expect(isBlockedNoticeAuthor(0, list), isFalse);
      expect(isBlockedNoticeAuthor(_bob, list), isFalse);
      final filtered = withoutBlockedNotices(
        NotificationV2(
          status: 0,
          noticeList: [
            notice(1, author: _troll),
            notice(2, author: _bob),
            notice(3),
          ],
          personalMessageList: const [
            PersonalMessageV2(
              timestamp: 1,
              data: 'pm',
              peerUid: _troll,
              peerUsername: 'troll',
              sender: false,
              alreadyRead: false,
            ),
          ],
          broadcastMessageList: const [],
        ),
        list,
      );
      expect(filtered.noticeList.map((e) => e.id), [2, 3]);
      // Only the fresh alert payload is filtered; persistence keeps the conversation.
      expect(filtered.personalMessageList, isEmpty);
    });

    test('blocked notices are stored raw but neither fresh nor unread; unblocking counts them again', () async {
      final storage = _memoryStorage();
      final repo = UserBlockRepository(storage);
      addTearDown(repo.dispose);
      await repo.block(ownerUid: _alice, uid: _troll, username: 'troll');

      final persisted = await persistFetchedNotification(
        storage: storage,
        uid: _alice,
        fetched: notices([notice(1, author: _troll), notice(2, author: _bob)]),
      );
      expect(persisted.fresh.noticeList.map((e) => e.id), [2]);
      expect(persisted.unread.notice, 1);

      final stored = await storage.fetchNotificationSince(uid: _alice, timestamp: 0).run();
      final troll = stored.noticeList.firstWhere((e) => e.nid == 1);
      expect(troll.authorId, _troll);
      expect(troll.ignoreType, 'post');
      // The server read state is not changed by hiding.
      expect(troll.alreadyRead, isNot(true));

      // Another account is not affected by alice's list.
      expect((await countUnreadNotification(storage: storage, uid: _bob)).notice, 0);

      await repo.unblock(ownerUid: _alice, uid: _troll);
      expect((await countUnreadNotification(storage: storage, uid: _alice)).notice, 2);
    });

    // Revised from round 1 ("a later copy without metadata keeps the stored author"): Discuz keeps the nid when it
    // merges a later event into a notice, and that event may come from another user. Keeping the old author for a
    // changed copy would hide (or offer to block / ignore) the wrong user, so the author is kept only for the same
    // revision and becomes unknown otherwise.
    test('a copy without metadata keeps the stored author only for the same revision', () async {
      final storage = _memoryStorage();
      Future<NoticeEntity> storeAndRead(NoticeV2 n) async {
        await persistFetchedNotification(storage: storage, uid: _alice, fetched: notices([n]));
        return (await storage.fetchNotificationSince(uid: _alice, timestamp: 0).run()).noticeList.single;
      }

      var stored = await storeAndRead(notice(1, author: _troll, timestamp: 200, data: 'reply by troll'));
      expect(stored.authorId, _troll);

      // Same time and body, only the ignore link is missing this time (layout hiccup): still the same notice.
      stored = await storeAndRead(notice(1, timestamp: 200, data: 'reply by troll'));
      expect(stored.authorId, _troll);
      expect(stored.ignoreType, 'post');

      // Merged with a newer event, no metadata: the author is not known any more.
      stored = await storeAndRead(notice(1, timestamp: 500, data: 'merged: new reply'));
      expect(stored.data, 'merged: new reply');
      expect(stored.authorId, isNull);
      expect(stored.ignoreType, isNull);

      // A newer copy carrying another author takes that author.
      stored = await storeAndRead(notice(1, author: _bob, timestamp: 600, data: 'reply by bob'));
      expect(stored.authorId, _bob);

      // Same time, other body, no metadata: another revision as well.
      stored = await storeAndRead(notice(1, timestamp: 600, data: 'reply by somebody else'));
      expect(stored.authorId, isNull);
    });

    test('a block list that can not be read holds back attributed notices instead of announcing them', () async {
      final storage = _memoryStorage();
      expect((await noticeBlockListOf(storage, _alice)).isKnown, isTrue, reason: 'an absent row is an empty list');
      // A row of another type under the list name cannot be read as a string list.
      await storage.saveString(UserBlockRepository.keyOf(_alice), 'damaged row');
      final list = await noticeBlockListOf(storage, _alice);
      expect(list.status, UserBlockListStatus.failed);
      final fetched = notices([notice(1, author: _troll), notice(2)]).copyWith(
        personalMessageList: const [
          PersonalMessageV2(
            timestamp: 1,
            data: 'kept while list unavailable',
            peerUid: _troll,
            peerUsername: 'troll',
            sender: false,
            alreadyRead: false,
          ),
        ],
      );
      expect(withoutBlockedNotices(fetched, list).noticeList.map((e) => e.id), [2]);
      final persisted = await persistFetchedNotification(storage: storage, uid: _alice, fetched: fetched);
      expect(persisted.fresh.personalMessageList, isEmpty);
      expect(persisted.unread.personalMessage, 0);
      final stored = await storage.fetchNotificationSince(uid: _alice, timestamp: 0).run();
      expect(stored.personalMessageList.single.alreadyRead, isFalse);
      expect(stored.personalMessageList.single.peerUid, _troll);
      final repository = UserBlockRepository(storage);
      addTearDown(repository.dispose);
      await expectLater(
        repository.block(ownerUid: _alice, uid: _troll, username: 'troll'),
        throwsA(isA<UserBlockStorageException>()),
      );
      expect(await storage.getString(UserBlockRepository.keyOf(_alice)), 'damaged row');
    });
  });

  group('widgets', () {
    Future<UserBlockCubit> pumpWith(WidgetTester tester, Widget child, {Set<int> blocked = const {}}) async {
      final repo = UserBlockRepository(_memoryStorage());
      await tester.runAsync(() async {
        for (final uid in blocked) {
          await repo.block(ownerUid: _alice, uid: uid, username: 'u$uid');
        }
      });
      final cubit = UserBlockCubit(
        repository: repo,
        currentUid: () => _alice,
        authStatus: const Stream<AuthStatus>.empty(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: child),
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      addTearDown(() async {
        await cubit.close();
        await repo.dispose();
      });
      return cubit;
    }

    testWidgets('isBlockedByCurrentUser hides only the blocked author and reacts to unblock', (tester) async {
      final cubit = await pumpWith(
        tester,
        Column(
          children: [
            Builder(builder: (c) => Text(isBlockedByCurrentUser(c, '$_troll') ? 'hidden' : 'troll topic')),
            Builder(builder: (c) => Text(isBlockedByCurrentUser(c, '$_bob') ? 'hidden' : 'bob topic')),
            Builder(builder: (c) => Text(isBlockedByCurrentUser(c, null) ? 'hidden' : 'anonymous topic')),
          ],
        ),
        blocked: {_troll},
      );
      expect(find.text('troll topic'), findsNothing);
      expect(find.text('bob topic'), findsOneWidget);
      expect(find.text('anonymous topic'), findsOneWidget);

      await tester.runAsync(() async {
        await cubit.unblock(_troll, expectedOwner: _alice);
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
      expect(find.text('troll topic'), findsOneWidget);
    });

    testWidgets('without a cubit nothing is hidden', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: (c) => Text(isBlockedByCurrentUser(c, '$_troll') ? 'hidden' : 'shown'))),
      );
      expect(find.text('shown'), findsOneWidget);
    });
  });
}
