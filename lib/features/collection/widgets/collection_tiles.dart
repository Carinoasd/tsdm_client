import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The counts of a collection as pills: threads, subscribers, comments, each with its name as the tooltip.
List<Widget> collectionCountPills(BuildContext context, {int? threads, int? follows, int? comments}) {
  final tr = context.t.collection;
  return [
    if (threads != null)
      AppInfoPill(
        icon: Icons.article_outlined,
        label: '$threads',
        tooltip: tr.threads(count: threads),
      ),
    if (follows != null)
      AppInfoPill(
        icon: Icons.people_outline,
        label: '$follows',
        tooltip: tr.follows(count: follows),
      ),
    if (comments != null)
      AppInfoPill(
        icon: Icons.chat_bubble_outline,
        label: '$comments',
        tooltip: tr.comments(count: comments),
      ),
  ];
}

/// Counts the changes the account made to collections in the app: the lists showing them load again.
final collectionChanges = ValueNotifier<int>(0);

/// Open the page of collection [ctid].
Future<void> openCollection(BuildContext context, int ctid) async =>
    context.pushNamed(ScreenPaths.collectionDetail, pathParameters: {'ctid': '$ctid'});

/// Open thread [tid].
Future<void> openCollectionThread(BuildContext context, int tid) async =>
    context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '$tid'});

/// A row of a collection list: name (marked when it changed since the account last opened it), description, keywords,
/// counts, creator and the time of its last change. A tap opens the collection.
class CollectionSummaryCard extends StatelessWidget {
  /// Constructor.
  const CollectionSummaryCard(this.collection, {super.key});

  /// The collection.
  final CollectionSummary collection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = collection;
    return AppSurface(
      key: ValueKey('collection-${c.ctid}'),
      onTap: () async => openCollection(context, c.ctid),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (c.updated) ...[
                Icon(Icons.circle, size: 8, color: theme.colorScheme.primary),
                sizedBoxW8H8,
              ],
              Expanded(child: Text(c.name, style: theme.textTheme.titleMedium)),
            ],
          ),
          if (c.description.isNotEmpty) ...[
            sizedBoxW4H4,
            Text(
              c.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          sizedBoxW8H8,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...collectionCountPills(
                context,
                threads: c.threadCount,
                follows: c.followCount,
                comments: c.commentCount,
              ),
              if (c.creatorName.isNotEmpty) AppInfoPill(icon: Icons.person_outline, label: c.creatorName),
              if (c.lastUpdate.isNotEmpty) AppInfoPill(icon: Icons.update, label: c.lastUpdate),
              for (final keyword in c.keywords) AppInfoPill(icon: Icons.sell_outlined, label: keyword),
            ],
          ),
        ],
      ),
    );
  }
}

/// A thread of a collection: subject, the reason it was put in, author, date and counts. A tap opens the thread;
/// [onRemove], when given, takes it out of the collection.
class CollectionThreadTile extends StatelessWidget {
  /// Constructor.
  const CollectionThreadTile(this.thread, {this.onRemove, super.key});

  /// The thread.
  final CollectionThread thread;

  /// Take it out of the collection.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = thread;
    return AppSurface(
      key: ValueKey('collection-thread-${t.tid}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      onTap: () async => openCollectionThread(context, t.tid),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.subject, style: theme.textTheme.titleSmall),
                if (t.reason.isNotEmpty) ...[
                  sizedBoxW4H4,
                  Text(
                    context.t.collection.reason(reason: t.reason),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                sizedBoxW8H8,
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (t.authorName.isNotEmpty) AppInfoPill(icon: Icons.person_outline, label: t.authorName),
                    if (t.date.isNotEmpty) AppInfoPill(icon: Icons.schedule, label: t.date),
                    if (t.replies != null) AppInfoPill(icon: Icons.forum_outlined, label: '${t.replies}'),
                    if (t.views != null) AppInfoPill(icon: Icons.visibility_outlined, label: '${t.views}'),
                  ],
                ),
              ],
            ),
          ),
          if (onRemove != null)
            PopupMenuButton<void>(
              key: ValueKey('collection-thread-menu-${t.tid}'),
              itemBuilder: (context) => [
                PopupMenuItem(
                  onTap: onRemove,
                  child: Row(
                    children: [
                      const Icon(Icons.remove_circle_outline),
                      sizedBoxPopupMenuItemIconSpacing,
                      Text(context.t.collection.removeThread),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The stars of a rating [rate] (1 to 5).
class CollectionStars extends StatelessWidget {
  /// Constructor.
  const CollectionStars(this.rate, {this.size = 16, super.key});

  /// The rating.
  final double rate;

  /// Size of a star.
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            rate >= i ? Icons.star : (rate >= i - 0.5 ? Icons.star_half : Icons.star_border),
            size: size,
            color: color,
          ),
      ],
    );
  }
}

/// A comment on a collection: author, time, the rating given with it, text.
class CollectionCommentTile extends StatelessWidget {
  /// Constructor.
  const CollectionCommentTile(this.comment, {super.key});

  /// The comment.
  final CollectionComment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = comment;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: InkWell(
                  onTap: c.uid == null
                      ? null
                      : () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${c.uid}'}),
                  child: Text(c.username, style: theme.textTheme.titleSmall),
                ),
              ),
              sizedBoxW8H8,
              Text(c.time, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
              if (c.rate case final rate?) ...[sizedBoxW8H8, CollectionStars(rate.toDouble(), size: 14)],
            ],
          ),
          if (c.message.isNotEmpty) ...[sizedBoxW4H4, SelectableText(c.message)],
        ],
      ),
    );
  }
}
