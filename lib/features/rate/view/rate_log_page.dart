import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/rate/bloc/rate_log_cubit.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/rate/widgets/fast_rate_template_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';

/// Page to view all rate log for a post.
class RateLogPage extends StatefulWidget {
  /// Constructor.
  const RateLogPage({required this.tid, required this.pid, this.threadTitle, this.total, super.key});

  /// Thread id.
  final String tid;

  /// Post id.
  final String pid;

  /// Optional thread title.
  final String? threadTitle;

  /// TotalStatus.
  final String? total;

  @override
  State<RateLogPage> createState() => _RateLogPageState();
}

class _RateLogPageState extends State<RateLogPage> with SingleTickerProviderStateMixin {
  late final TabController tabController;

  /// One rate log surface: rater (avatar, name, time) on top, scores as chips, the reason quoted under them.
  Widget _buildLogCard({
    required String uid,
    required String username,
    required String time,
    required String reason,
    required List<Widget> scores,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppSurface(
      onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': uid}),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              HeroUserAvatar(username: username, avatarUrl: null, disableHero: true),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(time, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
                  ],
                ),
              ),
            ],
          ),
          sizedBoxW8H8,
          Wrap(spacing: 6, runSpacing: 6, children: scores),
          if (reason.isNotEmpty) ...[sizedBoxW8H8, QuotedText(reason)],
        ],
      ),
    );
  }

  Widget _buildAccumulatedCard(RateLogAccumulatedItem logItem) => _buildLogCard(
    uid: logItem.uid,
    username: logItem.username,
    time: logItem.firstRateTime != logItem.lastRateTime
        ? '${logItem.firstRateTime.yyyyMMDDHHMMSS()} ~ ${logItem.lastRateTime.yyyyMMDDHHMMSS()}'
        : logItem.firstRateTime.yyyyMMDDHHMMSS(),
    reason: logItem.reason,
    scores: [for (final attr in logItem.attrMap.entries) RateScoreChip(name: attr.key, value: attr.value)],
  );

  Widget _buildSimpleCard(RateLogItem logItem) => _buildLogCard(
    uid: logItem.uid,
    username: logItem.username,
    time: logItem.time.yyyyMMDDHHMMSS(),
    reason: logItem.reason,
    scores: [RateScoreChip(name: logItem.attrName, value: logItem.attrValue)],
  );

  Widget _buildList(int count, IndexedWidgetBuilder builder) {
    if (count == 0) {
      return AppStateView(icon: Icons.thumbs_up_down_outlined, message: context.t.rateLogPage.empty);
    }
    return AppCenteredList(
      builder: (context, horizontal, width) => ListView.separated(
        padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)).add(context.safePadding()),
        separatorBuilder: (_, _) => appListSeparator,
        itemCount: count,
        itemBuilder: builder,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.rateLogPage;

    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => RateRepository()),
        BlocProvider(
          create: (context) {
            final cubit = RateLogCubit(context.repo());
            unawaited(cubit.fetchLog(tid: widget.tid, pid: widget.pid));
            return cubit;
          },
        ),
      ],
      child: BlocBuilder<RateLogCubit, RateLogState>(
        builder: (context, state) {
          final body = switch (state.status) {
            RateLogStatus.initial || RateLogStatus.loading => const CenteredCircularIndicator(),
            RateLogStatus.failure => FailureView(
              failure: state.failure,
              onRetry: () => context.read<RateLogCubit>().fetchLog(tid: widget.tid, pid: widget.pid),
            ),
            RateLogStatus.success => TabBarView(
              controller: tabController,
              children: [
                _buildList(
                  state.accumulatedLogItems.length,
                  (_, idx) => _buildAccumulatedCard(state.accumulatedLogItems[idx]),
                ),
                _buildList(state.logItems.length, (_, idx) => _buildSimpleCard(state.logItems[idx])),
              ],
            ),
          };

          return Scaffold(
            appBar: AppBar(
              title: Text(tr.title),
              actions: [
                if (widget.total != null)
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    tooltip: tr.showTotalRatePointsTip,
                    onPressed: () async =>
                        showMessageSingleButtonDialog(context: context, title: tr.total, message: widget.total!),
                  ),
              ],
              bottom: state.status != RateLogStatus.success
                  ? null
                  : TabBar(
                      controller: tabController,
                      tabs: [
                        Tab(text: tr.tabs.accumulated),
                        Tab(text: tr.tabs.original),
                      ],
                    ),
            ),
            body: body,
          );
        },
      ),
    );
  }
}
