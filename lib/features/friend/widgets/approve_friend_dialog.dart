import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right, left;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/repository/approve_friend_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Localized text of [failure].
String approveFriendFailureText(BuildContext context, ApproveFriendFailure failure) {
  final tr = context.t.friendPage.approveFriend.failure;
  return switch (failure) {
    ApproveFriendFailure.network => tr.network,
    ApproveFriendFailure.notLoggedIn => tr.notLoggedIn,
    ApproveFriendFailure.accountMismatch => tr.accountMismatch,
    ApproveFriendFailure.challenge => tr.challenge,
    ApproveFriendFailure.unknownForm => tr.unknownForm,
    ApproveFriendFailure.unknownAfterSubmit => tr.unknownAfterSubmit,
  };
}

/// What the approval dialog ended with: a failure, or the forum's answer (a refusal of the form counts as an answer).
typedef ApproveFriendOutcome = Either<ApproveFriendFailure, AddFriendResult>;

/// Approvals open now, by `account uid:member uid`: the same request is never loaded or posted twice at once.
final Set<String> _active = {};

/// Approve the pending friend request of [targetUid] inside the app, the way the notice's "批准申请" link does.
///
/// The account (and one client bound to it) is captured first; the form is loaded, the user picks a group and
/// confirms, then the approval is posted once. Cancel, a refusal, an unknown form, a failure or a switch of account
/// never post anything more and never claim success. Only a real success shows the forum's message and asks the
/// notification bloc (when there is one) to reload, and only while the same account is current. Stored notices are
/// left as they are.
///
/// [repository] replaces the repository (and the clients it builds) in tests; without it a provided
/// [ApproveFriendRepository] is used, else the default one.
Future<void> showApproveFriendDialog(
  BuildContext context, {
  required int targetUid,
  ApproveFriendRepository? repository,
}) async {
  final tr = context.t.friendPage.approveFriend;
  final repo = repository ?? context.readOrNull<ApproveFriendRepository>() ?? const ApproveFriendRepository();
  final auth = context.readOrNull<AuthenticationRepository>();
  final notifications = context.readOrNull<NotificationBloc>();
  final navigator = Navigator.of(context, rootNavigator: true);
  final user = auth?.currentUser;
  final uid = user?.uid;
  if (auth == null || user == null || uid == null || uid <= 0) {
    showSnackBar(context: context, message: tr.failure.notLoggedIn);
    return;
  }
  final key = '$uid:$targetUid';
  if (_active.contains(key)) {
    showSnackBar(context: context, message: tr.busy);
    return;
  }
  _active.add(key);
  final ApproveFriendOutcome? outcome;
  try {
    final client = repo.clientFor(user);
    outcome = await showDialog<ApproveFriendOutcome>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => ApproveFriendDialog(
        targetUid: targetUid,
        load: () => repo.fetchForm(client, targetUid: targetUid),
        submit: (form, gid) => repo.approve(client, form: form, gid: gid),
        isCurrentAccount: () => auth.currentUser?.uid == uid,
        accountChanges: auth.status,
      ),
    );
  } finally {
    _active.remove(key);
  }
  if (outcome == null || !navigator.mounted) {
    // Cancelled.
    return;
  }
  // The messenger of the app: the notice card that opened this may be gone by now.
  final messengerContext = navigator.context;
  if (!messengerContext.mounted) {
    return;
  }
  if (auth.currentUser?.uid != uid) {
    // Whatever came back belongs to the previous account.
    showSnackBar(context: messengerContext, message: tr.failure.accountMismatch);
    return;
  }
  switch (outcome) {
    case Left(:final value):
      showSnackBar(context: messengerContext, message: approveFriendFailureText(messengerContext, value));
    case Right(value: AddFriendResult(success: true, :final message)):
      showSnackBar(context: messengerContext, message: message.isEmpty ? tr.approved : message);
      if (notifications != null && !notifications.isClosed) {
        notifications.add(NotificationUpdateAllRequested());
      }
    case Right(value: AddFriendResult(:final message)):
      showSnackBar(context: messengerContext, message: message.isEmpty ? tr.refused : message);
  }
}

/// Loads the approval form, shows who asked and the groups to pick from, and posts the approval once.
///
/// Pops with an [ApproveFriendOutcome], or null when cancelled. While posting every control is disabled and the
/// dialog can not be closed, so the approval is never sent twice nor left without its answer.
class ApproveFriendDialog extends StatefulWidget {
  /// Constructor.
  const ApproveFriendDialog({
    required this.targetUid,
    required this.load,
    required this.submit,
    required this.isCurrentAccount,
    this.accountChanges,
    super.key,
  });

  /// Uid of the member whose request is approved.
  final int targetUid;

  /// Load the approval form.
  final Future<Either<ApproveFriendFailure, ApproveFriendFormResult>> Function() load;

