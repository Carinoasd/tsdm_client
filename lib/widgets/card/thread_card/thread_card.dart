import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/features/reading_progress/cubit/reading_progress_cubit.dart';
import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/dialog.dart';
import 'package:tsdm_client/features/thread_preview/widgets/thread_preview_section.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/html/author_style.dart' show contrastRatio, readableContrast;
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/widgets/adaptive_ink_response.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';
import 'package:tsdm_client/widgets/two_pane.dart';
import 'package:url_launcher/url_launcher.dart';

/// An item of the info row: its icon, its text, and a highlighted text after it (the replies since the last visit).
typedef _ThreadInfo = (IconData, String, String?);

/// All actions used in the context menu.
///
/// The context menu is opened by either long press or right click, depending on the platform.
enum _CtxMenuActions { select, openInNewTab, openInBrowser, viewInfo, readLater }

class _CardLayout extends StatelessWidget {
  const _CardLayout({
    required this.threadID,
    required this.title,
    this.preview,
    this.forum,
    this.author,
    this.publishTime,
    this.threadType,
    this.replyCount,
    this.viewCount,
    this.lastReplyAuthor,
    this.latestReplyTime,
    this.price,
    this.privilege,
    this.quotedMessage,
    this.css,
    this.stateSet,
    this.disableTap = false,
    this.isRecentThread = false,
    this.replied = false,
    this.progress,
    this.markReplies,
    this.onPick,
    this.onStartPicking,
  });

  final String threadID;
  final String title;

  /// The excerpt and the thumbnail of the first floor (the forum's app API, plugin 3.1.0), under the title.
  final ThreadPreview? preview;
  final String? forum;
  final ThreadType? threadType;
  final User? author;
  final DateTime? publishTime;

  final int? replyCount;
  final int? viewCount;
  final User? lastReplyAuthor;
  final DateTime? latestReplyTime;
  final int? price;
  final int? privilege;
  final String? quotedMessage;
  final CssTypes? css;
  final Set<ThreadStateModel>? stateSet;
  final bool isRecentThread;

  /// The current account replied in this thread (local mark, issue #21): a small reply icon in the trailing row.
  final bool replied;

  /// Where the current account stopped reading this thread, null when it never read it or the lists do not mark the
  /// threads read ([visitMarkOf]): the replies posted since its last visit are told ("+N" after the reply count);
  /// without any, the title is dimmed.
  final ReadingProgress? progress;

  /// The replies of the thread as the list counts them, for telling the replies posted since the last visit when the
  /// card shows no reply count ([replyCount] null): the title is not dimmed when there are some.
  final int? markReplies;

  /// Replies posted since the current account read this thread, 0 when not known or not read.
  int get _newReplies => progress?.newRepliesOf(replyCount ?? markReplies) ?? 0;

  /// See [NormalThreadCard.onPick].
  final VoidCallback? onPick;

  /// See [NormalThreadCard.onStartPicking].
  final VoidCallback? onStartPicking;

  /// A middle click opens the thread in a new tab of the wide list page's detail pane.
  Widget _wrapWithCard(BuildContext context, Widget child) => TwoPaneMiddleClickOpener(
    query: disableTap || onPick != null ? null : threadQuery(threadID: threadID, title: title, threadType: threadType),
    child: _card(context, child),
  );

