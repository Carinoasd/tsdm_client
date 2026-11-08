import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_calendar.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/rate_stats/utils/rate_stats.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/charts/chart_format.dart';
import 'package:tsdm_client/widgets/charts/net_bar_chart.dart';
import 'package:tsdm_client/widgets/charts/ranked_bars.dart';

/// Page of the rating statistics: who rated the user's posts the most, and how many ratings came each week, read
/// from the rate notices the app keeps.
class RateStatsPage extends StatelessWidget {
  /// Constructor.
  const RateStatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notices = context.select<NotificationBloc, List<NoticeV2>>((bloc) => bloc.state.noticeList);
    return RateStatsView(events: rateEventsOf(notices), today: forumToday());
  }
}

/// The statistics of [events], the weeks counted back from [today].
class RateStatsView extends StatelessWidget {
  /// Constructor.
  const RateStatsView({required this.events, required this.today, super.key});

  /// The ratings received.
  final List<RateEvent> events;

  /// Today as the forum counts it.
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.ratingStats;
    final weekly = weeklyCountsOf(events, today);
    final top = topRatersOf(events);
    final totals = scoreTotalsOf(events);
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: events.isEmpty
          ? AppStateView(icon: Icons.thumb_up_alt_outlined, message: context.t.general.noData, scrollable: false)
          : AppCenteredList(
              builder: (context, side, width) => ListView(
                padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
                children: [
                  AppSurface(
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: [
                        _Total(key: const ValueKey('rate-total-count'), label: tr.count, value: '${events.length}'),
                        for (final MapEntry(:key, :value) in totals.entries)
                          _Total(label: key, value: signedNumber(value)),
                      ],
                    ),
                  ),
                  appListSeparator,
                  AppSurface(
                    child: NetBarChart(
                      key: const ValueKey('rate-weekly'),
                      values: weekly,
                      labels: [
                        for (var week = 0; week < weekly.length; week++)
                          shortDate(DateTime(today.year, today.month, today.day - (weekly.length - week) * 7 + 1)),
                      ],
                    ),
                  ),
                  appListSeparator,
                  AppSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppSectionHeader(tr.topRaters, icon: Icons.emoji_events_outlined),
                        RankedBars(
                          items: [
                            for (final rater in top)
                              RankedBarItem(
                                label: rater.rater,
                                value: rater.count,
                                detail: rater.scores.entries.map((e) => '${e.key} ${signedNumber(e.value)}').join('  '),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value, super.key});

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
