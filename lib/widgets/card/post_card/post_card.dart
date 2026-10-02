import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post_report/view/post_report_dialog.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/widgets/interactive_post_entry.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/medal.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/thread_floor_interaction_mode.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/adaptive_ink_response.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
import 'package:tsdm_client/widgets/card/packet_card.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/card/post_card/show_user_brief_profile_dialog.dart';
import 'package:tsdm_client/widgets/card/rate_card.dart';
import 'package:tsdm_client/widgets/copy_content_dialog.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';
import 'package:url_launcher/url_launcher.dart';

/// Width of the secondary title, capped by available room without enlarging on rotation.
double postAuthorSecondBadgeWidth(double availableWidth) =>
    SecondaryTitleBadge.fitWidth(availableWidth, preferred: SecondaryTitleBadge.widthFor(authorBadgeHeight));

/// Actions in post context menu.
///
/// * State of [viewTheAuthor] and [viewAllAuthors] are thread level state so
///   this state is stored by the parent thread. Disable these actions when
///   there is no available thread above current post in the widget tree.
enum _PostCardActions {
  reply,
  rate,

  /// Only view posts published by current author.
  viewTheAuthor,

  /// View all authors.
  viewAllAuthors,

  /// Edit the post.
  ///
  /// Only available when the current user is the author of post.
  edit,

  /// Share the post.
  ///
  /// Share with thread and post id, and 'fromuid=$UID'.
  share,

  /// Open the post link in browser.
  ///
  /// Use the anchor not works on mobile UI no matter it always is or originally was `findpost`.
  openInBrowser,

  /// Open the dialog to copy contents.
  openAndCopy,

  /// Copy post id.
  copyPid,

  /// Report the post to the forum.
  ///
  /// Only available when the forum offered the report link of this floor to the account that read the page (#127).
  report,
}

/// Card for a [Post] model.
///
/// Usually inside a ThreadPage.
class PostCard extends StatefulWidget {
  /// Constructor.
  const PostCard(this.post, {this.replyCallback, this.onEdited, super.key});

  /// [Post] model to show.
  final Post post;

  /// A callback function that will be called every time when user try to
  /// reply to the post.
  final FutureOr<void> Function(User user, int? postFloor, String? replyAction)? replyCallback;

