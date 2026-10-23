import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Key of the retry button of a [FailureView].
const ValueKey<String> failureRetryKey = ValueKey('failure-retry');

/// Key of the login button of a [FailureView].
const ValueKey<String> failureLoginKey = ValueKey('failure-login');

/// Key of the button showing or hiding the details of a [FailureView].
const ValueKey<String> failureDetailsKey = ValueKey('failure-details');

/// The words telling [failure]: what went wrong in one sentence (the title) and what to do about it (the hint, null
/// when the title says it all).
///
/// A message of the forum ([LoadFailureKind.forumMessage]) is its own title, as the forum wrote it.
({String title, String? hint}) failureTexts(BuildContext context, LoadFailure failure) {
  final tr = context.t.loadState.failure;
  final seconds = failure.retryAfterSeconds;
  return switch (failure.kind) {
    LoadFailureKind.noNetwork => (title: tr.noNetwork.title, hint: tr.noNetwork.hint),
    LoadFailureKind.connectionLost => (title: tr.connectionLost.title, hint: tr.connectionLost.hint),
    LoadFailureKind.timeout => (title: tr.timeout.title, hint: tr.timeout.hint),
    LoadFailureKind.rateLimited => (
      title: tr.rateLimited.title,
      hint: seconds == null || seconds <= 0 ? tr.rateLimited.hint : tr.rateLimited.hintSeconds(seconds: seconds),
    ),
    LoadFailureKind.server when (failure.statusCode ?? 500) >= 500 => (title: tr.server.title, hint: tr.server.hint),
    LoadFailureKind.server => (title: tr.badStatus.title, hint: tr.badStatus.hint),
    LoadFailureKind.challenge => (title: tr.challenge.title, hint: tr.challenge.hint),
    LoadFailureKind.closed => (title: tr.closed.title, hint: tr.closed.hint),
    LoadFailureKind.needLogin => (title: tr.needLogin.title, hint: tr.needLogin.hint),
    LoadFailureKind.noPermission => (title: tr.noPermission.title, hint: tr.noPermission.hint),
    LoadFailureKind.forumMessage => (title: failure.message ?? tr.unknown.title, hint: null),
    LoadFailureKind.accountChanged => (title: tr.accountChanged.title, hint: tr.accountChanged.hint),
    LoadFailureKind.unknown => (title: tr.unknown.title, hint: tr.unknown.hint),
  };
}

/// One short line naming [failure], for the end of a list or a snack bar: the title of [failureTexts].
String failureReason(BuildContext context, LoadFailure failure) => failureTexts(context, failure).title;

/// The icon of a failure of [kind].
IconData failureIcon(LoadFailureKind kind) => switch (kind) {
  LoadFailureKind.noNetwork => Icons.wifi_off_outlined,
  LoadFailureKind.connectionLost => Icons.signal_wifi_bad_outlined,
  LoadFailureKind.timeout => Icons.hourglass_bottom_outlined,
  LoadFailureKind.rateLimited => Icons.hourglass_top_outlined,
  LoadFailureKind.server => Icons.dns_outlined,
  LoadFailureKind.challenge => Icons.verified_user_outlined,
  LoadFailureKind.closed => Icons.construction_outlined,
  LoadFailureKind.needLogin => Icons.lock_person_outlined,
  LoadFailureKind.noPermission => Icons.lock_outline,
  LoadFailureKind.forumMessage => Icons.info_outline,
  LoadFailureKind.accountChanged => Icons.switch_account_outlined,
  LoadFailureKind.unknown => Icons.error_outline,
};

/// Whether a failure of [kind] is shown in the error colors: what failed on the way (network, server), not what the
/// forum told (log in, no permission, closed, its message).
bool failureUsesErrorColors(LoadFailureKind kind) => switch (kind) {
  LoadFailureKind.noNetwork ||
  LoadFailureKind.connectionLost ||
  LoadFailureKind.timeout ||
  LoadFailureKind.server ||
  LoadFailureKind.challenge ||
  LoadFailureKind.unknown => true,
  _ => false,
};

/// Seconds left of the wait [failure] asks for ([LoadFailure.retryAfterSeconds] counted from [LoadFailure.at]), 0
/// when there is none or it is over.
int failureWaitLeft(LoadFailure failure) {
  final seconds = failure.retryAfterSeconds;
  if (seconds == null || seconds <= 0) {
    return 0;
  }
  return math.max(0, seconds - DateTime.now().difference(failure.at).inSeconds);
}

/// Tell that a refresh failed with [failure] while the page keeps what it showed: a snack bar with the reason and a
/// retry ([onRetry]).
void showRefreshFailedSnackBar(BuildContext context, LoadFailure? failure, {VoidCallback? onRetry}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  final reason = failureReason(context, failure ?? LoadFailure(LoadFailureKind.unknown));
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(context.t.loadState.refreshFailed(reason: reason)),
        action: onRetry == null ? null : SnackBarAction(label: context.t.general.retry, onPressed: onRetry),
      ),
    );
}

/// A page or a section that failed to load: what went wrong in one sentence, what to do (retry, log in, wait), the
/// forum's own words when it gave any, and the technical details folded away.
///
/// The failure is [failure], or the one of the last request of the app that failed when the page did not keep its
/// own ([LoadFailure.lastRequest]).
class FailureView extends StatefulWidget {
  /// Constructor.
  const FailureView({
    this.failure,
    this.onRetry,
    this.onLogin,
    this.message,
    this.scrollable = true,
    super.key,
  });

