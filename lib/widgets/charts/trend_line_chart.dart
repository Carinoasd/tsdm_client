import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/widgets/charts/chart_format.dart';

/// A line over days: [values] oldest first, the last one on [end]. Touching a point tells its day and value.
class TrendLineChart extends StatelessWidget {
  /// Constructor.
  const TrendLineChart({required this.values, required this.end, this.height = 220, super.key});

  /// The value of every day, oldest first.
  final List<int> values;

  /// The day of the last value.
  final DateTime end;

  /// Height of the chart.
  final double height;

  DateTime _dayOf(int index) => DateTime(end.year, end.month, end.day - (values.length - 1 - index));

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant);
    final spots = [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i].toDouble())];
    final step = (values.length / 4).ceil().clamp(1, values.length);
    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: (values.length - 1).toDouble(),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: colorScheme.outlineVariant, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(
            horizontalLines: [HorizontalLine(y: 0, color: colorScheme.outline, strokeWidth: 1)],
          ),
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
                // Every index is asked and the filter below keeps the ones that count back from the last day by [step]:
                // a bigger interval would tick at 0, 8, 16... and meet the filter only at the end.
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final index = value.round();
                  if (index < 0 || index >= values.length || (values.length - 1 - index) % step != 0) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(shortDate(_dayOf(index)), style: labelStyle),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => [
                for (final spot in touched)
                  LineTooltipItem(
                    '${shortDate(_dayOf(spot.x.round()))}  ${signedNumber(spot.y)}',
                    textTheme.labelMedium!.copyWith(color: colorScheme.onInverseSurface),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              color: colorScheme.primary,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: colorScheme.primary.withValues(alpha: 0.12)),
            ),
          ],
        ),
      ),
    );
  }
}
