import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// Widget to show the answer of a bounty in thread.
class BountyAnswerCard extends StatelessWidget {
  /// Constructor.
  const BountyAnswerCard({
    required this.username,
    required this.userSpaceUrl,
    required this.userAvatarUrl,
    required this.answer,
    super.key,
  });

  /// User name of the answer.
  final String username;

  /// Profile url of the answer's user.
  final String userSpaceUrl;

  /// Avatar url of the answer's user.
  final String userAvatarUrl;

  /// Answer content.
  final String answer;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // The accepted answer: who answered (opens the profile) and the answer quoted under it.
    return AppEmbedCard(
      icon: Icons.verified,
      title: context.t.bountyAnswerCard.title,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () async => context.dispatchAsUrl(userSpaceUrl),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundImage: CachedImageProvider(
                    userAvatarUrl,
                    fallbackImageUrl: noAvatarUrl,
                    usage: ImageUsageInfoUserAvatar(username),
                  ),
                ),
                sizedBoxW8H8,
                Expanded(
                  child: Text(username, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          sizedBoxW8H8,
          SizedBox(
            width: double.infinity,
            child: AppInsetBlock(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: Text(context.displayText(answer), style: textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}
