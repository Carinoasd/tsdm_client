import 'package:flutter/material.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

/// The progress towards the next user group: the current group, the next one and the bar between them, the credits
/// the member has and the credits missing under it.
class UserGroupProgressBar extends StatelessWidget {
  /// Constructor.
  const UserGroupProgressBar(this.progress, {super.key});

  /// What to show.
  final UserGroupProgress progress;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(context.displayText(progress.mainGroupName), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                progress.nextName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: progress.fraction, minHeight: 8),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('${progress.credits} / ${progress.nextFrom}', style: textTheme.labelLarge),
            const Spacer(),
            if (progress.creditsLeft > 0)
              Text(
                context.t.userGroupProgress.creditsLeft(n: progress.creditsLeft),
                style: textTheme.labelMedium?.copyWith(color: colorScheme.primary),
              ),
          ],
        ),
      ],
    );
  }
}
