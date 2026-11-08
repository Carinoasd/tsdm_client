import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_calendar.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/load_failure.dart';

/// How far back the streak is followed, in months.
const _streakMonthsLimit = 14;

/// How far back the calendar goes, in months.
const checkinCalendarMonthsLimit = 36;

/// Status of [CheckinCalendarState].
enum CheckinCalendarStatus {
  /// The first month is on its way.
  loading,

  /// The month shown is read.
  success,

  /// The first month failed.
  failed,
}

/// State of the check-in calendar.
final class CheckinCalendarState {
  /// Constructor.
  const CheckinCalendarState({
    required this.today,
    required this.month,
    this.status = CheckinCalendarStatus.loading,
    this.daysByMonth = const {},
    this.streak = 0,
    this.totalDays,
    this.loadingMonth = false,
    this.failure,
  });

  /// Today as the forum counts it.
  final DateTime today;

  /// First day of the month shown.
  final DateTime month;

  /// Status of the first load.
  final CheckinCalendarStatus status;

  /// The days checked in of every month read, by [monthKey].
  final Map<int, Set<int>> daysByMonth;

  /// Days in a row up to today, as far as the months read tell.
  final int streak;

  /// All the days the account ever checked in, told by the forum; null when it does not tell.
  final int? totalDays;

  /// A month other than the first is on its way.
  final bool loadingMonth;

  /// Why the first load or the last month failed.
  final LoadFailure? failure;

  /// The days checked in of the month shown.
  Set<int> get markedDays => daysByMonth[monthKey(month)] ?? const {};

  /// Whether the month shown is the month of today.
  bool get isCurrentMonth => month.year == today.year && month.month == today.month;

  /// Copy with changes; [failure] is replaced as given (null clears it).
  CheckinCalendarState copyWith({
    DateTime? month,
    CheckinCalendarStatus? status,
    Map<int, Set<int>>? daysByMonth,
    int? streak,
    int? totalDays,
    bool? loadingMonth,
    LoadFailure? failure,
  }) => CheckinCalendarState(
    today: today,
    month: month ?? this.month,
    status: status ?? this.status,
    daysByMonth: daysByMonth ?? this.daysByMonth,
    streak: streak ?? this.streak,
    totalDays: totalDays ?? this.totalDays,
    loadingMonth: loadingMonth ?? this.loadingMonth,
    failure: failure,
  );
}

/// The key of the month of [day] in [CheckinCalendarState.daysByMonth].
int monthKey(DateTime day) => day.year * 12 + day.month - 1;

/// The total days of the account told by the forum's app API (`checkin`, `days`), null when it does not tell.
Future<int?> fetchCheckinTotalDays() async {
  final answer = await TsdmAppApi.ask(getIt.get<NetClientProvider>(), 'checkin');
  if (answer == null || answer['ok'] != 1 || answer['installed'] != 1) {
    return null;
  }
  final days = answer['days'];
  return days is int && days > 0 ? days : null;
}

/// Reads the changelog records of the days [start] to [end]: [PointsRepository.fetchChangelogRange].
typedef ChangelogRangeFetcher =
    Future<Either<LoadFailure, RangedChangelog>> Function({required DateTime start, required DateTime end});

/// Cubit of the check-in calendar: reads the check-in records of the points changelog month by month.
final class CheckinCalendarCubit extends Cubit<CheckinCalendarState> {
  /// Constructor.
  CheckinCalendarCubit({
    required ChangelogRangeFetcher fetchRange,
    Future<int?> Function() totalDays = fetchCheckinTotalDays,
    DateTime? now,
  }) : _fetchRange = fetchRange,
       _totalDays = totalDays,
       super(CheckinCalendarState(today: forumToday(now), month: _firstOf(forumToday(now))));

  final ChangelogRangeFetcher _fetchRange;
  final Future<int?> Function() _totalDays;

  /// Bumped by every [load]: an answer of an earlier one is dropped.
  int _generation = 0;

  static DateTime _firstOf(DateTime day) => DateTime(day.year, day.month);

  /// Read the month of today, then the days in a row and the total.
  Future<void> load() async {
    final generation = ++_generation;
    emit(
      CheckinCalendarState(today: state.today, month: _firstOf(state.today)),
    );
    final total = _totalDays();
    final failure = await _readMonth(_firstOf(state.today), generation);
    if (generation != _generation) {
      return;
    }
    if (failure != null) {
      emit(state.copyWith(status: CheckinCalendarStatus.failed, failure: failure));
      return;
    }
    emit(state.copyWith(status: CheckinCalendarStatus.success, totalDays: await total));
    await _followStreak(generation);
  }

  /// Show the month [months] away from the one shown (negative: earlier), reading it when it is not read yet.
  Future<void> moveMonth(int months) async {
    final target = DateTime(state.month.year, state.month.month + months);
    final current = _firstOf(state.today);
    final earliest = DateTime(current.year, current.month - checkinCalendarMonthsLimit);
    if (state.status != CheckinCalendarStatus.success ||
        target.isAfter(current) ||
        target.isBefore(earliest) ||
        state.loadingMonth) {
      return;
    }
    final generation = _generation;
    if (state.daysByMonth.containsKey(monthKey(target))) {
      emit(state.copyWith(month: target));
      return;
    }
    final previous = state.month;
    emit(state.copyWith(month: target, loadingMonth: true));
    final failure = await _readMonth(target, generation);
    if (generation != _generation) {
      return;
    }
    // The month that failed is not shown empty: the calendar stays where it was and the failure is told.
    emit(state.copyWith(month: failure == null ? target : previous, loadingMonth: false, failure: failure));
    if (failure == null) {
      await _followStreak(generation);
    }
  }

  /// Read the month starting at [first] into the state; the failure when it failed.
  Future<LoadFailure?> _readMonth(DateTime first, int generation) async {
    final last = DateTime(first.year, first.month + 1, 0);
    final result = await _fetchRange(start: first, end: last);
    if (generation != _generation) {
      return null;
    }
    switch (result) {
      case Left(:final value):
        return value;
      case Right(:final value):
        final days = {for (final day in checkinDaysOf(value.changes)) day.day};
        emit(state.copyWith(daysByMonth: {...state.daysByMonth, monthKey(first): days}, failure: state.failure));
        return null;
    }
  }

  /// Count the days in a row up to today, reading earlier months while the row reaches back into one not read.
  Future<void> _followStreak(int generation) async {
    while (generation == _generation) {
      final days = <DateTime>{};
      for (final MapEntry(:key, :value) in state.daysByMonth.entries) {
        for (final day in value) {
          days.add(DateTime(key ~/ 12, key % 12 + 1, day));
        }
      }
      final row = checkinStreakOf(days, state.today);
      final today = _firstOf(state.today);
      final monthsBack = (today.year - row.before.year) * 12 + today.month - row.before.month;
      if (state.streak != row.length) {
        emit(state.copyWith(streak: row.length, failure: state.failure));
      }
      if (state.daysByMonth.containsKey(monthKey(row.before)) || monthsBack >= _streakMonthsLimit) {
        return;
      }
      final failure = await _readMonth(_firstOf(row.before), generation);
      if (failure != null) {
        return;
      }
    }
  }
}
