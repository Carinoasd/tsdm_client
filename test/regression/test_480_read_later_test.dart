/// Read later (「稍後閱讀」): a local list of threads per account, apart from the forum's favorites.
///
/// Kept in the `read_later` table (schema 19), one row per account and thread, the latest put aside first; removed
/// with the account. The cubit follows the account in use. A thread is taken off by hand or once read to its last
/// floor, see [hasReadToEnd]. No network, no real account.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/features/read_later/utils/read_to_end.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Storage whose removals fail.
final class _FailingStorage extends StorageProvider {
  _FailingStorage(AppDatabase db) : super(db, {}, {});

  @override
  Future<void> removeReadLater(int uid, int tid) async => throw StateError('disk full');

  @override
  Future<void> clearReadLater(int uid) async => throw StateError('disk full');
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
  });

  tearDown(() async => db.close());

  group('the stored list', () {
    test('the latest put aside comes first, and putting a thread aside again moves it up', () async {
      await storage.addReadLater(uid: 31, tid: 1, title: 'one', time: DateTime(2026));
      await storage.addReadLater(
        uid: 31,
        tid: 2,
        title: 'two',
        author: 'Bob',
        forumName: 'forum',
        time: DateTime(2026, 1, 2),
      );
      expect((await storage.fetchReadLater(31)).map((e) => e.tid), [2, 1]);
      final two = (await storage.fetchReadLater(31)).first;
      expect((two.threadTitle, two.author, two.forumName), ('two', 'Bob', 'forum'));

      await storage.addReadLater(uid: 31, tid: 1, title: 'one again', time: DateTime(2026, 1, 3));
      final rows = await storage.fetchReadLater(31);
      expect(rows.map((e) => e.tid), [1, 2]);
      expect(rows.first.threadTitle, 'one again');
    });

    test('every account has its own list', () async {
      await storage.addReadLater(uid: 31, tid: 1, title: 'one');
      await storage.addReadLater(uid: 32, tid: 1, title: 'one');
      await storage.removeReadLater(31, 1);
      expect(await storage.fetchReadLater(31), isEmpty);
      expect((await storage.fetchReadLater(32)).single.tid, 1);
      await storage.clearReadLater(32);
      expect(await storage.fetchReadLater(32), isEmpty);
    });

    test('clear empties only the list of the account', () async {
      await storage.addReadLater(uid: 31, tid: 1, title: 'one');
      await storage.addReadLater(uid: 31, tid: 2, title: 'two');
      await storage.addReadLater(uid: 32, tid: 3, title: 'three');
      await storage.clearReadLater(31);
      expect(await storage.fetchReadLater(31), isEmpty);
      expect((await storage.fetchReadLater(32)).single.tid, 3);
    });
  });

  group('the cubit', () {
    /// Let the stream of the stored list deliver (a real wait).
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('follows the list of its account', () async {
      await storage.addReadLater(uid: 31, tid: 1, title: 'one', time: DateTime(2000));
      final cubit = ReadLaterCubit(storageProvider: storage, uid: 31);
      addTearDown(cubit.close);
      await settle();
      expect(cubit.state.loaded, isTrue);
      expect(cubit.state.contains(1), isTrue);
      expect(cubit.state.contains(2), isFalse);

      expect(await cubit.add(tid: 2, title: 'two', author: 'Bob', forumName: 'forum'), isTrue);
      await settle();
      expect(cubit.state.items.map((e) => e.tid), [2, 1]);
      expect(cubit.state.items.first.author, 'Bob');

      await cubit.remove(2);
      await settle();
      expect(cubit.state.items.map((e) => e.tid), [1]);

      await cubit.clear();
      await settle();
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.loaded, isTrue);
    });

    test('threads put aside within one second keep the later thread id first', () async {
      final at = DateTime(2026, 5, 5, 10);
      await storage.addReadLater(uid: 31, tid: 3, title: 'three', time: at);
      await storage.addReadLater(uid: 31, tid: 9, title: 'nine', time: at);
      await storage.addReadLater(uid: 31, tid: 5, title: 'five', time: at);
      expect((await storage.fetchReadLater(31)).map((e) => e.tid), [9, 5, 3]);
    });

    test('a removed entry is gone from the state at once', () async {
      await storage.addReadLater(uid: 31, tid: 1, title: 'one');
      final cubit = ReadLaterCubit(storageProvider: storage, uid: 31);
      addTearDown(cubit.close);
      await settle();
      final removal = cubit.remove(1);
      expect(cubit.state.contains(1), isFalse);
      await removal;

      await storage.addReadLater(uid: 31, tid: 2, title: 'two');
      await settle();
      final clearing = cubit.clear();
      expect(cubit.state.items, isEmpty);
      await clearing;
    });

    test('a write that fails puts the list back', () async {
      await storage.addReadLater(uid: 31, tid: 1, title: 'one');
      final failing = _FailingStorage(db);
      final cubit = ReadLaterCubit(storageProvider: failing, uid: 31);
      addTearDown(cubit.close);
      await settle();
      expect(cubit.state.contains(1), isTrue);
      await cubit.remove(1);
      expect(cubit.state.contains(1), isTrue);
      await cubit.clear();
      expect(cubit.state.items.map((e) => e.tid), [1]);
    });

    test('without an account nothing is kept', () async {
      final cubit = ReadLaterCubit(storageProvider: storage);
      addTearDown(cubit.close);
      expect(cubit.state.uid, isNull);
      expect(await cubit.add(tid: 1, title: 'one'), isFalse);
      await cubit.remove(1);
      await cubit.clear();
      expect(await storage.fetchReadLater(31), isEmpty);
    });
  });

  group('read to the end', () {
    bool read({
      bool loaded = true,
      bool offline = false,
      bool onlyOneAuthor = false,
      bool readOnFromStart = true,
      bool newestFirst = false,
      bool canLoadMore = false,
      bool hasFloors = true,
      double extentAfter = 0,
    }) => hasReadToEnd(
      loaded: loaded,
      offline: offline,
      onlyOneAuthor: onlyOneAuthor,
      readOnFromStart: readOnFromStart,
      newestFirst: newestFirst,
      canLoadMore: canLoadMore,
      hasFloors: hasFloors,
      extentAfter: extentAfter,
    );

    test('the last page loaded and the list at its end', () {
      expect(read(), isTrue);
      expect(read(extentAfter: readToEndExtent), isTrue);
      expect(read(extentAfter: readToEndExtent + 1), isFalse);
    });

    test('not before the last page, nor for what is not the whole thread', () {
      expect(read(canLoadMore: true), isFalse);
      expect(read(loaded: false), isFalse);
      expect(read(hasFloors: false), isFalse);
      expect(read(offline: true), isFalse);
      expect(read(onlyOneAuthor: true), isFalse);
      expect(read(newestFirst: true), isFalse);
      // Jumped to the last page: the floors before it were not read.
      expect(read(readOnFromStart: false), isFalse);
    });
  });
}
