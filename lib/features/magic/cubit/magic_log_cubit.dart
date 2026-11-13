import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/magic/models/magic_log.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';

/// One list of the log as last loaded.
final class MagicLogTabState {
  /// Constructor.
  const MagicLogTabState({this.page, this.loading = false, this.failed = false});

  /// The page shown, null before the first load and after a failed one.
  final MagicLogList? page;

  /// A GET is in progress.
  final bool loading;

  /// The last GET failed.
  final bool failed;
}

/// Account-scoped snapshot of the magic item log.
final class MagicLogState {
  /// Constructor.
  const MagicLogState({this.uid, this.tabs = const {}, this.loginRequired = false, this.message});

  /// The account the lists belong to.
  final int? uid;

  /// Lists by tab; a tab not loaded yet is absent.
  final Map<MagicLogTab, MagicLogTabState> tabs;

  /// Sign in to see the log.
  final bool loginRequired;

  /// The forum's message in place of the log (magics closed).
  final String? message;

  /// The state of [tab], empty when not loaded yet.
  MagicLogTabState tab(MagicLogTab tab) => tabs[tab] ?? const MagicLogTabState();
}

/// Loads the lists of the magic item log (GET only), dropping whatever completes for another account.
class MagicLogCubit extends Cubit<MagicLogState> {
  /// Constructor.
  MagicLogCubit({required this.currentUid, required this.repository}) : super(const MagicLogState());

  /// Active account, checked around every await.
  final int? Function() currentUid;

  /// Produces an identity-bound client.
  final MagicRepository Function() repository;

  int _account = 0;
  final Map<MagicLogTab, int> _loads = {};

  /// Erase the snapshot immediately; any pending load becomes stale.
  void invalidate() {
    _account++;
    if (!isClosed) emit(const MagicLogState());
  }

  /// Load [tab] unless it is loaded, loading or failed.
  Future<void> ensureLoaded(MagicLogTab tab) async {
    final s = state.tab(tab);
    if (s.page != null || s.loading || s.failed || state.loginRequired || state.message != null) return;
    await load(tab);
  }

  /// Load page [page] of [tab] (the page shown when not given).
  Future<void> load(MagicLogTab tab, {int? page}) async {
    if (isClosed) return;
    final uid = currentUid();
    if (uid == null || uid <= 0) {
      _account++;
      emit(const MagicLogState(loginRequired: true));
      return;
    }
    if (state.uid != uid || state.loginRequired || state.message != null) {
      _account++;
      emit(MagicLogState(uid: uid));
    }
    final account = _account;
    final generation = (_loads[tab] ?? 0) + 1;
    _loads[tab] = generation;
    bool fresh() => !isClosed && account == _account && uid == currentUid() && _loads[tab] == generation;
    final previous = state.tab(tab).page;
    emit(_withTab(tab, MagicLogTabState(page: previous, loading: true)));
    try {
      final result = await repository().fetchLog(tab, page ?? previous?.page ?? 1, uid);
      if (!fresh()) return;
      emit(_withTab(tab, MagicLogTabState(page: result)));
    } on MagicIdentityException catch (e) {
      if (!fresh()) return;
      if (e.guest) {
        _account++;
        emit(const MagicLogState(loginRequired: true));
      } else {
        emit(_withTab(tab, const MagicLogTabState(failed: true)));
      }
    } on MagicForumMessage catch (e) {
      if (!fresh()) return;
      _account++;
      emit(MagicLogState(uid: uid, message: e.message));
    } on Object {
      if (fresh()) emit(_withTab(tab, MagicLogTabState(page: previous, failed: true)));
    }
  }

  MagicLogState _withTab(MagicLogTab tab, MagicLogTabState value) => MagicLogState(
    uid: state.uid,
    tabs: {...state.tabs, tab: value},
    loginRequired: state.loginRequired,
    message: state.message,
  );
}
