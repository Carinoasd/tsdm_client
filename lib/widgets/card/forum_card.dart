import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/forum/utils/frequent_forums.dart';
import 'package:tsdm_client/features/forum/widgets/frequent_forums_bar.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// Card to show forum information.
///
/// Header (icon, name, time of the latest thread), counters as pills, then the optional shortcuts (latest thread,
/// links and sub forums) in inner blocks.
///
/// As the forum's pages print them, a forum the viewer may not enter says "私密版块" where the time of its latest
/// thread goes ([Forum.isPrivate]), and a link forum ([Forum.redirectUrl]) says "链接到外部地址" there and shows no
/// counters; tapping a link forum opens its address in a browser (web addresses only), as the page opens it in a new
/// window.
///
/// [large] is for the forum lists of desktop windows (see [forumCardListLayout]): the forum picture (up to 240x120,
/// fitted whole) and a 24px name share the card width, and the three counters are equal blocks ([ForumCardStat])
/// filling the bottom. Phones (even wide landscape ones) and medium windows keep the compact card.
class ForumCard extends StatefulWidget {
  /// Constructor.
  const ForumCard(this.forum, {this.large = false, super.key});

  /// Forum id.
  final Forum forum;

  /// Show the card large, see [ForumCard].
  final bool large;

  @override
  State<ForumCard> createState() => _ForumCardState();
}

/// Size of the forum picture of a compact [ForumCard].
const forumCardImageSize = Size(88, 44);

/// Largest forum picture of a large [ForumCard] (2:1); the picture is fitted whole (contain), enlarged when smaller.
const forumCardLargeImageSize = Size(240, 120);

/// Narrowest forum picture shown beside the name of a large [ForumCard].
const forumCardLargeImageMinWidth = 180.0;

/// Gap between the picture and the name of a large [ForumCard].
const forumCardLargeImageGap = 20.0;

/// Room the name of a large [ForumCard] needs beside the picture at 1x text; below it the name goes under the picture.
const forumCardLargeNameMinWidth = 220.0;

/// Picture size of a large [ForumCard] whose content is [contentWidth] wide, and whether the name fits beside it.
///
/// Beside the name the picture takes 42% of the card (180 to 240 wide). When the name would get less than
/// [forumCardLargeNameMinWidth] (scaled by [textScale]), the picture keeps its largest size and the name goes under it.
({Size image, bool sideBySide}) forumCardLargeHeaderLayout(double contentWidth, double textScale) {
  final ratio = forumCardLargeImageSize.height / forumCardLargeImageSize.width;
  final beside = (contentWidth * 0.42).clamp(forumCardLargeImageMinWidth, forumCardLargeImageSize.width);
  if (contentWidth - beside - forumCardLargeImageGap >= forumCardLargeNameMinWidth * textScale) {
    return (image: Size(beside, beside * ratio), sideBySide: true);
  }
  final stacked = math.min(contentWidth, forumCardLargeImageSize.width);
  return (image: Size(stacked, stacked * ratio), sideBySide: false);
}

/// Padding of a large [ForumCard].
const forumCardLargePadding = EdgeInsets.symmetric(horizontal: 24, vertical: 20);

/// Widest a list of [ForumCard]s grows once it shows large cards (other lists, and forum lists below
/// [forumCardListLargeWidth], keep [appListMaxWidth]).
const forumCardListMaxWidth = 1520.0;

/// Width a list of [ForumCard]s must really have (measured: navigation and safe area excluded) to show large cards.
///
/// Below it the list keeps the compact cards of phones and tablets (one column, then two from [appTwoColumnWidth]).
const forumCardListLargeWidth = 1100.0;

/// Whether [platform] is a desktop one. Only desktop windows get large [ForumCard]s: phones and tablets keep the
/// compact cards at any width, landscape included.
bool forumCardListIsDesktop(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => false,
};

/// Whether a list of [ForumCard]s shows large cards in a page of [width] on [platform].
bool forumCardListUsesLargeCards(double width, TargetPlatform platform) =>
    forumCardListIsDesktop(platform) && width >= forumCardListLargeWidth;

/// Layout of a list of [ForumCard]s in a page of [width] on [platform] (topics, sub forums of a forum, forum group).
///
/// Desktop windows get a wider content area (still two columns) with large cards, so the list is not a small island
/// in the middle of the window; phones (any width), tablets and medium windows keep the shared list width and the
/// compact cards. Pass `Theme.of(context).platform`.
({bool large, int columns, EdgeInsets side, double gap, Widget separator}) forumCardListLayout(
  double width,
  TargetPlatform platform,
) {
  final large = forumCardListUsesLargeCards(width, platform);
  return (
    large: large,
    columns: appColumnsFor(width),
    side: appCenteredPadding(width, maxWidth: large ? forumCardListMaxWidth : appListMaxWidth),
    gap: large ? appSurfaceGap : appSurfaceGapCompact,
    separator: large ? const SizedBox(height: appSurfaceGap) : appListSeparator,
  );
}

