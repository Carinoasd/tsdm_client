import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';

/// One list of the task center as last loaded.
final class TaskTabState {
  /// Constructor.
  const TaskTabState({this.list, this.loading = false, this.failed = false});

  /// The loaded list, null before the first load and after a failed one.
  final TaskList? list;

  /// A GET is in progress.
  final bool loading;

  /// The last GET failed.
  final bool failed;
}

/// Account-scoped task center snapshot.
final class TaskCenterState {
  /// Constructor.
  const TaskCenterState({
    this.uid,
    this.tabs = const {},
    this.loginRequired = false,
    this.busyTaskId,
    this.result,
    this.resultName = '',
    this.resultTab,
    this.detailAvailable = false,
  });

  /// The account the lists belong to.
  final int? uid;

  /// Lists by tab; a tab not loaded yet is absent.
  final Map<TaskCenterTab, TaskTabState> tabs;

  /// Sign in to use the task center.
  final bool loginRequired;

  /// The task whose apply or claim is being sent; every button is disabled meanwhile.
  final int? busyTaskId;

  /// The latest apply or claim result for this account.
  final TaskActionResult? result;

  /// The name of the task of [result].
  final String resultName;

  /// The tab [result] was acted from, the only one showing it.
  final TaskCenterTab? resultTab;

  /// A task's page can be opened (the forum's plugin answers it); the cards open nothing otherwise.
  final bool detailAvailable;

  /// The state of [tab], empty when not loaded yet.
  TaskTabState tab(TaskCenterTab tab) => tabs[tab] ?? const TaskTabState();

  TaskCenterState _copyWith({
    Map<TaskCenterTab, TaskTabState>? tabs,
    bool? loginRequired,
    int? Function()? busyTaskId,
    TaskActionResult? Function()? result,
    String? resultName,
    TaskCenterTab? resultTab,
    bool? detailAvailable,
  }) => TaskCenterState(
    uid: uid,
    tabs: tabs ?? this.tabs,
    loginRequired: loginRequired ?? this.loginRequired,
    busyTaskId: busyTaskId == null ? this.busyTaskId : busyTaskId(),
    result: result == null ? this.result : result(),
    resultName: resultName ?? this.resultName,
    resultTab: resultTab ?? this.resultTab,
    detailAvailable: detailAvailable ?? this.detailAvailable,
  );
}

/// Loads the task lists and sends at most one apply or claim per tap, discarding completions of another account.
class TaskCenterCubit extends Cubit<TaskCenterState> {
  /// Constructor.
  TaskCenterCubit({required this.currentUid, required this.repository}) : super(const TaskCenterState());

  /// Active account, checked around every await.
  final int? Function() currentUid;

  /// Produces an identity-bound client.
  final TaskCenterRepository Function() repository;

  int _account = 0;
  final Map<TaskCenterTab, int> _loads = {};
  bool _acting = false;

  bool _current(int account, int uid) => !isClosed && account == _account && uid == currentUid();

  /// Erase the snapshot immediately; any pending load or action completion becomes stale.
  void invalidate() {
    _account++;
    _acting = false;
    if (!isClosed) emit(const TaskCenterState());
  }

  /// Load [tab] unless it is loaded or loading.
  Future<void> ensureLoaded(TaskCenterTab tab) async {
    final s = state.tab(tab);
    if (s.list != null || s.loading || s.failed || state.loginRequired) return;
    await load(tab);
  }