  /// What failed, the last failed request of the app when null.
  final LoadFailure? failure;

  /// Load again; no retry button when null.
  final VoidCallback? onRetry;

  /// Log in, for a failure asking to ([LoadFailureKind.needLogin]); by default the login page is opened and the page
  /// loaded again once it closes.
  final VoidCallback? onLogin;

  /// The forum's own words as a widget (its html rendered), shown instead of [LoadFailure.message].
  final Widget? message;

  /// Scroll by itself when the room is too small; false when the view is already inside a scroll view.
  final bool scrollable;

  @override
  State<FailureView> createState() => _FailureViewState();
}

class _FailureViewState extends State<FailureView> {
  late LoadFailure _failure;
  bool _showDetails = false;
  Timer? _timer;
  int _waitLeft = 0;

  void _startCountdown() {
    _timer?.cancel();
    _timer = null;
    _waitLeft = failureWaitLeft(_failure);
    if (_waitLeft <= 0) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // Counted down by the ticks from the wait left when the view showed up.
      setState(() => _waitLeft = math.max(0, _waitLeft - 1));
      if (_waitLeft <= 0) {
        timer.cancel();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _failure = widget.failure ?? LoadFailure.lastRequest();
    _startCountdown();
  }

  @override
  void didUpdateWidget(FailureView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.failure, widget.failure)) {
      _failure = widget.failure ?? LoadFailure.lastRequest();
      _showDetails = false;
      _startCountdown();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _login() async {
    if (widget.onLogin case final onLogin?) {
      onLogin();
      return;
    }
    await context.pushNamed(ScreenPaths.login);
    if (mounted) {
      widget.onRetry?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final tr = context.t.loadState;
    final failure = _failure;
    final (:title, :hint) = failureTexts(context, failure);
    final errorColors = failureUsesErrorColors(failure.kind);
    // The forum's words under the sentence telling what they are about; a message of the forum is the title itself.
    final forumWords =
        widget.message ??
        (failure.kind != LoadFailureKind.forumMessage && failure.message != null
            ? SelectableText(failure.message!, style: textTheme.bodyMedium)
            : null);
    final details = failure.details;
    final retry = widget.onRetry == null
        ? null
        : FilledButton.tonalIcon(
            key: failureRetryKey,
            icon: const Icon(Icons.refresh_outlined),
            label: Text(_waitLeft > 0 ? tr.retryIn(seconds: _waitLeft) : context.t.general.retry),
            onPressed: _waitLeft > 0 ? null : widget.onRetry,
          );
    final actions = <Widget>[
      if (failure.kind == LoadFailureKind.needLogin) ...[
        FilledButton.icon(
          key: failureLoginKey,
          icon: const Icon(Icons.login_outlined),
          label: Text(context.t.loginPage.login),
          onPressed: _login,
        ),
        if (widget.onRetry != null)
          TextButton(key: failureRetryKey, onPressed: widget.onRetry, child: Text(context.t.general.retry)),
      ] else
        ?retry,
    ];

    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: errorColors ? colorScheme.errorContainer : colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(appSurfaceRadius),
            ),
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(
                failureIcon(failure.kind),
                size: 32,
                color: errorColors ? colorScheme.onErrorContainer : colorScheme.outline,
              ),
            ),
          ),
          sizedBoxW16H16,
          Text(
            title,
            textAlign: TextAlign.center,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (hint != null) ...[
            sizedBoxW8H8,
            Text(
              hint,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
          if (forumWords != null) ...[
            sizedBoxW12H12,
            SizedBox(
              width: double.infinity,
              child: AppInsetBlock(child: forumWords),
            ),
          ],
          if (actions.isNotEmpty) ...[
            sizedBoxW16H16,
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: actions),
          ],
          if (details != null) ...[
            sizedBoxW8H8,
            TextButton.icon(
              key: failureDetailsKey,
              icon: Icon(_showDetails ? Icons.expand_less : Icons.expand_more),
              label: Text(_showDetails ? tr.hideDetails : tr.details),
              style: TextButton.styleFrom(foregroundColor: colorScheme.outline),
              onPressed: () => setState(() => _showDetails = !_showDetails),
            ),
            if (_showDetails)
              SizedBox(
                width: double.infinity,
                child: AppInsetBlock(
                  padding: edgeInsetsL12T4R4B4,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: SelectableText(
                            details,
                            style: textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              // The app's own font where no monospace one has the glyphs.
                              fontFamilyFallback: [?textTheme.bodySmall?.fontFamily],
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        tooltip: tr.copyDetails,
                        onPressed: () async => copyToClipboard(context, details),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
    if (!widget.scrollable) {
      return Center(
        child: Padding(padding: edgeInsetsL24T24R24B24, child: content),
      );
    }
    return Center(
      child: SingleChildScrollView(padding: edgeInsetsL24T24R24B24, child: content),
    );
  }
}

/// [FailureView] filling the viewport of a scroll view with the given [physics], so a failed list keeps its pull to
/// refresh.
class ScrollableFailureView extends StatelessWidget {
  /// Constructor.
  const ScrollableFailureView({required this.physics, required this.child, super.key});

  /// Physics of the scroll view, usually given by the refresh wrapper.
  final ScrollPhysics? physics;

  /// Failure view, built with `scrollable: false`.
  final FailureView child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: physics,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth, minHeight: constraints.maxHeight),
        child: child,
      ),
    ),
  );
}
