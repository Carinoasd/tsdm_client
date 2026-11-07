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

  /// The copy of thread [tid] kept now, null when none.
  Future<OfflineCopyFacts?> copyOf(int tid);

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

  @override
  Future<OfflineCopyFacts?> copyOf(int tid) async {
    final copies = await _offline.copies(uid);
    final copy = copies.where((e) => e.tid == tid).firstOrNull;
    if (copy == null) {
      return null;
    }
    // Any page tells the replies and pages of the thread as it was when it was loaded; the lowest one is the oldest
    // request-free page the user has.
    final pages = copy.defaultPages;
    final probe = pages.isEmpty ? 1 : pages.first;
    final saved = await _offline.peek(OfflineThreadKey(uid: uid, tid: tid, page: probe, orderType: 0, authorId: 0));
    final facts = saved == null ? null : _threads.summaryOfSaved(saved.body);
    if (facts == null) {
      return (facts: (title: null, replyCount: null, totalPages: 0), pages: pages);
    }
    return (facts: facts, pages: pages);
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
