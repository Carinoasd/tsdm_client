import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Localized text of [failure].
String noticeIgnoreFailureText(BuildContext context, NoticeIgnoreFailure failure) {
  final tr = context.t.userBlock.serverRules.failure;
  return switch (failure) {
    NoticeIgnoreFailure.network => tr.network,
    NoticeIgnoreFailure.notLoggedIn => tr.notLoggedIn,
    NoticeIgnoreFailure.accountMismatch => tr.accountMismatch,
    NoticeIgnoreFailure.challenge => tr.challenge,
    NoticeIgnoreFailure.forumError => tr.forumError,
    NoticeIgnoreFailure.unknownForm => tr.unknownForm,
    NoticeIgnoreFailure.ruleNotFound => tr.ruleNotFound,
    NoticeIgnoreFailure.unknownAfterSubmit => tr.unknownAfterSubmit,
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

/// Whether the account [uid] is still the current one.
bool isStillCurrentUser(BuildContext context, int uid) =>
    context.read<AuthenticationRepository>().currentUser?.uid == uid;

/// Ask the user which server-side ignore rule to add for [target], then add it after an explicit confirmation.
///
/// This writes to the forum's settings, it is never called without the user choosing it. The account (and one client
/// bound to it) is captured before the first dialog: if the current account changes while a dialog is open, the
/// choice is dropped instead of being written into the other account.
///
/// A system notice (author 0) only offers the rule for everybody.
Future<void> showNoticeIgnoreDialog(
  BuildContext context,
  NoticeIgnoreTarget target, {
  NoticeIgnoreRepository repository = const NoticeIgnoreRepository(),
  BoundClientFactory? clientFactory,
}) async {
  final tr = context.t.userBlock.serverRules;
  final bound = boundClientOfCurrentUser(context, clientFactory: clientFactory);
  if (bound == null) {
    showSnackBar(context: context, message: tr.failure.notLoggedIn);
    return;
  }
  final (uid, client) = bound;
  final everybody = await showDialog<bool>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(tr.title),
      children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text(tr.hint)),
        if (target.authorId > 0)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr.ignoreThisUser(type: target.type)),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr.ignoreEverybody(type: target.type)),
        ),
      ],
    ),
  );
  if (everybody == null || !context.mounted) {
    return;
  }
  final confirmed = await showQuestionDialog(context: context, title: tr.confirmTitle, message: tr.confirmContent);
  if (confirmed != true || !context.mounted) {
    return;
  }
  if (!isStillCurrentUser(context, uid)) {
    showSnackBar(context: context, message: tr.failure.accountMismatch);
    return;
  }
  final result = await repository.addRule(client, uid: uid, target: target, everybody: everybody);
  if (!context.mounted || !isStillCurrentUser(context, uid)) {
    return;
  }
  showSnackBar(
    context: context,
    message: result.isSuccess ? tr.success : noticeIgnoreFailureText(context, result.failure!),
  );
}
