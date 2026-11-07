/// Offline batch: save the threads of the favorites for reading without network, and bring the offline copies up to
/// date, one thread at a time.
///
/// The batch runs over a fake source (no forum, no database): it works through the threads with a pause before every
/// request but the first, skips what has a copy already (download) or has nothing new (update: the replies and the
/// pages of the first page against those the copy was made with), reports a thread that fails at the end and goes on
/// with the next, can be canceled between two requests, never keeps more new threads than the offline repository keeps
/// and stops when the account changes. The list of the copies is read from the real database, bodies untouched.
library;

import 'dart:io';

import 'package:drift/native.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_cubit.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_source.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A forum with the threads in `forum`, and the copies kept.
final class _FakeSource implements OfflineBatchSource {
  _FakeSource({this.limit = 50});

  @override
  final int limit;

  @override
  int get pagesPerThread => 20;

  /// Threads of the fake forum: tid -> (replies, pages).
  final Map<int, ({int replies, int pages})> forum = {};

  /// Copies kept: tid -> facts and pages.
  final Map<int, OfflineCopyFacts> copies = {};

  /// Threads whose requests fail, with the reason.
  final Map<int, String> failing = {};

  /// Every request made, in order.
  final List<(int, int)> requests = [];

  /// Called before every request.
  void Function(int tid, int page)? onFetch;

  /// Thrown instead of an answer when set.
  Exception? abortWith;

  @override
  Future<OfflineCopyFacts?> copyOf(int tid) async => copies[tid];

  @override
  Future<OfflineThreadFacts> fetch(int tid, int page) async {
    onFetch?.call(tid, page);
    if (abortWith != null) {
      throw abortWith!;
    }
    requests.add((tid, page));
    final reason = failing[tid];
    if (reason != null) {
      throw OfflineFetchFailure(reason);
    }
    final thread = forum[tid]!;
    final facts = (title: 't$tid', replyCount: thread.replies, totalPages: thread.pages);
    final pages = {...?copies[tid]?.pages, page}.toList()..sort();
    copies[tid] = (facts: copies[tid]?.facts ?? facts, pages: pages);
    return facts;
  }
}

OfflineBatchJob _job(int tid) => (tid: tid, title: 't$tid');

