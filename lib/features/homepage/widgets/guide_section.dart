import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/homepage/cubit/guide_index_cubit.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_feed.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/reading_progress/cubit/reading_progress_cubit.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Opens the full guide list page ([ScreenPaths.latestThread]) for [url], titled [title].
Future<void> _openGuideList(BuildContext context, String url, String title) async =>
    context.pushNamed(ScreenPaths.latestThread, queryParameters: {'url': url, 'title': title});

/// Homepage section showing the modules of the forum guide index page (GitHub #12).
///
/// `forum.php?mod=guide&view=index` lists 最新热门, 最新精华, 最新回复 and 最新发表 with a handful of threads each.
/// The modules are tabs of one card so the threads start right below the tab row instead of four stacked cards; the
/// 更多 button opens the full list page of the selected module and 抢沙发, which the page only offers in its nav row,
/// opens its list page. The section owns its [GuideIndexCubit]: the homepage rebuilds this widget after every refresh,
/// so the page is fetched again together with the rest of the homepage.
///
/// Without a [repository] the section takes the guide from the app's [GuideFeed] when there is one: the request the
/// homepage asked together with its own page, and the modules saved for the account at the last start, shown while
/// the guide is asked again.
class GuideSection extends StatelessWidget {
  /// Constructor.
  const GuideSection({this.maxCount = 10, this.repository, super.key});

  /// Maximum number of threads shown per module; the page lists more, the rest is one tap away.
  final int maxCount;

  /// Repository override (tests); the real one is used when null.
  final GuideIndexRepository? repository;

  @override
  Widget build(BuildContext context) {
    final feed = repository == null ? context.readOrNull<GuideFeed>() : null;
    return BlocProvider(
      create: (_) {
        final cubit = GuideIndexCubit(
          repository ?? const GuideIndexRepository(),
          feed: feed,
          saved: feed?.savedModules,
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocBuilder<GuideIndexCubit, GuideIndexState>(
        builder: (context, state) => _GuideFeedCard(state, maxCount: maxCount),
      ),
    );
  }
}

class _GuideFeedCard extends StatefulWidget {
  const _GuideFeedCard(this.state, {required this.maxCount});

  final GuideIndexState state;
  final int maxCount;

  @override
  State<_GuideFeedCard> createState() => _GuideFeedCardState();
}

class _GuideFeedCardState extends State<_GuideFeedCard> {
  /// View key of the selected module, kept across reloads; the first module when unknown.
  String? _selectedView;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guide;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final state = widget.state;
    final modules = state.modules;
    final matching = modules.where((e) => e.view == _selectedView);
    final selected = matching.isNotEmpty ? matching.first : (modules.isNotEmpty ? modules.first : null);

    final Widget body;
    final retry = ListTile(
      leading: const Icon(Icons.refresh_outlined),
      title: Text(tr.failed),
      onTap: () async => context.read<GuideIndexCubit>().load(),
    );
    if ((state.status == GuideIndexStatus.initial || state.status == GuideIndexStatus.loading) && modules.isEmpty) {
      body = const Padding(padding: edgeInsetsL12T12R12B12, child: CenteredCircularIndicator());
    } else if (state.status == GuideIndexStatus.failure && selected == null) {
      body = retry;
    } else if (state.status == GuideIndexStatus.failure) {
      // The modules saved at the last start stay when asking for them again failed.
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          GuideModuleList(selected!, maxCount: widget.maxCount),
          retry,
        ],
      );
    } else if (selected == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(tr.empty, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
      );
    } else {
      body = GuideModuleList(selected, maxCount: widget.maxCount);
    }

    // Read row by row: on the page itself, no panel around it.
    final line = AppSurfaces.of(context).line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.t.homepage.guideTitle,
                  style: homeSectionTitleStyle(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('guide-sofa'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  foregroundColor: colorScheme.onSurfaceVariant,
                  iconColor: colorScheme.onSurfaceVariant,
                  side: BorderSide(color: AppSurfaces.of(context).lineStrong),
                  textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w400),
                ),
                icon: const Icon(Icons.weekend_outlined, size: 18),
                label: Text(tr.sofa),
                onPressed: () async => _openGuideList(context, guideUrl('sofa'), tr.sofa),
              ),
              if (selected != null)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  onPressed: () async => _openGuideList(context, selected.moreUrl, selected.title),
                  icon: const Icon(Icons.chevron_right_outlined),
                  iconAlignment: IconAlignment.end,
                  label: Text(tr.more),
                ),
            ],
          ),
        ),
        if (modules.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, module) in modules.indexed) ...[
                  if (i > 0) const SizedBox(width: homeTabGap),
                  HomeCardTab(
                    label: module.title,
                    selected: module == selected,
                    onTap: () => setState(() => _selectedView = module.view),
                  ),
                ],
              ],
            ),
          ),
        Divider(height: 1, thickness: 1, color: line),
        body,
      ],
    );
  }
}

