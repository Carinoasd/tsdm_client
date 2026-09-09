import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// The moderators of a forum group, as the site lists them in the group header ("分区版主: a, b"), GitHub #22.
///
/// Tapping a name opens that user's profile.
class GroupModeratorsRow extends StatelessWidget {
  /// Constructor.
  const GroupModeratorsRow({required this.moderators, super.key});

  /// Moderator names, in the site's order.
  final List<String> moderators;

  @override
  Widget build(BuildContext context) {
    if (moderators.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: edgeInsetsL12T4R12,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          Text(
            context.t.topicsPage.moderators,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.secondary),
          ),
          for (final name in moderators)
            ActionChip(
              label: Text(name),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              labelStyle: Theme.of(context).textTheme.labelMedium,
              onPressed: () async =>
                  context.pushNamed(ScreenPaths.profile, queryParameters: <String, String>{'username': name}),
            ),
        ],
      ),
    );
  }
}
