import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_source.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What a batch does with the threads it is given.
enum OfflineBatchMode {
  /// Save the threads that have no copy, leave the others alone.
  download,

  /// Load the threads that have a copy again, those with no new reply excepted.
  update,
}

/// How far a batch is.
enum OfflineBatchStatus {
  /// The threads to work on are being listed.
  collecting,

  /// Threads are being loaded.
  running,

  /// Every thread was dealt with.
  done,

  /// Stopped on the user's request.
  canceled,

  /// Stopped because the account changed or the setting was turned off.
  aborted,
}

/// A thread the batch is given.
typedef OfflineBatchJob = ({int tid, String title});

/// The threads a batch works on, and why the list is short of some when it is (`failure`).
typedef OfflineBatchList = ({List<OfflineBatchJob> jobs, String? failure});

/// A thread the batch could not load.
typedef OfflineBatchFailure = ({int tid, String title, String reason});

/// State of an [OfflineBatchCubit].
@immutable
final class OfflineBatchState {
  /// Constructor.
  const OfflineBatchState({
    required this.mode,
    this.status = OfflineBatchStatus.collecting,
    this.total = 0,
    this.processed = 0,
    this.saved = 0,
    this.skipped = 0,
    this.overLimit = 0,
    this.failures = const [],
    this.current,
  });

  /// What the batch does.
  final OfflineBatchMode mode;

  /// How far the batch is.
  final OfflineBatchStatus status;

  /// Threads to deal with.
  final int total;

  /// Threads dealt with: saved, skipped or failed.
  final int processed;

  /// Threads loaded (a new copy, or a copy brought up to date).
  final int saved;

  /// Threads left alone: they have a copy already (download) or nothing new (update).
  final int skipped;

  /// Threads left alone because the offline copies kept are at their limit: saving them would push others out.
  final int overLimit;

  /// Threads that could not be loaded.
  final List<OfflineBatchFailure> failures;

  /// Title of the thread being loaded.
  final String? current;

  /// Whether the batch has stopped, for whatever reason.
  bool get finished =>
      status == OfflineBatchStatus.done ||
      status == OfflineBatchStatus.canceled ||
      status == OfflineBatchStatus.aborted;

  /// Copy with fields replaced; [current] is cleared unless given.
  OfflineBatchState copyWith({
    OfflineBatchStatus? status,
    int? total,
    int? processed,
    int? saved,
    int? skipped,
    int? overLimit,
    List<OfflineBatchFailure>? failures,
    String? current,
  }) => OfflineBatchState(
    mode: mode,
    status: status ?? this.status,
    total: total ?? this.total,
    processed: processed ?? this.processed,
    saved: saved ?? this.saved,
    skipped: skipped ?? this.skipped,
    overLimit: overLimit ?? this.overLimit,
    failures: failures ?? this.failures,
    current: current,
  );
}

/// Saves the threads of the favorites ([OfflineBatchMode.download]) or brings the copies up to date
/// ([OfflineBatchMode.update]), one thread at a time with a pause before every request after the first, so the forum
/// is never asked in a burst. Loading a page marks it used again, so a thread updated moves ahead of those left alone
/// in the order copies are evicted in. A thread that fails is skipped and reported at the end; cancel stops after the request
/// in flight.
final class OfflineBatchCubit extends Cubit<OfflineBatchState> with LoggerMixin {
  /// Constructor.
  OfflineBatchCubit({
    required OfflineBatchMode mode,
    required OfflineBatchSource source,
    this.requestGap = const Duration(milliseconds: 1500),
    Future<void> Function(Duration)? wait,
  }) : _source = source,
       _wait = wait ?? Future<void>.delayed,
       super(OfflineBatchState(mode: mode));

  final OfflineBatchSource _source;
  final Future<void> Function(Duration) _wait;

  /// Pause before every request but the first of the batch.
  final Duration requestGap;

  bool _canceled = false;
  bool _started = false;
  bool _requested = false;

  /// Stop after the request in flight.
  void cancel() {
    _canceled = true;
  }

  // Closed with its dialog (a page left by the navigation, say): nothing is left to report to, so nothing more is loaded.
  @override
  Future<void> close() {
    _canceled = true;
    return super.close();
  }

