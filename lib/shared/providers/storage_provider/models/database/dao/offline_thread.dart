part of 'dao.dart';

/// One thread kept for an account: how many pages of every request, their size, when the newest was loaded and which
/// pages of the default request are there.
///
/// `probePage` is the page of the default request that was loaded the longest ago (the highest page of those), null
/// when there is none: what it tells about the thread (replies, pages) is the oldest, so any change since shows.
typedef OfflineThreadCopyRow = ({
  int tid,
  int pageCount,
  int size,
  DateTime savedAt,
  List<int> defaultPages,
  int? probePage,
});

/// DAO for table [OfflineThread].
@DriftAccessor(tables: [OfflineThread])
final class OfflineThreadDao extends DatabaseAccessor<AppDatabase> with _$OfflineThreadDaoMixin {
  /// Constructor.
  OfflineThreadDao(super.attachedDatabase);

  Expression<bool> _isKey(
    $OfflineThreadTable e, {
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
  }) =>
      e.uid.equals(uid) &
      e.tid.equals(tid) &
      e.page.equals(page) &
      e.orderType.equals(orderType) &
      e.authorId.equals(authorId);

  /// Insert or replace the page.
  Future<void> upsert(OfflineThreadCompanion companion) async {
    await into(offlineThread).insertOnConflictUpdate(companion);
  }

  /// Insert or replace the page, only while the account `uid` is stored on this device (a row in the cookie table).
  ///
  /// One statement, so the write lock is taken once and the busy timeout of the connection covers it: a check followed
  /// by a write in a deferred transaction would fail at once while another connection (the Android background service)
  /// holds the lock, the upgrade from the read lock not being retried. Returns whether the page was written.
  Future<bool> upsertForStoredAccount({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
    required int size,
    required DateTime savedAt,
    required int lastUsedAt,
    required String body,
  }) async {
    // The upsert clause of an INSERT … SELECT needs the WHERE of the SELECT (sqlite's parsing rule), which it has.
    final written = await customUpdate(
      'INSERT INTO offline_thread (uid, tid, page, order_type, author_id, size, saved_at, last_used_at, body) '
      'SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9 WHERE EXISTS (SELECT 1 FROM cookie WHERE uid = ?1) '
      'ON CONFLICT (uid, tid, page, order_type, author_id) DO UPDATE SET '
      'size = excluded.size, saved_at = excluded.saved_at, last_used_at = excluded.last_used_at, body = excluded.body',
      variables: [
        Variable.withInt(uid),
        Variable.withInt(tid),
        Variable.withInt(page),
        Variable.withInt(orderType),
        Variable.withInt(authorId),
        Variable.withInt(size),
        Variable<DateTime>(savedAt),
        Variable.withInt(lastUsedAt),
        Variable.withString(body),
      ],
      updates: {offlineThread},
      updateKind: UpdateKind.insert,
    );
    return written > 0;
  }

  /// The saved page of the key, null when none.
  Future<OfflineThreadEntity?> selectPage({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
  }) async =>
      (select(offlineThread)..where(
            (e) => _isKey(e, uid: uid, tid: tid, page: page, orderType: orderType, authorId: authorId),
          ))
          .getSingleOrNull();

  /// The saved page of the thread with the highest page number for the rest of the key (account, thread, order,
  /// author), null when none: the last page saved of a thread asked past its last page.
  Future<OfflineThreadEntity?> selectLastPage({
    required int uid,
    required int tid,
    required int orderType,
    required int authorId,
  }) async =>
      (select(offlineThread)
            ..where(
              (e) =>
                  e.uid.equals(uid) & e.tid.equals(tid) & e.orderType.equals(orderType) & e.authorId.equals(authorId),
            )
            ..orderBy([(e) => OrderingTerm.desc(e.page)])
            ..limit(1))
          .getSingleOrNull();

  /// One row per thread kept for user [uid] (most recently used first), read from the index alone: no body is touched.
  Future<List<OfflineThreadCopyRow>> selectCopies(int uid) async {
    final lastUsed = offlineThread.lastUsedAt.max();
    final savedAt = offlineThread.savedAt.max();
    final pages = offlineThread.page.count();
    final size = offlineThread.size.sum();
    final rows =
        await (selectOnly(offlineThread)
              ..addColumns([offlineThread.tid, pages, size, savedAt, lastUsed])
              ..where(offlineThread.uid.equals(uid))
              ..groupBy([offlineThread.tid])
              ..orderBy([OrderingTerm.desc(lastUsed), OrderingTerm.desc(offlineThread.tid)]))
            .get();
    // The pages of the default request (no order, no author filter), which the batch updates keep up to date.
    final defaults =
        await (selectOnly(offlineThread)
              ..addColumns([offlineThread.tid, offlineThread.page, offlineThread.savedAt])
              ..where(
                offlineThread.uid.equals(uid) & offlineThread.orderType.equals(0) & offlineThread.authorId.equals(0),
              )
              ..orderBy([OrderingTerm.asc(offlineThread.page)]))
            .get();
    final defaultPages = <int, List<int>>{};
    final probes = <int, ({int page, DateTime savedAt})>{};
    for (final row in defaults) {
      final tid = row.read<int>(offlineThread.tid)!;
      final page = row.read<int>(offlineThread.page)!;
      final at = row.read<DateTime>(offlineThread.savedAt)!;
      (defaultPages[tid] ??= <int>[]).add(page);
      // Pages come in ascending order: a tie goes to the later (higher) page.
      final probe = probes[tid];
      if (probe == null || !at.isAfter(probe.savedAt)) {
        probes[tid] = (page: page, savedAt: at);
      }
    }
    return [
      for (final row in rows)
        (
          tid: row.read<int>(offlineThread.tid)!,
          pageCount: row.read(pages) ?? 0,
          size: row.read(size) ?? 0,
          savedAt: row.read(savedAt) ?? DateTime.fromMillisecondsSinceEpoch(0),
          defaultPages: defaultPages[row.read<int>(offlineThread.tid)!] ?? const <int>[],
          probePage: probes[row.read<int>(offlineThread.tid)!]?.page,
        ),
    ];
  }