/// Threads of one guide module, up to [maxCount], or the page's own empty message.
class GuideModuleList extends StatelessWidget {
  /// Constructor.
  const GuideModuleList(this.module, {this.maxCount = 10, super.key});

  /// The module to show.
  final GuideModule module;

  /// Maximum number of threads shown.
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guide;
    final colorScheme = Theme.of(context).colorScheme;
    final filters = currentBlockList(context).filters;
    final shown = module.items.where((e) => !filters.hides(title: e.title, fid: int.tryParse(e.fid ?? ''))).toList();
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          module.emptyMessage ?? tr.empty,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    final items = shown.take(maxCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, item) in items.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: AppSurfaces.of(context).line),
          _GuideItemTile(item),
        ],
      ],
    );
  }
}

/// Width of the homepage guide from which a thread is one row: title, forum, replied mark and the extra text.
const _guideOneLineWidth = 600.0;

/// One thread row: title (highlighted ones in the error color like the red titles on the page), the forum tag and the
/// module specific extra text (participants / time) at the end; two lines on phones, one on wide layouts.
class _GuideItemTile extends StatelessWidget {
  const _GuideItemTile(this.item);

  final GuideItem item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final forumName = item.forumName;
    final extra = item.extra;
    final visited = visitMarkOf(context, item.tid) != null;
    final replied = isThreadReplied(context, item.tid);
    Widget title({required int maxLines}) => Text(
      item.title,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      // A thread read before is dimmed and no longer bold, as in the thread lists; a highlighted one keeps its color.
      style: visitedTitleStyle(
        context,
        textTheme.bodyLarge?.copyWith(
          fontSize: 15.5,
          height: 1.5,
          color: item.highlighted ? colorScheme.error : colorScheme.onSurface,
          fontWeight: item.highlighted || !visited ? FontWeight.w700 : FontWeight.w400,
        ),
        visited: visited,
        background: surfaces.page,
      ),
    );
    final repliedMark = Tooltip(
      message: context.t.threadCard.replied,
      child: Icon(Icons.reply_outlined, size: 16, color: colorScheme.tertiary),
    );
    final extraText = extra == null
        ? null
        : Text(
            extra,
            maxLines: 1,
            style: textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              color: surfaces.muted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    return Semantics(
      button: true,
      child: InkWell(
        onTap: () async => context.pushNamed(
          ScreenPaths.threadV1,
          queryParameters: {'tid': item.tid, 'appBarTitle': item.title},
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= _guideOneLineWidth) {
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Expanded(child: title(maxLines: 1)),
                      if (forumName != null) ...[
                        sizedBoxW12H12,
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: _ForumChip(name: forumName, fid: item.fid),
                        ),
                      ],
                      if (replied) ...[sizedBoxW8H8, repliedMark],
                      if (extraText != null) ...[sizedBoxW12H12, extraText],
                    ],
                  ),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title(maxLines: 2),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            if (forumName != null)
                              Flexible(
                                child: _ForumChip(name: forumName, fid: item.fid),
                              ),
                            if (replied) ...[sizedBoxW8H8, repliedMark],
                          ],
                        ),
                      ),
                      if (extraText != null) ...[sizedBoxW8H8, extraText],
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Small forum name tag, neutral; opens the forum when its id is known.
class _ForumChip extends StatelessWidget {
  const _ForumChip({required this.name, required this.fid});

  final String name;
  final String? fid;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fid = this.fid;
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: fid == null
            ? null
            : () async => context.pushNamed(
                ScreenPaths.forum,
                pathParameters: {'fid': fid},
                queryParameters: {'appBarTitle': name},
              ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: AppSurfaces.of(context).card, borderRadius: BorderRadius.circular(5)),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontSize: 12, height: 1.4, color: colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
