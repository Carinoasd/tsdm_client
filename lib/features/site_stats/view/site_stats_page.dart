import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/site_stats/cubit/site_stats_cubit.dart';
import 'package:tsdm_client/features/site_stats/models/site_stats.dart';
import 'package:tsdm_client/features/site_stats/repository/site_stats_repository.dart';
import 'package:tsdm_client/features/site_stats/widgets/site_stats_chart_view.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';

/// The forum's statistics (`misc.php?mod=stat`), read only: the tabs the forum offers the viewer, each page's tables
/// and its trend.
///
/// A link of a table into the statistics (a forum's daily log, a month, a moderator's work) opens another page; the
/// tabs, the months and the pages of a list replace the one shown. Other links go where the app opens them.
class SiteStatsPage extends StatelessWidget {
  /// Constructor.
  const SiteStatsPage({this.url, this.repository, super.key});

  /// The page to show, absolute; the first one (基本概况) when null or not a page of the statistics on the forum
  /// ([SiteStatsRepository.isStatsUrl]).
  final String? url;

  /// Repository override (tests); the real one is used when null.
  final SiteStatsRepository? repository;

  @override
  Widget build(BuildContext context) => RepositoryProvider(
    create: (_) => repository ?? SiteStatsRepository(),
    child: BlocProvider(
      create: (context) {
        final given = url;
        final cubit = SiteStatsCubit(
          url: given != null && SiteStatsRepository.isStatsUrl(given) ? given : SiteStatsRepository.basicUrl,
          repository: context.read(),
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: const _SiteStatsView(),
    ),
  );
}

class _SiteStatsView extends StatefulWidget {
  const _SiteStatsView();

  @override
  State<_SiteStatsView> createState() => _SiteStatsViewState();
}

class _SiteStatsViewState extends State<_SiteStatsView> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  /// Open the link [url] of a table: another page of the statistics, or wherever the app opens it.
  Future<void> _openLink(BuildContext context, String url) async {
    if (SiteStatsRepository.isStatsUrl(url)) {
      await context.pushNamed(ScreenPaths.siteStats, queryParameters: {'url': url});
      return;
    }
    await context.dispatchAsUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.siteStatsPage;
    return BlocConsumer<SiteStatsCubit, SiteStatsState>(
      // A refresh that failed keeps the page on screen and says so.
      listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing && curr.failure != null,
      listener: (context, state) {
        final cubit = context.read<SiteStatsCubit>();
        showRefreshFailedSnackBar(
          context,
          state.failure,
          onRetry: () {
            if (!cubit.isClosed) {
              unawaited(cubit.load());
            }
          },
        );
      },
      builder: (context, state) {
        final cubit = context.read<SiteStatsCubit>();
        if (!state.refreshing) {
          _refreshController.finishRefresh();
        }
        final page = state.page;
        final title = page?.title ?? '';
        final tabs = state.tabs;
        final body = switch (state.status) {
          SiteStatsStatus.loading => const ThreadListSkeleton(),
          SiteStatsStatus.failed => FailureView(failure: state.failure, onRetry: cubit.load),
          SiteStatsStatus.success => _buildPage(context, page!),
        };
        return Scaffold(
          appBar: AppBar(
            title: Text(title.isEmpty ? tr.title : title),
            bottom: tabs.isEmpty
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(52),
                    child: _LinkChips(
                      keyPrefix: 'site-stats-tab',
                      links: tabs,
                      isSelected: (tab) => (state.page?.tabs.isNotEmpty ?? false)
                          ? state.page!.tabs.any((e) => e.selected && e.url == tab.url)
                          : tab.url == state.url,
                      onSelected: (tab) async => cubit.open(tab.url),
                    ),
                  ),
          ),
          body: SafeArea(bottom: false, child: body),
        );
      },
    );
  }

