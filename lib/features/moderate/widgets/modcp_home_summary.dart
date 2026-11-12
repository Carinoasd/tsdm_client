import 'package:flutter/material.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// What waits on the panel's first page (`modcp_home`), above the panel's tiles: the threads and replies awaiting
/// moderation (when the forum counts them), the notes, the forums managed; each opens its page where it has one.
class ModcpHomeSummary extends StatelessWidget {
  /// Constructor.
  const ModcpHomeSummary({required this.home, this.onModerate, this.onNotes, super.key});

  /// The panel's first page.
  final ModcpHome home;

  /// Open the moderation queue.
  final VoidCallback? onModerate;

  /// Open the notes.
  final VoidCallback? onNotes;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcpPages;
    final items = <(Key, String, int, VoidCallback?)>[
      if (home.moderateCount case final count?) (const ValueKey('modcp-count-moderate'), tr.pending, count, onModerate),
      (const ValueKey('modcp-count-notes'), tr.notesCount, home.noteCount, onNotes),
      (const ValueKey('modcp-count-forums'), tr.forumsCount, home.forumCount, null),
    ];
    final theme = Theme.of(context);
    return Row(
      key: const ValueKey('modcp-home-summary'),
      children: [
        for (final (i, (key, label, count, onTap)) in items.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Material(
              key: key,
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(appInnerRadius),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  child: Column(
                    children: [
                      Text(
                        '$count',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: count > 0 && onTap != null ? theme.colorScheme.primary : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
