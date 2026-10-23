import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The end of a list whose next page failed to load: the items loaded before stay above it, and it retries.
class LoadMoreFailedFooter extends StatelessWidget {
  /// Constructor.
  const LoadMoreFailedFooter({required this.onRetry, super.key});

  /// Ask the next page again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Icon(Icons.error_outline, size: 20, color: colorScheme.error),
          Text(context.t.general.loadMoreFailed, style: TextStyle(color: colorScheme.error)),
          TextButton.icon(
            icon: const Icon(Icons.refresh_outlined),
            label: Text(context.t.general.retry),
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
