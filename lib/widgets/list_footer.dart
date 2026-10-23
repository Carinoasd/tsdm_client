import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/failure_view.dart';

/// Key of the retry button of a [ListFooter].
const ValueKey<String> listFooterRetryKey = ValueKey('list-footer-retry');

/// Key of the login button of a [ListFooter] whose next page asked to log in.
const ValueKey<String> listFooterLoginKey = ValueKey('list-footer-login');

/// What the end of a paged list shows ([ListFooter]).
enum ListFooterStatus {
  /// More pages to load: the next one is asked once the end of the list is built.
  more,

  /// The next page is loading.
  loading,

  /// Every page is loaded.
  noMore,

  /// The next page failed: the items loaded before stay above the footer, which tells why and retries.
  failed,
}

/// The status of the end of a paged list: [failed] (the next page failed), [loading] (it is on its way), [hasMore]
/// (there is one), or the end.
ListFooterStatus listFooterStatus({required bool hasMore, bool loading = false, bool failed = false}) {
  if (failed) {
    return ListFooterStatus.failed;
  }
  if (loading) {
    return ListFooterStatus.loading;
  }
  return hasMore ? ListFooterStatus.more : ListFooterStatus.noMore;
}

/// The end of a paged list, the same on every list: loading the next page, no more pages, or the next page failed
/// with its reason and a retry. The items loaded before always stay above it.
///
/// Built with [ListFooterStatus.more], the footer asks the next page itself ([onLoadMore]) once it is built, so it
/// belongs as the last item of a lazily built list (`ListView.builder`, a `SliverList`): such a list builds it when the
/// end of the list comes near, and asks the next page without a pull. The footer asks once for each [itemCount]: a page
/// that came back with more items, or another status, lets it ask again.
class ListFooter extends StatefulWidget {
  /// Constructor.
  const ListFooter({
    required this.status,
    this.itemCount,
    this.onLoadMore,
    this.onRetry,
    this.failure,
    this.loadingText,
    this.noMoreText,
    super.key,
  });

  /// What to show.
  final ListFooterStatus status;

  /// Items loaded so far: asking the next page again once more items came.
  final int? itemCount;

  /// Ask the next page, when shown with [ListFooterStatus.more].
  final VoidCallback? onLoadMore;

  /// Ask the next page again after it failed ([ListFooterStatus.failed]).
  final VoidCallback? onRetry;

  /// Why the next page failed.
  final LoadFailure? failure;

  /// What loading says, "loading more" by default.
  final String? loadingText;

  /// What the end says, "no more" by default.
  final String? noMoreText;

  @override
  State<ListFooter> createState() => _ListFooterState();
}

class _ListFooterState extends State<ListFooter> {
  /// Asked the next page for the current status and item count.
  bool _asked = false;

  /// Counts down the wait a failure of too many requests asks for, before the retry.
  Timer? _timer;
  int _waitLeft = 0;

  void _startCountdown() {
    _timer?.cancel();
    _timer = null;
    final failure = widget.failure;
    _waitLeft = widget.status == ListFooterStatus.failed && failure != null ? failureWaitLeft(failure) : 0;
    if (_waitLeft <= 0) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _waitLeft = math.max(0, _waitLeft - 1));
      if (_waitLeft <= 0) {
        timer.cancel();
      }
    });
  }

  Future<void> _login() async {
    await context.pushNamed(ScreenPaths.login);
    if (mounted) {
      widget.onRetry?.call();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _askIfNeeded() {
    if (widget.status != ListFooterStatus.more || _asked || widget.onLoadMore == null) {
      return;
    }
    _asked = true;
    // Not during the build: the request changes the state of the list that is building this footer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.status == ListFooterStatus.more) {
        widget.onLoadMore?.call();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _askIfNeeded();
    _startCountdown();
  }

  @override
  void didUpdateWidget(ListFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status || oldWidget.itemCount != widget.itemCount) {
      _asked = false;
    }
    if (oldWidget.status != widget.status || !identical(oldWidget.failure, widget.failure)) {
      _startCountdown();
    }
    _askIfNeeded();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // The variant text color keeps a contrast of 4.5:1 on the surfaces, the outline color does not.
    final quiet = textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);
    final Widget child;
    switch (widget.status) {
      case ListFooterStatus.more || ListFooterStatus.loading:
        // No spinning with the system's "remove animations".
        final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        child = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: 16,
              child: reduceMotion
                  ? Icon(Icons.more_horiz, size: 16, color: colorScheme.outline)
                  : const CircularProgressIndicator(strokeWidth: 2),
            ),
            sizedBoxW8H8,
            Flexible(child: Text(widget.loadingText ?? context.t.loadState.footer.loading, style: quiet)),
          ],
        );
      case ListFooterStatus.noMore:
        final line = Expanded(child: Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.6)));
        child = Row(
          children: [
            line,
            Flexible(
              flex: 3,
              child: Padding(
                padding: edgeInsetsL12R12,
                child: Text(
                  widget.noMoreText ?? context.t.general.noMoreData,
                  style: quiet,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            line,
          ],
        );
      case ListFooterStatus.failed:
        final reason = failureReason(context, widget.failure ?? LoadFailure(LoadFailureKind.unknown));
        child = Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Icon(Icons.error_outline, size: 20, color: colorScheme.error),
            Text(
              context.t.loadState.footer.failed(reason: reason),
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.error),
            ),
            // A failure asking to log in offers the login; too many requests wait before the retry.
            if (widget.failure?.kind == LoadFailureKind.needLogin)
              TextButton.icon(
                key: listFooterLoginKey,
                icon: const Icon(Icons.login_outlined),
                label: Text(context.t.loginPage.login),
                onPressed: _login,
              )
            else if (widget.onRetry != null)
              TextButton.icon(
                key: listFooterRetryKey,
                icon: const Icon(Icons.refresh_outlined),
                label: Text(_waitLeft > 0 ? context.t.loadState.retryIn(seconds: _waitLeft) : context.t.general.retry),
                onPressed: _waitLeft > 0 ? null : widget.onRetry,
              ),
          ],
        );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Semantics(liveRegion: widget.status == ListFooterStatus.failed, child: child),
    );
  }
}