({OfflineBatchCubit cubit, List<Duration> waits}) _cubit(_FakeSource source, OfflineBatchMode mode) {
  final waits = <Duration>[];
  final cubit = OfflineBatchCubit(
    mode: mode,
    source: source,
    requestGap: const Duration(seconds: 2),
    wait: (d) async => waits.add(d),
  );
  return (cubit: cubit, waits: waits);
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('download', () {
    test('saves every page of the threads without copy, with a pause before every request but the first', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 5, pages: 2)
        ..forum[2] = (replies: 1, pages: 1);
      final run = _cubit(source, OfflineBatchMode.download);
      final states = <OfflineBatchState>[];
      run.cubit.stream.listen(states.add);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(source.requests, [(1, 1), (1, 2), (2, 1)]);
      expect(run.waits, [const Duration(seconds: 2), const Duration(seconds: 2)]);
      expect(run.cubit.state.status, OfflineBatchStatus.done);
      expect((run.cubit.state.total, run.cubit.state.processed, run.cubit.state.saved), (2, 2, 2));
      await Future<void>.delayed(Duration.zero);
      // The progress went through every count, the current title with it.
      expect(states.map((s) => s.processed).toSet(), containsAll(<int>[0, 1, 2]));
      expect(states.any((s) => s.current == 't2' && s.processed == 1), isTrue);
    });

    test('skips the threads that have a copy', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 5, pages: 1)
        ..forum[2] = (replies: 1, pages: 1)
        ..copies[1] = (facts: (title: 't1', replyCount: 5, totalPages: 1), pages: [1]);
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(source.requests, [(2, 1)]);
      expect((run.cubit.state.saved, run.cubit.state.skipped), (1, 1));
    });

    test('a thread listed twice is loaded once; pages past what is kept are not loaded', () async {
      final source = _FakeSource()..forum[1] = (replies: 900, pages: 45);
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async => [_job(1), _job(1)]);

      expect(run.cubit.state.total, 1);
      expect(source.requests.length, 20);
      expect(source.requests.last, (1, 20));
    });

    test('a thread that fails is skipped and reported, the others are saved', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 1, pages: 1)
        ..forum[2] = (replies: 1, pages: 3)
        ..forum[3] = (replies: 1, pages: 1)
        ..failing[2] = 'refused';
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async => [_job(1), _job(2), _job(3)]);

      final state = run.cubit.state;
      expect(state.status, OfflineBatchStatus.done);
      expect((state.saved, state.processed), (2, 3));
      expect(state.failures, [(tid: 2, title: 't2', reason: 'refused')]);
      // The failed thread was asked once, not page after page.
      expect(source.requests.where((r) => r.$1 == 2).length, 1);
      expect(source.requests.last, (3, 1));
    });

    test('a failure in the middle of a thread leaves the next thread to the batch', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 1, pages: 3)
        ..forum[2] = (replies: 1, pages: 1);
      source.onFetch = (tid, page) {
        if (tid == 1 && page == 2) {
          source.failing[1] = 'offline';
        }
      };
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(run.cubit.state.failures.map((f) => f.tid), [1]);
      expect(run.cubit.state.saved, 1);
      expect(source.requests.last, (2, 1));
    });

    test('keeps no more new threads than the repository keeps', () async {
      final source = _FakeSource(limit: 2)
        ..forum[1] = (replies: 1, pages: 1)
        ..forum[2] = (replies: 1, pages: 1)
        ..forum[3] = (replies: 1, pages: 1);
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async => [_job(1), _job(2), _job(3)]);

      expect(source.requests, [(1, 1), (2, 1)]);
      expect((run.cubit.state.saved, run.cubit.state.skipped), (2, 1));
    });

    test('cancel stops after the request in flight; nothing is asked after it', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 1, pages: 3)
        ..forum[2] = (replies: 1, pages: 1);
      final run = _cubit(source, OfflineBatchMode.download);
      source.onFetch = (tid, page) {
        if (tid == 1 && page == 2) {
          run.cubit.cancel();
        }
      };

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(run.cubit.state.status, OfflineBatchStatus.canceled);
      expect(source.requests, [(1, 1), (1, 2)]);
      expect(run.cubit.state.saved, 0);
    });

    test('cancel while the threads are being listed starts nothing', () async {
      final source = _FakeSource()..forum[1] = (replies: 1, pages: 1);
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async {
        run.cubit.cancel();
        return [_job(1)];
      });

      expect(run.cubit.state.status, OfflineBatchStatus.canceled);
      expect(source.requests, isEmpty);
    });

    test('the account changing stops the batch', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 1, pages: 1)
        ..forum[2] = (replies: 1, pages: 1)
        ..abortWith = const OfflineBatchAborted();
      final run = _cubit(source, OfflineBatchMode.download);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(run.cubit.state.status, OfflineBatchStatus.aborted);
      expect(run.cubit.state.failures, isEmpty);
    });

    test('a list that can not be made ends the batch', () async {
      final run = _cubit(_FakeSource(), OfflineBatchMode.download);

      await run.cubit.start(() async => throw StateError('no list'));

      expect(run.cubit.state.status, OfflineBatchStatus.aborted);
    });
  });

  group('update', () {
    OfflineCopyFacts copy(int replies, int pages, List<int> kept) =>
        (facts: (title: 't', replyCount: replies, totalPages: pages), pages: kept);

    test('a thread with no new reply costs one request, a thread with new replies is brought up to date', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 5, pages: 2)
        ..forum[2] = (replies: 40, pages: 3)
        ..copies[1] = copy(5, 2, [1, 2])
        ..copies[2] = copy(25, 2, [1, 2]);
      final run = _cubit(source, OfflineBatchMode.update);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      // Thread 1: the first page only. Thread 2: the first page, the page that was the last one and the new one.
      expect(source.requests, [(1, 1), (2, 1), (2, 2), (2, 3)]);
      expect((run.cubit.state.saved, run.cubit.state.skipped), (1, 1));
    });

    test('loads the pages that are kept too, however far they are', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 90, pages: 6)
        ..copies[1] = copy(60, 4, [1, 3, 4]);
      final run = _cubit(source, OfflineBatchMode.update);

      await run.cubit.start(() async => [_job(1)]);

      expect(source.requests.map((r) => r.$2), [1, 3, 4, 5, 6]);
    });

    test('more pages and the same replies is a change; a copy with no count is loaded again', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 5, pages: 2)
        ..forum[2] = (replies: 5, pages: 1)
        ..copies[1] = copy(5, 1, [1])
        ..copies[2] = (facts: (title: 't', replyCount: null, totalPages: 1), pages: [1]);
      final run = _cubit(source, OfflineBatchMode.update);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(source.requests, [(1, 1), (1, 2), (2, 1)]);
      expect(run.cubit.state.saved, 2);
    });

    test('a thread whose copy is gone is left alone', () async {
      final source = _FakeSource()..forum[1] = (replies: 5, pages: 1);
      final run = _cubit(source, OfflineBatchMode.update);

      await run.cubit.start(() async => [_job(1)]);

      expect(source.requests, isEmpty);
      expect(run.cubit.state.skipped, 1);
    });

    test('a thread deleted from the forum is reported, the others are updated', () async {
      final source = _FakeSource()
        ..forum[1] = (replies: 9, pages: 1)
        ..forum[2] = (replies: 9, pages: 1)
        ..copies[1] = copy(1, 1, [1])
        ..copies[2] = copy(1, 1, [1])
        ..failing[1] = 'gone';
      final run = _cubit(source, OfflineBatchMode.update);

      await run.cubit.start(() async => [_job(1), _job(2)]);

      expect(run.cubit.state.failures.map((f) => f.tid), [1]);
      expect(run.cubit.state.saved, 1);
    });
  });

  test('starts once', () async {
    final run = _cubit(_FakeSource()..forum[1] = (replies: 1, pages: 1), OfflineBatchMode.download);

    await run.cubit.start(() async => [_job(1)]);
    await run.cubit.start(() async => [_job(1), _job(2)]);

    expect(run.cubit.state.total, 1);
  });

  group('copies of the database', () {
    late AppDatabase db;
    late StorageProvider storage;
    late OfflineThreadRepository offline;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      await storage.saveCookie(username: 'a', uid: 35, cookie: {'Ystv_2132_auth': 'x'});
      await storage.saveCookie(username: 'b', uid: 36, cookie: {'Ystv_2132_auth': 'y'});
      offline = OfflineThreadRepository(storage: storage, currentUid: () => 35);
    });

    tearDown(() async => db.close());

    Future<void> save(int uid, int tid, int page, {int orderType = 0, int authorId = 0, DateTime? at, String? body}) =>
        storage.saveOfflineThreadPage(
          uid: uid,
          tid: tid,
          page: page,
          orderType: orderType,
          authorId: authorId,
          body: body ?? 'body of $tid/$page',
          savedAt: at ?? DateTime.fromMillisecondsSinceEpoch(1700000000000 + tid * 1000),
        );

    test(
      'one row per thread of the account, the pages of the default request apart, most recently used first',
      () async {
        await save(35, 1, 1);
        await save(35, 1, 3);
        await save(35, 1, 2, orderType: 1);
        await save(35, 2, 1);
        await save(36, 3, 1);

        final copies = await offline.copies(35);

        expect(copies.map((c) => c.tid), [2, 1]);
        final first = copies.last;
        expect(first.pageCount, 3);
        expect(first.defaultPages, [1, 3]);
        expect(first.size, 'body of 1/1'.length + 'body of 1/3'.length + 'body of 1/2'.length);
        expect(await offline.copies(36), hasLength(1));
        expect(await offline.copies(37), isEmpty);
      },
    );

    test('peeking does not mark the page used', () async {
      await save(35, 1, 1, body: 'one');
      await save(35, 2, 1, body: 'two');
      final before = (await offline.copies(35)).map((c) => c.tid).toList();

      final page = await offline.peek(const OfflineThreadKey(uid: 35, tid: 1, page: 1, orderType: 0, authorId: 0));

      expect(page?.body, 'one');
      expect((await offline.copies(35)).map((c) => c.tid).toList(), before);
    });

    test('the facts of a copy are read from a saved page without marking it used', () async {
      final source = AppOfflineBatchSource(uid: 35, offline: offline);
      expect(await source.copyOf(1), isNull);
      await save(35, 1, 2, body: File('test/data/tsdmapp/thread_v3_plain.json').readAsStringSync());
      await save(35, 2, 1, body: 'not a thread page');

      final copy = (await source.copyOf(1))!;
      final unreadable = (await source.copyOf(2))!;

      expect(copy.pages, [2]);
      expect(copy.facts.replyCount, 8);
      expect(copy.facts.totalPages, 1);
      expect(copy.facts.title, contains('FID2'));
      // A page that can not be read leaves no facts: the update loads the thread again.
      expect(unreadable.facts.replyCount, isNull);
      expect((await offline.copies(35)).map((c) => c.tid), [2, 1]);
    });

    test('removing a copy deletes its pages of that account only', () async {
      await save(35, 1, 1);
      await save(36, 1, 1);

      await offline.remove(uid: 35, tid: 1);

      expect(await offline.copies(35), isEmpty);
      expect(await offline.copies(36), hasLength(1));
    });
  });
}
