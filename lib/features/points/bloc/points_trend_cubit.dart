import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_calendar_cubit.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_calendar.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/utils/points_trend.dart';
import 'package:tsdm_client/utils/load_failure.dart';

/// Status of [PointsTrendState].
enum PointsTrendStatus {
  /// The records are on their way.
  loading,

  /// The records are read.
  success,

  /// The records could not be read.
  failed,
}

/// State of the points trend.
final class PointsTrendState {
  /// Constructor.
  const PointsTrendState({
    required this.today,
    this.status = PointsTrendStatus.loading,
    this.changes = const [],
    this.kinds = const [],
    this.selected = 0,
    this.complete = true,
    this.oldest,
    this.failure,
  });

  /// Today as the forum counts it.
  final DateTime today;

  /// Status of the read.
  final PointsTrendStatus status;

  /// The records of the last [pointsTrendDays] days.
  final List<PointsChange> changes;

  /// The kinds of points the records changed.
  final List<String> kinds;

  /// The index in [kinds] of the kind shown.
  final int selected;

  /// Whether every record of the range was read (the read stops at a page limit).
  final bool complete;

  /// The time of the oldest record read, null without any: when the read was cut, what is older is missing.
  final DateTime? oldest;

  /// Why the read failed.
  final LoadFailure? failure;

  /// The kind shown, null without a record.
  String? get kind => selected < kinds.length ? kinds[selected] : null;

  /// Copy with changes.
  PointsTrendState copyWith({
    PointsTrendStatus? status,
    List<PointsChange>? changes,
    List<String>? kinds,
    int? selected,
    DateTime? today,
    bool? complete,
    DateTime? oldest,
    LoadFailure? failure,
  }) => PointsTrendState(
    today: today ?? this.today,
    complete: complete ?? this.complete,
    oldest: oldest ?? this.oldest,
    status: status ?? this.status,
    changes: changes ?? this.changes,
    kinds: kinds ?? this.kinds,
    selected: selected ?? this.selected,
    failure: failure,
  );
}

/// Cubit of the points trend: reads the changelog of the last eight weeks once and charts a kind of points from it.
final class PointsTrendCubit extends Cubit<PointsTrendState> {
  /// Constructor.
  PointsTrendCubit({required ChangelogRangeFetcher fetchRange, DateTime? now})
    : _fetchRange = fetchRange,
      _now = now,
      super(PointsTrendState(today: forumToday(now)));

  final ChangelogRangeFetcher _fetchRange;
  final DateTime? _now;

  /// Bumped by every [load]: an answer of an earlier one is dropped.
  int _generation = 0;

  /// Read the records of the last [pointsTrendDays] days; the kind shown stays when it is still there.
  Future<void> load() async {
    final generation = ++_generation;
    final keep = state.status == PointsTrendStatus.success ? state.kind : null;
    // The day is taken again: a page kept open past midnight charts the new day.
    final today = forumToday(_now);
    if (keep == null) {
      emit(PointsTrendState(today: today));
    }
    final result = await _fetchRange(
      start: DateTime(today.year, today.month, today.day - (pointsTrendDays - 1)),
      end: today,
    );
    if (generation != _generation) {
      return;
    }
    switch (result) {
      case Left(:final value):
        emit(
          keep == null
              ? state.copyWith(status: PointsTrendStatus.failed, failure: value)
              : state.copyWith(failure: value),
        );
      case Right(:final value):
        final kinds = pointsKindsOf(value.changes);
        final index = keep == null ? 0 : kinds.indexOf(keep);
        emit(
          state.copyWith(
            status: PointsTrendStatus.success,
            changes: value.changes,
            kinds: kinds,
            selected: index < 0 ? 0 : index,
            today: today,
            complete: value.complete,
            oldest: value.oldest,
          ),
        );
    }
  }

  /// Show the kind of points at [index] of the kinds.
  void select(int index) {
    if (state.status == PointsTrendStatus.success && index >= 0 && index < state.kinds.length) {
      emit(state.copyWith(selected: index));
    }
  }
}
