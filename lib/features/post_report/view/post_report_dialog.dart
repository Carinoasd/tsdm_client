import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/post_report/cubit/post_report_cubit.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/post_report/repository/post_report_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';

/// Open the report dialog of [post] (#127). Does nothing when the forum offered no report for it.
///
/// Everything the dialog needs is taken now: the card may be rebuilt or replaced while the dialog is open.
Future<void> showPostReportDialog(BuildContext context, Post post) async {
  final target = post.reportTarget;
  final auth = context.readOrNull<AuthenticationRepository>();
  if (target == null || auth == null) {
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PostReportDialog(
      target: target,
      floorLabel: post.postFloor != null ? '#${post.postFloor}' : 'PID ${post.postID}',
      authorName: post.author.name,
      currentUid: () => auth.effectiveCurrentUid,
      accountChanges: auth.status,
      repository: () => PostReportRepository.network(getIt.get<NetClientProvider>()),
    ),
  );
}

/// Report dialog of one floor.
///
/// Owns its [PostReportCubit]; its lifetime is the dialog route, not the post card. Closing it or a change of account
/// drops every pending read, confirmation and answer.
class PostReportDialog extends StatefulWidget {
  /// Constructor.
  const PostReportDialog({
    required this.target,
    required this.floorLabel,
    required this.authorName,
    required this.currentUid,
    required this.accountChanges,
    required this.repository,
    this.openBrowser = openInExternalBrowser,
    super.key,
  });

  /// The floor.
  final PostReportTarget target;

  /// `#floor`, or the post id when the floor number is unknown.
  final String floorLabel;

  /// Author of the floor.
  final String authorName;

  /// The account in use now.
  final int? Function() currentUid;

  /// Fires on every change of the authentication state.
  final Stream<Object?> accountChanges;

  /// Builds an account-bound repository.
  final PostReportRepository Function() repository;

  /// Opens the floor in an external browser, returns whether one started.
  final Future<bool> Function(Uri) openBrowser;

  @override
  State<PostReportDialog> createState() => _PostReportDialogState();
}

class _PostReportDialogState extends State<PostReportDialog> {
  late final PostReportCubit _cubit;
  StreamSubscription<Object?>? _accountSub;
  final _custom = TextEditingController();

  /// Bumped on an account change: a confirmation of an older value, still open or already animating out, stops
  /// showing the floor, author and reason at once.
  final _privacy = ValueNotifier<int>(0);

  /// The route of this dialog.
  ModalRoute<Object?>? _route;

  /// Owned confirmations, retained until their overlays have actually disappeared.
  final _confirmRoutes = <DialogRoute<bool>>{};

  /// The route of this dialog was popped or removed: nothing more is checked or sent.
  bool _closing = false;

  /// The account changed: author and reason are no longer shown.
  bool _accountLost = false;

  int? _reason;
  bool _confirming = false;
  bool _browserFailed = false;

  @override
  void initState() {
    super.initState();
    _cubit = PostReportCubit(target: widget.target, currentUid: widget.currentUid, repository: widget.repository);
    _accountSub = widget.accountChanges.listen((_) {
      // A check of the same account keeps the input; any other account ends this dialog for good (A → B → A too).
      if (widget.currentUid() != widget.target.viewerUid) {
        _accountChanged();
      }
    });
    unawaited(_cubit.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route == null && route != null) {
      _route = route;
      // Completes at the pop or removal of the route, before it animates out and long before dispose. The PopScope
      // callback below usually comes first.
      unawaited(route.popped.then((_) => _routeClosed()));
    }
  }

  @override
  void dispose() {
    unawaited(_accountSub?.cancel());
    _routeClosed();
    _cubit.invalidate(silent: true);
    unawaited(_cubit.close());
    _custom.dispose();
    // A removed or popped confirmation may still need a frame to erase its content. Keep its notifier alive until
    // every owned overlay is gone, rather than disposing it with the underlying dialog.
    unawaited(Future.wait(_confirmRoutes.map((route) => route.completed)).then((_) => _privacy.dispose()));
    super.dispose();
  }

  /// The route of this dialog is closing (a button, back, or an imperative pop even while sending is shown): a pending
  /// check or confirmation must not send any more. A request already started keeps its result ignored, never resent.
  void _routeClosed() {
    if (_closing) {
      return;
    }
    _closing = true;
    _cubit.invalidate(silent: true);
    _privacy.value++;
    // Route callbacks can run while Navigator is locked. Invalidate immediately, then remove only our confirmations
    // after that navigation operation finishes.
    scheduleMicrotask(() {
      for (final confirm in _confirmRoutes.toList()) {
        if (confirm.isActive) {
          confirm.navigator?.removeRoute(confirm);
        }
      }
    });
  }