  /// Mark the page of the key used at [time].
  Future<void> touch({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
    required DateTime time,
  }) async {
    await (update(offlineThread)..where(
          (e) => _isKey(e, uid: uid, tid: tid, page: page, orderType: orderType, authorId: authorId),
        ))
        .write(OfflineThreadCompanion(lastUsedAt: Value(time.millisecondsSinceEpoch)));
  }

  /// Every saved page with its body, for `StorageProvider.fetchAllOfflineThreadPages` (tests only): the app never
  /// reads every body at once.
  Future<List<OfflineThreadEntity>> selectAll() async => select(offlineThread).get();

  /// Up to [limit] bodies of saved pages after the row [afterRowId] in row order, with their row ids: for the clean up
  /// of the image cache, which keeps the pictures of the saved pages. Read a few at a time, never every body at once.
  Future<List<({int rowId, String body})>> selectBodiesAfter(int afterRowId, int limit) async {
    final rows = await customSelect(
      'SELECT rowid AS r, body FROM offline_thread WHERE rowid > ?1 ORDER BY rowid LIMIT ?2',
      variables: [Variable.withInt(afterRowId), Variable.withInt(limit)],
      readsFrom: {offlineThread},
    ).get();
    return rows.map((r) => (rowId: r.read<int>('r'), body: r.read<String>('body'))).toList();
  }

  /// Delete every saved page of thread [tid] for user [uid].
  Future<int> deleteThread({required int uid, required int tid}) async =>
      (delete(offlineThread)..where((e) => e.uid.equals(uid) & e.tid.equals(tid))).go();

  /// How many threads are kept, of every account together (one thread being one account and one tid): the number the
  /// limit of [keepRecentThreads] counts.
  Future<int> countThreads() async {
    final rows = await customSelect(
      'SELECT COUNT(*) AS n FROM (SELECT 1 FROM offline_thread GROUP BY uid, tid)',
      readsFrom: {offlineThread},
    ).getSingle();
    return rows.read<int>('n');
  }

  /// Delete the pages of the default request (no order, no author filter) of thread [tid] for user [uid] after page
  /// [page]: the thread has fewer pages than it had. Returns the number of pages deleted.
  Future<int> deletePagesAfter({required int uid, required int tid, required int page}) async =>
      (delete(offlineThread)..where(
            (e) =>
                e.uid.equals(uid) &
                e.tid.equals(tid) &
                e.orderType.equals(0) &
                e.authorId.equals(0) &
                e.page.isBiggerThanValue(page),
          ))
          .go();

  /// Delete every saved page of user [uid].
  Future<int> deleteByUid(int uid) async => (delete(offlineThread)..where((e) => e.uid.equals(uid))).go();

  /// Delete all saved pages.
  Future<int> deleteAll() async => delete(offlineThread).go();

  /// Total size of the saved bodies in bytes, read from the index ([OfflineThread] keeps `size` in it), not the rows.
  Future<int> totalSize() async {
    final sum = offlineThread.size.sum();
    final row = await (selectOnly(offlineThread)..addColumns([sum])).getSingle();
    return row.read(sum) ?? 0;
  }

  /// Whether no page is saved.
  Future<bool> isEmpty() async {
    final row =
        await (selectOnly(offlineThread)
              ..addColumns([offlineThread.uid])
              ..limit(1))
            .getSingleOrNull();
    return row == null;
  }

  /// Keep the [limit] most recently used pages of thread [tid] for user [uid] (any page, order and author filter);
  /// delete the others. Returns the number of pages deleted.
  Future<int> keepRecentPages({required int uid, required int tid, required int limit}) async {
    if (limit < 0) {
      return 0;
    }
    return customUpdate(
      'DELETE FROM offline_thread WHERE uid = ?1 AND tid = ?2 AND rowid NOT IN ( '
      'SELECT rowid FROM offline_thread WHERE uid = ?1 AND tid = ?2 '
      'ORDER BY last_used_at DESC, page, order_type, author_id LIMIT ?3 '
      ')',
      variables: [Variable.withInt(uid), Variable.withInt(tid), Variable.withInt(limit)],
      updates: {offlineThread},
      updateKind: UpdateKind.delete,
    );
  }

  /// Keep the [limit] most recently used threads (one thread being one account and one tid, whatever its pages);
  /// delete the pages of the others. Returns the number of pages deleted.
  ///
  /// The threads are ranked from the index alone; only the pages deleted are touched.
  Future<int> keepRecentThreads(int limit) async {
    if (limit < 0) {
      return 0;
    }
    return customUpdate(
      'DELETE FROM offline_thread WHERE (uid, tid) NOT IN ( '
      'SELECT uid, tid FROM offline_thread GROUP BY uid, tid '
      'ORDER BY MAX(last_used_at) DESC, uid, tid LIMIT ? '
      ')',
      variables: [Variable.withInt(limit)],
      updates: {offlineThread},
      updateKind: UpdateKind.delete,
    );
  }
}
