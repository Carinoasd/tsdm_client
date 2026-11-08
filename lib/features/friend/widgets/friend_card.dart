import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/html/adaptive_color.dart';
import 'package:tsdm_client/utils/html/css_parser.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// Card of one friend: avatar, colored username, user group and credits, and a button to message this user.
///
/// Tapping the card opens the user's profile page. With [visitor] the card is a row of the visitors list: the time of
/// the visit under the name, no message button.
class FriendCard extends StatelessWidget {
  /// Constructor.
  const FriendCard(this.friend, {this.visitor = false, super.key});

  /// Whether the card shows a visitor.
  final bool visitor;

  /// Friend to show.
  final Friend friend;

  static const _avatarRadius = 22.0;
  static const _groupIconHeight = 18.0;

  /// Forum colors (e.g. `Red`, `blue`) are chosen for the light web page; in dark mode they are adapted the same way
  /// the post renderer does.
  Color? _color(BuildContext context, String? cssColor) {
    final color = cssColor == null ? null : parseCssString('color:$cssColor')?.color;
    if (color == null) {
      return null;
    }
    return Theme.of(context).brightness == Brightness.dark ? color.adaptiveDark() : color;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.friendPage;
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    final groupName = friend.groupName;
    final groupIconUrl = friend.groupIconUrl;
    final credits = friend.credits;
    final visitTime = friend.visitedAt?.yyyyMMDDHHMM() ?? friend.visitedText;

    return AppSurface(
      padding: edgeInsetsL12T12R12B12,
      onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': friend.uid}),
      child: Row(
        children: [
          HeroUserAvatar(
            username: friend.username,
            avatarUrl: friend.avatarUrl,
            minRadius: _avatarRadius,
            maxRadius: _avatarRadius,
            disableHero: true,
          ),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  friend.username,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: _color(context, friend.nameColor),
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (visitor) ...[
                  if (visitTime != null) ...[sizedBoxW4H4, Text(visitTime, style: secondaryStyle)],
                ] else ...[
                  sizedBoxW4H4,
                  // Group and credits; a long group name pushes the credits to the next line instead of being cut.
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (groupIconUrl != null || groupName != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (groupIconUrl != null) ...[
                              CachedImage(groupIconUrl, height: _groupIconHeight, maxWidth: 64),
                              sizedBoxW4H4,
                            ],
                            if (groupName != null)
                              Flexible(
                                child: Text(
                                  groupName,
                                  style: secondaryStyle?.copyWith(
                                    color: _color(context, friend.groupColor) ?? secondaryStyle.color,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      if (credits != null)
                        AppInfoPill(
                          icon: Icons.stars_outlined,
                          label: tr.credits(count: credits),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (!visitor) ...[
            sizedBoxW8H8,
            IconButton.filledTonal(
              icon: const Icon(Icons.email_outlined),
              tooltip: tr.sendMessage,
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
              ),
              onPressed: () async => context.pushNamed(
                ScreenPaths.chat,
                pathParameters: {'uid': friend.uid},
                extra: <String, dynamic>{'username': friend.username},
              ),
            ),
          ],
        ],
      ),
    );
  }
}
