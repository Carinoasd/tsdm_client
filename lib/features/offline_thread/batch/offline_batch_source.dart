import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What is known of a thread: title, replies and pages.
typedef OfflineThreadFacts = ({String? title, int? replyCount, int totalPages});

/// What the copy of a thread kept now says: the facts of the page it was read from and the pages of the default request
/// that are saved.
typedef OfflineCopyFacts = ({OfflineThreadFacts facts, List<int> pages});

/// A request of the batch failed: the forum could not be reached, refused the thread, or did not answer a thread page.
final class OfflineFetchFailure implements Exception {
  /// Constructor.
  const OfflineFetchFailure(this.reason);

  /// Short text for the report.
  final String reason;

  @override
  String toString() => 'OfflineFetchFailure($reason)';
}

/// The account in use is not the one the batch started as, or the offline setting was turned off: nothing more is
/// loaded.
final class OfflineBatchAborted implements Exception {
  /// Constructor.
  const OfflineBatchAborted();
}

/// Where the batch gets threads from and what it keeps: the forum through the thread repository, the copies through
/// the offline repository. An interface so the batch is tested without either.
abstract interface class OfflineBatchSource {
  /// How many threads are kept at most.
  int get limit;

  /// How many pages of one thread are kept at most.
  int get pagesPerThread;

  /// How many threads are kept now.
  Future<int> copyCount();

  /// The copy of thread [tid] kept now, null when none. `pages` lists the pages of the default request only: empty
  /// for a thread kept for another request (the author's floors only, say).
  Future<OfflineCopyFacts?> copyOf(int tid);

  /// Delete the pages of thread [tid] after page [page]: the thread has fewer pages now.
  Future<void> dropPagesAfter(int tid, int page);

  /// Load page [page] of thread [tid] (default order, nobody's posts only) from the forum; the thread repository
  /// saves it as the copy. Throws [OfflineFetchFailure] or [OfflineBatchAborted].
  Future<OfflineThreadFacts> fetch(int tid, int page);
}

/// [OfflineBatchSource] of the app.
final class AppOfflineBatchSource with LoggerMixin implements OfflineBatchSource {
  /// Constructor.
  ///
  /// [uid] is the account the batch runs as: once another one is in use nothing more is loaded.
  AppOfflineBatchSource({required this.uid, OfflineThreadRepository? offline})
    : _offline = offline ?? appOfflineThreads,
      _threads = ThreadRepository(offline: offline ?? appOfflineThreads);

  /// The account the batch runs as.
  final int uid;

  final OfflineThreadRepository _offline;
  final ThreadRepository _threads;

  @override
  int get limit => _offline.limit;

  @override
  int get pagesPerThread => OfflineThreadRepository.pagesPerThread;

  void _checkAccount() {
    if (!_offline.enabled || _offline.currentUid() != uid) {
      throw const OfflineBatchAborted();
    }
  }

  /// The threads kept, read once: the batch loads each thread once, and what it saves is not asked about again.
  Map<int, OfflineThreadCopy>? _copies;

  Future<Map<int, OfflineThreadCopy>> _loadCopies() async =>
      _copies ??= {for (final copy in await _offline.copies(uid)) copy.tid: copy};

  @override
  Future<int> copyCount() async => (await _loadCopies()).length;

  @override
  Future<OfflineCopyFacts?> copyOf(int tid) async {
    final copy = (await _loadCopies())[tid];
    if (copy == null) {
      return null;
    }
    final pages = copy.defaultPages;
    final probe = copy.probePage;
    // The page loaded the longest ago tells the replies and pages the copy was made with: a change since shows in it.
    final saved = probe == null
        ? null
        : await _offline.peek(OfflineThreadKey(uid: uid, tid: tid, page: probe, orderType: 0, authorId: 0));
    final facts = saved == null ? null : _threads.summaryOfSaved(saved.body);
    return (facts: facts ?? (title: null, replyCount: null, totalPages: 0), pages: pages);
  }

  @override
  Future<void> dropPagesAfter(int tid, int page) async {
    _checkAccount();
    await _offline.removePagesAfter(uid: uid, tid: tid, page: page);
  }

  @override
  Future<OfflineThreadFacts> fetch(int tid, int page) async {
    _checkAccount();
    final result = await _threads.fetchThreadPage(tid: '$tid', pageNumber: page).run();
    // The save is queued by the thread repository: wait for it, so the next request starts on a settled database.
    await _offline.writesDone;
    _checkAccount();
    switch (result) {
      case Left(:final value):
        handle(value);
        throw OfflineFetchFailure(value.message ?? value.runtimeType.toString());
      case Right(value: final thread):
        // The copy of an earlier visit shown for a forum that could not be reached is no new page.
        if (thread.offlineSavedAt != null) {
          throw const OfflineFetchFailure('offline');
        }
        if (!thread.havePermission || thread.needLogin || thread.postList.isEmpty) {
          throw const OfflineFetchFailure('refused');
        }
        return (title: thread.title, replyCount: thread.replyCount, totalPages: thread.totalPages);
    }
  }
}