  /// Called after a successful edit, before reloading, so the thread can retain this floor as its scroll target.
  final VoidCallback? onEdited;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> with AutomaticKeepAliveClientMixin, LoggerMixin {
  Future<void> _rateCallback() async {
    await context.pushNamed(
      ScreenPaths.ratePost,
      pathParameters: <String, String>{
        'username': widget.post.author.name,
        'pid': widget.post.postID,
        'floor': '${widget.post.postFloor}',
        'rateAction': widget.post.rateAction!,
      },
    );
  }

  Widget _buildAuthorRow(BuildContext context) {
    final avatarHeroTag = 'Avatar-${widget.post.author.uid}-${widget.post.postFloor}';
    final nameHeroTag = 'Name-${widget.post.author.name}-${widget.post.postFloor}';

    // No thread above the card on the notice detail page.
    final knownMedals = context.readOrNull<ThreadBloc>()?.state.postMedals ?? const [];

    final medals =
        widget.post.postMedals
            ?.map((userMedal) {
              final foundMedal = knownMedals.firstWhereOrNull((e) => e.id == userMedal.menuItemId);
              if (foundMedal == null) {
                return null;
              }

              return Medal(
                name: foundMedal.name,
                description: foundMedal.description,
                image: userMedal.image,
                alter: userMedal.alter,
              );
            })
            .whereType<Medal>()
            .toList() ??
        [];

    Future<void> openBriefProfile() async {
      if (widget.post.userBriefProfile != null) {
        await showUserBriefProfileDialog(
          context,
          widget.post.userBriefProfile!,
          widget.post.author.url,
          avatarHeroTag: avatarHeroTag,
          nameHeroTag: nameHeroTag,
          medals: medals,
          badge: widget.post.badge,
          secondBadge: widget.post.secondBadge,
          signature: widget.post.signature,
          pokemon: widget.post.pokemon,
          checkin: widget.post.checkin,
        );
      }
    }

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final nickname = widget.post.userBriefProfile?.nickname;
    final userGroup = widget.post.userBriefProfile?.userGroup;
    final publishTime = widget.post.publishTime;
    final floor = widget.post.postFloor;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: openBriefProfile,
            child: SizedBox(
              width: 44,
              height: 44,
              child: HeroUserAvatar(
                avatarUrl: widget.post.author.avatarUrl,
                username: widget.post.author.name,
                heroTag: avatarHeroTag,
              ),
            ),
          ),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    GestureDetector(
                      onTap: openBriefProfile,
                      child: Hero(
                        tag: nameHeroTag,
                        flightShuttleBuilder: (_, _, _, _, toHeroContext) => DefaultTextStyle(
                          style: DefaultTextStyle.of(toHeroContext).style,
                          child: toHeroContext.widget,
                        ),
                        child: Text(
                          widget.post.author.name,
                          style: textTheme.titleSmall?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    if (nickname != null)
                      Text(
                        nickname,
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.secondary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                  ],
                ),
                sizedBoxW2H2,
                Text(
                  [
                    if (userGroup != null && userGroup.isNotEmpty) userGroup,
                    if (publishTime != null) publishTime.yyyyMMDDHHMMSS(),
                  ].join(' · '),
                  style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                ),
                // Badges the forum renders in this floor's author column: the user group badge and the secondary title
                // of this author. Nothing about the current account is used here. They wrap below each other on narrow
                // windows instead of being squeezed, the secondary title keeps its 184:100 ratio.
                if (widget.post.badge != null || widget.post.secondBadge != null) ...[
                  sizedBoxW8H8,
                  LayoutBuilder(
                    builder: (context, constraints) => Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (widget.post.badge != null)
                          CachedImage(
                            widget.post.badge!,
                            height: authorBadgeHeight,
                            maxWidth: 160,
                            fit: BoxFit.contain,
                          ),
                        if (widget.post.secondBadge != null)
                          SecondaryTitleBadge(
                            widget.post.secondBadge!,
                            width: postAuthorSecondBadgeWidth(constraints.maxWidth),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          sizedBoxW8H8,
          DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                floor == null ? '#' : '#$floor',
                style: textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLastEditInfoRow(BuildContext context) {
    return Padding(
      padding: edgeInsetsL12T4R12,
      child: Text(
        context.t.postCard.lastEditInfo(username: widget.post.lastEditUsername!, time: widget.post.lastEditTime!),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }

  Widget _buildPostBody(BuildContext context) {
    final interactionMode = context.read<SettingsBloc>().state.settingsMap.threadFloorInteractionMode;
    final child = Row(
      children: [
        Expanded(
          child: Padding(
            padding: edgeInsetsL16R16,
            child: MunchedHtml(widget.post.data),
          ),
        ),
      ],
    );
    return switch (interactionMode) {
      ThreadFloorInteractionMode.adaptiveTapMenu => AdaptiveInkResponse(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        mouseCursor: MouseCursor.uncontrolled,
        behavior: HitTestBehavior.opaque,
        onAdaptiveContextTap: (tapPosition) async {
          // Get the position where the tap occurred.
          RelativeRect? position;
          position = RelativeRect.fromRect(
            tapPosition.globalPosition & Size.zero, // Rect from the tap position
            Offset.zero & MediaQuery.of(context).size, // Bounding box for the menu
          );
          final choice = await showMenu<_PostCardActions>(
            context: context,
            position: position,
            items: _buildContextMenuEntries(context),
          );

          if (choice == null || !context.mounted) {
            return;
          }

          await _onContextMenuItemSelected(context, choice);
        },
        child: child,
      ),
      ThreadFloorInteractionMode.tapToReply => GestureDetector(
        onTap: () async {
          await widget.replyCallback?.call(widget.post.author, widget.post.postFloor, widget.post.replyAction);
        },
        child: child,
      ),
    };
  }

  List<PopupMenuEntry<_PostCardActions>> _buildContextMenuEntries(BuildContext context) {
    final threadBloc = context.readOrNull<ThreadBloc>();
    final onlyVisibleUid = threadBloc?.state.onlyVisibleUid;
    final colorScheme = Theme.of(context).colorScheme;

    PopupMenuItem<_PostCardActions> item(_PostCardActions value, IconData icon, String text, {Color? color}) =>
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, color: color),
              sizedBoxPopupMenuItemIconSpacing,
              Flexible(
                child: Text(text, style: color == null ? null : TextStyle(color: color)),
              ),
            ],
          ),
        );

    // Same actions and conditions as before, grouped: answer the floor, change what is shown (author filter, edit),
    // share and copy, then report on its own in the error color.
    final groups = <List<PopupMenuEntry<_PostCardActions>>>[
      [
        item(_PostCardActions.reply, Icons.reply_outlined, context.t.postCard.reply),
        if (widget.post.rateAction != null)
          item(_PostCardActions.rate, Icons.rate_review_outlined, context.t.postCard.rate),
      ],
      [
        // Viewing all authors, can switch to only view current author mode.
        if (threadBloc != null && onlyVisibleUid == null && widget.post.author.uid != null)
          item(_PostCardActions.viewTheAuthor, Icons.person_outlined, context.t.postCard.onlyViewAuthor),
        // Viewing specified author now, can switch to view all authors mode.
        if (threadBloc != null && onlyVisibleUid != null)
          item(_PostCardActions.viewAllAuthors, Icons.group_outlined, context.t.postCard.viewAllAuthors),
        if (widget.post.editUrl != null) item(_PostCardActions.edit, Icons.edit_outlined, context.t.postCard.edit),
      ],
      [
        if (widget.post.shareLink != null) ...[
          item(_PostCardActions.share, Icons.share_outlined, context.t.postCard.share),
          item(_PostCardActions.openInBrowser, Icons.open_in_browser_outlined, context.t.postCard.openInBrowser),
          item(_PostCardActions.openAndCopy, Icons.copy_outlined, context.t.postCard.copyText),
          item(
            _PostCardActions.copyPid,
            Icons.numbers_outlined,
            context.t.postCard.copyPid(pid: widget.post.postID),
          ),
        ],
      ],
      [
        if (widget.post.reportTarget != null)
          item(_PostCardActions.report, Icons.flag_outlined, context.t.postReport.menu, color: colorScheme.error),
      ],
    ];

    return [
      // Which floor the menu acts on.
      PopupMenuItem<_PostCardActions>(
        enabled: false,
        height: 32,
        child: Text(
          '${widget.post.author.name.truncate(10, ellipsis: true)} #${widget.post.postFloor}',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colorScheme.secondary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      for (final group in groups.where((e) => e.isNotEmpty)) ...[const PopupMenuDivider(height: 8), ...group],
    ];
  }

  Future<void> _onContextMenuItemSelected(BuildContext context, _PostCardActions value) async {
    switch (value) {
      case _PostCardActions.reply:
        await widget.replyCallback?.call(widget.post.author, widget.post.postFloor, widget.post.replyAction);
      case _PostCardActions.rate:
        if (widget.post.rateAction != null) {
          await _rateCallback.call();
        }
      case _PostCardActions.viewTheAuthor:
        // Here is guaranteed a not-null `ThreadBloc`.
        context.read<ThreadBloc>().add(ThreadOnlyViewAuthorRequested(widget.post.author.uid!));
      case _PostCardActions.viewAllAuthors:
        // Here is guaranteed a not-null `ThreadBloc` and a
        // not-null author uid.
        context.read<ThreadBloc>().add(ThreadViewAllAuthorsRequested());
      case _PostCardActions.edit:
        final url = Uri.parse(widget.post.editUrl!);
        final editType = widget.post.isDraft ? PostEditType.editDraft.index : PostEditType.editPost.index;
        // Take everything the reload needs before the editor opens. While it is up the thread page may rebuild and
        // re-key this floor (the floor it scrolled to on the last reload loses its key on the next build, see
        // PostList), which replaces this card by a new element: `context.mounted` is then false here although the
        // thread is still on screen, and the reload silently never happened (GitHub #76).
        final threadBloc = context.read<ThreadBloc>();
        final onEdited = widget.onEdited;
        final postID = widget.post.postID;
        final page = widget.post.page;
        final edited = await context.pushNamed<bool>(
          ScreenPaths.editPost,
          pathParameters: {'editType': '$editType', 'fid': '${url.queryParameters["fid"]}'},
          queryParameters: {'tid': '${url.queryParameters["tid"]}', 'pid': '${url.queryParameters["pid"]}'},
        );
        if (!(edited ?? false)) {
          return;
        }
        if (threadBloc.isClosed) {
          // The thread page was left while the editor was open: nothing to reload.
          debug('post $postID edited but its thread page is gone, skip reload');
          return;
        }
        debug('post $postID edited, reload page $page');
        onEdited?.call();
        // A list may contain several loaded pages. Reload the edited post's page, not the last loaded page or 1.
        threadBloc.add(ThreadJumpPageRequested(page));
      case _PostCardActions.share:
        await copyToClipboard(context, widget.post.shareLink!);
      case _PostCardActions.openInBrowser:
        await launchUrl(Uri.parse(widget.post.shareLink!), mode: LaunchMode.externalApplication);
      case _PostCardActions.openAndCopy:
        final data =
            parseHtmlDocument(widget.post.data).body?.childNodes
                .map(
                  (e) => switch (e.nodeType) {
                    uh.Node.TEXT_NODE => e.text!.trim(),
                    uh.Node.ELEMENT_NODE => () {
                      final x = e as uh.Element;
                      if (x.tagName.toLowerCase() == 'script') {
                        return null;
                      }
                      return x.innerText.trim();
                    }(),
                    _ => null,
                  },
                )
                .whereType<String>()
                .join() ??
            '';
        await showCopySelectContentDialog(context: context, data: data);
      case _PostCardActions.copyPid:
        await copyToClipboard(context, widget.post.postID);
      case _PostCardActions.report:
        await showPostReportDialog(context, widget.post);
    }
  }

  Widget _buildContextMenuRow(BuildContext context) => Row(
    children: [
      const Spacer(),
      // The floor's action menu, at the end of the floor: muted rounded button, the icon stays the usual "more" so it
      // reads like the other menus of the app.
      PopupMenuButton(
        itemBuilder: _buildContextMenuEntries,
        onSelected: (value) async => _onContextMenuItemSelected(context, value),
        style: IconButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
        ),
      ),
      sizedBoxW8H8,
    ],
  );

  // TODO: Handle better.
  // FIXME: Fix rebuild when interacting with widgets inside.
  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Post author user info.
        _buildAuthorRow(context),
        // Last edit status.
        if (widget.post.lastEditUsername != null && widget.post.lastEditTime != null) _buildLastEditInfoRow(context),
        // Post body
        sizedBoxW12H12,
        InteractivePostEntry(data: widget.post.data, postId: widget.post.postID),
        _buildPostBody(context),
        // 红包 if any.
        if (widget.post.locked.isNotEmpty) ...widget.post.locked.where((e) => e.isValid()).map(LockedCard.new),
        if (widget.post.hasPoll) PollCard(widget.post.postID),
        if (widget.post.packetUrl != null) ...[
          sizedBoxW12H12,
          PacketCard(widget.post.packetUrl!, allTaken: widget.post.packetAllTaken),
        ],
        // Rate status if any.
        if (widget.post.rate != null) ...[
          sizedBoxW12H12,
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 712),
            child: RateCard(widget.post.rate!, widget.post.postID),
          ),
        ],
        // Context menu.
        _buildContextMenuRow(context),
      ],
    );
  }

  // Add mixin and return true to avoid post list shaking when scrolling.
  @override
  bool get wantKeepAlive => true;
}