  /// Load the list of [tab] (GET only).
  Future<void> load(TaskCenterTab tab) async {
    if (isClosed) return;
    final uid = currentUid();
    if (uid == null || uid <= 0) {
      _account++;
      emit(const TaskCenterState(loginRequired: true));
      return;
    }
    if (state.uid != uid) {
      _account++;
      emit(TaskCenterState(uid: uid));
    }
    final account = _account;
    final generation = (_loads[tab] ?? 0) + 1;
    _loads[tab] = generation;
    bool fresh() => _current(account, uid) && _loads[tab] == generation;
    final previous = state.tab(tab).list;
    emit(
      state._copyWith(
        tabs: {
          ...state.tabs,
          tab: TaskTabState(list: previous, loading: true),
        },
      ),
    );
    try {
      final repo = repository();
      final list = await repo.fetchList(tab, uid);
      // Asked after the list: the plugin's `status` is known by then.
      final detail = await repo.detailAvailable();
      if (!fresh()) return;
      emit(
        state._copyWith(
          tabs: {
            ...state.tabs,
            tab: TaskTabState(list: list),
          },
          detailAvailable: detail,
        ),
      );
    } on TaskCenterIdentityException catch (e) {
      if (!fresh()) return;
      if (e.guest) {
        _account++;
        emit(const TaskCenterState(loginRequired: true));
      } else {
        emit(state._copyWith(tabs: {...state.tabs, tab: const TaskTabState(failed: true)}));
      }
    } on Object {
      if (fresh()) emit(state._copyWith(tabs: {...state.tabs, tab: const TaskTabState(failed: true)}));
    }
  }

  /// Whether [task] of [tab] can be acted on now.
  bool canAct(TaskCenterTab tab, ForumTask task) =>
      !isClosed &&
      !_acting &&
      task.action != null &&
      state.uid != null &&
      state.uid == currentUid() &&
      (state.tab(tab).list?.tasks.any((t) => identical(t, task)) ?? false);

  /// Send the apply or the claim of [task] once, then reload the lists it changes.
  ///
  /// A failed or ambiguous request is never repeated: the reloaded lists tell what the forum did.
  Future<void> act(TaskCenterTab tab, ForumTask task) async {
    if (!canAct(tab, task)) return;
    final uid = state.uid!;
    final account = _account;
    final kind = task.action!;
    _acting = true;
    emit(state._copyWith(busyTaskId: () => task.id, result: () => null));
    TaskActionResult result;
    try {
      final repo = repository();
      result = switch (kind) {
        TaskActionKind.apply => await repo.apply(task.id),
        TaskActionKind.draw => await repo.draw(task.id),
        TaskActionKind.giveUp => await repo.giveUp(task.id),
      };
      if (result.uid case final served? when served != uid) {
        result = TaskActionResult(
          taskId: task.id,
          outcome: served == 0 ? TaskActionOutcome.loginRequired : TaskActionOutcome.unconfirmed,
        );
      }
    } on Object {
      result = TaskActionResult(taskId: task.id, outcome: TaskActionOutcome.unconfirmed);
    } finally {
      if (account == _account) _acting = false;
    }
    if (!_current(account, uid)) {
      // The account changed without an invalidate (a caller not listening to account changes): unlock the buttons.
      if (!isClosed && account == _account) emit(state._copyWith(busyTaskId: () => null));
      return;
    }
    if (result.outcome == TaskActionOutcome.loginRequired) {
      // The session expired: the lists are a guest's now, nothing more is sent from them.
      _account++;
      emit(const TaskCenterState(loginRequired: true));
      return;
    }
    emit(state._copyWith(busyTaskId: () => null, result: () => result, resultName: task.name, resultTab: tab));
    final affected = switch (kind) {
      TaskActionKind.apply || TaskActionKind.giveUp => const [TaskCenterTab.available, TaskCenterTab.doing],
      TaskActionKind.draw => const [TaskCenterTab.doing, TaskCenterTab.done],
    };
    final reload = {tab, ...affected};
    // Lists not shown are dropped, and their loads in flight with them, and loaded again when their tab is opened.
    for (final other in reload) {
      if (other != tab) _loads[other] = (_loads[other] ?? 0) + 1;
    }
    emit(
      state._copyWith(
        tabs: {
          for (final e in state.tabs.entries)
            if (!reload.contains(e.key) || e.key == tab) e.key: e.value,
        },
      ),
    );
    await load(tab);
  }

  /// Drop every list (a task's page acted on one of them) and load [tab] again.
  Future<void> reloadAll(TaskCenterTab tab) async {
    if (isClosed || state.uid == null) return;
    for (final other in TaskCenterTab.values) {
      if (other != tab) _loads[other] = (_loads[other] ?? 0) + 1;
    }
    emit(state._copyWith(tabs: {tab: ?state.tabs[tab]}));
    await load(tab);
  }

  /// Forget the shown result.
  void dismissResult() {
    if (state.result != null && !isClosed) emit(state._copyWith(result: () => null));
  }
}
