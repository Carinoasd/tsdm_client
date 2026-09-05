import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/themes/widget_themes.dart';

/// Card of one favorite record: title, time, optional note and a remove button.
class FavoriteCard extends StatelessWidget {
  /// Constructor.
  const FavoriteCard(this.item, {required this.onRemove, this.removing = false, super.key});

  /// Record to show.
  final FavoriteThread item;

  /// Called when the user asks to remove this record.
  final VoidCallback onRemove;

  /// Removal in progress.
  final bool removing;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.favoritePage;
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final description = item.description;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () async => context.pushNamed(
          ScreenPaths.threadV1,
          queryParameters: {'tid': item.tid, 'appBarTitle': item.title},
        ),
        child: Padding(
          padding: edgeInsetsL12T12R12B12,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: theme.textTheme.titleMedium),
                    sizedBoxW4H4,
                    Row(
                      children: [
                        Icon(Icons.access_time_outlined, size: smallIconSize, color: outline),
                        sizedBoxW4H4,
                        Text(
                          item.time == null ? '-' : tr.favoritedAt(time: item.time!.yyyyMMDDHHMM()),
                          style: theme.textTheme.bodySmall?.copyWith(color: outline),
                        ),
                      ],
                    ),
                    if (description != null) ...[
                      sizedBoxW4H4,
                      Text(
                        description,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary),
                      ),
                    ],
                  ],
                ),
              ),
              sizedBoxW8H8,
              if (removing)
                const Padding(padding: edgeInsetsL8R8, child: sizedCircularProgressIndicator)
              else
                IconButton(
                  icon: const Icon(Icons.bookmark_remove_outlined),
                  tooltip: tr.remove,
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
