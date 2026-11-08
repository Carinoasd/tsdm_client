/// Keyword and forum filters of the thread lists: the one check every list uses, the local rows of each account, and
/// the cross-device sync of the two sections `block_keywords` and `block_forums`.
///
/// * The check: a keyword hides a thread whose title contains it, case ignored, Simplified and Traditional Chinese as
///   they are (never converted); a forum hides its threads in lists of many forums only.
/// * The rows: per account, removals kept as records, blocking or unblocking a user never touches the filters, entries
///   this version can not read are written back, nothing is written when the sync brings nothing new.
/// * The sync: a document without the sections (an older version's) changes nothing here; a device that upgrades
///   after an older version kept the forum's filters in its last document takes them instead of deleting them; a
///   removal reaches the other devices; a pull with nothing new writes nothing.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 3000;

/// A forum keeping one document; a successful push replaces it.
final class _FakeApi implements SyncApi {
  _FakeApi([this.stored]);

  String? stored;
  int storedUpdated = 1;
  final pushes = <String>[];

  @override
  Future<SyncPullAnswer> pull(int uid) async =>
      SyncPulled(updated: storedUpdated, data: stored, formhash: 'fh', uid: uid);

  @override
  Future<SyncPushAnswer> push(
    int uid, {
    required String data,
    required int baseUpdated,
    required String formhash,
  }) async {
    pushes.add(data);
    stored = data;
    storedUpdated++;
    return SyncPushed(storedUpdated);
  }

  Map<String, dynamic> get lastPushed => jsonDecode(pushes.last) as Map<String, dynamic>;
}

