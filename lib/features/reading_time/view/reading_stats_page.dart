import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/reading_time/models/reading_time_summary.dart';
import 'package:tsdm_client/features/reading_time/repository/reading_time_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The text of [seconds] read: seconds below a minute, minutes below an hour, hours and minutes above.
String formatReadingTime(Translations t, int seconds) {
  if (seconds < 60) {
    return t.readingStats.seconds(seconds: seconds);
  }
  final minutes = seconds ~/ 60;
  if (minutes < 60) {
    return t.readingStats.minutes(minutes: minutes);
  }
  return t.readingStats.hoursMinutes(hours: minutes ~/ 60, minutes: minutes % 60);
}

/// Page of the time spent reading threads: today, this week, this month, each of the last days and the forums read the
/// most.
class ReadingStatsPage extends StatefulWidget {
  /// Constructor.
  const ReadingStatsPage({super.key, this.store, this.now, this.uid});

  /// Where the time is kept; the database by default.
  final ReadingTimeStore? store;

  /// The time of "now"; the clock by default.
  final DateTime Function()? now;

  /// The account to show; the one in use by default.
  final int? uid;

  @override
  State<ReadingStatsPage> createState() => _ReadingStatsPageState();
}

class _ReadingStatsPageState extends State<ReadingStatsPage> {
  ReadingTimeSummary? _summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final now = (widget.now ?? DateTime.now)();
    final uid = widget.uid ?? context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid;
    final store = widget.store ?? StorageReadingTimeStore(getIt.get<StorageProvider>());
    // The month may start before the last 14 days: read whichever reaches further back.
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(now.year, now.month).isBefore(today.subtract(const Duration(days: 13)))
        ? DateTime(now.year, now.month)
        : today.subtract(const Duration(days: 13));
    final rows = uid == null ? const <ReadingTimeRow>[] : await store.fetch(uid: uid, from: from, to: today);
    if (!mounted) {
      return;
    }
    setState(() => _summary = ReadingTimeSummary.of(rows, now: now));
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.readingStats;
    final summary = _summary;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: summary == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _TotalsRow(summary: summary),
                const SizedBox(height: 8),
                AppSurface(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr.last14Days, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 16),
                      SizedBox(height: 180, child: _DailyBars(summary: summary)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (summary.forums.isNotEmpty)
                  AppSurface(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr.forums, style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 12),
                        for (final share in summary.forums) _ForumShareRow(share: share, total: summary.total),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.summary});

  final ReadingTimeSummary summary;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.readingStats;
    Widget cell(Key key, String label, int seconds) => Expanded(
      child: AppSurface(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            Text(
              formatReadingTime(context.t, seconds),
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
    return Row(
      children: [
        cell(const ValueKey('reading-stats-today'), tr.today, summary.today),
        const SizedBox(width: 8),
        cell(const ValueKey('reading-stats-week'), tr.week, summary.week),
        const SizedBox(width: 8),
        cell(const ValueKey('reading-stats-month'), tr.month, summary.month),
      ],
    );
  }
}

class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.summary});

  final ReadingTimeSummary summary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall;
    final days = summary.days;
    // Minutes on the axis; at least ten so a quiet day does not fill the chart.
    final maxMinutes = math.max(10, days.fold<int>(0, (m, d) => math.max(m, d.seconds)) / 60);
    return BarChart(
      key: const ValueKey('reading-stats-daily-bars'),
      BarChartData(
        maxY: maxMinutes.toDouble(),
        alignment: BarChartAlignment.spaceAround,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          topTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                // Every other day so the labels do not touch.
                if (index < 0 || index >= days.length || (days.length - 1 - index).isOdd) {
                  return const SizedBox.shrink();
                }
                final day = days[index].day;
                return SideTitleWidget(
                  meta: meta,
                  child: Text('${day.month}/${day.day}', style: style),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
              formatReadingTime(context.t, days[groupIndex].seconds),
              TextStyle(color: colors.onInverseSurface),
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < days.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: days[i].seconds / 60,
                  width: 10,
                  color: colors.primary,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ForumShareRow extends StatelessWidget {
  const _ForumShareRow({required this.share, required this.total});

  final ReadingForumShare share;
  final int total;

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : share.seconds / total;
    final name = share.fid == null || share.forumName.isEmpty ? context.t.readingStats.otherForums : share.forumName;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Text('${(fraction * 100).round()}%  ${formatReadingTime(context.t, share.seconds)}'),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: fraction, minHeight: 6),
          ),
        ],
      ),
    );
  }
}
