import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/notice_block_filter.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/notification/utils/relative_time.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

enum _Actions { markAsRead, markAsUnread, deleteItem, copyRawContent, blockAuthor, ignoreOnForum }

/// Widgets in this file are for models fetched through notification APIs.
///
/// Those models are the ones fetched through APIs.
///
/// Compare with the original v1 version, now all these notices are more
/// concrete.
///
/// Likely specialize the layout for all known messages is possible, but
/// currently only use a more normal layout to ensure all kinds of messages are
/// parsed successfully.

/// The html a personal message or broadcast message card hands to [MunchedHtml] for the summary [data]: its text,
/// never markup.
///
/// The summary is plain text since the forum's pages are parsed, but the forum keeps a numeric character reference
/// written in a message, which the parser decodes: `&#060;img src=…&#062;` comes back as a real tag, which rendered
/// would load a remote image or inject other markup. The copies stored by the v2 JSON API (until 2026-09) hold html
/// and entities (`他说&quot;好&quot;`). So [data] is read as an html fragment and only its text is kept, escaped:
/// entities decode, tags are dropped, never rendered.
@visibleForTesting
String summaryShownOf(String data) =>
    htmlEscape.convert(parseHtmlDocument('<html><body>$data</body></html>').body?.text ?? '');

/// Widget to display data in [NoticeV2].
class NoticeCardV2 extends StatefulWidget {
  /// Constructor.
  const NoticeCardV2(this.data, {super.key});

  /// Data to display.
  final NoticeV2 data;

  @override
  State<NoticeCardV2> createState() => _NoticeCardV2State();
}

class _NoticeCardV2State extends State<NoticeCardV2> {
  /// What the card shows of the notice, read once per notice.
  late NoticeInfo _info;

  @override
  void initState() {
    super.initState();
    _info = NoticeInfo.of(widget.data);
  }

