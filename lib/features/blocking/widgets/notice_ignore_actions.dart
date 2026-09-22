import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Localized text of [failure].
String noticeIgnoreFailureText(BuildContext context, NoticeIgnoreFailure failure) =>
    _failureText(context.t.userBlock.serverRules.failure, failure);

String _failureText(TranslationsUserBlockServerRulesFailureEn tr, NoticeIgnoreFailure failure) => switch (failure) {
  NoticeIgnoreFailure.network => tr.network,
  NoticeIgnoreFailure.notLoggedIn => tr.notLoggedIn,
  NoticeIgnoreFailure.accountMismatch => tr.accountMismatch,
  NoticeIgnoreFailure.challenge => tr.challenge,
  NoticeIgnoreFailure.forumError => tr.forumError,
  NoticeIgnoreFailure.unknownForm => tr.unknownForm,
  NoticeIgnoreFailure.ruleNotFound => tr.ruleNotFound,
  NoticeIgnoreFailure.unknownAfterSubmit => tr.unknownAfterSubmit,
};

/// Localized name of the forum notice [type] (`post`, `pcomment`, ...), the type itself when it is not a known one.
///
/// The type is only sent to the forum as it is; the name is for reading.
String noticeTypeName(BuildContext context, String type) {
  final tr = context.t.userBlock.serverRules.types;
  return switch (type) {
    'post' => tr.post,
    'pcomment' => tr.pcomment,
    'activity' => tr.activity,
    'reward' => tr.reward,
    'goods' => tr.goods,
    'at' => tr.at,
    'poke' => tr.poke,
    'friend' => tr.friend,
    'wall' => tr.wall,
    'comment' => tr.comment,
    'click' => tr.click,
    'sharenotice' => tr.sharenotice,
    'system' => tr.system,
    _ => type,
  };
}

/// The account a forum write acts for, with one client bound to it for the whole operation.
///
/// Null when no account is logged in. [clientFactory] replaces the client in tests.
(int, NetClientProvider)? boundClientOfCurrentUser(BuildContext context, {BoundClientFactory? clientFactory}) {
  final user = context.read<AuthenticationRepository>().currentUser;
  final uid = user?.uid;
  if (user == null || uid == null || uid <= 0) {
    return null;
  }
  return (uid, (clientFactory ?? _defaultClient)(user));
}

/// Builds a client acting as one account.
typedef BoundClientFactory = NetClientProvider Function(UserLoginInfo user);

NetClientProvider _defaultClient(UserLoginInfo user) => NetClientProvider.build(userLoginInfo: user);

/// Whether a rule added from a notice is being sent now, see [showNoticeIgnoreDialog].
bool _submitting = false;

/// Ask the user which server-side ignore rule to add for [target], then add it after an explicit confirmation.
///
/// This writes to the forum's settings, it is never called without the user choosing it. The account (and one client
/// bound to it) is captured before the first dialog: if the current account changes while a dialog is open, the
/// choice is dropped instead of being written into the other account.
///
/// [context] is only read before the first dialog. The notice card that opens this is unmounted whenever the notice
/// list reloads (every auto sync shows a loading indicator in place of the list), so the dialogs run on the root
/// navigator and the result is shown on the app's messenger: a choice made and a rule written while the list reloads
/// are not dropped. While the forum answers a progress dialog is shown and a second rule can not be started.
///
/// A system notice (author 0) only offers the rule for everybody.
Future<void> showNoticeIgnoreDialog(
  BuildContext context,
  NoticeIgnoreTarget target, {
  NoticeIgnoreRepository repository = const NoticeIgnoreRepository(),
  BoundClientFactory? clientFactory,
}) async {
  final tr = context.t.userBlock.serverRules;
  final auth = context.read<AuthenticationRepository>();
  final navigator = Navigator.of(context, rootNavigator: true);
  final typeName = noticeTypeName(context, target.type);
  if (_submitting) {
    showSnackBar(context: context, message: tr.busy);
    return;
  }
  final bound = boundClientOfCurrentUser(context, clientFactory: clientFactory);
  if (bound == null) {
    showSnackBar(context: context, message: tr.failure.notLoggedIn);
    return;
  }
  final (uid, client) = bound;
  final everybody = await showDialog<bool>(
    context: navigator.context,
    builder: (context) => SimpleDialog(
      title: Text(tr.title),
      children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text(tr.hint)),
        if (target.authorId > 0)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr.ignoreThisUser(type: typeName)),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr.ignoreEverybody(type: typeName)),
        ),
      ],
    ),
  );
  if (everybody == null || !navigator.mounted) {
    return;
  }
  final confirmed = await showQuestionDialog(
    context: navigator.context,
    title: tr.confirmTitle,
    message: tr.confirmContent,
  );
  if (confirmed != true || !navigator.mounted) {
    return;
  }
  if (auth.currentUser?.uid != uid) {
    showSnackBar(context: navigator.context, message: tr.failure.accountMismatch);
    return;
  }
  if (_submitting) {
    showSnackBar(context: navigator.context, message: tr.busy);
    return;
  }
  _submitting = true;
  final closeProgress = _showProgress(navigator, tr.submitting);
  final NoticeIgnoreResult result;
  try {
    result = await repository.addRule(client, uid: uid, target: target, everybody: everybody);
  } finally {
    _submitting = false;
    closeProgress();
  }
  // An answer that arrives after a switch belongs to the previous account: dropped.
  if (auth.currentUser?.uid != uid || !navigator.mounted) {
    return;
  }
  final String message;
  if (!result.isSuccess) {
    message = _failureText(tr.failure, result.failure!);
  } else if (result.alreadyApplied) {
    message = tr.alreadyApplied;
  } else {
    message = tr.success;
  }
  // The messenger of the app, not of the card: shown even when the card is gone.
  showSnackBar(context: navigator.context, message: message);
}

/// Show a progress dialog with [message] on [navigator]; call the returned function to close it.
///
/// Tapping outside does not close it. The back button does, so a request that never ends can not trap the user; the
/// request goes on and its result is still shown.
VoidCallback _showProgress(NavigatorState navigator, String message) {
  final route = DialogRoute<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          sizedBoxW16H16,
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
  unawaited(navigator.push(route));
  return () {
    if (route.isActive) {
      navigator.removeRoute(route);
    }
  };
}
