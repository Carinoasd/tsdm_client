import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/features/collection/widgets/collection_dialogs.dart';
import 'package:tsdm_client/features/collection/widgets/collection_pager.dart';
import 'package:tsdm_client/features/collection/widgets/collection_tiles.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';

enum _Menu { edit, delete }

/// The page of collection [ctid]: its name, description, keywords, creator, counts and rating, the subscription,
/// the link to its comments, and its threads. Its managers edit and delete it and take threads out of it.
///
class CollectionDetailPage extends StatefulWidget {
  /// Constructor.
  const CollectionDetailPage({required this.ctid, this.repository, super.key});

  /// The collection.
  final int ctid;

  /// Repository override (tests).
  final CollectionRepository? repository;

  @override
  State<CollectionDetailPage> createState() => _CollectionDetailPageState();
}

class _CollectionDetailPageState extends State<CollectionDetailPage> {
  late final CollectionRepository _repository = widget.repository ?? CollectionRepository.network();
  late final _pager = CollectionPager<CollectionDetail, CollectionThread>(
    fetch: (page) => _repository.fetchDetail(widget.ctid, page: page),
    itemsOf: (page) => page.threads,
    pagesOf: (page) => page.totalPages,
  );

  /// A change is on its way: the buttons wait.
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_pager.refresh());
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  /// Send [change], tell its outcome, and read the page again: the forum's page is what the account sees.
  Future<CollectionOutcome?> _run(Future<CollectionOutcome> Function() change) async {
    if (_sending) {
      return null;
    }
    setState(() => _sending = true);
    final outcome = await change();
    if (!mounted) {
      return outcome;
    }
    setState(() => _sending = false);
    if (await reportCollectionOutcome(context, outcome)) {
      collectionChanges.value++;
    }
    return outcome;
  }

  Future<void> _toggleFollow(CollectionDetail detail) async {
    await _run(
      () => _repository.setFollow(detail, follow: detail.followState == CollectionFollowState.canFollow),
    );
    await _pager.refresh();
  }

  Future<void> _edit(CollectionDetail detail) async {
    final fields = await showCollectionEditDialog(
      context,
      initial: (title: detail.name, description: detail.description, keywords: detail.keywords.join(' ')),
    );
    if (fields == null || !mounted) {
      return;
    }
    await _run(
      () => _repository.edit(
        detail,
        title: fields.title,
        description: fields.description,
        keywords: fields.keywords,
      ),
    );
    await _pager.refresh();
  }

  Future<void> _delete(CollectionDetail detail) async {
    final tr = context.t.collection;
    final ok = await showQuestionDialog(
      context: context,
      title: tr.delete,
      message: tr.deleteConfirm(name: detail.name),
      dangerous: true,
    );
    if (ok != true || !mounted) {
      return;
    }
    final outcome = await _run(() => _repository.delete(detail));
    if (!mounted) {
      return;
    }
    if (outcome is CollectionDone) {
      context.pop();
      return;
    }
    await _pager.refresh();
  }

  Future<void> _remove(CollectionDetail detail, CollectionThread thread) async {
    final tr = context.t.collection;
    final ok = await showQuestionDialog(
      context: context,
      title: tr.removeThread,
      message: tr.removeConfirm(subject: thread.subject),
      dangerous: true,
    );
    if (ok != true || !mounted) {
      return;
    }
    await _run(() => _repository.removeThreads(detail, [thread.tid]));
    await _pager.refresh();
  }

  Widget _header(BuildContext context, CollectionDetail detail) {
    final theme = Theme.of(context);
    final tr = context.t.collection;
    final outline = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline);
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.displayText(detail.name), style: theme.textTheme.titleLarge),
          if (detail.description.isNotEmpty) ...[sizedBoxW8H8, SelectableText(detail.description)],
          sizedBoxW12H12,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...collectionCountPills(
                context,
                threads: detail.threadCount,
                follows: detail.followCount,
                comments: detail.commentCount,
              ),
              for (final keyword in detail.keywords)
                AppInfoPill(icon: Icons.sell_outlined, label: context.displayText(keyword)),
            ],
          ),
          if (detail.creator case final creator?) ...[
            sizedBoxW8H8,
            InkWell(
              onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${creator.uid}'}),
              child: Text(tr.creator(name: creator.name), style: outline),
            ),
          ],
          if (detail.teamworkers.isNotEmpty) ...[
            sizedBoxW4H4,
            Text(tr.teamworkers(names: detail.teamworkers.map((e) => e.name).join('、')), style: outline),
          ],
          sizedBoxW12H12,
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('collection-comments'),
                  borderRadius: BorderRadius.circular(appInnerRadius),
                  onTap: () async {
                    final before = collectionChanges.value;
                    await context.pushNamed(ScreenPaths.collectionComments, pathParameters: {'ctid': '${detail.ctid}'});
                    if (mounted && collectionChanges.value != before) {
                      await _pager.refresh();
                    }
                  },
                  child: Padding(
                    padding: edgeInsetsT4B4,
                    child: Row(
                      children: [
                        if (detail.averageRate case final rate?) ...[
                          CollectionStars(rate),
                          sizedBoxW8H8,
                          Flexible(
                            child: Text(tr.rating(rate: rate.toStringAsFixed(1), count: detail.rateCount)),
                          ),
                        ] else
                          Flexible(child: Text(tr.commentsTitle)),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ),
              ),
              if (detail.followState != CollectionFollowState.none)
                detail.followState == CollectionFollowState.following
                    ? OutlinedButton(
                        key: const ValueKey('collection-follow'),
                        onPressed: _sending ? null : () async => _toggleFollow(detail),
                        child: Text(tr.unfollow),
                      )
                    : FilledButton.tonal(
                        key: const ValueKey('collection-follow'),
                        onPressed: _sending ? null : () async => _toggleFollow(detail),
                        child: Text(tr.follow),
                      ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) {
        final detail = _pager.first;
        final Widget body;
        if (detail == null) {
          body = _pager.loading || _pager.failure == null
              ? const CenteredCircularIndicator()
              : FailureView(failure: _pager.failure, onRetry: _pager.refresh);
        } else {
          final threads = _pager.items;
          body = RefreshIndicator(
            onRefresh: _pager.refresh,
            child: AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: side.copyWith(top: 12, bottom: 24).add(context.safePadding()),
                itemCount: threads.length + 2,
                separatorBuilder: (_, _) => appListSeparator,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _header(context, detail);
                  }
                  final i = index - 1;
                  if (i < threads.length) {
                    return CollectionThreadTile(
                      threads[i],
                      onRemove: detail.canManage && !_sending ? () => unawaited(_remove(detail, threads[i])) : null,
                    );
                  }
                  if (threads.isEmpty) {
                    return AppStateView(
                      icon: Icons.article_outlined,
                      message: context.t.collection.noThreads,
                      scrollable: false,
                    );
                  }
                  return ListFooter(
                    status: listFooterStatus(
                      hasMore: _pager.hasMore,
                      loading: _pager.loadingMore,
                      failed: _pager.moreFailed,
                    ),
                    itemCount: threads.length,
                    failure: _pager.failure,
                    onLoadMore: _pager.loadMore,
                    onRetry: _pager.loadMore,
                  );
                },
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(detail == null ? context.t.collection.title : context.displayText(detail.name)),
            actions: [
              if (detail != null && detail.canManage)
                PopupMenuButton<_Menu>(
                  key: const ValueKey('collection-menu'),
                  enabled: !_sending,
                  onSelected: (item) async => switch (item) {
                    _Menu.edit => _edit(detail),
                    _Menu.delete => _delete(detail),
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: _Menu.edit, child: Text(context.t.collection.edit)),
                    PopupMenuItem(value: _Menu.delete, child: Text(context.t.collection.delete)),
                  ],
                ),
            ],
          ),
          body: SafeArea(bottom: false, child: body),
        );
      },
    );
  }
}
