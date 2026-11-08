import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_calendar_cubit.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/charts/month_calendar.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page of the check-in calendar: the days of a month the account checked in, with the days of the month, in a row and
/// in all.
class CheckinCalendarPage extends StatelessWidget {
  /// Constructor.
  const CheckinCalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.checkinCalendar;
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => PointsRepository()),
        BlocProvider(
          create: (context) {
            final cubit = CheckinCalendarCubit(fetchRange: context.repo<PointsRepository>().fetchChangelogRange);
            unawaited(cubit.load());
            return cubit;
          },
        ),
      ],
      child: Scaffold(
        appBar: AppBar(title: Text(tr.title)),
        body: BlocConsumer<CheckinCalendarCubit, CheckinCalendarState>(
          listenWhen: (prev, curr) =>
              curr.failure != null && curr.status == CheckinCalendarStatus.success && prev.failure != curr.failure,
          listener: (context, state) => showRefreshFailedSnackBar(context, state.failure),
          builder: (context, state) {
            switch (state.status) {
              case CheckinCalendarStatus.loading:
                return const CenteredCircularIndicator();
              case CheckinCalendarStatus.failed:
                return FailureView(failure: state.failure, onRetry: () => context.read<CheckinCalendarCubit>().load());
              case CheckinCalendarStatus.success:
                return _CalendarBody(state: state);
            }
          },
        ),
      ),
    );
  }
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({required this.state});

  final CheckinCalendarState state;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.checkinCalendar;
    final cubit = context.read<CheckinCalendarCubit>();
    final earliest = DateTime(state.today.year, state.today.month - checkinCalendarMonthsLimit);
    final canGoBack = state.month.isAfter(earliest);
    return AppCenteredList(
      builder: (context, side, width) => ListView(
        padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
        children: [
          AppSurface(
            child: Row(
              children: [
                Expanded(
                  child: _Stat(
                    key: const ValueKey('stat-month'),
                    label: state.isCurrentMonth ? tr.thisMonth : tr.thatMonth,
                    value: '${state.markedDays.length}',
                  ),
                ),
                Expanded(
                  child: _Stat(
                    key: const ValueKey('stat-streak'),
                    label: tr.streak,
                    value: '${state.streak}${state.streakAtLeast ? '+' : ''}',
                  ),
                ),
                if (state.totalDays case final total?)
                  Expanded(
                    child: _Stat(key: const ValueKey('stat-total'), label: tr.total, value: '$total'),
                  ),
              ],
            ),
          ),
          appListSeparator,
          AppSurface(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: state.loadingMonth ? 0.4 : 1,
                  child: MonthCalendar(
                    month: state.month,
                    marked: state.markedDays,
                    today: state.today,
                    onPrevious: canGoBack && !state.loadingMonth ? () => cubit.moveMonth(-1) : null,
                    onNext: !state.isCurrentMonth && !state.loadingMonth ? () => cubit.moveMonth(1) : null,
                  ),
                ),
                if (state.loadingMonth) const CircularIndicator(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A number with its name under it.
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          value,
          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.primary),
        ),
        Text(label, style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
