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
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/dialog.dart';
import 'package:tsdm_client/features/thread_preview/widgets/thread_preview_section.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/themes/widget_themes.dart';
import 'package:tsdm_client/widgets/adaptive_ink_response.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';
import 'package:url_launcher/url_launcher.dart';

typedef _ThreadInfo = (IconData, String);

/// All actions used in the context menu.
///
/// The context menu is opened by either long press or right click, depending on the platform.
enum _CtxMenuActions { openInBrowser, viewInfo }

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

  Card _wrapWithCard(BuildContext context, Widget child) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: AdaptiveInkResponse(
      onTap: disableTap
          ? null
          : () async {
              await context.pushNamed(
                ScreenPaths.threadV1,
                // pathParameters: {'id': threadID},
                // FIXME: Query parameters are not recognized by v2 yet.
                queryParameters: {
                  'tid': threadID,
                  'appBarTitle': title,
                  'threadTypeName': threadType?.name,
                  'threadTypeID': threadType?.url.tryParseAsUri().tryGetQueryParameters()?['typeid'],
                },
              );
            },
      onAdaptiveContextTap: (tapPosition) async {
        // Get the position where the tap occurred.
        RelativeRect? position;
        position = RelativeRect.fromRect(
          tapPosition.globalPosition & Size.zero, // Rect from the tap position
          Offset.zero & MediaQuery.of(context).size, // Bounding box for the menu
        );
        final choice = await showMenu<_CtxMenuActions>(
          context: context,
          position: position,
          items: <PopupMenuEntry<_CtxMenuActions>>[
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
          ],
        );

        if (choice == null || !context.mounted) {
          return;
        }

        switch (choice) {
          case _CtxMenuActions.openInBrowser:
            await launchUrl(
              Uri.parse('$baseUrl/forum.php?mod=viewthread&tid=$threadID'),
              mode: LaunchMode.externalApplication,
            );
          case _CtxMenuActions.viewInfo:
            await showCopyThreadInfoDialog(context: context, tid: threadID, title: title);
        }
      },
      child: child,
    ),
  );

  /// [author] MUST not be null.
  Widget _buildAvatar(BuildContext context) {
    return HeroUserAvatar(username: author!.name, avatarUrl: author!.avatarUrl, disableHero: true);
  }

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

    final infoList = <_ThreadInfo>[
      if (replyCount != null) (Icons.forum_outlined, '$replyCount'),
      if (viewCount != null) (Icons.bar_chart_outlined, '$viewCount'),
      if (showLastReplyAuthor && lastReplyAuthor != null) (Icons.person_outline, lastReplyAuthor!.name),
      if (latestReplyTime != null) (Icons.timelapse_outlined, latestReplyTime!.elapsedTillNow(context)),
      if ((price ?? 0) > 0) (FontAwesomeIcons.coins, '$price'),
      if ((privilege ?? 0) > 0) (Icons.feedback_outlined, '$privilege'),
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
                              child: Text(
                                e.$2,
                                style: TextStyle(fontSize: smallTextSize, color: infoColor),
                                maxLines: 1,
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
                    Text(
                      e.$2,
                      style: TextStyle(fontSize: smallTextSize, color: infoColor),
                      maxLines: 1,
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
      leading = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canOpenAuthor ? openAuthor : null,
        child: _buildAvatar(context),
      );
      name = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canOpenAuthor ? openAuthor : null,
        child: SingleLineText(author!.name, style: nameStyle),
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
      name = SingleLineText('$forum', style: nameStyle);
    }
    final meta = <Widget>[
      if (publishTime != null) SingleLineText(publishTime!.yyyyMMDD(), style: timeStyle),
      // The forum is the title of the head already when there is no author.
      if (author != null && forum != null) SingleLineText(forum!, style: forumNameStyle),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
      child: Row(
        children: [
          leading,
          sizedBoxW12H12,
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
            name,
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

    return _wrapWithCard(
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
                  // The thread title leads the card, as in the homepage guide; forum set colors and weights stay.
                  child: Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: css?.color,
                      fontWeight: css?.fontWeight ?? FontWeight.w500,
                      height: 1.45,
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
            ),
          if (quotedMessage != null)
            Padding(
              padding: edgeInsetsL16R16B12,
              child: Row(children: [Expanded(child: QuotedText(quotedMessage ?? ''))]),
            ),
          _buildInfoWidgetRow(
            context: context,
            infoRowAlignCenter: infoRowAlignCenter,
            showLastReplyAuthor: showLastReplyAuthor,
            highlightInfoRow: highlightInfoRow,
          ),
        ].insertBetween(sizedBoxW4H4),
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

/// Card to show thread info.
class NormalThreadCard extends StatelessWidget {
  /// Constructor.
  const NormalThreadCard(this.thread, {this.disableTap = false, super.key});

  /// Thread data.
  final NormalThread thread;

  /// Creat a card that disable tap gestures.
  final bool disableTap;

  @override
  Widget build(BuildContext context) {
    // Topics of locally blocked users are hidden, the list and its pagination stay untouched.
    ThreadAuthorCache.record(thread.threadID, thread.author.uid);
    if (isBlockedByCurrentUser(context, thread.author.uid)) {
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
    if (isBlockedByCurrentUser(context, thread.author.uid)) {
      return const SizedBox.shrink();
    }
    return _CardLayout(
      threadID: '${thread.threadID}',
      title: thread.title,
      preview: thread.preview,
      forum: thread.forumName,
      author: thread.author,
      publishTime: thread.publishTime,
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
    ThreadAuthorCache.record(thread.threadID, thread.threadAuthor?.uid);
    if (isBlockedByCurrentUser(context, thread.threadAuthor?.uid)) {
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
      quotedMessage: thread.quotedMessage,
    );
  }
}