  @override
  void didUpdateWidget(covariant NoticeCardV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _info = NoticeInfo.of(widget.data);
    }
  }

  void _onUrlLaunched({required bool markAsRead}) {
    // Update state to read if any link in rendered html launched. `mounted`, not `context.mounted`: reading `context`
    // on an unmounted state throws (the card is rebuilt while the pushed page is open).
    if (!mounted) {
      return;
    }
    if (markAsRead == widget.data.alreadyRead) {
      // Nothing changes: the badge must not count it twice.
      _recordMark(markAsRead: markAsRead);
      return;
    }

    if (markAsRead) {
      context.read<NotificationStateCubit>().decreaseNotice();
    } else {
      context.read<NotificationStateCubit>().increaseNotice();
    }
    _recordMark(markAsRead: markAsRead);
  }

  void _recordMark({required bool markAsRead}) {
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    if (uid == null) {
      return;
    }
    context.read<NotificationBloc>().add(
      NotificationMarkReadRequested(RecordMarkNotice(uid: uid, nid: widget.data.id, alreadyRead: markAsRead)),
    );
  }

  /// A tap on the card: the floor (or thread) the notice links, else the profile of the user of a friend, poke or wall
  /// notice; the notice is read either way.
  Future<void> _onTap() async {
    final url = _tapUrlOf(_info);
    _onUrlLaunched(markAsRead: true);
    if (url != null) {
      await context.dispatchAsUrl(url);
    }
  }

  Future<void> _openAuthor() async {
    final authorId = _info.authorId;
    if (authorId == null) {
      return;
    }
    await context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '$authorId'});
  }

  /// Reply to the floor of the notice on the notice detail page: the floor and the reply bar under it.
  Future<void> _quickReply() async {
    final target = _info.target;
    if (target == null || target.pid == null || target.tid == null) {
      return;
    }
    _onUrlLaunched(markAsRead: true);
    await context.pushNamed(
      ScreenPaths.reply,
      pathParameters: {'target': target.url},
      queryParameters: {'noticeType': '${NoticeType.reply.index}'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage.cardMenu;
    // Every list showing notice cards filters them already; the card checks again so a list that forgets (or holds
    // an old snapshot) never shows a notice of a blocked user.
    if (isBlockedNoticeAuthor(widget.data.authorId, currentBlockList(context))) {
      return const SizedBox.shrink();
    }
    final showBadge = getIt.get<SettingsRepository>().currentSettings.showUnreadNoticeBadge;
    final unread = showBadge && !widget.data.alreadyRead;
    final info = _info;
    final kindLabel = noticeKindLabel(context.t, info.kind);
    final author = info.author;
    final authorId = info.authorId;
    final colorScheme = Theme.of(context).colorScheme;
    final repliable = noticeKindRepliable(info.kind) && info.target?.pid != null && info.target?.tid != null;
    final kindIcon = noticeKindIcon(info.kind);
    final Widget leading;
    if (authorId != null) {
      // The author's avatar with the kind of the notice in its corner.
      leading = GestureDetector(
        onTap: _openAuthor,
        child: SizedBox.square(
          dimension: 40,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              HeroUserAvatar(
                username: author ?? '$authorId',
                avatarUrl: avatarUrlOfUid('$authorId'),
                disableHero: true,
              ),
              Positioned(
                right: -4,
                bottom: -4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                    border: Border.all(color: colorScheme.surfaceContainerLow, width: 2),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(kindIcon, size: 12, color: colorScheme.onSecondaryContainer),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      leading = info.kind == NoticeKind.system || info.kind == NoticeKind.manage
          ? AppIconTile(
              kindIcon,
              color: colorScheme.tertiaryContainer,
              foregroundColor: colorScheme.onTertiaryContainer,
            )
          : AppIconTile(kindIcon);
    }
    return _NotificationCardShell(
      key: ValueKey('notice-card-${widget.data.id}'),
      highlight: unread,
      onTap: _onTap,
      leading: Badge(isLabelVisible: unread, child: leading),
      title: Text(author ?? kindLabel),
      label: author != null ? kindLabel : null,
      timestamp: widget.data.timestamp,
      footer: repliable
          ? Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: ValueKey('notice-quick-reply-${widget.data.id}'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.reply_outlined, size: 18),
                label: Text(context.t.noticePage.quickReply),
                onPressed: _quickReply,
              ),
            )
          : null,
      menu: PopupMenuButton(
        itemBuilder: (_) => [
          if (!widget.data.alreadyRead)
            PopupMenuItem(
              value: _Actions.markAsRead,
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_read_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.markAsRead),
                ],
              ),
            ),
          if (widget.data.alreadyRead)
            PopupMenuItem(
              value: _Actions.markAsUnread,
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_unread_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.markAsUnread),
                ],
              ),
            ),
          PopupMenuItem(
            value: _Actions.deleteItem,
            child: Row(
              children: [
                Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                sizedBoxPopupMenuItemIconSpacing,
                Text(tr.delete.title, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
          // Only offered when the notice's own ignore link names its author and type. System notices (author 0)
          // can only be ignored for everybody on the forum, there is no user to block.
          if (widget.data.authorId != null && widget.data.ignoreType != null) ...<PopupMenuEntry<_Actions>>[
            const PopupMenuDivider(),
            // Not listening: the menu is built on tap, outside of the build phase.
            if (widget.data.authorId! > 0 && widget.data.authorId != currentBlockList(context, listen: false).ownerUid)
              PopupMenuItem(
                value: _Actions.blockAuthor,
                child: Row(
                  children: [
                    const Icon(Icons.block_outlined),
                    sizedBoxPopupMenuItemIconSpacing,
                    Expanded(child: Text(context.t.userBlock.block)),
                  ],
                ),
              ),
            PopupMenuItem(
              value: _Actions.ignoreOnForum,
              child: Row(
                children: [
                  const Icon(Icons.notifications_off_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Expanded(child: Text(context.t.userBlock.serverRules.entry)),
                ],
              ),
            ),
          ] else ...<PopupMenuEntry<_Actions>>[
            // Without the ignore link there is nothing to act on; say so instead of silently dropping the entries
            // above.
            const PopupMenuDivider(),
            PopupMenuItem<_Actions>(enabled: false, child: Text(context.t.userBlock.serverRules.notAvailable)),
          ],
          if (context.read<SettingsBloc>().state.settingsMap.enableDebugOperations) ...<PopupMenuEntry<_Actions>>[
            const PopupMenuDivider(),
            PopupMenuItem(value: _Actions.copyRawContent, child: Text(tr.copyRawContent)),
          ],
        ],
        onSelected: (value) async {
          switch (value) {
            case _Actions.blockAuthor:
              // The name is the one the notice gives (the forum's app API, or the author's link in the body); the
              // management page shows the uid otherwise.
              final authorId = widget.data.authorId!;
              await confirmAndBlockUser(context, uid: authorId, username: _info.author ?? 'UID $authorId');
            case _Actions.ignoreOnForum:
              await showNoticeIgnoreDialog(
                context,
                NoticeIgnoreTarget(type: widget.data.ignoreType!, authorId: widget.data.authorId!),
              );
            case _Actions.markAsRead:
              _onUrlLaunched(markAsRead: true);
            case _Actions.markAsUnread:
              _onUrlLaunched(markAsRead: false);
            case _Actions.deleteItem:
              final tr = context.t.noticePage.cardMenu.delete;
              final result = await showQuestionDialog(
                context: context,
                title: tr.title,
                message: tr.detail,
                dangerous: true,
              );
              if (!context.mounted || result == null || !result) {
                return;
              }

              if (!widget.data.alreadyRead) {
                context.read<NotificationStateCubit>().decreaseNotice();
              }
              context.read<NotificationBloc>().add(
                NotificationDeleteNoticeRequested(
                  uid: context.read<AuthenticationRepository>().currentUser!.uid!,
                  nid: widget.data.id,
                ),
              );
            case _Actions.copyRawContent:
              await copyToClipboard(context, widget.data.data);
          }
        },
      ),
      body: MunchedHtml(
        widget.data.data,
        options: MunchOptions(onUrlLaunched: () => _onUrlLaunched(markAsRead: true)),
      ),
    );
  }
}

/// Where a tap on a notice card with [info] goes: the floor or thread it links, else the profile of the user of a
/// friend, poke or wall notice; null when there is nowhere to go.
String? _tapUrlOf(NoticeInfo info) {
  if (info.target case final target?) {
    return target.url;
  }
  final authorId = info.authorId;
  if (authorId != null &&
      (info.kind == NoticeKind.friend ||
          info.kind == NoticeKind.friendRequest ||
          info.kind == NoticeKind.poke ||
          info.kind == NoticeKind.wall)) {
    return '$baseUrl/home.php?mod=space&uid=$authorId';
  }
  return null;
}

/// Widget to display personal message stored in [PersonalMessageV2].
class PersonalMessageCardV2 extends StatefulWidget {
  /// Constructor.
  const PersonalMessageCardV2(this.data, {super.key});

  /// Data to display.
  final PersonalMessageV2 data;

  @override
  State<PersonalMessageCardV2> createState() => _PersonalMessageCardV2State();
}

class _PersonalMessageCardV2State extends State<PersonalMessageCardV2> {
  Future<void> _onTap(BuildContext context, {required bool markAsRead, required bool launch}) async {
    // Record the read state before navigating. Recording it once the chat page popped lost the mark whenever this card
    // was gone by then (the list refreshed, the user left the notification page), and the badge stayed on.
    // A muted peer's conversation is never counted as unread, so there is nothing to adjust for it.
    if (markAsRead != widget.data.alreadyRead &&
        !isMutedPersonalMessagePeer(widget.data.peerUid, currentBlockList(context, listen: false))) {
      if (markAsRead) {
        context.read<NotificationStateCubit>().decreasePersonalMessage();
      } else {
        context.read<NotificationStateCubit>().increasePersonalMessage();
      }
    }
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    if (uid != null) {
      context.read<NotificationBloc>().add(
        NotificationMarkReadRequested(
          RecordMarkPersonalMessage(uid: uid, peerUid: widget.data.peerUid, alreadyRead: markAsRead),
        ),
      );
    }

    if (launch) {
      await context.pushNamed(ScreenPaths.chatHistory, pathParameters: {'uid': '${widget.data.peerUid}'});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage.cardMenu;
    final showBadge = getIt.get<SettingsRepository>().currentSettings.showUnreadPersonalMessageBadge;
    // Muted peers keep their conversation in the list, only the unread badge is dropped.
    final muted = isMutedPersonalMessagePeer(widget.data.peerUid, currentBlockList(context));
    final unread = showBadge && !muted && !widget.data.alreadyRead;

    Future<void> openProfile() async {
      await context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${widget.data.peerUid}'});
    }

    return _NotificationCardShell(
      highlight: unread,
      onTap: () async => _onTap(context, markAsRead: true, launch: true),
      leading: GestureDetector(
        onTap: openProfile,
        child: Badge(
          isLabelVisible: unread,
          child: HeroUserAvatar(username: widget.data.peerUsername, avatarUrl: null, disableHero: true),
        ),
      ),
      title: GestureDetector(onTap: openProfile, child: Text(widget.data.peerUsername)),
      timestamp: widget.data.timestamp,
      menu: PopupMenuButton(
        itemBuilder: (_) => [
          if (!widget.data.alreadyRead)
            PopupMenuItem(
              value: _Actions.markAsRead,
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_read_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.markAsRead),
                ],
              ),
            ),
          if (widget.data.alreadyRead)
            PopupMenuItem(
              value: _Actions.markAsUnread,
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_unread_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.markAsUnread),
                ],
              ),
            ),
          PopupMenuItem(
            value: _Actions.deleteItem,
            child: Row(
              children: [
                Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                sizedBoxPopupMenuItemIconSpacing,
                Text(tr.delete.title, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ],
        onSelected: (value) async {
          switch (value) {
            case _Actions.markAsRead:
              await _onTap(context, markAsRead: true, launch: false);
            case _Actions.markAsUnread:
              await _onTap(context, markAsRead: false, launch: false);
            case _Actions.deleteItem:
              final tr = context.t.noticePage.cardMenu.delete;
              final result = await showQuestionDialog(context: context, title: tr.title, message: tr.detail);
              if (!context.mounted || result == null || !result) {
                return;
              }

              if (!widget.data.alreadyRead &&
                  !isMutedPersonalMessagePeer(widget.data.peerUid, currentBlockList(context, listen: false))) {
                context.read<NotificationStateCubit>().decreasePersonalMessage();
              }
              context.read<NotificationBloc>().add(
                NotificationDeletePersonalMessageRequested(
                  uid: context.read<AuthenticationRepository>().currentUser!.uid!,
                  peerUid: widget.data.peerUid,
                ),
              );
            case _Actions.copyRawContent:
              await copyToClipboard(context, widget.data.data);
            case _Actions.blockAuthor || _Actions.ignoreOnForum:
              // Only offered on notices.
              break;
          }
        },
      ),
      // The list only carries a summary of the last message and the server drops the `&` of every url in it
      // (`forum.php?mod=viewthreadtid=1`), so a link made of that text is not the one the sender wrote: it is
      // unrecognized and would open the browser. Plain text here; the real link is in the conversation the
      // card opens (GitHub #46). Never markup either, see [summaryShownOf].
      body: MunchedHtml(summaryShownOf(widget.data.data), options: const MunchOptions(renderUrl: false)),
    );
  }
}