  /// Post the approval with the chosen group.
  final Future<ApproveFriendOutcome> Function(ApproveFriendForm form, String gid) submit;

  /// Whether the account the approval acts for is still the current one.
  final bool Function() isCurrentAccount;

  /// Emits when the current account may have changed.
  final Stream<Object?>? accountChanges;

  @override
  State<ApproveFriendDialog> createState() => _ApproveFriendDialogState();
}

class _ApproveFriendDialogState extends State<ApproveFriendDialog> with LoggerMixin {
  ApproveFriendForm? _form;
  String? _gid;
  bool _submitting = false;
  bool _done = false;
  StreamSubscription<Object?>? _accountSub;

  @override
  void initState() {
    super.initState();
    _accountSub = widget.accountChanges?.listen((_) {
      // A post in flight is answered first (its client drops the answer of a previous account).
      if (!_submitting && !widget.isCurrentAccount()) {
        _finish(left(ApproveFriendFailure.accountMismatch));
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_accountSub?.cancel());
    super.dispose();
  }

  void _finish(ApproveFriendOutcome? outcome) {
    // Once the dialog left (closed by system back too), popping again would pop the page below it.
    if (_done || !mounted) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) {
      return;
    }
    _done = true;
    // A group menu may be above the dialog when the account changes.
    Navigator.of(context)
      ..popUntil((candidate) => identical(candidate, route))
      ..pop(outcome);
  }

  Future<void> _load() async {
    // The caller checked the account right before opening; the client drops a load of a previous account.
    Either<ApproveFriendFailure, ApproveFriendFormResult> result;
    try {
      result = await widget.load();
    } on Object catch (e, st) {
      // Nothing was posted: a read that broke is a network failure.
      error('failed to load the approval form', e, st);
      result = left(ApproveFriendFailure.network);
    }
    if (_done || !mounted) {
      return;
    }
    if (!widget.isCurrentAccount()) {
      _finish(left(ApproveFriendFailure.accountMismatch));
      return;
    }
    switch (result) {
      case Left(:final value):
        _finish(Left(value));
      case Right(value: ApproveFriendRefused(:final message)):
        _finish(Right(AddFriendResult(success: false, message: message)));
      case Right(value: final ApproveFriendForm form):
        setState(() {
          _form = form;
          _gid = form.selectedGid;
        });
    }
  }

  Future<void> _approve() async {
    final form = _form;
    final gid = _gid;
    if (_submitting || _done || form == null || gid == null || !form.offers(gid)) {
      return;
    }
    if (!widget.isCurrentAccount()) {
      _finish(left(ApproveFriendFailure.accountMismatch));
      return;
    }
    setState(() => _submitting = true);
    ApproveFriendOutcome result;
    try {
      result = await widget.submit(form, gid);
    } on Object catch (e, st) {
      // The approval may have reached the forum: claim neither outcome, never post again.
      error('approval failed, result unknown', e, st);
      result = left(ApproveFriendFailure.unknownAfterSubmit);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
    if (!widget.isCurrentAccount()) {
      _finish(left(ApproveFriendFailure.accountMismatch));
      return;
    }
    _finish(result);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.friendPage.approveFriend;
    final form = _form;
    final Widget content;
    if (form == null) {
      content = Row(
        children: [
          const CircularProgressIndicator(),
          sizedBoxW16H16,
          Expanded(child: Text(tr.loading)),
        ],
      );
    } else {
      final name = form.targetName.isEmpty ? 'UID ${form.targetUid}' : form.targetName;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.content(name: name)),
          sizedBoxW12H12,
          DropdownButtonFormField<String>(
            key: const ValueKey('approve-friend-group'),
            initialValue: _gid,
            decoration: InputDecoration(labelText: tr.group),
            items: [for (final group in form.groups) DropdownMenuItem(value: group.gid, child: Text(group.name))],
            onChanged: _submitting ? null : (v) => setState(() => _gid = v ?? _gid),
          ),
          if (_submitting) ...[
            sizedBoxW12H12,
            Row(
              children: [
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                sizedBoxW8H8,
                Expanded(child: Text(tr.submitting)),
              ],
            ),
          ],
        ],
      );
    }
    return PopScope(
      canPop: !_submitting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          // Closed from outside (system back while loading): a late answer must not pop anything.
          _done = true;
        }
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(tr.title),
        content: content,
        actions: [
          TextButton(
            key: const ValueKey('approve-friend-cancel'),
            onPressed: _submitting ? null : () => _finish(null),
            child: Text(context.t.general.cancel),
          ),
          FilledButton(
            key: const ValueKey('approve-friend-approve'),
            onPressed: form == null || _submitting ? null : _approve,
            child: Text(tr.approve),
          ),
        ],
      ),
    );
  }
}