  /// Run the batch over the threads [jobs] lists (once, whatever is listed). [jobs] is given `next`, to call before
  /// every request it makes to the forum: it pauses as the batch does and answers false once the batch is canceled.
  /// The list it returns names the reason when it is short of threads (a page of the favorites failed).
  Future<void> start(Future<OfflineBatchList> Function(Future<bool> Function() next) jobs) async {
    if (_started) {
      return;
    }
    _started = true;
    final OfflineBatchList list;
    try {
      list = await jobs(_next);
    } on Object catch (e, st) {
      handleRaw(e, st);
      _emit(state.copyWith(status: OfflineBatchStatus.aborted));
      return;
    }
    final failures = <OfflineBatchFailure>[
      if (list.failure != null) (tid: 0, title: '', reason: list.failure!),
    ];
    if (_canceled) {
      _emit(state.copyWith(status: OfflineBatchStatus.canceled, failures: failures));
      return;
    }
    // A thread more than once makes one request.
    final seen = <int>{};
    final unique = [
      for (final job in list.jobs)
        if (seen.add(job.tid)) job,
    ];
    _emit(state.copyWith(status: OfflineBatchStatus.running, total: unique.length, failures: failures));
    // Threads that get a first copy fit up to the limit less the threads kept: past that each would push an older copy
    // out, maybe one of the favorites the batch has just found saved.
    var room = state.mode == OfflineBatchMode.download ? _source.limit - await _source.copyCount() : 0;
    var saved = 0;
    var skipped = 0;
    var overLimit = 0;
    var processed = 0;
    OfflineBatchState progress(OfflineBatchStatus status, {String? current}) => state.copyWith(
      status: status,
      processed: processed,
      saved: saved,
      skipped: skipped,
      overLimit: overLimit,
      failures: List.of(failures),
      current: current,
    );
    for (final job in unique) {
      if (_canceled) {
        _emit(progress(OfflineBatchStatus.canceled));
        return;
      }
      _emit(progress(OfflineBatchStatus.running, current: job.title));
      try {
        switch (await _work(job, canAdd: () => room > 0)) {
          case _Outcome.saved:
            saved += 1;
          case _Outcome.addedFirst:
            saved += 1;
            room -= 1;
          case _Outcome.skipped:
            skipped += 1;
          case _Outcome.overLimit:
            overLimit += 1;
        }
      } on OfflineBatchAborted {
        _emit(progress(OfflineBatchStatus.aborted));
        return;
      } on _Canceled {
        _emit(progress(OfflineBatchStatus.canceled));
        return;
      } on OfflineFetchFailure catch (e) {
        failures.add((tid: job.tid, title: job.title, reason: e.reason));
      } on Object catch (e, st) {
        handleRaw(e, st);
        failures.add((tid: job.tid, title: job.title, reason: '$e'));
      }
      processed += 1;
    }
    _emit(progress(OfflineBatchStatus.done));
  }

  void _emit(OfflineBatchState next) {
    if (!isClosed) {
      emit(next);
    }
  }

  /// The pause before a request, false when the batch was canceled meanwhile.
  Future<bool> _next() async {
    if (_requested) {
      await _wait(requestGap);
    }
    _requested = true;
    return !_canceled;
  }

  /// One request, after the pause that follows the first one.
  Future<OfflineThreadFacts> _request(int tid, int page) async {
    if (!await _next()) {
      throw const _Canceled();
    }
    return _source.fetch(tid, page);
  }

  int _lastPageOf(OfflineThreadFacts facts) =>
      facts.totalPages < _source.pagesPerThread ? facts.totalPages : _source.pagesPerThread;

  Future<_Outcome> _work(OfflineBatchJob job, {required bool Function() canAdd}) async {
    final copy = await _source.copyOf(job.tid);
    // The pages of the default request the copy has; none for a thread kept for another request only.
    final kept = copy?.pages ?? const <int>[];
    switch (state.mode) {
      case OfflineBatchMode.download:
        // Whole when it has every page up to the last one it knew (or the most that are kept): a copy cut short by a
        // failure or a cancel, or made of the pages the user happened to open, is completed.
        if (copy != null && kept.isNotEmpty) {
          final last = _lastPageOf(copy.facts);
          if (copy.facts.totalPages > 0 && [for (var page = 1; page <= last; page += 1) page].every(kept.contains)) {
            return _Outcome.skipped;
          }
        }
        final first = copy == null;
        if (first && !canAdd()) {
          return _Outcome.overLimit;
        }
        final page1 = await _request(job.tid, 1);
        for (var page = 2; page <= _lastPageOf(page1); page += 1) {
          if (!kept.contains(page)) {
            await _request(job.tid, page);
          }
        }
        return first ? _Outcome.addedFirst : _Outcome.saved;
      case OfflineBatchMode.update:
        // A thread kept for another request only (the author's floors, a reverse order) is not what is updated.
        if (copy == null || kept.isEmpty) {
          return _Outcome.skipped;
        }
        final page1 = await _request(job.tid, 1);
        final before = copy.facts;
        // Nothing new when the replies and the pages are the same as when the oldest page of the copy was loaded;
        // without a count on either side there is nothing to compare, so the thread is loaded again.
        final changed =
            before.replyCount == null || before.replyCount != page1.replyCount || before.totalPages != page1.totalPages;
        final cap = _lastPageOf(page1);
        final pages = <int>{
          // Missing from the copy: it was cut short, or made of the pages the user opened.
          for (var page = 2; page <= cap; page += 1)
            if (!kept.contains(page)) page,
          if (changed) ...[
            ...kept,
            // New replies land on the page that was the last one and on the pages after it.
            for (var page = before.totalPages < 1 ? 1 : before.totalPages; page <= cap; page += 1) page,
          ],
        }..removeWhere((page) => page <= 1 || page > cap);
        for (final page in pages.toList()..sort()) {
          await _request(job.tid, page);
        }
        // Replies deleted: pages past the last one no longer exist. Only when the replies are fewer for certain: an
        // answer that does not tell its pages reads as one page, which must not delete the others.
        final fewer = before.replyCount != null && page1.replyCount != null && page1.replyCount! < before.replyCount!;
        final gone = fewer && kept.any((page) => page > page1.totalPages);
        if (gone) {
          await _source.dropPagesAfter(job.tid, page1.totalPages);
        }
        // Page one is loaded and kept in any case; it counts as an update only when something changed.
        return changed || pages.isNotEmpty || gone ? _Outcome.saved : _Outcome.skipped;
    }
  }
}

enum _Outcome { saved, addedFirst, skipped, overLimit }

final class _Canceled implements Exception {
  const _Canceled();
}
