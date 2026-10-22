import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// Widget to show a review for a post.
class ReviewCard extends StatelessWidget {
  /// Constructor.
  const ReviewCard({required this.name, required this.content, this.avatarUrl, this.time, super.key});

  /// Reviewer avatar url.
  final String? avatarUrl;

  /// Reviewer name.
  final String name;

  /// Review content.
  final String content;

  /// When the review was posted, as the web page prints it (`发表于 2021-10-1 18:04`).
  final String? time;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // A short review under the floor: reviewer and their words in one rounded block.
    return AppEmbedCard(
      icon: Icons.reviews_outlined,
      title: context.t.reviewCard.title,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundImage: CachedImageProvider(
              avatarUrl ?? noAvatarUrl,
              fallbackImageUrl: noAvatarUrl,
              usage: ImageUsageInfoUserAvatar(name),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                // All of it, as the web page shows it: it was cut after three lines.
                Text(content, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                if (time != null) Text(time!, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
