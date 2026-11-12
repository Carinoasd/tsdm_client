import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'thread_visit_history_bloc.mapper.dart';
part 'thread_visit_history_event.dart';
part 'thread_visit_history_state.dart';

typedef _Emit = Emitter<ThreadVisitHistoryState>;

/// Bloc of thread visit history feature.
final class ThreadVisitHistoryBloc extends Bloc<ThreadVisitHistoryEvent, ThreadVisitHistoryState> with LoggerMixin {
  /// Constructor.
  ThreadVisitHistoryBloc(this._repo) : super(const ThreadVisitHistoryState()) {
    on<ThreadVisitHistoryEvent>(
      (event, emit) async => switch (event) {
        ThreadVisitHistoryFetchAllRequested() => _onFetchAllRequested(emit),
        ThreadVisitHistoryFetchByUserRequested(:final uid) => _onFetchByUserRequested(uid, emit),
        ThreadVisitHistoryUpdateRequested(:final history) => _onUpdateRequested(history, emit),
        ThreadVisitHistoryDeleteRecordRequested(:final uid, :final tid) => _onDeleteRecordRequested(
          emit,
          uid: uid,
          tid: tid,
        ),
        ThreadVisitHistoryClearRequested() => _onClearRequested(emit),
      },
    );
  }

  final ThreadVisitHistoryRepo _repo;

  Future<void> _onFetchAllRequested(_Emit emit) async {
    emit(state.copyWith(status: ThreadVisitHistoryStatus.loadingData));
    switch (await _repo.fetchAllHistory().run()) {
      case Left():
        debug('fetch all failed');
        emit(state.copyWith(status: ThreadVisitHistoryStatus.failure));
      case Right(:final value):
        debug('fetch all succeeded, data count is ${value.length}');
        emit(state.copyWith(status: ThreadVisitHistoryStatus.success, history: value));
    }
  }

  Future<void> _onFetchByUserRequested(int uid, _Emit emit) async {
    emit(state.copyWith(status: ThreadVisitHistoryStatus.loadingData));
    switch (await _repo.fetchHistoryByUid(uid).run()) {
      case Left():
        debug('fetch by uid $uid failed');
        emit(state.copyWith(status: ThreadVisitHistoryStatus.failure));
      case Right(:final value):
        debug('fetch by uid $uid succeeded, data count is ${value.length}');
        emit(state.copyWith(status: ThreadVisitHistoryStatus.success, history: value));
    }
  }

  Future<void> _onUpdateRequested(ThreadVisitHistoryModel model, _Emit emit) async {
    emit(state.copyWith(status: ThreadVisitHistoryStatus.savingData));
    // A record that was not stored is not shown as stored: the history kept is what the storage holds. Before, a
    // failed save (a storage error thrown out of the handler) was dropped and the record was updated all the same.
    // The failure here is that of this save only, the history is still the one loaded; the bloc of the app saves the
    // visits, the history page loads a bloc of its own and shows its loading failures only.
    try {
      if (await _repo.saveHistory(model).run() case Left(:final value)) {
        throw value;
      }
    } on Exception catch (e, st) {
      error('failed to save thread visit history of tid ${model.threadId}');
      handleRaw(e, st);
      emit(state.copyWith(status: ThreadVisitHistoryStatus.failure));
      return;
    }
    // A new list: the one of the state before is not changed in place.
    final history = [
      for (final item in state.history) (item.uid == model.uid && item.threadId == model.threadId) ? model : item,
    ];
    emit(state.copyWith(status: ThreadVisitHistoryStatus.success, history: history));
  }

  Future<void> _onDeleteRecordRequested(_Emit emit, {required int uid, required int tid}) async {
    emit(state.copyWith(status: ThreadVisitHistoryStatus.savingData));
    await _repo.deleteRecord(uid: uid, tid: tid).run();
    final history = state.history.filter((e) => e.uid != uid || e.threadId != tid).toList();
    emit(state.copyWith(status: ThreadVisitHistoryStatus.success, history: history));
  }

  Future<void> _onClearRequested(_Emit emit) async {
    emit(state.copyWith(status: ThreadVisitHistoryStatus.savingData));
    await _repo.deleteAllRecords().run();
    emit(state.copyWith(status: ThreadVisitHistoryStatus.success, history: []));
  }
}
