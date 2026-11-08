import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/points/bloc/points_trend_cubit.dart';
import 'package:tsdm_client/features/points/utils/points_trend.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
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
    final weekLabels = [
      for (var week = 0; week < weekly.length; week++)
        shortDate(DateTime(today.year, today.month, today.day - (weekly.length - week) * 7 + 1)),
    ];
    return AppCenteredList(
      builder: (context, side, width) => ListView(
        padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
        children: [
          if (state.kinds.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < state.kinds.length; i++)
                  ChoiceChip(
                    key: ValueKey('trend-kind-$i'),
                    label: Text(state.kinds[i]),
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
            child: NetBarChart(key: const ValueKey('trend-bars'), values: weekly, labels: weekLabels),
          ),
        ],
      ),
    );
  }
}
