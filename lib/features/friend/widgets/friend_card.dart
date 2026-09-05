import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/html/css_parser.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// Card of one friend: avatar, colored username, user group and credits, and a button to message this user.
///
/// Tapping the card opens the user's profile page.
class FriendCard extends StatelessWidget {
  /// Constructor.
  const FriendCard(this.friend, {super.key});

  /// Friend to show.
  final Friend friend;

  static const _avatarRadius = 22.0;
  static const _groupIconHeight = 18.0;

  Color? _color(String? cssColor) => cssColor == null ? null : parseCssString('color:$cssColor')?.color;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.friendPage;
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    final groupName = friend.groupName;
    final groupIconUrl = friend.groupIconUrl;
    final credits = friend.credits;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': friend.uid}),
        child: Padding(
          padding: edgeInsetsL12T8R12B8,
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
                      style: theme.textTheme.titleMedium?.copyWith(color: _color(friend.nameColor)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
                                      color: _color(friend.groupColor) ?? secondaryStyle.color,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        if (credits != null) Text(tr.credits(count: credits), style: secondaryStyle),
                      ],
                    ),
                  ],
                ),
              ),
              sizedBoxW8H8,
              IconButton(
                icon: const Icon(Icons.email_outlined),
                tooltip: tr.sendMessage,
                onPressed: () async => context.pushNamed(
                  ScreenPaths.chat,
                  pathParameters: {'uid': friend.uid},
                  extra: <String, dynamic>{'username': friend.username},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
