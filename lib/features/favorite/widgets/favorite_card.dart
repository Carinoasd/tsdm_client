import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

/// Card of one favorite record (thread or forum): kind icon, title, time pill, optional note and a remove button.
class FavoriteCard extends StatelessWidget {
  /// Constructor.
  const FavoriteCard(this.item, {required this.onRemove, this.removing = false, super.key});

  /// Record to show.
  final FavoriteItem item;

  Future<void> _open(BuildContext context) async => switch (item) {
    // On the right of the wide favorites page, else as a page of its own.
    FavoriteThread(:final tid, :final title) when openThreadInPane(context, {'tid': tid, 'appBarTitle': title}) => null,
    FavoriteThread(:final tid, :final title) => context.pushNamed(
      ScreenPaths.threadV1,
      queryParameters: {'tid': tid, 'appBarTitle': title},
    ),
    FavoriteForum(:final fid, :final title) => context.pushNamed(
      ScreenPaths.forum,
      pathParameters: {'fid': fid},
      queryParameters: {'appBarTitle': title},
    ),
  };

  /// Called when the user asks to remove this record.
  final VoidCallback onRemove;

  /// Removal in progress.
  final bool removing;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.favoritePage;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final description = item.description;
    final isForum = item is FavoriteForum;
    return AppSurface(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      onTap: () async => _open(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIconTile(isForum ? Icons.folder_outlined : Icons.bookmark_outline, size: 36),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                sizedBoxW8H8,
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    AppInfoPill(
                      icon: Icons.access_time_outlined,
                      label: item.time == null ? '-' : tr.favoritedAt(time: item.time!.yyyyMMDDHHMM()),
                    ),
                  ],
                ),
                if (description != null) ...[
                  sizedBoxW8H8,
                  // The note of the favorite, set on the forum: quoted in an inner block.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(appInnerRadius),
                    ),
                    child: Padding(
                      padding: edgeInsetsL12T8R12B8,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.format_quote_outlined, size: 16, color: colorScheme.secondary),
                          sizedBoxW8H8,
                          Expanded(
                            child: Text(
                              description,
                              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.secondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          sizedBoxW4H4,
          if (removing)
            const Padding(padding: edgeInsetsL8R8, child: sizedCircularProgressIndicator)
          else
            IconButton(
              icon: Icon(isForum ? Icons.folder_off_outlined : Icons.bookmark_remove_outlined),
              tooltip: tr.remove,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
