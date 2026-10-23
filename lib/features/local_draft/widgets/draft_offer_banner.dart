import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_text.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A draft kept on this device offered to the editor of its target: "有未送出的草稿（時間）", what it says in a few words,
/// and the choice to restore or discard it.
class DraftOfferBanner extends StatelessWidget {
  /// Constructor.
  const DraftOfferBanner({required this.draft, required this.onRestore, required this.onDiscard, super.key});

  /// The draft offered.
  final LocalDraft draft;

  /// Put the draft into the editor.
  final VoidCallback onRestore;

  /// Delete the draft.
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.localDraft;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final foreground = colorScheme.onTertiaryContainer;
    final subject = draft.subject?.trim() ?? '';
    final snippet = draftSnippet(draft.body, emoji: tr.emoji, max: 60);
    final hint = draft.key.kind == LocalDraftKind.floorReply ? draft.hint : null;
    return AppInsetBlock(
      key: const ValueKey('draft-offer-banner'),
      color: colorScheme.tertiaryContainer,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(Icons.history_edu_outlined, size: 20, color: foreground),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr.offer(time: draft.updatedAt.yyyyMMDDHHMM()),
                  style: textTheme.labelLarge?.copyWith(color: foreground, fontWeight: FontWeight.bold),
                ),
                if (hint != null && hint.isNotEmpty)
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: foreground),
                  ),
                if (subject.isNotEmpty || snippet.isNotEmpty)
                  Text(
                    [subject, snippet].where((e) => e.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: foreground.withValues(alpha: 0.8)),
                  ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('draft-offer-restore'),
            style: TextButton.styleFrom(foregroundColor: foreground, visualDensity: VisualDensity.compact),
            onPressed: onRestore,
            child: Text(tr.restore),
          ),
          TextButton(
            key: const ValueKey('draft-offer-discard'),
            style: TextButton.styleFrom(foregroundColor: foreground, visualDensity: VisualDensity.compact),
            onPressed: onDiscard,
            child: Text(tr.discard),
          ),
        ],
      ),
    );
  }
}
