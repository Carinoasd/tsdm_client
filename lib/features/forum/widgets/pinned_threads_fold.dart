import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Key of the row of [PinnedThreadsFold].
const ValueKey<String> pinnedThreadsFoldKey = ValueKey('forum-pinned-fold');

/// The pinned threads above a forum's thread list folded to one row: how many, and a tap expands or collapses them.
class PinnedThreadsFold extends StatelessWidget {
  /// Constructor.
  const PinnedThreadsFold({required this.count, required this.expanded, required this.onTap, super.key});

  /// How many pinned threads the row stands for.
  final int count;

  /// The pinned threads are shown under the row.
  final bool expanded;

  /// Expand or collapse.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      expanded: expanded,
      child: AppSurface(
        key: pinnedThreadsFoldKey,
        onTap: onTap,
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(Icons.push_pin_outlined, size: 20, color: colorScheme.primary)),
            sizedBoxW12H12,
            Expanded(
              child: Text(
                context.t.forumPage.threadTab.pinnedFold(count: count),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            ExcludeSemantics(
              child: AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: duration200,
                child: Icon(Icons.expand_more, color: colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
