import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/points/bloc/points_trend_cubit.dart';
import 'package:tsdm_client/features/points/utils/points_trend.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/charts/chart_format.dart';
import 'package:tsdm_client/widgets/charts/net_bar_chart.dart';
import 'package:tsdm_client/widgets/charts/trend_line_chart.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The points trend: the net change of a kind of points per day over the last 30 days and per week over the last 8,
/// the kind chosen from the chips above.
class PointsTrendTab extends StatelessWidget {
  /// Constructor.
  const PointsTrendTab({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PointsTrendCubit, PointsTrendState>(
      listenWhen: (prev, curr) => curr.status == PointsTrendStatus.success && curr.failure != null,
      listener: (context, state) => showRefreshFailedSnackBar(
        context,
        state.failure,
        onRetry: () => context.read<PointsTrendCubit>().load(),
      ),
      builder: (context, state) {
        switch (state.status) {
          case PointsTrendStatus.loading:
            return const CenteredCircularIndicator();
          case PointsTrendStatus.failed:
            return FailureView(failure: state.failure, onRetry: () => context.read<PointsTrendCubit>().load());
          case PointsTrendStatus.success:
            final kind = state.kind;
            if (kind == null) {
              return AppStateView(
                icon: Icons.show_chart_outlined,
                message: context.t.general.noData,
                scrollable: false,
              );
            }
            return _TrendBody(state: state, kind: kind);
        }
      },
    );
  }
}

class _TrendBody extends StatelessWidget {
  const _TrendBody({required this.state, required this.kind});

  final PointsTrendState state;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final daily = dailyNetOf(state.changes, kind, state.today);
    final weekly = weeklyNetOf(state.changes, kind, state.today);
    final today = state.today;
    final weekStarts = [
      for (var week = 0; week < weekly.length; week++)
        DateTime(today.year, today.month, today.day - (weekly.length - week) * 7 + 1),
    ];
    // A read cut at the page limit misses what is older than its oldest record: the weeks that reach back that far
    // may be short (the day of the oldest record itself too).
    final oldest = state.oldest;
    final cutAt = state.complete || oldest == null ? null : DateTime(oldest.year, oldest.month, oldest.day);
    final dimmed = {
      for (var week = 0; week < weekStarts.length; week++)
        if (cutAt != null && !weekStarts[week].isAfter(cutAt)) week,
    };
    return AppCenteredList(
      builder: (context, side, width) => ListView(
        padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (var i = 0; i < state.kinds.length; i++)
                ChoiceChip(
                  key: ValueKey('trend-kind-$i'),
                  label: Text(context.displayText(state.kinds[i])),
                  selected: i == state.selected,
                  onSelected: (_) => context.read<PointsTrendCubit>().select(i),
                ),
            ],
          ),
          appListSeparator,
          AppSurface(
            child: TrendLineChart(key: const ValueKey('trend-line'), values: daily, end: today),
          ),
          appListSeparator,
          AppSurface(
            child: NetBarChart(
              key: const ValueKey('trend-bars'),
              values: weekly,
              labels: [for (final start in weekStarts) shortDate(start)],
              dimmed: dimmed,
            ),
          ),
        ],
      ),
    );
  }
}