/// Widget to display broadcast message in [BroadcastMessageV2].
class BroadcastMessageCardV2 extends StatefulWidget {
  /// Constructor.
  const BroadcastMessageCardV2(this.data, {super.key});

  static const _detailPageUrl = '$baseUrl/home.php?mod=space&do=pm&subop=viewg&pmid=';

  /// Data to display.
  final BroadcastMessageV2 data;

  @override
  State<BroadcastMessageCardV2> createState() => _BroadcastMessageCardV2State();
}

class _BroadcastMessageCardV2State extends State<BroadcastMessageCardV2> {
  Future<void> _onTap(BuildContext context, {required bool markAsRead, required bool launch}) async {
    // Record the read state before navigating, see the personal message card above.
    if (markAsRead != widget.data.alreadyRead) {
      if (markAsRead) {
        context.read<NotificationStateCubit>().decreaseBroadcastMessage();
      } else {
        context.read<NotificationStateCubit>().increaseBroadcastMessage();
      }
    }
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    if (uid != null) {
      context.read<NotificationBloc>().add(
        NotificationMarkReadRequested(
          RecordMarkBroadcastMessage(uid: uid, timestamp: widget.data.timestamp, alreadyRead: markAsRead),
        ),
      );
    }

    if (launch) {
      await context.dispatchAsUrl('${BroadcastMessageCardV2._detailPageUrl}${widget.data.pmid}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage.cardMenu;
    final showBadge = getIt.get<SettingsRepository>().currentSettings.showUnreadBroadcastMessageBadge;
    final unread = showBadge && !widget.data.alreadyRead;
    final colorScheme = Theme.of(context).colorScheme;
    return _NotificationCardShell(
      highlight: unread,
      onTap: () async => _onTap(context, markAsRead: true, launch: true),
      leading: Badge(
        isLabelVisible: unread,
        child: AppIconTile(
          Icons.campaign_outlined,
          color: colorScheme.tertiaryContainer,
          foregroundColor: colorScheme.onTertiaryContainer,
        ),
      ),
      title: Text(context.t.noticePage.broadcastMessageTab.system),
      timestamp: widget.data.timestamp,
      menu: PopupMenuButton(
        itemBuilder: (_) => [
          if (!widget.data.alreadyRead)
            PopupMenuItem(
              value: _Actions.markAsRead,
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_read_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.markAsRead),
                ],
              ),
            ),
          if (widget.data.alreadyRead)
            PopupMenuItem(
              value: _Actions.markAsUnread,
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_unread_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.markAsUnread),
                ],
              ),
            ),
          PopupMenuItem(
            value: _Actions.deleteItem,
            child: Row(
              children: [
                Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                sizedBoxPopupMenuItemIconSpacing,
                Text(tr.delete.title, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ],
        onSelected: (value) async {
          switch (value) {
            case _Actions.markAsRead:
              await _onTap(context, markAsRead: true, launch: false);
            case _Actions.markAsUnread:
              await _onTap(context, markAsRead: false, launch: false);
            case _Actions.deleteItem:
              final tr = context.t.noticePage.cardMenu.delete;
              final result = await showQuestionDialog(context: context, title: tr.title, message: tr.detail);
              if (!context.mounted || result == null || !result) {
                return;
              }

              if (!widget.data.alreadyRead) {
                context.read<NotificationStateCubit>().decreaseBroadcastMessage();
              }
              context.read<NotificationBloc>().add(
                NotificationDeleteBroadcastMessageRequested(
                  uid: context.read<AuthenticationRepository>().currentUser!.uid!,
                  pmid: widget.data.pmid,
                ),
              );
            case _Actions.copyRawContent:
              await copyToClipboard(context, widget.data.data);
            case _Actions.blockAuthor || _Actions.ignoreOnForum:
              // Only offered on notices.
              break;
          }
        },
      ),
      // Same summary as the personal message list, see above; the detail page has the full message.
      body: MunchedHtml(summaryShownOf(widget.data.data), options: const MunchOptions(renderUrl: false)),
    );
  }
}