  Widget _buildPage(BuildContext context, SiteStatsData page) {
    final cubit = context.read<SiteStatsCubit>();
    final tr = context.t.siteStatsPage;
    final theme = Theme.of(context);
    final chart = page.chart;
    final hasPager = page.nextPageUrl != null || page.previousPageUrl != null;
    final children = <Widget>[
      if (page.months.isNotEmpty)
        _LinkChips(
          keyPrefix: 'site-stats-month',
          links: page.months,
          isSelected: (e) => e.selected,
          onSelected: (e) async => cubit.open(e.url),
          padding: EdgeInsets.zero,
        ),
      if (page.heading case final heading?) Text(context.displayText(heading), style: theme.textTheme.titleSmall),
      if (chart != null && !chart.isEmpty)
        AppSurface(
          key: const ValueKey('site-stats-chart'),
          child: SiteStatsChartView(chart),
        ),
      for (final table in page.tables) _TableCard(table, onLink: (url) async => _openLink(context, url)),
      if (hasPager)
        Center(
          child: AppPager(
            key: const ValueKey('site-stats-pager'),
            current: page.currentPage,
            total: page.totalPages,
            onPrevious: page.previousPageUrl == null ? null : () async => cubit.open(page.previousPageUrl!),
            onNext: page.nextPageUrl == null ? null : () async => cubit.open(page.nextPageUrl!),
          ),
        ),
      if (page.note case final note?)
        Text(
          context.displayText(note),
          key: const ValueKey('site-stats-note'),
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
        ),
    ];
    return EasyRefresh.builder(
      controller: _refreshController,
      header: const MaterialHeader(),
      onRefresh: cubit.load,
      childBuilder: (context, physics) => page.tables.isEmpty && (chart == null || chart.isEmpty)
          ? AppScrollableStateView(
              physics: physics,
              child: AppStateView(icon: Icons.query_stats_outlined, message: tr.empty, scrollable: false),
            )
          : AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                key: const ValueKey('site-stats-list'),
                physics: physics,
                padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
                itemCount: children.length,
                itemBuilder: (context, index) => children[index],
                separatorBuilder: (_, _) => const SizedBox(height: appSurfaceGap),
              ),
            ),
    );
  }
}

/// A row of choices that replace the page shown: the tabs of the statistics, the months of the moderation work.
class _LinkChips extends StatelessWidget {
  const _LinkChips({
    required this.keyPrefix,
    required this.links,
    required this.isSelected,
    required this.onSelected,
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 8),
  });

  final String keyPrefix;

  final List<SiteStatsLink> links;

  final bool Function(SiteStatsLink link) isSelected;

  final ValueChanged<SiteStatsLink> onSelected;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: padding,
    child: Row(
      spacing: 8,
      children: [
        for (final (i, link) in links.indexed)
          ChoiceChip(
            key: ValueKey('$keyPrefix-$i'),
            label: Text(context.displayText(link.label)),
            selected: isSelected(link),
            onSelected: (_) => onSelected(link),
          ),
      ],
    ),
  );
}

/// One table of the statistics: labeled values in a grid for a table of pairs, else the forum's grid of rows,
/// scrolled sideways when it is wider than the window.
class _TableCard extends StatelessWidget {
  const _TableCard(this.table, {required this.onLink});

  final SiteStatsTable table;

  final ValueChanged<String> onLink;

  Widget _cellText(BuildContext context, SiteStatsCell cell, {TextStyle? style}) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = cell.url;
    final text = Text(
      context.displayText(cell.text),
      style: url == null ? style : (style ?? const TextStyle()).copyWith(color: colorScheme.primary),
    );
    if (url == null) {
      return text;
    }
    return InkWell(onTap: () => onLink(url), child: text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final valueStyle = theme.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final headerStyle = theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final Widget content;
    if (table.isKeyValue) {
      content = LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 560 ? 3 : 2;
          final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (label, value) in table.pairs)
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.displayText(label.text), style: labelStyle),
                      _cellText(context, value, style: valueStyle),
                    ],
                  ),
                ),
            ],
          );
        },
      );
    } else {
      final columns = table.rows.fold(0, (n, row) => row.length > n ? row.length : n);
      content = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(horizontalInside: BorderSide(color: theme.colorScheme.outlineVariant)),
          children: [
            for (final row in table.rows)
              TableRow(
                children: [
                  for (var i = 0; i < columns; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: i < row.length
                          ? _cellText(context, row[i], style: row[i].header ? headerStyle : bodyStyle)
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
          ],
        ),
      );
    }
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (table.title case final title?) AppSectionHeader(title, padding: const EdgeInsets.only(bottom: 8)),
          content,
        ],
      ),
    );
  }
}
