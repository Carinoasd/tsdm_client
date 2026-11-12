import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

/// What to tell of a reply that is not an answer: the plugin's sentence (as served, shown in the script of the app),
/// "log in first", or [fallback].
String batchRateReplyText(BuildContext context, BatchRateReply<Object?> reply, String fallback) => switch (reply) {
  BatchRateRefused(:final message) when message.isNotEmpty => context.displayText(message),
  BatchRateRefused(login: true) => context.t.general.needLogin,
  _ => fallback,
};

/// A floor of a confirmation or a batch: its number (or its thread's title), its author, what the plugin says of it,
/// and [trailing] (the multiple, the taking back).
class BatchRateItemTile extends StatelessWidget {
  /// Constructor.
  const BatchRateItemTile({required this.item, this.trailing, this.marked = false, super.key});

  /// The floor.
  final BatchRateItem item;

  /// At the end of the row.
  final Widget? trailing;

  /// Shown as an error (out of range).
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final head = item.subject.isNotEmpty
        ? context.displayText(item.subject)
        : context.t.batchRate.floor(n: item.position);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('$head · ${item.author}', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        context.displayText(item.statusText),
        style: textTheme.bodySmall?.copyWith(
          color: marked
              ? colorScheme.error
              : item.pending || item.status == 'applied'
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: trailing,
      onTap: item.tid > 0 && item.pid > 0
          ? () async => context.dispatchAsUrl(
              '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=${item.tid}&pid=${item.pid}',
            )
          : null,
    );
  }
}
