import 'dart:async';

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
    this.streakAtLeast = false,
    this.incompleteMonths = const {},
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

  /// Whether [streak] is only the least: the row reached back into a month whose records were not all read.
  final bool streakAtLeast;

  /// The months ([monthKey]) whose records were cut at the page limit, with the time of the oldest record read: the
  /// days from that day back may be missing.
  final Map<int, DateTime> incompleteMonths;

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
    bool? streakAtLeast,
    Map<int, DateTime>? incompleteMonths,
    int? totalDays,
    bool? loadingMonth,
    LoadFailure? failure,
  }) => CheckinCalendarState(
    today: today,
    month: month ?? this.month,
    status: status ?? this.status,
    daysByMonth: daysByMonth ?? this.daysByMonth,
    streak: streak ?? this.streak,
    streakAtLeast: streakAtLeast ?? this.streakAtLeast,
    incompleteMonths: incompleteMonths ?? this.incompleteMonths,
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
  ///
  /// [now] stands for the clock (tests).
  CheckinCalendarCubit({
    required ChangelogRangeFetcher fetchRange,
    Future<int?> Function() totalDays = fetchCheckinTotalDays,
    DateTime? now,
  }) : _fetchRange = fetchRange,
       _totalDays = totalDays,
       _now = now,
       super(CheckinCalendarState(today: forumToday(now), month: _firstOf(forumToday(now))));

  final ChangelogRangeFetcher _fetchRange;
  final Future<int?> Function() _totalDays;
  final DateTime? _now;

  /// Bumped by every [load]: an answer of an earlier one is dropped.
  int _generation = 0;

  /// The months on their way by [monthKey]: a month asked while it is read waits for that read instead of reading it
  /// again (a page of the changelog is one request, a month is up to 30 of them).
  final Map<int, Future<LoadFailure?>> _reading = {};

  /// The streak count in progress: one at a time, the next one runs after it and so sees what the first one read.
  Future<void> _streakRun = Future.value();

  static DateTime _firstOf(DateTime day) => DateTime(day.year, day.month);

  /// Read the month of today, then the days in a row and the total; the page shows as soon as the month is there.
  Future<void> load() async {
    final generation = ++_generation;
    _reading.clear();
    // The count of a load before may still be reading; the new one does not wait for it.
    _streakRun = Future.value();
    // The day is taken again: a page kept open past midnight starts the new day here.
    final today = forumToday(_now);
    emit(CheckinCalendarState(today: today, month: _firstOf(today)));
    final total = _totalDays();
    final failure = await _readMonth(_firstOf(today), generation);
    if (generation != _generation) {
      return;
    }
    if (failure != null) {
      emit(state.copyWith(status: CheckinCalendarStatus.failed, failure: failure));
      return;
    }
    emit(state.copyWith(status: CheckinCalendarStatus.success));
    await Future.wait([_followStreak(generation), _applyTotal(total, generation)]);
  }

  /// Put the total days [total] told by the forum into the state; the total is an extra number, the page does not
  /// wait for it.
  Future<void> _applyTotal(Future<int?> total, int generation) async {
    final days = await total;
    if (generation == _generation && days != null) {
      emit(state.copyWith(totalDays: days, failure: state.failure));
    }
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

  /// Read the month starting at [first] into the state, once however many ask; the failure when it failed.
  Future<LoadFailure?> _readMonth(DateTime first, int generation) async {
    final key = monthKey(first);
    final existing = _reading[key];
    if (existing != null) {
      return existing;
    }
    late final Future<LoadFailure?> reading;
    reading = _fetchMonth(first, generation).whenComplete(() {
      // Only its own entry (a load since may have put another there), and not an arrow: the removed future returned
      // from here would be waited for by itself.
      if (identical(_reading[key], reading)) {
        unawaited(_reading.remove(key));
      }
    });
    _reading[key] = reading;
    return reading;
  }

  Future<LoadFailure?> _fetchMonth(DateTime first, int generation) async {
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
        emit(
          state.copyWith(
            daysByMonth: {...state.daysByMonth, monthKey(first): days},
            incompleteMonths: value.complete || value.oldest == null
                ? null
                : {...state.incompleteMonths, monthKey(first): value.oldest!},
            failure: state.failure,
          ),
        );
        return null;
    }
  }

  /// Count the days in a row up to today, after the count in progress.
  Future<void> _followStreak(int generation) => _streakRun = _streakRun.then((_) => _countStreak(generation));

  /// Count the days in a row up to today, reading earlier months while the row reaches back into one not read.
  Future<void> _countStreak(int generation) async {
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
      // The row ends where the records of an incomplete month end: a day that is not older than the oldest record
      // read may only be missing. A break inside what was read is a break.
      final cut = state.incompleteMonths[monthKey(row.before)];
      final atLeast = cut != null && !row.before.isAfter(DateTime(cut.year, cut.month, cut.day));
      if (state.streak != row.length || state.streakAtLeast != atLeast) {
        emit(state.copyWith(streak: row.length, streakAtLeast: atLeast, failure: state.failure));
      }
      if (state.daysByMonth.containsKey(monthKey(row.before)) || monthsBack >= _streakMonthsLimit) {
        return;
      }
      final failure = await _readMonth(_firstOf(row.before), generation);
      if (failure != null) {
        // Told like a month that failed: the row stays as far as it was counted.
        if (generation == _generation) {
          emit(state.copyWith(failure: failure));
        }
        return;
      }
    }
  }
}
