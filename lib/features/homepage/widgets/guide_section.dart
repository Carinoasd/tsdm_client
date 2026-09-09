import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/homepage/cubit/guide_index_cubit.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Opens the full guide list page ([ScreenPaths.latestThread]) for [url], titled [title].
Future<void> _openGuideList(BuildContext context, String url, String title) async =>
    context.pushNamed(ScreenPaths.latestThread, queryParameters: {'url': url, 'title': title});

/// Homepage section showing the modules of the forum guide index page (GitHub #12).
///
/// `forum.php?mod=guide&view=index` lists 最新热门, 最新精华, 最新回复 and 最新发表 with a handful of threads each;
/// every module becomes a [GuideModuleCard] and a chip row on top links the full list pages, including 抢沙发 which
/// the page only offers in its nav row. The section owns its [GuideIndexCubit]: the homepage rebuilds this widget
/// after every refresh, so the page is fetched again together with the rest of the homepage.
class GuideSection extends StatelessWidget {
  /// Constructor.
  const GuideSection({this.maxCount = 10, this.repository, super.key});

  /// Maximum number of threads shown per module; the page lists more, the rest is one tap away.
  final int maxCount;

  /// Repository override (tests); the real one is used when null.
  final GuideIndexRepository? repository;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final cubit = GuideIndexCubit(repository ?? const GuideIndexRepository());
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocBuilder<GuideIndexCubit, GuideIndexState>(
        builder: (context, state) {
          final tr = context.t.homepage.guide;
          final body = switch (state.status) {
            GuideIndexStatus.initial || GuideIndexStatus.loading when state.modules.isEmpty => const Card(
              margin: EdgeInsets.zero,
              child: Padding(padding: edgeInsetsL12T12R12B12, child: CenteredCircularIndicator()),
            ),
            GuideIndexStatus.failure => Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.refresh_outlined),
                title: Text(tr.failed),
                onTap: () async => context.read<GuideIndexCubit>().load(),
              ),
            ),
            _ => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, module) in state.modules.indexed) ...[
                  if (i > 0) sizedBoxW12H12,
                  GuideModuleCard(module, maxCount: maxCount),
                ],
              ],
            ),
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_GuideNavRow(state.modules), sizedBoxW12H12, body],
          );
        },
      ),
    );
  }
}

/// Quick links to the full list pages: one chip per module plus 抢沙发, like the nav row of the guide page.
class _GuideNavRow extends StatelessWidget {
  const _GuideNavRow(this.modules);

  final List<GuideModule> modules;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guide;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final module in modules)
          ActionChip(
            label: Text(module.title),
            onPressed: () async => _openGuideList(context, module.moreUrl, module.title),
          ),
        ActionChip(
          key: const ValueKey('guide-sofa'),
          avatar: const Icon(Icons.weekend_outlined),
          label: Text(tr.sofa),
          onPressed: () async => _openGuideList(context, guideUrl('sofa'), tr.sofa),
        ),
      ],
    );
  }
}

/// Card of one guide module: title, 更多 button and up to [maxCount] threads.
class GuideModuleCard extends StatelessWidget {
  /// Constructor.
  const GuideModuleCard(this.module, {this.maxCount = 10, super.key});

  /// The module to show.
  final GuideModule module;

  /// Maximum number of threads shown.
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guide;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: edgeInsetsT8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                sizedBoxW12H12,
                Expanded(
                  child: Text(module.title, style: textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                ),
                TextButton.icon(
                  onPressed: () async => _openGuideList(context, module.moreUrl, module.title),
                  icon: const Icon(Icons.chevron_right_outlined),
                  iconAlignment: IconAlignment.end,
                  label: Text(tr.more),
                ),
                sizedBoxW4H4,
              ],
            ),
            if (module.items.isEmpty)
              Padding(
                padding: edgeInsetsL12R12B12,
                child: Text(
                  module.emptyMessage ?? tr.empty,
                  style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
                ),
              )
            else ...[
              ...module.items.take(maxCount).map(_GuideItemTile.new),
              sizedBoxW8H8,
            ],
          ],
        ),
      ),
    );
  }
}

/// One thread row: title (highlighted ones in the error color like the red titles on the page), the forum chip and
/// the module specific extra text (participants / time) on the right of the second line.
class _GuideItemTile extends StatelessWidget {
  const _GuideItemTile(this.item);

  final GuideItem item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final forumName = item.forumName;
    final extra = item.extra;
    return InkWell(
      onTap: () async => context.pushNamed(
        ScreenPaths.threadV1,
        queryParameters: {'tid': item.tid, 'appBarTitle': item.title},
      ),
      child: Padding(
        padding: edgeInsetsL12T4R12B4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyLarge?.copyWith(
                color: item.highlighted ? colorScheme.error : null,
                fontWeight: item.highlighted ? FontWeight.bold : null,
              ),
            ),
            sizedBoxW4H4,
            Row(
              children: [
                if (forumName != null) _ForumChip(name: forumName, fid: item.fid),
                if (isThreadReplied(context, item.tid)) ...[
                  sizedBoxW4H4,
                  Icon(Icons.reply_outlined, size: 14, color: colorScheme.outline),
                ],
                const Spacer(),
                if (extra != null)
                  Text(extra, style: textTheme.bodySmall?.copyWith(color: colorScheme.outline), maxLines: 1),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small forum name tag; opens the forum when its id is known.
class _ForumChip extends StatelessWidget {
  const _ForumChip({required this.name, required this.fid});

  final String name;
  final String? fid;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fid = this.fid;
    return Flexible(
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: fid == null
            ? null
            : () async => context.pushNamed(
                ScreenPaths.forum,
                pathParameters: {'fid': fid},
                queryParameters: {'appBarTitle': name},
              ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}
