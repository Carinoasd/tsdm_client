import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/widgets/hour_ticker.dart';

/// First card of the homepage without an account: what a login adds, the login and the way to the forums.
///
/// The homepage of a guest used to be a login wall; it shows what the forum shows to everyone now (the forums, the
/// guide), under this card.
class HomeGuestCard extends StatelessWidget {
  /// Constructor.
  const HomeGuestCard({required this.compact, super.key});

  /// Phone layout: tighter padding and title.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guest;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: const ValueKey('homepage-guest-card'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      color: colorScheme.surfaceContainerLow,
      child: DecoratedBox(
        // The look of the greeting card of an account, which this card stands for.
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topRight,
            radius: 1.4,
            colors: [colorScheme.primaryContainer.withValues(alpha: 0.55), colorScheme.surfaceContainerLow],
            stops: const [0, 0.6],
          ),
        ),
        child: Padding(
          padding: compact ? edgeInsetsL16T16R16B16 : edgeInsetsL24T24R24B24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HourTicker(
                builder: (context, now) => Text(
                  '${context.t.appName} · ${MaterialLocalizations.of(context).formatMediumDate(now)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
                ),
              ),
              sizedBoxW4H4,
              Text(
                tr.title,
                style: (compact ? textTheme.titleLarge : textTheme.headlineSmall)?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              sizedBoxW4H4,
              Text(tr.detail, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
              SizedBox(height: compact ? 14 : 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('homepage-guest-login'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                    icon: const Icon(Icons.login_outlined),
                    label: Text(context.t.loginPage.login),
                    onPressed: () async => context.pushNamed(ScreenPaths.login),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    icon: const Icon(Icons.topic_outlined),
                    label: Text(tr.allForums),
                    onPressed: () => showHomeTab(context, HomeTab.topic),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The forum groups of the `forum.php` page [page] the homepage loaded for a guest, without the favorites panel and
/// the groups without a forum. Empty for a page served to an account: the stream replays the last page, which may be
/// the one of the account that just logged out.
List<ForumGroup> guestForumGroupsOf(ForumHomePage? page) {
  if (page == null || page.servedUid != null) {
    return const [];
  }
  final groups = switch (page) {
    ForumHomeWebPage(:final document) => buildGroupListFromDocument(document),
    ForumHomeApiPage(:final json) => forumGroupsFromApi(json),
  };
  return groups.where((e) => !e.isFavorites && e.forumList.any((f) => f.redirectUrl == null)).toList();
}

/// The forums of the homepage without an account: one tab per forum group, its forums as entries; all the forums are
/// on the forums tab.
///
/// Read from the `forum.php` page the homepage loaded ([ForumHomeRepository]), the page the forums tab shows: nothing
/// is fetched for this card. Nothing is shown while there is no such page (offline).
class HomeForumEntriesCard extends StatefulWidget {
  /// Constructor.
  const HomeForumEntriesCard({super.key});

  @override
  State<HomeForumEntriesCard> createState() => _HomeForumEntriesCardState();
}

class _HomeForumEntriesCardState extends State<HomeForumEntriesCard> {
  StreamSubscription<ForumHomePage>? _sub;

  /// The page [_groups] were read from.
  ForumHomePage? _page;

  List<ForumGroup> _groups = const [];

  /// Name of the group shown, the first one when unknown.
  String? _selected;

  void _read(ForumHomePage? page) {
    if (identical(page, _page)) {
      return;
    }
    _page = page;
    final groups = guestForumGroupsOf(page);
    if (mounted) {
      setState(() => _groups = groups);
    } else {
      _groups = groups;
    }
  }

  @override
  void initState() {
    super.initState();
    final repository = context.readOrNull<ForumHomeRepository>();
    if (repository == null) {
      return;
    }
    _read(repository.getCache());
    _sub = repository.pageStream.listen(_read);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final tr = context.t.homepage.guest;
    final colorScheme = Theme.of(context).colorScheme;
    final shown = groups.firstWhere((e) => e.name == _selected, orElse: () => groups.first);
    return Card(
      key: const ValueKey('homepage-forum-entries'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                Icon(Icons.topic_outlined, size: 20, color: colorScheme.primary),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    tr.forums,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () => showHomeTab(context, HomeTab.topic),
                  child: Text(tr.allForums),
                ),
              ],
            ),
          ),
          // The groups as tabs, like the pinned thread groups of an account's homepage.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                for (final group in groups)
                  HomeCardTab(
                    label: group.name,
                    selected: identical(group, shown),
                    onTap: () => setState(() => _selected = group.name),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
          Padding(
            padding: edgeInsetsL12T12R12B12,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final forum in shown.forumList.where((e) => e.redirectUrl == null)) _ForumEntry(forum),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A forum of [HomeForumEntriesCard]: its name, the count of today's posts when there are some; opens the forum.
class _ForumEntry extends StatelessWidget {
  const _ForumEntry(this.forum);

  final Forum forum;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final today = forum.threadTodayCount ?? 0;
    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async => context.pushNamed(
          ScreenPaths.forum,
          pathParameters: {'fid': '${forum.forumID}'},
          queryParameters: {'appBarTitle': forum.name},
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_outlined, size: 18, color: colorScheme.primary),
                sizedBoxW8H8,
                Flexible(
                  child: Text(forum.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.labelLarge),
                ),
                if (today > 0) ...[
                  sizedBoxW4H4,
                  Text('+$today', style: textTheme.labelSmall?.copyWith(color: colorScheme.tertiary)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
