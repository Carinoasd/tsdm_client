import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';

/// Account-scoped draft snapshots.
final class DraftState {
  /// Constructor.
  const DraftState({
    this.entries = const [],
    this.uid,
    this.nextPage,
    this.loading = false,
    this.failed = false,
    this.loginRequired = false,
    this.opening,
  });

  /// Current page contents.
  final List<DraftEntry> entries;

  /// Owner of the snapshot.
  final int? uid;

  /// Remaining page, if any.
  final int? nextPage;

  /// A GET is pending.
  final bool loading;

  /// A read failed; an existing page can still be shown.
  final bool failed;

  /// No account is selected.
  final bool loginRequired;

  /// Draft currently being resolved.
  final String? opening;
}

/// Drops stale refreshes, page loads and edit resolutions across account changes.
class DraftCubit extends Cubit<DraftState> {
  /// Constructor.
  DraftCubit({required this.currentUid, required this.repository}) : super(const DraftState());

  /// Current account.
  final int? Function() currentUid;

  /// Creates an account-bound repository for each fresh list.
  final DraftRepository Function() repository;
  int _generation = 0;
  DraftRepository? _loaded;

  bool _current(int generation, int? uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Erase private data immediately on authentication changes.
  void invalidate() {
    _generation++;
    _loaded = null;
    if (!isClosed) emit(const DraftState());
  }

  /// Refresh, or retry loading the next page without losing existing rows.
  Future<void> load({bool more = false}) async {
    if (isClosed || more && (state.loading || state.nextPage == null || state.uid != currentUid())) return;
    final generation = ++_generation;
    final uid = currentUid();
    if (uid == null || uid <= 0) {
      _loaded = null;
      emit(const DraftState(loginRequired: true));
      return;
    }
    final previous = more ? state.entries : <DraftEntry>[];
    final page = more ? state.nextPage! : 1;
    final repo = more ? _loaded! : repository();
    _loaded = repo;
    emit(DraftState(uid: uid, entries: previous, nextPage: more ? page : null, loading: true));
    try {
      final result = await repo.load(uid, page: page);
      if (!_current(generation, uid)) return;
      final merged = {
        for (final entry in previous) entry.tid: entry,
        for (final entry in result.entries) entry.tid: entry,
      };
      emit(DraftState(uid: uid, entries: List.unmodifiable(merged.values), nextPage: result.nextPage));
    } on Object {
      if (_current(generation, uid)) {
        emit(DraftState(uid: uid, entries: previous, nextPage: more ? page : null, failed: true));
      }
    }
  }

  /// Resolve only a row that belongs to the currently displayed snapshot.
  Future<DraftEditTarget?> open(DraftEntry entry) async {
    final snapshot = state;
    if (isClosed ||
        snapshot.loading ||
        snapshot.opening != null ||
        snapshot.uid != currentUid() ||
        snapshot.uid == null ||
        !snapshot.entries.contains(entry) ||
        _loaded == null) {
      return null;
    }
    final generation = _generation;
    emit(DraftState(uid: snapshot.uid, entries: snapshot.entries, nextPage: snapshot.nextPage, opening: entry.tid));
    try {
      final target = await _loaded!.resolve(entry, snapshot.uid!);
      if (!_current(generation, snapshot.uid)) return null;
      emit(snapshot);
      return target;
    } on Object {
      if (_current(generation, snapshot.uid)) emit(snapshot);
      return null;
    }
  }
}
