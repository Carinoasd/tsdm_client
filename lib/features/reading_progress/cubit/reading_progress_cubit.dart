import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';
import 'package:tsdm_client/features/reading_progress/repository/reading_progress_store.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The threads the current account read, with where it stopped reading them (by tid).
@immutable
final class ReadingProgressState {
  /// Constructor.
  const ReadingProgressState({this.uid, this.threads = const {}, this.loaded = false});

  /// The account, null when none is in use.
  final int? uid;

  /// Whether [threads] are read from the records of [uid] yet (they are empty before, as for an account that read
  /// nothing).
  final bool loaded;

  /// Threads read, by tid.
  final Map<int, ReadingProgress> threads;

  /// Where the reading of thread [tid] stopped; null when the account never read it.
  ReadingProgress? of(int tid) => threads[tid];
}

/// The threads the current account read and where it stopped reading them, from the visit records.
///
/// Follows the account in use as `RepliedThreadCubit` does; empty while no account is in use (a guest keeps no visit
/// record). Thread lists read it through [readingProgressOf], the thread page saves the progress through [save].
final class ReadingProgressCubit extends Cubit<ReadingProgressState> with LoggerMixin {
  /// Constructor.
  ///
  /// With [authenticationRepository] the cubit follows the current account; without it the records of [uid] are
  /// watched (tests).
  ReadingProgressCubit({
    required ReadingProgressStore store,
    AuthenticationRepository? authenticationRepository,
    int? uid,
  }) : _store = store,
       super(const ReadingProgressState()) {
    if (authenticationRepository == null) {
      _follow(uid);
      return;
    }
    _follow(authenticationRepository.effectiveCurrentUid);
    _authSub = authenticationRepository.status.listen((_) => _follow(authenticationRepository.effectiveCurrentUid));
  }

  final ReadingProgressStore _store;

  StreamSubscription<void>? _authSub;
  StreamSubscription<Map<int, ReadingProgress>>? _recordsSub;
  int? _uid;

  void _follow(int? uid) {
    if (uid == _uid && (_recordsSub != null || uid == null)) {
      return;
    }
    _uid = uid;
    unawaited(_recordsSub?.cancel());
    _recordsSub = null;
    if (uid == null) {
      emit(const ReadingProgressState());
      return;
    }
    emit(ReadingProgressState(uid: uid));
    _recordsSub = _store
        .watch(uid)
        .listen(
          (threads) {
            if (!isClosed && _uid == uid) {
              emit(ReadingProgressState(uid: uid, threads: threads, loaded: true));
            }
          },
          onError: (Object e, StackTrace st) {
            error('failed to watch the reading progress: $e', e, st);
            // Nothing more to wait for: the thread page goes on without it.
            if (!isClosed && _uid == uid && !state.loaded) {
              emit(ReadingProgressState(uid: uid, threads: state.threads, loaded: true));
            }
          },
        );
  }

  /// Keep [progress] as where account [uid] stopped reading thread [tid].
  ///
  /// Shown at once for the account in use; the record is written in the background.
  Future<void> save({required int uid, required int tid, required ReadingProgress progress}) async {
    if (uid == state.uid && state.threads[tid] != progress && !isClosed) {
      emit(ReadingProgressState(uid: uid, threads: {...state.threads, tid: progress}, loaded: state.loaded));
    }
    try {
      await _store.save(uid, tid, progress);
    } on Object catch (e, st) {
      error('failed to save the reading progress of thread $tid: $e', e, st);
    }
  }

  @override
  Future<void> close() async {
    await _authSub?.cancel();
    await _recordsSub?.cancel();
    return super.close();
  }
}

/// Where the current account stopped reading thread [tid]; null when it never read it, when [tid] is not a thread id
/// or when no [ReadingProgressCubit] is above [context] (a widget shown outside the app tree).
///
/// Rebuilds the caller when the record of that thread changes.
ReadingProgress? readingProgressOf(BuildContext context, String? tid) {
  final id = int.tryParse(tid ?? '');
  if (id == null || context.readOrNull<ReadingProgressCubit>() == null) {
    return null;
  }
  return context.select<ReadingProgressCubit, ReadingProgress?>((cubit) => cubit.state.of(id));
}