/// One counter of a large [ForumCard]: icon and caption on top, the number below; the three share the card width.
///
/// The number is never cut: it scales down when a narrow block with large text cannot hold it.
class ForumCardStat extends StatelessWidget {
  /// Constructor.
  const ForumCardStat({
    required this.icon,
    required this.caption,
    required this.value,
    required this.tooltip,
    super.key,
  });

  /// Icon.
  final IconData icon;

  /// Short caption ("Threads").
  final String caption;

  /// The number.
  final String value;

  /// Tooltip and semantic label.
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(appInnerRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: colorScheme.primary),
                  sizedBoxW8H8,
                  Expanded(
                    child: Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(fontSize: 15, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              sizedBoxW4H4,
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  value,
                  maxLines: 1,
                  style: textTheme.titleLarge?.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Caption of a counter from a tooltip prefix like "Threads: ".
String _statCaption(String prefix) => prefix.replaceAll(RegExp(r'[:：]\s*$'), '').trim();

final class _ForumCardState extends State<ForumCard> with LoggerMixin {
  bool showingSubThread = false;
  bool showingSubForum = false;

  Future<void> _openUrl(String? url) async {
    final target = url?.parseUrlToRoute();
    if (target == null) {
      error('invalid forum card url: $url');
      return;
    }
    await context.pushNamed(
      target.screenPath,
      pathParameters: target.pathParameters,
      queryParameters: target.queryParameters,
    );
  }

  Widget _buildShortcut(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final large = widget.large;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.forum.isExpanded && (widget.forum.latestThreadTitle?.isNotEmpty ?? false)) ...[
          sizedBoxW8H8,
          // Latest thread: an inner block, title on the start, author on the end.
          Material(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(appInnerRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async => _openUrl(widget.forum.latestThreadUrl),
              child: Padding(
                padding: edgeInsetsL12T8R12B8,
                child: Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right_outlined, size: 16, color: colorScheme.outline),
                    sizedBoxW8H8,
                    Expanded(
                      child: Text(
                        widget.forum.latestThreadTitle ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: large ? textTheme.bodyMedium : textTheme.labelMedium,
                      ),
                    ),
                    if (widget.forum.latestThreadUserName?.isNotEmpty ?? false) ...[
                      sizedBoxW8H8,
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          widget.forum.latestThreadUserName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (large ? textTheme.labelMedium : textTheme.labelSmall)?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
        if (widget.forum.subThreadList?.isNotEmpty ?? false)
          ..._buildWrapSection(context, context.t.forumCard.links, widget.forum.subThreadList!, showingSubThread, () {
            setState(() {
              showingSubThread = !showingSubThread;
            });
          }),
        if (widget.forum.subForumList?.isNotEmpty ?? false)
          ..._buildWrapSection(context, context.t.forumCard.subForums, widget.forum.subForumList!, showingSubForum, () {
            setState(() {
              showingSubForum = !showingSubForum;
            });
          }),
      ],
    );
  }

  List<Widget> _buildWrapSection(
    BuildContext context,
    String title,
    List<(String, String)> dataList,
    bool state,
    VoidCallback onPressed,
  ) {
    final wrapChildren = dataList
        .map(
          (e) => ActionChip(
            label: Text(e.$1),
            labelStyle: widget.large ? Theme.of(context).textTheme.labelMedium : Theme.of(context).textTheme.labelSmall,
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
            onPressed: () async => _openUrl(e.$2),
          ),
        )
        .toList();

    return [
      sizedBoxW4H4,
      // Collapsible section: title with the number of entries and the expand mark.
      InkWell(
        borderRadius: BorderRadius.circular(appInnerRadius),
        onTap: onPressed,
        child: Padding(
          padding: edgeInsetsT4B4,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$title (${dataList.length})',
                  style:
                      (widget.large ? Theme.of(context).textTheme.titleMedium : Theme.of(context).textTheme.titleSmall)
                          ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Icon(state ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
      if (state)
        Padding(
          padding: edgeInsetsT4B4,
          child: Wrap(spacing: 8, runSpacing: 8, children: wrapChildren),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final settingsStream = getIt.get<SettingsRepository>().settings;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final tr = context.t.topicPage;
    final large = widget.large;
    final isLink = widget.forum.redirectUrl != null;

    final shortcut = StreamBuilder(
      stream: settingsStream,
      builder: (context, settings) {
        if (!settings.hasData) {
          return const SizedBox.shrink();
        }
        if (settings.data!.showShortcutInForumCard) {
          return _buildShortcut(context);
        }
        return const SizedBox.shrink();
      },
    );

    Future<void> openForum() async {
      final redirect = widget.forum.redirectUrl;
      if (redirect != null) {
        // A browser only: the forum's own page (a link forum read from the web page) is a link of this app, which a
        // generic launch may open in the app again (#105).
        final uri = Uri.tryParse(redirect);
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
          error('link forum ${widget.forum.forumID} has no web address, not opened');
          return;
        }
        try {
          await openInExternalBrowser(uri);
        } on Object catch (e, st) {
          handleRaw(e, st);
        }
        return;
      }
      await context.pushNamed(
        ScreenPaths.forum,
        pathParameters: <String, String>{'fid': '${widget.forum.forumID}'},
        queryParameters: {'appBarTitle': widget.forum.name},
      );
    }

    // A link forum has no page of its own to pin.
    final pinForum = isLink
        ? null
        : () => unawaited(
            showFrequentForumMenu(context, FrequentForum(fid: widget.forum.forumID, name: widget.forum.name)),
          );

    if (large) {
      return AppSurface(
        padding: forumCardLargePadding,
        onTap: openForum,
        onLongPress: pinForum,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildLargeHeader(context),
            // Three equal blocks filling the bottom of the card; a link forum has no counts.
            if (!isLink) ...[
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ForumCardStat(
                      icon: Icons.forum_outlined,
                      caption: _statCaption(tr.threads),
                      value: '${widget.forum.threadCount}',
                      tooltip: '${tr.threads}${widget.forum.threadCount}',
                    ),
                  ),
                  sizedBoxW12H12,
                  Expanded(
                    child: ForumCardStat(
                      icon: Icons.chat_outlined,
                      caption: _statCaption(tr.posts),
                      value: '${widget.forum.replyCount}',
                      tooltip: '${tr.posts}${widget.forum.replyCount}',
                    ),
                  ),
                  sizedBoxW12H12,
                  Expanded(
                    child: ForumCardStat(
                      icon: Icons.mark_chat_unread_outlined,
                      caption: _statCaption(tr.today),
                      value: '${widget.forum.threadTodayCount ?? 0}',
                      tooltip: '${tr.today}${widget.forum.threadTodayCount ?? 0}',
                    ),
                  ),
                ],
              ),
            ],
            shortcut,
          ],
        ),
      );
    }

    return AppSurface(
      padding: edgeInsetsL12T12R12B12,
      onTap: openForum,
      onLongPress: pinForum,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(appInnerRadius),
                child: SizedBox.fromSize(
                  size: forumCardImageSize,
                  child: NetworkIndicatorImage(widget.forum.iconUrl),
                ),
              ),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.forum.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (_note(context) ?? widget.forum.latestThreadTime?.elapsedTillNow(context) case final line?)
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.secondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (!isLink) ...[
            sizedBoxW12H12,
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                AppInfoPill(
                  icon: Icons.forum_outlined,
                  label: '${widget.forum.threadCount}',
                  tooltip: '${tr.threads}${widget.forum.threadCount}',
                ),
                AppInfoPill(
                  icon: Icons.chat_outlined,
                  label: '${widget.forum.replyCount}',
                  tooltip: '${tr.posts}${widget.forum.replyCount}',
                ),
                AppInfoPill(
                  icon: Icons.mark_chat_unread_outlined,
                  label: '${widget.forum.threadTodayCount ?? 0}',
                  tooltip: '${tr.today}${widget.forum.threadTodayCount ?? 0}',
                ),
              ],
            ),
          ],
          shortcut,
        ],
      ),
    );
  }

  /// What the forum's pages print in place of the latest thread: "私密版块" for a forum the viewer may not enter,
  /// "链接到外部地址" for a link forum; null for any other forum.
  String? _note(BuildContext context) => widget.forum.isPrivate
      ? context.t.forumCard.privateForum
      : (widget.forum.redirectUrl != null ? context.t.forumCard.redirectForum : null);

  /// Picture and name of a large card, laid out from the real card width and text scale (see
  /// [forumCardLargeHeaderLayout]): side by side, or the name under the picture on narrow cards with large text.
  Widget _buildLargeHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final textScale = MediaQuery.textScalerOf(context).scale(24) / 24;

    final name = Text(
      widget.forum.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textTheme.headlineSmall?.copyWith(fontSize: 24, fontWeight: FontWeight.w600, height: 1.3),
    );
    final note = _note(context);
    final time = note == null && widget.forum.latestThreadTime == null
        ? null
        : Row(
            children: [
              Icon(
                note == null
                    ? Icons.schedule_outlined
                    : (widget.forum.isPrivate ? Icons.lock_outline : Icons.open_in_new_outlined),
                size: 18,
                color: colorScheme.secondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  note ?? widget.forum.latestThreadTime!.elapsedTillNow(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyLarge?.copyWith(fontSize: 16, color: colorScheme.secondary),
                ),
              ),
            ],
          );
    final nameBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        name,
        if (time != null) ...[sizedBoxW4H4, time],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = forumCardLargeHeaderLayout(constraints.maxWidth, textScale);
        final picture = ClipRRect(
          borderRadius: BorderRadius.circular(appInnerRadius),
          child: SizedBox.fromSize(
            size: layout.image,
            // Fit the whole picture and let a small one grow with the box.
            child: NetworkIndicatorImage(widget.forum.iconUrl, fit: BoxFit.contain),
          ),
        );
        if (layout.sideBySide) {
          return Row(
            children: [
              picture,
              const SizedBox(width: forumCardLargeImageGap),
              Expanded(child: nameBlock),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [picture, sizedBoxW12H12, nameBlock],
        );
      },
    );
  }
}
