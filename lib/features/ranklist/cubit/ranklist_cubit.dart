import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/ranklist/models/ranklist.dart';
import 'package:tsdm_client/features/ranklist/repository/ranklist_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';

/// Status of a ranking tab.
enum RanklistStatus {
  /// First load on its way.
  loading,

  /// Loaded.
  success,

  /// Failed, nothing shown.
  failed,
}

/// State of a ranking tab.
final class RanklistState {
  /// Constructor.
  const RanklistState({
    this.status = RanklistStatus.loading,
    this.page,
    this.failure,
    this.refreshing = false,
    this.threadView = RanklistThreadView.replies,
  });

  /// Status.
  final RanklistStatus status;

  /// The ranking shown.
  final RanklistData? page;

  /// Why the last load failed: the whole tab ([RanklistStatus.failed]) or a refresh that kept [page] shown.
  final LoadFailure? failure;

  /// [page] is asked again while it stays on screen.
  final bool refreshing;

  /// Order of the thread ranking.
  final RanklistThreadView threadView;

  /// Copy with the fields given; [failure] is cleared unless given.
  RanklistState copyWith({
    RanklistStatus? status,
    RanklistData? page,
    LoadFailure? failure,
    bool? refreshing,
    RanklistThreadView? threadView,
  }) => RanklistState(
    status: status ?? this.status,
    page: page ?? this.page,
    failure: failure,
    refreshing: refreshing ?? this.refreshing,
    threadView: threadView ?? this.threadView,
  );
}

/// Loads one ranking.
final class RanklistCubit extends Cubit<RanklistState> {
  /// Constructor.
  RanklistCubit({required this.kind, required RanklistRepository repository})
    : _repository = repository,
      super(const RanklistState());

  /// The ranking loaded.
  final RanklistKind kind;

  final RanklistRepository _repository;

  /// Bumped by every load: an answer to an older one is dropped.
  int _generation = 0;

  /// Load the ranking; the one shown stays while it is asked again, and when that fails.
  Future<void> load() async {
    final generation = ++_generation;
    final shown = state.status == RanklistStatus.success;
    emit(shown ? state.copyWith(refreshing: true) : state.copyWith(status: RanklistStatus.loading));
    final result = await _repository.fetch(ranklistUrl(kind, threadView: state.threadView)).run();
    if (isClosed || generation != _generation) {
      return;
    }
    result.match(
      (e) => emit(
        shown
            ? state.copyWith(refreshing: false, failure: LoadFailure.of(e))
            : state.copyWith(status: RanklistStatus.failed, failure: LoadFailure.of(e)),
      ),
      (page) => emit(state.copyWith(status: RanklistStatus.success, page: page, refreshing: false)),
    );
  }

  /// Order the thread ranking by [view] and load it.
  Future<void> changeThreadView(RanklistThreadView view) async {
    if (view == state.threadView) {
      return;
    }
    // Another list: the one shown is not kept while it loads.
    emit(RanklistState(threadView: view));
    await load();
  }
}
