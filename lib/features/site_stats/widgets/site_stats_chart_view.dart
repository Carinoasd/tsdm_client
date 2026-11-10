import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/features/site_stats/models/site_stats.dart';
import 'package:tsdm_client/widgets/charts/chart_format.dart';

/// The trend of a statistics page: a line for every series over the forum's own labels (days the forum names, gaps
/// kept as it prints them), drawn like the points trend (`TrendLineChart`); with more than one line their titles are
/// the legend. Touching a point tells its label and every line's value.
class SiteStatsChartView extends StatelessWidget {
  /// Constructor.
  const SiteStatsChartView(this.chart, {this.height = 220, super.key});

  /// The trend.
  final SiteStatsChart chart;

  /// Height of the drawing.
  final double height;

  /// Color of the line at [index].
  static Color _colorOf(ColorScheme colorScheme, int index) => [
    colorScheme.primary,
    colorScheme.tertiary,
    colorScheme.secondary,
    colorScheme.error,
    colorScheme.outline,
  ][index % 5];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant);
    final labels = chart.labels;
    final step = (labels.length / 4).ceil().clamp(1, labels.length);
    final many = chart.series.length > 1;
    final drawing = SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: (labels.length - 1).toDouble().clamp(0, double.infinity),
          minY: 0,
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
                // Counted back from the last label by [step], as the points trend does.
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final index = value.round();
                  if (index < 0 || index >= labels.length || (labels.length - 1 - index) % step != 0) {
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
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => [
                for (final (i, spot) in touched.indexed)
                  LineTooltipItem(
                    [
                      if (i == 0) labels[spot.x.round().clamp(0, labels.length - 1)],
                      if (many) '${chart.series[spot.barIndex].title}  ${spot.y.round()}' else '${spot.y.round()}',
                    ].join('  '),
                    textTheme.labelMedium!.copyWith(color: colorScheme.onInverseSurface),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            for (final (i, series) in chart.series.indexed)
              LineChartBarData(
                spots: [for (final (x, y) in series.values.indexed) FlSpot(x.toDouble(), y.toDouble())],
                color: _colorOf(colorScheme, i),
                barWidth: 2.5,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: !many, color: _colorOf(colorScheme, i).withValues(alpha: 0.12)),
              ),
          ],
        ),
      ),
    );
    if (!many) {
      return drawing;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        drawing,
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final (i, series) in chart.series.indexed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 10, color: _colorOf(colorScheme, i)),
                  const SizedBox(width: 4),
                  Text(series.title, style: labelStyle),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