  void _accountChanged() {
    _cubit.invalidate();
    _custom.clear();
    _reason = null;
    if (!mounted) {
      return;
    }
    setState(() => _accountLost = true);
    // Remove only the routes this dialog owns, wherever they are: an unrelated page pushed above them stays. A route
    // already animating out can not be removed; it no longer shows anything private.
    _routeClosed();
    final route = _route;
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
  }

  /// Pop the route of [context] with [result] only while it is the top route: a tap on a dialog that is already
  /// animating out or removed must not close the page below it.
  static void _popIfCurrent<T>(BuildContext context, T result) {
    if (context.mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).pop(result);
    }
  }

  Future<void> _openBrowser() async {
    bool ok;
    try {
      ok = await widget.openBrowser(widget.target.floorUrl);
    } on Object {
      ok = false;
    }
    if (mounted) {
      setState(() => _browserFailed = !ok);
    }
  }

  Future<void> _submit(PostReportForm form) async {
    final reason = _reason;
    final navigator = _route?.navigator;
    if (_confirming || _closing || reason == null || navigator == null) {
      return;
    }
    final generation = _cubit.generation;
    final custom = _custom.text;
    final message = form.messageFor(reason, custom);
    if (message == null || !_cubit.canConfirm(generation)) {
      return;
    }
    final tr = context.t.postReport;
    final privacy = _privacy.value;
    // Pushed on this dialog's own navigator and kept, so an account change removes exactly this route.
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: _privacy,
        builder: (context, value, _) => value != privacy
            ? const SizedBox.shrink()
            : AlertDialog(
                scrollable: true,
                title: Text(tr.confirmTitle),
                content: Text(tr.confirmBody(floor: widget.floorLabel, name: widget.authorName, reason: message)),
                actions: [
                  TextButton(
                    key: const ValueKey('post-report-confirm-cancel'),
                    onPressed: () => _popIfCurrent(context, false),
                    child: Text(tr.cancel),
                  ),
                  FilledButton(
                    key: const ValueKey('post-report-confirm'),
                    // Checked again at the tap: a confirmation animating out or removed after an account change is no
                    // longer the current route and sends nothing (and must not pop whatever route is on top now).
                    onPressed: () => _popIfCurrent(context, _cubit.canConfirm(generation)),
                    child: Text(tr.confirm),
                  ),
                ],
              ),
      ),
    );
    setState(() => _confirming = true);
    _confirmRoutes.add(route);
    unawaited(route.completed.then((_) => _confirmRoutes.remove(route)));
    try {
      final confirmed = await navigator.push(route);
      if (confirmed != true || !mounted || _closing || !_cubit.canConfirm(generation)) {
        return;
      }
      await _cubit.submit(generation: generation, reasonIndex: reason, custom: custom);
    } finally {
      if (mounted) {
        setState(() => _confirming = false);
      }
    }
  }

  String _problemText(Translations t, PostReportProblem problem) {
    final tr = t.postReport.problem;
    return switch (problem) {
      PostReportProblem.accountChanged => tr.accountChanged,
      PostReportProblem.notLoggedIn => tr.notLoggedIn,
      PostReportProblem.noPermission => tr.noPermission,
      PostReportProblem.verificationRequired => tr.verificationRequired,
      PostReportProblem.challenge => tr.challenge,
      PostReportProblem.network => tr.network,
      PostReportProblem.forumMessage => tr.forumMessage,
      PostReportProblem.unsupported => tr.unsupported,
    };
  }

  Widget _notice(BuildContext context, String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: error ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
    ),
  );

  List<Widget> _buildForm(BuildContext context, PostReportState state, PostReportForm form) {
    final tr = context.t.postReport;
    final editable = state.phase != PostReportPhase.submitting && !_confirming;
    final customSelected = _reason == form.customIndex;
    final custom = normalizePostReportReason(_custom.text);
    final remaining = postReportReasonLimit - postReportReasonWeight(custom);
    String? error;
    if (remaining < 0) {
      error = tr.overLimit(count: -remaining);
    } else if (custom.endsWith(r'\')) {
      error = tr.trailingBackslash;
    } else if (!postReportReasonFits(custom)) {
      // Within the count, but the forum would still drop the last character: refused, never changed silently.
      error = tr.entityAtLimit;
    }
    return [
      if (state.formChanged) _notice(context, tr.formChanged, error: true),
      if (state.phase == PostReportPhase.notSent && state.problem != null) ...[
        _notice(context, _problemText(context.t, state.problem!), error: true),
        if (state.message != null) _notice(context, state.message!),
      ],
      if (state.phase == PostReportPhase.rejected) ...[
        _notice(
          context,
          state.problem == PostReportProblem.notLoggedIn ? tr.problem.notLoggedIn : tr.rejected,
          error: true,
        ),
        if (state.message?.isNotEmpty ?? false) _notice(context, state.message!),
      ],
      Text(tr.reason, style: Theme.of(context).textTheme.titleSmall),
      RadioGroup<int>(
        groupValue: _reason,
        onChanged: (value) {
          if (editable) {
            setState(() => _reason = value);
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, label) in form.reasons.indexed)
              RadioListTile<int>(
                key: ValueKey('post-report-reason-$index'),
                value: index,
                enabled: editable,
                contentPadding: EdgeInsets.zero,
                title: Text(label),
              ),
          ],
        ),
      ),
      if (customSelected) ...[
        TextField(
          key: const ValueKey('post-report-custom'),
          controller: _custom,
          enabled: editable,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: tr.customHint,
            border: const OutlineInputBorder(),
            errorText: error,
            helperText: error == null ? tr.remaining(count: remaining) : null,
            helperMaxLines: 3,
            errorMaxLines: 3,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
      if (state.phase == PostReportPhase.submitting) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(tr.submitting),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postReport;
    return BlocConsumer<PostReportCubit, PostReportState>(
      bloc: _cubit,
      listenWhen: (prev, curr) => curr.formChanged && !prev.formChanged,
      listener: (context, state) => setState(() => _reason = null),
      builder: (context, state) {
        final form = state.form;
        final withForm =
            form != null &&
            (state.phase == PostReportPhase.ready ||
                state.phase == PostReportPhase.notSent ||
                state.phase == PostReportPhase.rejected ||
                state.phase == PostReportPhase.submitting);
        final canSend =
            withForm &&
            state.phase != PostReportPhase.submitting &&
            !_confirming &&
            _reason != null &&
            form.messageFor(_reason!, _custom.text) != null;

        final browserButton = TextButton(
          key: const ValueKey('post-report-browser'),
          onPressed: state.phase == PostReportPhase.submitting ? null : _openBrowser,
          child: Text(tr.openInBrowser),
        );
        final closeButton = TextButton(
          key: const ValueKey('post-report-close'),
          onPressed: state.phase == PostReportPhase.submitting ? null : () => _popIfCurrent<void>(context, null),
          child: Text(withForm ? tr.cancel : tr.close),
        );

        final List<Widget> content;
        final List<Widget> actions;
        switch (state.phase) {
          case PostReportPhase.loading:
            content = [
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 8),
              Text(tr.loading),
            ];
            actions = [closeButton];
          case PostReportPhase.unavailable:
            final problem = state.problem ?? PostReportProblem.unsupported;
            content = [
              _notice(context, _problemText(context.t, problem), error: true),
              if (state.message != null) _notice(context, state.message!),
            ];
            actions = [
              browserButton,
              if (problem == PostReportProblem.network || problem == PostReportProblem.challenge)
                TextButton(
                  key: const ValueKey('post-report-retry'),
                  onPressed: () => unawaited(_cubit.load()),
                  child: Text(tr.retry),
                ),
              closeButton,
            ];
          case PostReportPhase.ready ||
              PostReportPhase.notSent ||
              PostReportPhase.rejected ||
              PostReportPhase.submitting:
            final shown = form!;
            content = _buildForm(context, state, shown);
            actions = [
              browserButton,
              closeButton,
              FilledButton(
                key: const ValueKey('post-report-submit'),
                onPressed: canSend ? () => unawaited(_submit(shown)) : null,
                child: Text(tr.submit),
              ),
            ];
          case PostReportPhase.succeeded:
            content = [
              _notice(context, tr.succeeded),
              if (state.message?.isNotEmpty ?? false) _notice(context, state.message!),
            ];
            actions = [closeButton];
          case PostReportPhase.unknown:
            content = [_notice(context, tr.unknown, error: true)];
            actions = [browserButton, closeButton];
          case PostReportPhase.closed:
            content = [_notice(context, tr.problem.accountChanged, error: true)];
            actions = [closeButton];
        }

        return PopScope(
          canPop: state.phase != PostReportPhase.submitting,
          // Also called for an imperative pop that ignores canPop: stop any pending check right at the pop.
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              _routeClosed();
            }
          },
          child: AlertDialog(
            scrollable: true,
            title: Text(tr.title(floor: widget.floorLabel)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_accountLost) _notice(context, tr.author(name: widget.authorName)),
                ...content,
                if (_browserFailed) _notice(context, tr.browserFailed, error: true),
              ],
            ),
            actions: actions,
          ),
        );
      },
    );
  }
}
