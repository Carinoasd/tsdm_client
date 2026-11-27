import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The app bar of a thread while its floors are searched: the words, where the current hit is among the hits, the
/// steps to the hit before and after it, and the pages not searched yet once the hits on screen are gone through.
///
/// As tall as the app bar it stands for, the forum path under it kept ([bottom]): the floors do not move when the
/// search opens or closes. It holds no state: the page owns the search.
class ThreadSearchBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const ThreadSearchBar({
    required this.controller,
    required this.searched,
    required this.current,
    required this.total,
    required this.morePages,
    required this.onSubmitted,
    required this.onStep,
    required this.onClose,
    required this.bottom,
    super.key,
  });

  /// The words typed.
  final TextEditingController controller;

  /// Whether words are searched for: the count shows then.
  final bool searched;

  /// Index of the current hit among the hits, negative for none.
  final int current;

  /// How many hits there are.
  final int total;

  /// Pages not searched yet, offered at the end of the hits: whether one is loading, and loading the next (null when
  /// none can be loaded now). Null when there is nothing to offer.
  final ({bool loading, VoidCallback? onLoad})? morePages;

  /// The field was submitted.
  final ValueChanged<String> onSubmitted;

  /// Go to the hit after (1) or before (-1) the current one.
  final ValueChanged<int> onStep;

  /// Leave the search.
  final VoidCallback onClose;

  /// What stays under the bar (the forum path).
  final PreferredSizeWidget bottom;

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + bottom.preferredSize.height);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.search;
    final more = morePages;
    return AppBar(
      automaticallyImplyLeading: false,
      title: TextField(
        key: const ValueKey('thread-search-field'),
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: tr.hint,
          border: InputBorder.none,
          suffix: !searched
              ? null
              : Text(
                  tr.count(n: current + 1, total: total),
                  key: const ValueKey('thread-search-count'),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
        // Enter goes to the next hit, the field keeps the focus (and the keyboard stays up).
        onEditingComplete: () {},
        onSubmitted: onSubmitted,
      ),
      actions: [
        if (more != null)
          more.loading
              ? const SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              : IconButton(
                  key: const ValueKey('thread-search-load-more'),
                  tooltip: tr.loadMore,
                  icon: const Icon(Icons.playlist_add),
                  onPressed: more.onLoad,
                ),
        IconButton(
          key: const ValueKey('thread-search-previous'),
          tooltip: tr.previous,
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: total == 0 ? null : () => onStep(-1),
        ),
        IconButton(
          key: const ValueKey('thread-search-next'),
          tooltip: tr.next,
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: total == 0 ? null : () => onStep(1),
        ),
        IconButton(
          key: const ValueKey('thread-search-close'),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
      ],
      bottom: bottom,
    );
  }
}