  /// A row of the list on the page itself, no card around it (the lists separate their rows with hairlines,
  /// [ThreadListSeparator]); the transparent material carries the ink of a tap.
  Widget _card(BuildContext context, Widget child) => Material(
    type: MaterialType.transparency,
    child: AdaptiveInkResponse(
      onTap: disableTap
          ? null
          : onPick ?? () async => openThread(context, threadID: threadID, title: title, threadType: threadType),
      onAdaptiveContextTap: (tapPosition) async {
        if (onPick case final pick?) {
          pick();
          return;
        }
        if (onStartPicking case final start? when isMobile) {
          start();
          return;
        }
        // Get the position where the tap occurred.
        RelativeRect? position;
        position = RelativeRect.fromRect(
          tapPosition.globalPosition & Size.zero, // Rect from the tap position
          Offset.zero & MediaQuery.of(context).size, // Bounding box for the menu
        );
        // Put aside for the account in use: not offered without one.
        final readLater = context.readOrNull<ReadLaterCubit>();
        final readLaterId = int.tryParse(threadID);
        final canReadLater = readLater != null && readLater.state.uid != null && readLaterId != null;
        final isReadLater = canReadLater && readLater.state.contains(readLaterId);
        final choice = await showMenu<_CtxMenuActions>(
          context: context,
          position: position,
          items: <PopupMenuEntry<_CtxMenuActions>>[
            if (onStartPicking != null)
              PopupMenuItem(
                value: _CtxMenuActions.select,
                child: Row(
                  children: [
                    const Icon(Icons.checklist_outlined),
                    sizedBoxPopupMenuItemIconSpacing,
                    Text(context.t.moderate.batch.select),
                  ],
                ),
              ),
            if (!disableTap && TwoPaneScope.readOf(context)?.side == TwoPaneSide.list)
              PopupMenuItem(
                value: _CtxMenuActions.openInNewTab,
                child: Row(
                  children: [
                    const Icon(Icons.tab_outlined),
                    sizedBoxPopupMenuItemIconSpacing,
                    Text(context.t.threadCard.openInNewTab),
                  ],
                ),
              ),
            PopupMenuItem(
              value: _CtxMenuActions.openInBrowser,
              child: Row(
                children: [
                  const Icon(Icons.open_in_browser_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.general.openInBrowser),
                ],
              ),
            ),
            PopupMenuItem(
              value: _CtxMenuActions.viewInfo,
              child: Row(
                children: [
                  const Icon(Icons.info_outline),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.threadCard.viewInfo),
                ],
              ),
            ),
            if (canReadLater)
              PopupMenuItem(
                value: _CtxMenuActions.readLater,
                child: Row(
                  children: [
                    Icon(isReadLater ? Icons.watch_later : Icons.watch_later_outlined),
                    sizedBoxPopupMenuItemIconSpacing,
                    Text(isReadLater ? context.t.readLater.remove : context.t.readLater.add),
                  ],
                ),
              ),
          ],
        );

        if (choice == null || !context.mounted) {
          return;
        }

        switch (choice) {
          case _CtxMenuActions.select:
            onStartPicking?.call();
          case _CtxMenuActions.openInNewTab:
            await openThread(context, threadID: threadID, title: title, threadType: threadType, newTab: true);
          case _CtxMenuActions.openInBrowser:
            await launchUrl(
              Uri.parse('$baseUrl/forum.php?mod=viewthread&tid=$threadID'),
              mode: LaunchMode.externalApplication,
            );
          case _CtxMenuActions.viewInfo:
            await showCopyThreadInfoDialog(context: context, tid: threadID, title: title);
          case _CtxMenuActions.readLater:
            await toggleReadLater(
              context,
              tid: threadID,
              title: title,
              author: author?.name,
              forumName: forum,
            );
        }
      },
      child: child,
    ),
  );

  /// [author] MUST not be null.
  Widget _buildAvatar(BuildContext context) {
    return HeroUserAvatar(
      username: author!.name,
      avatarUrl: author!.avatarUrl,
      disableHero: true,
      maxRadius: _avatarSize / 2,
      minRadius: _avatarSize / 2,
    );
  }

  /// Size of the avatar in the head of the row.
  static const double _avatarSize = 24;

  /// Height (and least width) of the tap target of the author: the minimum of the platform guidelines.
  static const double _authorTapSize = 48;

  /// Style of the meta texts of the row (time, counts): 12.5, the quiet text color, tabular figures.
  TextStyle _metaStyle(BuildContext context, {Color? color}) => TextStyle(
    fontSize: 12.5,
    height: 1.4,
    color: color ?? AppSurfaces.of(context).muted,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Mainly for test.
  final bool disableTap;

  Widget _buildInfoWidgetRow({
    required BuildContext context,
    required bool infoRowAlignCenter,
    required bool showLastReplyAuthor,
    required bool highlightInfoRow,
  }) {
    final infoColor = highlightInfoRow ? Theme.of(context).colorScheme.secondary : AppSurfaces.of(context).muted;
    final style = _metaStyle(context, color: infoColor);
    const iconSize = 16.0;

    final newReplies = _newReplies;
    final counts = <_ThreadInfo>[
      if (replyCount != null) (Icons.forum_outlined, '$replyCount', newReplies > 0 ? '+$newReplies' : null),
      if (viewCount != null) (Icons.bar_chart_outlined, '$viewCount', null),
      if ((price ?? 0) > 0) (FontAwesomeIcons.coins, '$price', null),
      if ((privilege ?? 0) > 0) (Icons.feedback_outlined, '$privilege', null),
    ];
    final lastReply = showLastReplyAuthor && lastReplyAuthor != null ? lastReplyAuthor!.name : null;
    final lastTime = latestReplyTime?.elapsedTillNow(context);

    if (counts.isEmpty && lastReply == null && lastTime == null) {
      return sizedBoxEmpty;
    }

    if (infoRowAlignCenter) {
      // The setting of the info row: every item the same width, as it always was.
      final infoList = <_ThreadInfo>[
        ...counts.take(2),
        if (lastReply != null) (Icons.person_outline, lastReply, null),
        if (lastTime != null) (Icons.timelapse_outlined, lastTime, null),
        ...counts.skip(2),
      ];
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 13),
        child: Row(
          children: [
            for (final e in infoList)
              Expanded(
                child: Row(
                  children: [
                    Icon(e.$1, size: iconSize, color: infoColor),
                    sizedBoxW4H4,
                    Expanded(
                      child: _infoText(context, e, style: style, overflow: TextOverflow.clip),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    // The counts on the left; who replied last and when on the right, up to 60% of the row (the name is cut first).
    final hasRight = lastReply != null || lastTime != null;
    final left = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, e) in counts.indexed) ...[
            if (i > 0) const SizedBox(width: 14),
            Icon(e.$1, size: iconSize, color: infoColor),
            sizedBoxW4H4,
            _infoText(context, e, style: style),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 13),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(child: counts.isEmpty ? sizedBoxEmpty : left),
            if (hasRight) ...[
              sizedBoxW12H12,
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      lastReply != null ? Icons.person_outline : Icons.timelapse_outlined,
                      size: iconSize,
                      color: infoColor,
                    ),
                    sizedBoxW4H4,
                    if (lastReply != null)
                      Flexible(
                        child: Text(lastReply, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    if (lastReply != null && lastTime != null) Text(' · ', style: style),
                    if (lastTime != null)
                      Flexible(
                        child: Text(lastTime, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The text of [info], its highlighted part (new replies) after it in the primary color.
  Widget _infoText(BuildContext context, _ThreadInfo info, {required TextStyle style, TextOverflow? overflow}) {
    final highlighted = info.$3;
    if (highlighted == null) {
      return Text(info.$2, style: style, maxLines: 1, overflow: overflow);
    }
    final count = int.tryParse(highlighted.substring(1)) ?? 0;
    return Text.rich(
      TextSpan(
        text: info.$2,
        children: [
          TextSpan(
            text: ' $highlighted',
            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      key: const ValueKey('thread-card-new-replies'),
      style: style,
      maxLines: 1,
      overflow: overflow,
      semanticsLabel: '${info.$2}, ${context.t.threadCard.newReplies(count: count)}',
    );
  }

  Widget _buildCardTitle(BuildContext context, SettingsState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final highlightRecentThread = state.settingsMap.threadCardHighlightRecentThread;
    final nameStyle = TextStyle(
      fontSize: 13,
      height: 1.35,
      fontWeight: FontWeight.w700,
      color: state.settingsMap.threadCardHighlightAuthorName ? colorScheme.primary : colorScheme.onSurface,
    );
    final timeStyle = _metaStyle(
      context,
      color: isRecentThread && highlightRecentThread ? colorScheme.secondary : null,
    );

    // Marks at the end of the head: thread type (or forum) tag, replied by the current account, thread states.
    final marks = <Widget>[
      if (threadType?.name.isNotEmpty ?? false) _buildTypeTag(context, threadType!.name),
      if (replied) _buildRepliedMark(context),
      if (stateSet != null) ...stateSet!.map((e) => Icon(e.icon, size: 16, color: AppSurfaces.of(context).muted)),
    ];

    // Head of the row: who (avatar and name, one 48 high target opening the user) or, without an author, the forum;
    // then when and where; the marks at the end. The settings of the card (highlighted name, recent time) apply as
    // before.
    final Widget who;
    if (author != null) {
      // An anonymous author (the forum's app API lists anonymous threads, named "匿名" without a page) has no url:
      // nothing to open, so no tap at all, instead of the "open in app" page for the forum root an empty url
      // would resolve to.
      final canOpenAuthor = !disableTap && author!.url.isNotEmpty;
      Future<void> openAuthor() async => context.dispatchAsUrl(author!.url);
      who = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canOpenAuthor ? openAuthor : null,
        child: Semantics(
          link: canOpenAuthor,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _authorTapSize, minWidth: _authorTapSize),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(child: _buildAvatar(context)),
                sizedBoxW8H8,
                Flexible(child: SingleLineText(author!.name, style: nameStyle)),
              ],
            ),
          ),
        ),
      );
    } else {
      who = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _authorTapSize),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: context.t.myThreadPage.forum,
              child: AppIconTile(
                Icons.forum_outlined,
                size: _avatarSize,
                color: AppSurfaces.of(context).card,
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
            ),
            sizedBoxW8H8,
            Flexible(child: SingleLineText(context.displayText('$forum'), style: nameStyle)),
          ],
        ),
      );
    }
    final meta = <Widget>[
      if (publishTime != null) Text(publishTime!.yyyyMMDD(), style: timeStyle),
      // The forum is the title of the head already when there is no author.
      if (author != null && forum != null)
        Text(context.displayText(forum!), style: _metaStyle(context), maxLines: 1, overflow: TextOverflow.ellipsis),
    ];

    // The date (and forum) go under the name instead of cutting it when the head is narrow (large text).
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [who, ...meta],
            ),
          ),
          if (marks.isNotEmpty) ...[
            sizedBoxW8H8,
            // The marks give way too on a very narrow head: the tag is cut before anything overflows.
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (i, mark) in marks.indexed) ...[
                    if (i > 0) const SizedBox(width: 6),
                    if (i == 0 && (threadType?.name.isNotEmpty ?? false)) Flexible(child: mark) else mark,
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Thread type (or forum, for the latest threads) as a small neutral tag, like the forum tags of the homepage guide.
  Widget _buildTypeTag(BuildContext context, String name) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: DecoratedBox(
        decoration: BoxDecoration(color: AppSurfaces.of(context).card, borderRadius: BorderRadius.circular(5)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            context.displayText(name),
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

  /// Subtle marker of a thread the current account replied to: theme tertiary color, tooltip with the words.
  Widget _buildRepliedMark(BuildContext context) => Tooltip(
    message: context.t.threadCard.replied,
    child: Icon(Icons.reply_outlined, size: 16, color: Theme.of(context).colorScheme.tertiary),
  );

  /// Build a thread card that has [author] (or [forum] when [author] is null)
  /// info like title, thread title or
  /// content as body, and thread info as bottom.
  Widget _buildContent(BuildContext context, SettingsState state) {
    final infoRowAlignCenter = state.settingsMap.threadCardInfoRowAlignCenter;
    final showLastReplyAuthor = state.settingsMap.threadCardShowLastReplyAuthor;
    final highlightInfoRow = state.settingsMap.threadCardHighlightInfoRow;
    final showExcerpt = state.settingsMap.threadCardShowExcerpt;
    final thumbnailMode = state.settingsMap.threadThumbnailMode;
    final externalImages = state.settingsMap.threadCardExternalThumbnails;
    final dataSaver = DataSaverMode.fromIndex(state.settingsMap.dataSaverMode);

    final visited = progress != null && _newReplies == 0;

    // The list decides on the data saver when its first card is built, thumbnails or not.
    return DataSaverPageDecision(
      mode: dataSaver,
      child: _wrapWithCard(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // TODO: Tap to navigate to user space.
            _buildCardTitle(context, state),
            Padding(
              padding: edgeInsetsL16R16,
              child: Row(
                children: [
                  Expanded(
                    // The thread title leads the row, as in the homepage guide; forum set colors and weights stay. A
                    // thread read before is no longer bold and dimmed, as visited links are, until replies are
                    // posted after the visit.
                    child: Text(
                      context.displayText(title),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: visitedTitleStyle(
                        context,
                        Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontSize: 16.5,
                          color: css?.color,
                          fontWeight: css?.fontWeight ?? (visited ? FontWeight.w400 : FontWeight.w700),
                          height: 1.45,
                        ),
                        visited: visited,
                        background: AppSurfaces.of(context).page,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (ThreadPreviewSection.shows(
              preview,
              showExcerpt: showExcerpt,
              thumbnailMode: thumbnailMode,
              externalImages: externalImages,
            ))
              ThreadPreviewSection(
                preview!,
                showExcerpt: showExcerpt,
                thumbnailMode: thumbnailMode,
                externalImages: externalImages,
                dataSaver: dataSaver,
              ),
            if (quotedMessage != null)
              Padding(
                padding: edgeInsetsL16R16,
                child: Row(children: [Expanded(child: QuotedText(context.displayText(quotedMessage ?? '')))]),
              ),
            _buildInfoWidgetRow(
              context: context,
              infoRowAlignCenter: infoRowAlignCenter,
              showLastReplyAuthor: showLastReplyAuthor,
              highlightInfoRow: highlightInfoRow,
            ),
          ].insertBetween(const SizedBox(height: 6)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsBloc, SettingsState>(
      buildWhen: (prev, curr) {
        final pm = prev.settingsMap;
        final cm = curr.settingsMap;

        return pm.threadCardInfoRowAlignCenter != cm.threadCardInfoRowAlignCenter ||
            pm.threadCardShowLastReplyAuthor != cm.threadCardShowLastReplyAuthor ||
            pm.threadCardHighlightRecentThread != cm.threadCardHighlightRecentThread ||
            pm.threadCardHighlightAuthorName != cm.threadCardHighlightAuthorName ||
            pm.threadCardHighlightInfoRow != cm.threadCardHighlightInfoRow ||
            pm.threadCardShowExcerpt != cm.threadCardShowExcerpt ||
            pm.threadCardThumbnailMode != cm.threadCardThumbnailMode ||
            pm.threadCardExternalThumbnails != cm.threadCardExternalThumbnails;
      },
      builder: _buildContent,
    );
  }
}

/// The hairline between two rows of a list of thread cards: the [AppSurfaces.line] color, inset as far as the texts of
/// the rows.
class ThreadListSeparator extends StatelessWidget {
  /// Constructor.
  const ThreadListSeparator({super.key});

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: AppSurfaces.of(context).line);
}

/// Horizontal padding of a list of thread cards [width] wide: none on phones, the rows run to the edges and keep their
/// own inner padding; centered at most [appListMaxWidth] wide on wide windows.
EdgeInsets threadListPadding(double width) => appCenteredPadding(width, minPadding: 0);

/// The query of [ScreenPaths.threadV1] a thread card opens its thread with.
Map<String, String?> threadQuery({required String threadID, required String title, ThreadType? threadType}) => {
  'tid': threadID,
  'appBarTitle': title,
  'threadTypeName': threadType?.name,
  'threadTypeID': threadType?.url.tryParseAsUri().tryGetQueryParameters()?['typeid'],
};

/// Opens a thread as its card does: on the right of a wide list page, else as a page of its own. [newTab] as
/// [openThreadInPane] has it.
Future<void> openThread(
  BuildContext context, {
  required String threadID,
  required String title,
  ThreadType? threadType,
  bool? newTab,
}) async {
  final query = threadQuery(threadID: threadID, title: title, threadType: threadType);
  if (openThreadInPane(context, query, newTab: newTab)) {
    return;
  }
  await context.pushNamed(ScreenPaths.threadV1, queryParameters: query);
}

/// Card to show thread info.
class NormalThreadCard extends StatelessWidget {
  /// Constructor.
  const NormalThreadCard(this.thread, {this.disableTap = false, this.onPick, this.onStartPicking, super.key});

  /// Thread data.
  final NormalThread thread;

  /// Creat a card that disable tap gestures.
  final bool disableTap;

  /// The list is picking threads: a tap (or a long press) picks or unpicks this one instead of opening it.
  final VoidCallback? onPick;

  /// The list can pick threads: a long press (the context menu on desktop) starts picking with this one.
  final VoidCallback? onStartPicking;

  @override
  Widget build(BuildContext context) {
    // Topics of locally blocked users are hidden, the list and its pagination stay untouched.
    ThreadAuthorCache.record(thread.threadID, thread.author.uid);
    // The page of one forum: the forum filters do not apply, the user opened it.
    if (isBlockedByCurrentUser(context, thread.author.uid) ||
        isThreadFilteredOut(context, title: thread.title, byForum: false)) {
      return const SizedBox.shrink();
    }
    return _CardLayout(
      threadID: thread.threadID,
      title: thread.title,
      preview: thread.preview,
      author: thread.author,
      publishTime: thread.publishDate,
      threadType: thread.threadType,
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      lastReplyAuthor: thread.latestReplyAuthor,
      latestReplyTime: thread.latestReplyTime,
      price: thread.price,
      privilege: thread.privilege,
      css: thread.css,
      stateSet: thread.stateSet,
      disableTap: disableTap,
      isRecentThread: thread.isRecentThread,
      replied: isThreadReplied(context, thread.threadID),
      progress: visitMarkOf(context, thread.threadID),
      onPick: onPick,
      onStartPicking: onStartPicking,
    );
  }
}

/// Card to show a thread in search result.
class SearchedThreadCard extends StatelessWidget {
  /// Constructor.
  const SearchedThreadCard(this.thread, {this.onPick, this.onStartPicking, super.key});

  /// Thread model.
  final SearchedThread thread;

  /// See [NormalThreadCard.onPick].
  final VoidCallback? onPick;

  /// See [NormalThreadCard.onStartPicking].
  final VoidCallback? onStartPicking;

  @override
  Widget build(BuildContext context) {
    ThreadAuthorCache.record('${thread.threadID}', thread.author.uid);
    if (isBlockedByCurrentUser(context, thread.author.uid) ||
        isThreadFilteredOut(context, title: thread.title, fid: fidOfForumUrl(thread.forumUrl))) {
      return const SizedBox.shrink();
    }
    return _CardLayout(
      threadID: '${thread.threadID}',
      title: thread.title,
      preview: thread.preview,
      forum: thread.forumName,
      author: thread.author,
      publishTime: thread.publishTime,
      progress: visitMarkOf(context, '${thread.threadID}'),
      onPick: onPick,
      onStartPicking: onStartPicking,
    );
  }
}

/// Card to show current user's thread info in "My Thread" page.
class MyThreadCard extends StatelessWidget {
  /// Constructor.
  const MyThreadCard(this.thread, {this.onPick, this.onStartPicking, super.key});

  /// Thread model.
  final MyThread thread;

  /// See [NormalThreadCard.onPick].
  final VoidCallback? onPick;

  /// See [NormalThreadCard.onStartPicking].
  final VoidCallback? onStartPicking;

  @override
  Widget build(BuildContext context) {
    return _CardLayout(
      threadID: thread.threadID,
      title: thread.title,
      preview: thread.preview,
      forum: thread.forumName,
      stateSet: thread.stateSet,
      // The date as the forum prints it (its wall clock); the info row tells the same time relative to now.
      publishTime: thread.latestReplyClock ?? thread.latestReplyTime,
      quotedMessage: thread.quotedMessage,
      lastReplyAuthor: thread.latestReplyAuthor,
      latestReplyTime: thread.latestReplyTime,
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      progress: visitMarkOf(context, thread.threadID),
      onPick: onPick,
      onStartPicking: onStartPicking,
    );
  }
}

/// Card to show result in "Latest thread" page.
class LatestThreadCard extends StatelessWidget {
  /// Constructor.
  const LatestThreadCard(this.thread, {this.onPick, this.onStartPicking, super.key});

  /// Thread model.
  final LatestThread thread;

  /// See [NormalThreadCard.onPick].
  final VoidCallback? onPick;

  /// See [NormalThreadCard.onStartPicking].
  final VoidCallback? onStartPicking;

  @override
  Widget build(BuildContext context) {
    final showExcerpt = context.select<SettingsBloc, bool>((bloc) => bloc.state.settingsMap.threadCardShowExcerpt);
    ThreadAuthorCache.record(thread.threadID, thread.threadAuthor?.uid);
    if (isBlockedByCurrentUser(context, thread.threadAuthor?.uid) ||
        isThreadFilteredOut(context, title: thread.title, fid: fidOfForumUrl(thread.forumUrl))) {
      return const SizedBox.shrink();
    }
    return _CardLayout(
      threadID: thread.threadID!,
      title: thread.title!,
      preview: thread.preview,
      author: thread.latestReplyAuthor,
      // FIXME: Do not use thread type to represent forum.
      threadType: ThreadType(name: thread.forumName!, url: thread.forumUrl!),
      publishTime: thread.latestReplyTime,
      // The forum's own excerpt of a search row goes with the excerpts setting; a reply quoted always shows.
      quotedMessage: thread.quoteIsExcerpt && !showExcerpt ? null : thread.quotedMessage,
      progress: visitMarkOf(context, thread.threadID),
      // Not shown on this card, still the replies since the last visit undim the title.
      markReplies: thread.replyCount,
      onPick: onPick,
      onStartPicking: onStartPicking,
    );
  }
}

/// [style] of a thread title, dimmed when the thread was [visited] (read before by the current account), as visited
/// links are: its own color (a forum may color a title; else the theme's text color) at a lower opacity.
///
/// Never dimmer than text that reads on its [background] ([readableContrast], more with the platform's high contrast):
/// in a theme (or a forum color) where [visitedTitleOpacity] would not read, the title is dimmed less, down to not at
/// all. [background] defaults to the one of a card ([Card], `AppSurface`); pass the color the title is on otherwise.
TextStyle? visitedTitleStyle(BuildContext context, TextStyle? style, {required bool visited, Color? background}) {
  if (!visited) {
    return style;
  }
  final theme = Theme.of(context);
  final color = style?.color ?? DefaultTextStyle.of(context).style.color ?? theme.colorScheme.onSurface;
  final behind = background ?? theme.cardTheme.color ?? AppSurfaces.ofTheme(theme).card;
  final needed = (MediaQuery.maybeHighContrastOf(context) ?? false) ? highContrastVisitedTitle : readableContrast;
  double contrastAt(double opacity) =>
      contrastRatio(Color.alphaBlend(color.withValues(alpha: color.a * opacity), behind), behind);
  // A color hard to read at full opacity already is not made any harder.
  final target = math.min(needed, contrastAt(1));
  var opacity = visitedTitleOpacity;
  while (opacity < 1 && contrastAt(opacity) < target) {
    opacity = math.min(1, opacity + 0.05);
  }
  return (style ?? const TextStyle()).copyWith(color: color.withValues(alpha: color.a * opacity));
}

/// Opacity of the title of a thread read before, see [visitedTitleStyle].
const visitedTitleOpacity = 0.6;

/// Contrast a dimmed title keeps on the card with the platform's high contrast on: WCAG AAA for body text.
const highContrastVisitedTitle = 7.0;
