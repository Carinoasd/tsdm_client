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

  /// Threads left alone: they have a copy already (download), nothing new (update), or are beyond what is kept.
  final int skipped;

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
    List<OfflineBatchFailure>? failures,
    String? current,
  }) => OfflineBatchState(
    mode: mode,
    status: status ?? this.status,
    total: total ?? this.total,
    processed: processed ?? this.processed,
    saved: saved ?? this.saved,
    skipped: skipped ?? this.skipped,
    failures: failures ?? this.failures,
    current: current,
  );
}

/// Saves the threads of the favorites ([OfflineBatchMode.download]) or brings the copies up to date
/// ([OfflineBatchMode.update]), one thread at a time with a pause before every request after the first, so the forum
/// is never asked in a burst. A thread that fails is skipped and reported at the end; cancel stops after the request
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

  /// Run the batch over the threads [jobs] lists (once, whatever is listed).
  Future<void> start(Future<List<OfflineBatchJob>> Function() jobs) async {
    if (_started) {
      return;
    }
    _started = true;
    final List<OfflineBatchJob> list;
    try {
      list = await jobs();
    } on Object catch (e, st) {
      handleRaw(e, st);
      _emit(state.copyWith(status: OfflineBatchStatus.aborted));
      return;
    }
    if (_canceled) {
      _emit(state.copyWith(status: OfflineBatchStatus.canceled));
      return;
    }
    // A thread more than once makes one request.
    final seen = <int>{};
    final unique = [
      for (final job in list)
        if (seen.add(job.tid)) job,
    ];
    _emit(state.copyWith(status: OfflineBatchStatus.running, total: unique.length));
    // The threads that get a new copy are at most as many as are kept: past that each would push an older one out.
    var room = _source.limit;
    var saved = 0;
    var skipped = 0;
    var processed = 0;
    final failures = <OfflineBatchFailure>[];
    for (final job in unique) {
      if (_canceled) {
        _emit(state.copyWith(status: OfflineBatchStatus.canceled, saved: saved, skipped: skipped, failures: failures));
        return;
      }
      _emit(
        state.copyWith(
          processed: processed,
          saved: saved,
          skipped: skipped,
          failures: List.of(failures),
          current: job.title,
        ),
      );
      try {
        final outcome = await _work(job, canAdd: () => room > 0);
        switch (outcome) {
          case _Outcome.saved:
            saved += 1;
            if (state.mode == OfflineBatchMode.download) {
              room -= 1;
            }
          case _Outcome.skipped:
            skipped += 1;
        }
      } on OfflineBatchAborted {
        _emit(
          state.copyWith(
            status: OfflineBatchStatus.aborted,
            processed: processed,
            saved: saved,
            skipped: skipped,
            failures: failures,
          ),
        );
        return;
      } on _Canceled {
        _emit(
          state.copyWith(
            status: OfflineBatchStatus.canceled,
            processed: processed,
            saved: saved,
            skipped: skipped,
            failures: failures,
          ),
        );
        return;
      } on OfflineFetchFailure catch (e) {
        failures.add((tid: job.tid, title: job.title, reason: e.reason));
      } on Object catch (e, st) {
        handleRaw(e, st);
        failures.add((tid: job.tid, title: job.title, reason: '$e'));
      }
      processed += 1;
    }
    _emit(
      state.copyWith(
        status: OfflineBatchStatus.done,
        processed: processed,
        saved: saved,
        skipped: skipped,
        failures: failures,
      ),
    );
  }

  void _emit(OfflineBatchState next) {
    if (!isClosed) {
      emit(next);
    }
  }

  /// One request, after the pause that follows the first one.
  Future<OfflineThreadFacts> _request(int tid, int page) async {
    if (_requested) {
      await _wait(requestGap);
      if (_canceled) {
        throw const _Canceled();
      }
    }
    _requested = true;
    return _source.fetch(tid, page);
  }

  Future<_Outcome> _work(OfflineBatchJob job, {required bool Function() canAdd}) async {
    final copy = await _source.copyOf(job.tid);
    switch (state.mode) {
      case OfflineBatchMode.download:
        if (copy != null || !canAdd()) {
          return _Outcome.skipped;
        }
        final first = await _request(job.tid, 1);
        final last = first.totalPages < _source.pagesPerThread ? first.totalPages : _source.pagesPerThread;
        for (var page = 2; page <= last; page += 1) {
          await _request(job.tid, page);
        }
        return _Outcome.saved;
      case OfflineBatchMode.update:
        if (copy == null) {
          return _Outcome.skipped;
        }
        final first = await _request(job.tid, 1);
        final before = copy.facts;
        // Nothing new when the replies and the pages are the same as when the copy was made; without a count on either
        // side there is nothing to compare, so the thread is loaded again.
        if (before.replyCount != null &&
            before.replyCount == first.replyCount &&
            before.totalPages == first.totalPages) {
          return _Outcome.skipped;
        }
        // The pages already kept, and from the page that was the last one on: new replies land there and after it.
        final cap = first.totalPages < _source.pagesPerThread ? first.totalPages : _source.pagesPerThread;
        final from = before.totalPages < 1 ? 1 : before.totalPages;
        final pages = <int>{
          ...copy.pages,
          for (var page = from; page <= cap; page += 1) page,
        }..removeWhere((page) => page <= 1 || page > cap);
        for (final page in pages.toList()..sort()) {
          await _request(job.tid, page);
        }
        return _Outcome.saved;
    }
  }
}

enum _Outcome { saved, skipped }

final class _Canceled implements Exception {
  const _Canceled();
}