/// Clock of the relative times and the day groups of the notification cards; tests and screenshots set a fixed one.
DateTime Function() notificationCardClock = DateTime.now;

/// Layout shared by the notification cards: leading block with the unread badge, title, kind and relative time, menu,
/// then the content and an optional footer.
///
/// Unread cards (only when their unread badge is enabled in settings) get a tinted surface and a bolder title, so the
/// state is visible without relying on the small badge alone. The time is relative ("3 分钟前", "昨天 12:30"); a long
/// press on it shows the full time.
class _NotificationCardShell extends StatelessWidget {
  const _NotificationCardShell({
    required this.leading,
    required this.title,
    required this.timestamp,
    required this.menu,
    required this.body,
    required this.highlight,
    this.label,
    this.footer,
    this.onTap,
    super.key,
  });

  /// Avatar or icon block.
  final Widget leading;

  /// Title, a text; styled here.
  final Widget title;

  /// Kind of the notification shown before the time, none when null.
  final String? label;

  /// Time of the notification, in seconds.
  final int timestamp;

  /// Popup menu of the card.
  final Widget menu;

  /// Content.
  final Widget body;

  /// Actions under the content, none when null.
  final Widget? footer;

  /// Show as unread.
  final bool highlight;

  /// Tap on the card.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Timestamp in second.
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    // "Now" on the member's wall clock, like the stored times.
    final uid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
    final now = memberNowOf(notificationCardClock(), NotificationTimeOffsets.of(uid));
    final relative = relativeTimeOf(context.t, time, now: now);
    return AppSurface(
      onTap: onTap,
      color: highlight
          ? Color.alphaBlend(colorScheme.primaryContainer.withValues(alpha: 0.3), colorScheme.surfaceContainerLow)
          : null,
      padding: EdgeInsets.fromLTRB(14, 10, 4, footer == null ? 12 : 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              leading,
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle.merge(
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: highlight ? FontWeight.bold : FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: title,
                    ),
                    Tooltip(
                      message: time.yyyyMMDDHHMMSS(),
                      child: Text(
                        label == null ? relative : '$label · $relative',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                      ),
                    ),
                  ],
                ),
              ),
              menu,
            ],
          ),
          sizedBoxW8H8,
          Padding(padding: edgeInsetsR12, child: body),
          ?footer,
        ],
      ),
    );
  }
}
