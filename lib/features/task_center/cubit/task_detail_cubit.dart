import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/models/task_detail.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';

/// Account-scoped snapshot of one task's page.
final class TaskDetailState {
  /// Constructor.
  const TaskDetailState({
    this.uid,
    this.detail,
    this.parters = const [],
    this.loading = false,
    this.failed = false,
    this.loginRequired = false,
    this.message,
    this.busy,
    this.result,
    this.acted = false,
  });

  /// The account the page belongs to.
  final int? uid;

  /// The page, null before the first load and after a failed one.
  final TaskDetail? detail;

  /// The latest members who applied.
  final List<TaskParter> parters;

  /// A GET is in progress.
  final bool loading;

  /// The last GET failed.
  final bool failed;

  /// Sign in to see the task.
  final bool loginRequired;

  /// The forum's message in place of the task (it does not exist or is offline).
  final String? message;

  /// The action being sent; every button is disabled meanwhile.
  final TaskActionKind? busy;

  /// The latest apply, claim or give-up of this account.
  final TaskActionResult? result;

  /// Something was sent from this page: the task center's lists are stale.
  final bool acted;

  TaskDetailState _copyWith({
    TaskDetail? detail,
    List<TaskParter>? parters,
    bool? loading,
    bool? failed,
    TaskActionKind? Function()? busy,
    TaskActionResult? Function()? result,
    bool? acted,
  }) => TaskDetailState(
    uid: uid,
    detail: detail ?? this.detail,
    parters: parters ?? this.parters,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    loginRequired: loginRequired,
    message: message,
    busy: busy == null ? this.busy : busy(),
    result: result == null ? this.result : result(),
    acted: acted ?? this.acted,
  );
}

/// Loads one task's page and sends at most one apply, claim or give-up per confirmed tap, dropping whatever completes
/// for another account.
class TaskDetailCubit extends Cubit<TaskDetailState> {
  /// Constructor.
  TaskDetailCubit({required this.taskId, required this.currentUid, required this.repository})
    : super(const TaskDetailState(loading: true));

  /// The task.
  final int taskId;

  /// Active account, checked around every await.
  final int? Function() currentUid;

  /// Produces an identity-bound client.
  final TaskCenterRepository Function() repository;

  int _generation = 0;
  int _actToken = 0;
  bool _acting = false;

  bool _current(int generation, int uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Erase the snapshot immediately; anything pending becomes stale.
  void invalidate() {
    _generation++;
    _actToken++;
    _acting = false;
    if (!isClosed) emit(TaskDetailState(loading: true, acted: state.acted));
  }

  /// Load the page (GET only), then the members who applied when the page names them.
  ///
  /// Not while something is being sent: the page is loaded again once its answer is in.
  Future<void> load() async {
    if (isClosed || _acting) return;
    if (taskId <= 0) {
      emit(TaskDetailState(uid: currentUid(), failed: true, acted: state.acted));
      return;
    }
    final generation = ++_generation;
    final uid = currentUid();
    if (uid == null || uid <= 0) {
      emit(TaskDetailState(loginRequired: true, acted: state.acted));
      return;
    }
    final keep = state.uid == uid ? state : TaskDetailState(uid: uid, acted: state.acted);
    emit(
      TaskDetailState(
        uid: uid,
        detail: keep.detail,
        parters: keep.parters,
        loading: true,
        result: keep.result,
        acted: keep.acted,
      ),
    );
    try {
      final repo = repository();
      final detail = await repo.fetchDetail(taskId, uid);
      var parters = const <TaskParter>[];
      if (detail.hasParters) {
        try {
          parters = await repo.fetchParters(taskId, uid);
        } on TaskCenterIdentityException {
          rethrow;
        } on Object {
          // The page stands without them.
        }
      }
      if (!_current(generation, uid)) return;
      emit(TaskDetailState(uid: uid, detail: detail, parters: parters, result: state.result, acted: state.acted));
    } on TaskCenterIdentityException catch (e) {
      if (!_current(generation, uid)) return;
      emit(
        e.guest
            ? TaskDetailState(loginRequired: true, acted: state.acted)
            : TaskDetailState(uid: uid, failed: true, acted: state.acted),
      );
    } on TaskDetailMessage catch (e) {
      if (!_current(generation, uid)) return;
      emit(TaskDetailState(uid: uid, message: e.message, result: state.result, acted: state.acted));
    } on Object {
      if (!_current(generation, uid)) return;
      emit(state._copyWith(loading: false, failed: true));
    }
  }

  /// Whether the page offers [kind] now.
  bool canAct(TaskActionKind kind) {
    final detail = state.detail;
    if (isClosed || _acting || state.loading || detail == null || state.uid == null || state.uid != currentUid()) {
      return false;
    }
    return switch (kind) {
      TaskActionKind.apply => detail.canApply,
      TaskActionKind.draw => detail.canClaim,
      TaskActionKind.giveUp => detail.canGiveUp,
    };
  }

  /// Send [kind] once, then load the page again to show what the forum did. A failed or ambiguous request is never
  /// repeated.
  Future<void> act(TaskActionKind kind) async {
    if (!canAct(kind)) return;
    final uid = state.uid!;
    final generation = _generation;
    final token = ++_actToken;
    _acting = true;
    emit(state._copyWith(busy: () => kind, result: () => null));
    TaskActionResult result;
    try {
      final repo = repository();
      result = switch (kind) {
        TaskActionKind.apply => await repo.apply(taskId),
        TaskActionKind.draw => await repo.draw(taskId),
        TaskActionKind.giveUp => await repo.giveUp(taskId),
      };
      if (result.uid case final served? when served != uid) {
        result = TaskActionResult(
          taskId: taskId,
          outcome: served == 0 ? TaskActionOutcome.loginRequired : TaskActionOutcome.unconfirmed,
        );
      }
    } on Object {
      result = TaskActionResult(taskId: taskId, outcome: TaskActionOutcome.unconfirmed);
    } finally {
      if (token == _actToken) _acting = false;
    }
    if (!_current(generation, uid)) {
      if (!isClosed && generation == _generation) emit(state._copyWith(busy: () => null, acted: true));
      return;
    }
    if (result.outcome == TaskActionOutcome.loginRequired) {
      _generation++;
      emit(const TaskDetailState(loginRequired: true, acted: true));
      return;
    }
    emit(state._copyWith(busy: () => null, result: () => result, acted: true));
    await load();
  }

  /// Something was sent from another task's page opened from this one: this task may have changed, and the task
  /// center's lists are stale.
  Future<void> otherActed() async {
    if (isClosed) return;
    if (!state.acted) emit(state._copyWith(acted: true));
    await load();
  }

  /// Forget the shown result.
  void dismissResult() {
    if (state.result != null && !isClosed) emit(state._copyWith(result: () => null));
  }
}
