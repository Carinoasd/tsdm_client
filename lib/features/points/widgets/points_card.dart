import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:universal_html/parsing.dart';

/// A card to a change event of user's points.
class PointsChangeCard extends StatelessWidget {
  /// Constructor.
  const PointsChangeCard(this.pointsChange, {super.key});

  /// Model of points change event.
  final PointsChange pointsChange;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, tile, foreground) = switch (pointsChange.pointsChangeType) {
      PointsChangeType.more => (
        Icons.trending_up_outlined,
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
      ),
      PointsChangeType.less => (
        Icons.trending_down_outlined,
        colorScheme.surfaceContainerHighest,
        colorScheme.onSurfaceVariant,
      ),
      PointsChangeType.unlimited => (
        Icons.trending_flat_outlined,
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
      ),
    };
    return AppSurface(
      onTap: pointsChange.redirectUrl == null
          ? null
          : () async {
              await context.dispatchAsUrl(pointsChange.redirectUrl!);
            },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconTile(icon, color: tile, foregroundColor: foreground),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.displayText(pointsChange.operation),
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.secondary),
                    ),
                    Text(
                      pointsChange.time.yyyyMMDDHHMMSS(),
                      style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (pointsChange.redirectUrl != null) Icon(Icons.chevron_right, color: colorScheme.outline),
            ],
          ),
          sizedBoxW8H8,
          munchElement(
            context,
            parseHtmlDocument(pointsChange.detail).body!,
            options: const MunchOptions(renderUrl: false),
          ),
          sizedBoxW8H8,
          AppInsetBlock(
            color: colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              context.displayText(pointsChange.changeMapString),
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
