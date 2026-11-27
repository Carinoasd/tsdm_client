part of 'thread_page.dart';

/// Tells [onChanged] whether the route of this widget is the one on top, first when built and then whenever that
/// changes (a page or a dialog pushed above it, or gone again), without rebuilding [child].
///
/// The thread page depends on it through this widget rather than in its own state: that would rebuild the whole page
/// for every page, dialog or menu opened above it.
class _RouteOnTopListener extends StatefulWidget {
  const _RouteOnTopListener({required this.onChanged, required this.child});

  final void Function({required bool onTop}) onChanged;

  final Widget child;

  @override
  State<_RouteOnTopListener> createState() => _RouteOnTopListenerState();
}

class _RouteOnTopListenerState extends State<_RouteOnTopListener> {
  bool? _onTop;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depends on this part of the route only.
    final onTop = ModalRoute.isCurrentOf(context) ?? true;
    if (onTop != _onTop) {
      _onTop = onTop;
      widget.onChanged(onTop: onTop);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shown instead of a thread whose author could not be learnt while the current account blocks somebody.
///
/// Neutral: the thread is not known to be blocked, only not shown until its author is known.
class _AuthorLookupFailure extends StatelessWidget {
  const _AuthorLookupFailure({required this.onRetry});

  /// Try again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      error: true,
      icon: Icons.error_outline,
      message: context.t.general.failedToLoad,
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          // In the detail pane of a list page, back takes this thread out of the pane rather than closing the page.
          if (TwoPaneScope.detailOf(context) case final pane?)
            OutlinedButton(onPressed: pane.pop, child: Text(context.t.userBlock.goBack))
          else if (Navigator.of(context).canPop())
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(context.t.userBlock.goBack),
            ),
          FilledButton(onPressed: onRetry, child: Text(context.t.general.retry)),
        ],
      ),
    );
  }
}

/// Asks for a floor of the thread to go to ([max] floors when known).
class _JumpToFloorDialog extends StatefulWidget {
  const _JumpToFloorDialog({required this.max});

  final int? max;

  @override
  State<_JumpToFloorDialog> createState() => _JumpToFloorDialogState();
}

class _JumpToFloorDialogState extends State<_JumpToFloorDialog> {
  final _controller = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final floor = int.tryParse(_controller.text.trim());
    if (floor == null || floor < 1) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(floor);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.jumpToFloor;
    return AlertDialog(
      title: Text(tr.title),
      content: TextField(
        key: const ValueKey('jump-to-floor-field'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(
          labelText: tr.label,
          hintText: widget.max == null ? null : tr.hint(max: widget.max!),
          errorText: _invalid ? tr.invalid : null,
          prefixText: '#',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(key: const ValueKey('jump-to-floor-go'), onPressed: _submit, child: Text(tr.go)),
      ],
    );
  }
}

/// Offers to go on reading where it stopped last time, floating above the floors (it moves none of them).
class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({required this.floor, required this.onResume, required this.onClose});

  final int floor;

  final VoidCallback onResume;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.resume;
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('thread-resume-banner'),
      elevation: 3,
      color: colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(appInnerRadius * 2),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.bookmark_outline, size: 20, color: colorScheme.onSecondaryContainer),
            sizedBoxW8H8,
            Expanded(
              child: Text(
                tr.message(floor: floor),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSecondaryContainer),
              ),
            ),
            TextButton(key: const ValueKey('thread-resume-go'), onPressed: onResume, child: Text(tr.action)),
            IconButton(
              key: const ValueKey('thread-resume-close'),
              tooltip: tr.close,
              icon: const Icon(Icons.close),
              color: colorScheme.onSecondaryContainer,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// [post], or for a hot reply the closest floor of the thread around it in [posts]: the next one, else the one
/// before it: the floor the reading is at when a hot reply is at the top of the list.
@visibleForTesting
Post readFloorAround(List<Post> posts, Post post) {
  if (!post.hot) {
    return post;
  }
  final at = posts.indexOf(post);
  if (at < 0) {
    return post;
  }
  for (var i = at + 1; i < posts.length; i++) {
    if (!posts[i].hot) {
      return posts[i];
    }
  }
  for (var i = at - 1; i >= 0; i--) {
    if (!posts[i].hot) {
      return posts[i];
    }
  }
  return post;
}
