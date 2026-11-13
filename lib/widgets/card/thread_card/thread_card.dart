import 'package:collection/collection.dart';
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
import 'package:tsdm_client/themes/widget_themes.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
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

  /// Where the current account stopped reading this thread, null when it never read it: the title is dimmed and the
  /// replies posted since its last visit are told ("+N" after the reply count).
  final ReadingProgress? progress;

  /// See [NormalThreadCard.onPick].
  final VoidCallback? onPick;

  /// See [NormalThreadCard.onStartPicking].
  final VoidCallback? onStartPicking;

  /// A middle click opens the thread in a new tab of the wide list page's detail pane.
  Widget _wrapWithCard(BuildContext context, Widget child) => TwoPaneMiddleClickOpener(
    query: disableTap || onPick != null ? null : threadQuery(threadID: threadID, title: title, threadType: threadType),
    child: _card(context, child),
  );

  Card _card(BuildContext context, Widget child) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
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
    return HeroUserAvatar(username: author!.name, avatarUrl: author!.avatarUrl, disableHero: true);
  }

  /// Size of the tap target of the avatar: the minimum of the platform guidelines.
  static const double _authorTapSize = 48;

  /// Mainly for test.
  final bool disableTap;

  Widget _buildInfoWidgetRow({
    required BuildContext context,
    required bool infoRowAlignCenter,
    required bool showLastReplyAuthor,
    required bool highlightInfoRow,
  }) {
    final infoColor = switch (highlightInfoRow) {
      true => Theme.of(context).colorScheme.secondary,
      false => null,
    };

    final newReplies = progress?.newRepliesOf(replyCount) ?? 0;
    final infoList = <_ThreadInfo>[
      if (replyCount != null) (Icons.forum_outlined, '$replyCount', newReplies > 0 ? '+$newReplies' : null),
      if (viewCount != null) (Icons.bar_chart_outlined, '$viewCount', null),
      if (showLastReplyAuthor && lastReplyAuthor != null) (Icons.person_outline, lastReplyAuthor!.name, null),
      if (latestReplyTime != null) (Icons.timelapse_outlined, latestReplyTime!.elapsedTillNow(context), null),
      if ((price ?? 0) > 0) (FontAwesomeIcons.coins, '$price', null),
      if ((privilege ?? 0) > 0) (Icons.feedback_outlined, '$privilege', null),
    ];

    if (infoList.isEmpty) {
      return sizedBoxEmpty;
    }

    if (infoRowAlignCenter) {
      // In center.
      return Padding(
        padding: edgeInsetsL16R16B12,
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: infoList
                    .map(
                      (e) => Expanded(
                        child: Row(
                          children: [
                            Icon(e.$1, size: smallIconSize, color: infoColor),
                            sizedBoxW4H4,
                            Expanded(
                              child: _infoText(
                                context,
                                e,
                                style: TextStyle(fontSize: smallTextSize, color: infoColor),
                                overflow: TextOverflow.clip,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      );
    } else {
      // Not in center.
      return Padding(
        padding: edgeInsetsL16R16B12,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: infoList
                .map(
                  (e) => [
                    Icon(e.$1, size: smallIconSize, color: infoColor),
                    sizedBoxW4H4,
                    _infoText(
                      context,
                      e,
                      style: TextStyle(fontSize: smallTextSize, color: infoColor),
                    ),
                    sizedBoxW12H12,
                  ],
                )
                .flattened
                .toList(),
          ),
        ),
      );
    }
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
    final highlightRecentThread = state.settingsMap.threadCardHighlightRecentThread;
    final TextStyle? authorNameStyle;
    if (state.settingsMap.threadCardHighlightAuthorName) {
      authorNameStyle = TextStyle(color: Theme.of(context).colorScheme.primary);
    } else {
      authorNameStyle = null;
    }

    final TextStyle? timeStyle;
    if (isRecentThread && highlightRecentThread) {
      timeStyle = TextStyle(
        color: Theme.of(context).colorScheme.secondary,
        fontSize: Theme.of(context).textTheme.labelMedium?.fontSize,
      );
    } else {
      timeStyle = TextStyle(fontSize: Theme.of(context).textTheme.labelMedium?.fontSize);
    }

    final forumNameStyle = TextStyle(
      color: Theme.of(context).colorScheme.secondary,
      fontSize: Theme.of(context).textTheme.labelMedium?.fontSize,
    );

    final textTheme = Theme.of(context).textTheme;
    final nameStyle = textTheme.titleSmall?.merge(authorNameStyle);
    // Marks at the end of the head: replied by the current account, thread states, thread type (or forum) tag.
    final marks = <Widget>[
      if (replied) _buildRepliedMark(context),
      if (stateSet != null) ...stateSet!.map((e) => Icon(e.icon, size: 16)),
      if (threadType?.name.isNotEmpty ?? false) _buildTypeTag(context, threadType!.name),
    ];

    // Head of the card: who (avatar and name, both open the user) or, without an author, the forum; then when and
    // where on one wrapping line; the marks stay at the end. Replaces a ListTile whose fixed three line layout cut
    // the forum name with a large font. The settings of the card (highlighted name, recent time) apply as before.
    final Widget leading;
    final Widget name;
    if (author != null) {
      // An anonymous author (the forum's app API lists anonymous threads, named "匿名" without a page) has no url:
      // nothing to open, so no tap at all, instead of the "open in app" page for the forum root an empty url
      // would resolve to.
      final canOpenAuthor = !disableTap && author!.url.isNotEmpty;
      Future<void> openAuthor() async => context.dispatchAsUrl(author!.url);
      // The avatar is a 48 wide tap target around the 40 wide circle, named after the author (the circle itself has
      // nothing to read); the name beside it opens the same page and is read as a link.
      leading = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canOpenAuthor ? openAuthor : null,
        child: Semantics(
          button: canOpenAuthor,
          label: author!.name,
          excludeSemantics: true,
          child: SizedBox.square(
            dimension: _authorTapSize,
            child: Center(child: _buildAvatar(context)),
          ),
        ),
      );
      name = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canOpenAuthor ? openAuthor : null,
        child: Semantics(
          link: canOpenAuthor,
          child: SingleLineText(author!.name, style: nameStyle),
        ),
      );
    } else {
      final colorScheme = Theme.of(context).colorScheme;
      leading = Tooltip(
        message: context.t.myThreadPage.forum,
        child: AppIconTile(
          Icons.forum_outlined,
          color: colorScheme.secondaryContainer,
          foregroundColor: colorScheme.onSecondaryContainer,
        ),
      );
      name = SingleLineText(context.displayText('$forum'), style: nameStyle);
    }
    final meta = <Widget>[
      // The date breaks to a second line rather than being cut where the head is narrow (large text, the marks at the
      // end).
      if (publishTime != null) Text(publishTime!.yyyyMMDD(), style: timeStyle),
      // The forum is the title of the head already when there is no author.
      if (author != null && forum != null)
        SingleLineText(context.displayText(forum!), style: forumNameStyle, overflow: TextOverflow.ellipsis),
    ];

    // The 48 wide avatar target keeps its circle where the 40 wide circle was: 4 less padding before and above it, 4
    // less gap after it, the circle in the middle of its box. The row is centered: at the default text size (texts
    // lower than the box) the circle and the texts stay where they were and the head grows 4 below; at a large size
    // the texts decide the height as before and everything is 4 higher.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          leading,
          sizedBoxW8H8,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                name,
                if (meta.isNotEmpty) Wrap(spacing: 8, runSpacing: 2, children: meta),
              ],
            ),
          ),
          if (marks.isNotEmpty) ...[
            sizedBoxW8H8,
            Row(mainAxisSize: MainAxisSize.min, children: marks.insertBetween(sizedBoxW4H4)),
          ],
        ],
      ),
    );
  }

  /// Thread type (or forum, for the latest threads) as a small tag, like the forum tags of the homepage guide.
  Widget _buildTypeTag(BuildContext context, String name) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: DecoratedBox(
        decoration: BoxDecoration(color: colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            context.displayText(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.onSecondaryContainer),
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
              padding: edgeInsetsL16R16B12,
              child: Row(
                children: [
                  Expanded(
                    // The thread title leads the card, as in the homepage guide; forum set colors and weights stay. A
                    // thread read before is dimmed, as visited links are.
                    child: Text(
                      context.displayText(title),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: visitedTitleStyle(
                        context,
                        Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: css?.color,
                          fontWeight: css?.fontWeight ?? FontWeight.w500,
                          height: 1.45,
                        ),
                        visited: progress != null,
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
                padding: edgeInsetsL16R16B12,
                child: Row(children: [Expanded(child: QuotedText(context.displayText(quotedMessage ?? '')))]),
              ),
            _buildInfoWidgetRow(
              context: context,
              infoRowAlignCenter: infoRowAlignCenter,
              showLastReplyAuthor: showLastReplyAuthor,
              highlightInfoRow: highlightInfoRow,
            ),
          ].insertBetween(sizedBoxW4H4),
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
      progress: readingProgressOf(context, thread.threadID),
      onPick: onPick,
      onStartPicking: onStartPicking,
    );
  }
}

/// Card to show a thread in search result.
class SearchedThreadCard extends StatelessWidget {
  /// Constructor.
  const SearchedThreadCard(this.thread, {super.key});

  /// Thread model.
  final SearchedThread thread;

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
      progress: readingProgressOf(context, '${thread.threadID}'),
    );
  }
}

/// Card to show current user's thread info in "My Thread" page.
class MyThreadCard extends StatelessWidget {
  /// Constructor.
  const MyThreadCard(this.thread, {super.key});

  /// Thread model.
  final MyThread thread;

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
      progress: readingProgressOf(context, thread.threadID),
    );
  }
}

/// Card to show result in "Latest thread" page.
class LatestThreadCard extends StatelessWidget {
  /// Constructor.
  const LatestThreadCard(this.thread, {super.key});

  /// Thread model.
  final LatestThread thread;

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
      progress: readingProgressOf(context, thread.threadID),
    );
  }
}

/// [style] of a thread title, dimmed when the thread was [visited] (read before by the current account), as visited
/// links are: its own color (a forum may color a title) at a lower opacity.
TextStyle? visitedTitleStyle(BuildContext context, TextStyle? style, {required bool visited}) {
  if (!visited) {
    return style;
  }
  final color = style?.color ?? DefaultTextStyle.of(context).style.color ?? Theme.of(context).colorScheme.onSurface;
  return (style ?? const TextStyle()).copyWith(color: color.withValues(alpha: color.a * visitedTitleOpacity));
}

/// Opacity of the title of a thread read before, see [visitedTitleStyle].
const visitedTitleOpacity = 0.6;
