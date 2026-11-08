import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/widgets/charts/chart_format.dart';

/// Bars over named steps: a positive value rises in the primary color, a negative one falls in the error color.
class NetBarChart extends StatelessWidget {
  /// Constructor.
  const NetBarChart({required this.values, required this.labels, this.height = 200, super.key});

  /// The value of every bar, left to right.
  final List<int> values;

  /// The label under every bar, as many as [values].
  final List<String> labels;

  /// Height of the chart.
  final double height;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant);
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: colorScheme.outlineVariant, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(compactNumber(value), style: labelStyle),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (value, meta) {
                  final index = value.round();
                  if (index < 0 || index >= labels.length) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(labels[index], style: labelStyle),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
                '${labels[groupIndex]}  ${signedNumber(rod.toY)}',
                textTheme.labelMedium!.copyWith(color: colorScheme.onInverseSurface),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < values.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: values[i].toDouble(),
                    color: values[i] >= 0 ? colorScheme.primary : colorScheme.error,
                    width: 14,
                    borderRadius: BorderRadius.vertical(
                      top: values[i] >= 0 ? const Radius.circular(3) : Radius.zero,
                      bottom: values[i] < 0 ? const Radius.circular(3) : Radius.zero,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
