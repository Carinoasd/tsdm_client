import 'package:flutter/material.dart';
import 'package:tsdm_client/features/thread/v1/models/multi_quote_selection.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The app bar of a thread while floors are picked to quote: how many are picked, and the reply with their quotes.
///
/// The count and the busy state follow [selection] on their own: the page is not built again for them.
class ThreadMultiQuoteBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const ThreadMultiQuoteBar({required this.selection, required this.onReply, required this.bottom, super.key});

  /// The floors picked.
  final MultiQuoteSelection selection;

  /// Reply with the quote of every floor picked.
  final VoidCallback onReply;

  /// What stays under the bar (the forum path).
  final PreferredSizeWidget bottom;

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + bottom.preferredSize.height);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.multiQuote;
    return AppBar(
      automaticallyImplyLeading: false,
      leading: IconButton(
        key: const ValueKey('multi-quote-exit'),
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
        icon: const Icon(Icons.close),
        onPressed: selection.exit,
      ),
      title: ListenableBuilder(
        listenable: selection,
        builder: (context, _) => Text(
          tr.selected(count: selection.length, max: MultiQuoteSelection.maxEntries),
          key: const ValueKey('multi-quote-count'),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: ListenableBuilder(
            listenable: selection,
            builder: (context, _) => FilledButton(
              key: const ValueKey('multi-quote-reply'),
              onPressed: selection.length == 0 || selection.busy ? null : onReply,
              child: selection.busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr.reply),
            ),
          ),
        ),
      ],
      bottom: bottom,
    );
  }
}