ThreadFilters _filters({List<String> keywords = const [], Map<int, String> forums = const {}}) => ThreadFilters(
  keywordRecords: [for (final (i, k) in keywords.indexed) BlockedKeyword(text: k, updated: 1000 + i)],
  forumRecords: [
    for (final MapEntry(:key, :value) in forums.entries) BlockedForum(fid: key, name: value, updated: 900),
  ],
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the check', () {
    test('a keyword hides the titles containing it, case ignored', () {
      final f = _filters(keywords: ['Spoiler', 'abc']);
      expect(f.hides(title: 'big SPOILER inside'), isTrue);
      expect(f.hides(title: 'xxABCxx'), isTrue);
      expect(f.hides(title: 'nothing here'), isFalse);
      expect(f.hides(title: null), isFalse);
    });

    test('Simplified and Traditional Chinese are matched as they are, never converted', () {
      final f = _filters(keywords: ['剧透']);
      expect(f.hides(title: '【剧透】第十话'), isTrue);
      expect(f.hides(title: '【劇透】第十話'), isFalse);
      final tw = _filters(keywords: ['劇透']);
      expect(tw.hides(title: '【劇透】第十話'), isTrue);
      expect(tw.hides(title: '【剧透】第十话'), isFalse);
    });

    test('a forum hides its threads in the lists of many forums, never in its own page', () {
      final f = _filters(forums: {8: 'Board'});
      expect(f.hides(title: 't', fid: 8), isTrue);
      expect(f.hides(title: 't', fid: 9), isFalse);
      expect(f.hides(title: 't', fid: 8, byForum: false), isFalse);
      expect(f.hides(title: 't'), isFalse);
    });

    test('removed records do not filter', () {
      final f = ThreadFilters(
        keywordRecords: const [BlockedKeyword(text: 'abc', updated: 5, deleted: true)],
        forumRecords: const [BlockedForum(fid: 8, name: 'Board', updated: 5, deleted: true)],
      );
      expect(f.isEmpty, isTrue);
      expect(f.hides(title: 'abc', fid: 8), isFalse);
    });

    test('the forum id of a forum link', () {
      expect(fidOfForumUrl('https://forum.test/forum.php?mod=forumdisplay&fid=8'), 8);
      expect(fidOfForumUrl('forum.php?mod=forumdisplay&amp;fid=12&amp;page=2'), 12);
      expect(fidOfForumUrl('https://forum.test/forum-31-1.html'), 31);
      expect(fidOfForumUrl('forum.php?mod=forumdisplay'), isNull);
      expect(fidOfForumUrl(null), isNull);
    });
  });

  group('the rows', () {
    late AppDatabase db;
    late StorageProvider storage;
    late UserBlockRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      repo = UserBlockRepository(storage);
    });

    tearDown(() async {
      await repo.dispose();
      await db.close();
    });

    test('keywords: added trimmed, one per key case ignored, removed as a record', () async {
      expect(await repo.addKeyword(ownerUid: _uid, text: '  Spoiler '), UserBlockResult.ok);
      expect(await repo.addKeyword(ownerUid: _uid, text: 'SPOILER'), UserBlockResult.alreadyBlocked);
      expect(await repo.addKeyword(ownerUid: _uid, text: '   '), UserBlockResult.invalid);
      expect(
        await repo.addKeyword(ownerUid: _uid, text: 'x' * (threadFilterKeywordMaxLength + 1)),
        UserBlockResult.invalid,
      );
      expect(await repo.addKeyword(ownerUid: null, text: 'a'), UserBlockResult.invalid);
      var list = await repo.load(_uid);
      expect([for (final k in list.filters.keywords) k.text], ['Spoiler']);

      expect(await repo.removeKeyword(ownerUid: _uid, key: 'spoiler'), UserBlockResult.ok);
      expect(await repo.removeKeyword(ownerUid: _uid, key: 'spoiler'), UserBlockResult.notBlocked);
      list = await repo.load(_uid);
      expect(list.filters.keywords, isEmpty);
      expect(list.filters.keywordRecords.single.deleted, isTrue);
      // Added again: live again, still one record.
      expect(await repo.addKeyword(ownerUid: _uid, text: 'spoiler'), UserBlockResult.ok);
      list = await repo.load(_uid);
      expect(list.filters.keywordRecords, hasLength(1));
      expect(list.filters.keywordKeys, ['spoiler']);
    });

    test('forums: exactly the picked ones, the others removed as records', () async {
      expect(await repo.setForums(ownerUid: _uid, forums: {8: 'Board', 9: 'Other'}), UserBlockResult.ok);
      expect(await repo.setForums(ownerUid: _uid, forums: {8: 'Board', 9: 'Other'}), UserBlockResult.alreadyBlocked);
      expect(await repo.setForums(ownerUid: _uid, forums: {9: 'Other', 10: 'New'}), UserBlockResult.ok);
      final f = (await repo.load(_uid)).filters;
      expect(f.forumIds, {9, 10});
      expect(f.forumRecords.firstWhere((e) => e.fid == 8).deleted, isTrue);
    });

    test('each account has its own filters', () async {
      await repo.addKeyword(ownerUid: _uid, text: 'abc');
      expect((await repo.load(_uid + 1)).filters.isEmpty, isTrue);
    });

    test('blocking and unblocking a user keeps the filters, a filter change keeps the users', () async {
      await repo.addKeyword(ownerUid: _uid, text: 'abc');
      await repo.setForums(ownerUid: _uid, forums: {8: 'Board'});
      final emitted = <UserBlockList>[];
      final sub = repo.changes.listen(emitted.add);
      addTearDown(sub.cancel);
      await repo.block(ownerUid: _uid, uid: 77, username: 'x');
      await repo.unblock(ownerUid: _uid, uid: 77);
      await repo.replaceAll(ownerUid: _uid, users: const []);
      await repo.block(ownerUid: _uid, uid: 78, username: 'y');
      await repo.addKeyword(ownerUid: _uid, text: 'def');
      await pumpEventQueue();
      for (final list in emitted) {
        expect(list.filters.forumIds, {8});
        expect(list.filters.keywordKeys, contains('abc'));
      }
      final list = await repo.load(_uid);
      expect(list.uids, {78});
      expect(list.filters.keywordKeys.toSet(), {'abc', 'def'});
    });

    test('entries this version can not read are written back as they are', () async {
      await storage.saveStringList(UserBlockRepository.keywordKeyOf(_uid), ['{"future":1}']);
      await repo.addKeyword(ownerUid: _uid, text: 'abc');
      final raw = await storage.getStringList(UserBlockRepository.keywordKeyOf(_uid));
      expect(raw, contains('{"future":1}'));
      expect(raw, hasLength(2));
    });

    test('the sync: the later record wins, the same records write nothing', () async {
      await repo.addKeyword(ownerUid: _uid, text: 'abc', now: DateTime.fromMillisecondsSinceEpoch(2000));
      final emitted = <UserBlockList>[];
      final sub = repo.changes.listen(emitted.add);
      addTearDown(sub.cancel);
      // Older removal from another device: this device's later add stays.
      await repo.applySyncedFilters(
        ownerUid: _uid,
        keywords: const [BlockedKeyword(text: 'abc', updated: 1000, deleted: true)],
        forums: const [],
        now: DateTime.fromMillisecondsSinceEpoch(3000),
      );
      await pumpEventQueue();
      expect(emitted, isEmpty);
      expect((await repo.load(_uid)).filters.keywordKeys, ['abc']);
      // A later removal and a new forum are taken.
      await repo.applySyncedFilters(
        ownerUid: _uid,
        keywords: const [BlockedKeyword(text: 'abc', updated: 2500, deleted: true)],
        forums: const [BlockedForum(fid: 8, name: 'Board', updated: 2500)],
        now: DateTime.fromMillisecondsSinceEpoch(3000),
      );
      await pumpEventQueue();
      expect(emitted, hasLength(1));
      final f = (await repo.load(_uid)).filters;
      expect(f.keywordKeys, isEmpty);
      expect(f.forumIds, {8});
    });
  });

  group('the sync', () {
    late _FakeApi api;
    late MemorySyncLocalStore store;
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final at = now.millisecondsSinceEpoch;

    SyncRepository repo() => SyncRepository(api: api, store: store, enabled: () => true, now: () => now);

    setUp(() {
      store = MemorySyncLocalStore();
    });

    test("this device's filters go to the forum in their own sections, removals included", () async {
      api = _FakeApi();
      store.filtersByUid[_uid] = ThreadFilters(
        keywordRecords: [
          BlockedKeyword(text: 'ABC', updated: at - 10),
          BlockedKeyword(text: 'x', updated: at - 5, deleted: true),
        ],
        forumRecords: [BlockedForum(fid: 8, name: 'Board', updated: at - 10)],
      );
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(api.lastPushed['schema'], 1);
      expect(api.lastPushed['block_keywords'], {
        'abc': {'updated': at - 10, 'text': 'ABC'},
        'x': {'updated': at - 5, 'deleted': true},
      });
      expect(api.lastPushed['block_forums'], {
        '8': {'updated': at - 10, 'name': 'Board'},
      });
      expect(api.lastPushed.containsKey('blocks'), isFalse);
    });

    test("a document without the sections (an older version's) leaves the filters here alone", () async {
      final old = jsonEncode({
        'schema': 1,
        'blocks': {
          '77': {'updated': 5, 'username': 'x'},
        },
      });
      api = _FakeApi(old);
      store
        ..lastByUid[_uid] = (document: old, updated: 1)
        ..filtersByUid[_uid] = _filters(keywords: ['abc']);
      await repo().pull(_uid);
      expect(store.writes, isNot(contains('applyThreadFilters')));
      expect(store.filtersByUid[_uid]!.keywordKeys, ['abc']);
      expect((api.lastPushed['block_keywords'] as Map).keys, ['abc']);
    });

    test('an upgraded device whose last document holds filters it never took keeps them, deletes none', () async {
      // Device A of this version wrote filters; device B of an older version synced and kept the document (carrying
      // the sections it does not read), then B upgrades: its own rows are still empty.
      final doc = jsonEncode({
        'schema': 1,
        'block_keywords': {
          'abc': {'updated': 500, 'text': 'ABC'},
        },
        'block_forums': {
          '8': {'updated': 500, 'name': 'Board'},
        },
      });
      api = _FakeApi(doc);
      store.lastByUid[_uid] = (document: doc, updated: 1);
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(api.pushes, isEmpty, reason: 'no removal is sent');
      expect(store.filtersByUid[_uid]!.keywordKeys, ['abc']);
      expect(store.filtersByUid[_uid]!.forumIds, {8});
    });

    test("a removal on one device reaches the other, the other's later add wins", () async {
      final doc = jsonEncode({
        'schema': 1,
        'block_keywords': {
          'abc': SyncDocument.tombstone(at - 100),
          'def': SyncDocument.tombstone(at - 100),
        },
      });
      api = _FakeApi(doc);
      store.filtersByUid[_uid] = ThreadFilters(
        keywordRecords: [
          BlockedKeyword(text: 'abc', updated: at - 200),
          BlockedKeyword(text: 'def', updated: at - 50),
        ],
      );
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(store.filtersByUid[_uid]!.keywordKeys, ['def']);
      expect(api.lastPushed['block_keywords'], {
        'abc': SyncDocument.tombstone(at - 100),
        'def': {'updated': at - 50, 'text': 'def'},
      });
    });

    test('removals older than kept are dropped from the document', () async {
      api = _FakeApi();
      store.filtersByUid[_uid] = ThreadFilters(
        keywordRecords: [
          BlockedKeyword(text: 'old', updated: at - const Duration(days: 181).inMilliseconds, deleted: true),
          BlockedKeyword(text: 'new', updated: at - 1, deleted: true),
        ],
      );
      await repo().pull(_uid);
      expect((api.lastPushed['block_keywords'] as Map).keys, ['new']);
    });

    test('a pull with nothing new writes nothing, here or to the forum', () async {
      api = _FakeApi();
      store.filtersByUid[_uid] = _filters(keywords: ['abc'], forums: {8: 'Board'});
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      store.writes.clear();
      final pushes = api.pushes.length;
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(api.pushes, hasLength(pushes));
      expect(store.writes, isEmpty);
    });
  });

  test('the account rows the storage keeps are named apart from the user block list', () {
    expect(UserBlockRepository.keywordKeyOf(1).startsWith(UserBlockRepository.keyPrefix), isFalse);
    expect(UserBlockRepository.forumKeyOf(1).startsWith(UserBlockRepository.keyPrefix), isFalse);
  });
}
