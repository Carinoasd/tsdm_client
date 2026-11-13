import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// Whether [message] was sent by the logged user [currentUid] / [currentUsername].
///
/// The chat history carries the uid of every author; the chat dialog only names them. Unknown stays "not mine": the
/// message is then shown like one of the other user, never attributed to the current account by guess.
bool isOwnChatMessage(ChatMessage message, {required int? currentUid, required String? currentUsername}) {
  if (message.authorUid != null && currentUid != null) {
    return message.authorUid == '$currentUid';
  }
  return message.author != null && currentUsername != null && message.author == currentUsername;
}

/// Widget to show a chat message.
///
/// A bubble: messages of the current user on the end side in the primary container color, the other user's on the
/// start side with the avatar. At most 560 wide (or 85% of narrow windows) so long lines stay readable.
final class ChatMessageCard extends StatelessWidget {
  /// Constructor.
  const ChatMessageCard(this.chatMessage, {super.key});

  /// Avatar url for current message's author.
  // final String? authorAvatarUrl;

  /// Message to display.
  final ChatMessage chatMessage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentUser = context.readOrNull<AuthenticationRepository>()?.currentUser;
    final mine = isOwnChatMessage(chatMessage, currentUid: currentUser?.uid, currentUsername: currentUser?.username);

    final time = switch (chatMessage.dateTime) {
      null => null,
      final t when chatMessage.dateOnly => t.yyyyMMDD(),
      final t => t.yyyyMMDDHHMMSS(),
    };

    // The avatar is a 48 wide tap target around the 40 wide circle, named after the user (the circle itself has
    // nothing to read): the circle stays on its side, the target takes the gap before the bubble.
    final avatar = GestureDetector(
      // The whole box takes the tap, not only the circle.
      behavior: HitTestBehavior.opaque,
      onTap: chatMessage.author != null
          ? () async => context.pushNamed(
              ScreenPaths.profile,
              queryParameters: {'uid': ?chatMessage.authorUid, 'username': ?chatMessage.author},
            )
          : null,
      child: Semantics(
        button: chatMessage.author != null,
        label: chatMessage.author,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: 48,
          child: Align(
            alignment: mine ? AlignmentDirectional.topEnd : AlignmentDirectional.topStart,
            child: HeroUserAvatar(
              username: chatMessage.author ?? '',
              avatarUrl: chatMessage.authorAvatarUrl,
              disableHero: true,
            ),
          ),
        ),
      ),
    );

    // The time goes under the name when both do not fit (large text).
    final header = Wrap(
      spacing: 8,
      alignment: mine ? WrapAlignment.end : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        GestureDetector(
          // The avatar beside it opens the same page and is the target a screen reader gets: the name is read as
          // text, not as a second, smaller button.
          excludeFromSemantics: true,
          onTap: chatMessage.author != null
              ? () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'username': chatMessage.author})
              : null,
          child: Text(
            chatMessage.author ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (time != null) Text(time, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
      ],
    );

    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: mine ? colorScheme.primaryContainer : colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(mine ? appSurfaceRadius : 4),
          topRight: Radius.circular(mine ? 4 : appSurfaceRadius),
          bottomLeft: const Radius.circular(appSurfaceRadius),
          bottomRight: const Radius.circular(appSurfaceRadius),
        ),
      ),
      child: Padding(
        padding: edgeInsetsL12T8R12B8,
        child: DefaultTextStyle.merge(
          style: TextStyle(color: mine ? colorScheme.onPrimaryContainer : colorScheme.onSurface),
          child: MunchedHtml(chatMessage.message),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubbleWidth = constraints.maxWidth < 600 ? constraints.maxWidth * 0.85 : 560.0;
        final content = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Padding(padding: edgeInsetsL4R4, child: header),
              sizedBoxW4H4,
              bubble,
            ],
          ),
        );
        return Padding(
          padding: edgeInsetsT4B4,
          child: Row(
            mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The 48 box of the avatar holds the gap to the bubble.
              if (!mine) avatar,
              Flexible(child: content),
              if (mine) avatar,
            ],
          ),
        );
      },
    );
  }
}
