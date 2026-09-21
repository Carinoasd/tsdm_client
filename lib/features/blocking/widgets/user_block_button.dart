import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Localized text of a block / unblock [result] for user [name].
String userBlockResultText(BuildContext context, UserBlockResult result, {required String name, required bool block}) {
  final tr = context.t.userBlock;
  return switch (result) {
    UserBlockResult.ok ||
    UserBlockResult.alreadyBlocked ||
    UserBlockResult.notBlocked => block ? tr.blocked(name: name) : tr.unblocked(name: name),
    UserBlockResult.selfBlock => tr.selfBlock,
    UserBlockResult.invalid => tr.invalid,
    UserBlockResult.accountChanged => tr.accountChanged,
    UserBlockResult.storageError => tr.storageError,
  };
}

/// Ask for confirmation, then block [uid] locally for the account that was current when this was called.
///
/// The account is captured before the dialog: when it changes while the dialog is open the choice is dropped
/// ([UserBlockResult.accountChanged]) instead of being applied to the new account.
Future<UserBlockResult?> confirmAndBlockUser(BuildContext context, {required int uid, required String username}) async {
  final cubit = context.read<UserBlockCubit>();
  final owner = cubit.owner;
  final tr = context.t.userBlock;
  final ok = await showQuestionDialog(
    context: context,
    title: tr.blockConfirmTitle(name: username),
    message: tr.blockConfirmContent,
  );
  if (ok != true) {
    return null;
  }
  final result = await cubit.block(uid: uid, username: username, expectedOwner: owner);
  if (context.mounted) {
    showSnackBar(
      context: context,
      message: userBlockResultText(context, result, name: username, block: true),
    );
  }
  return result;
}

/// Unblock [uid] for the account current when this is called.
Future<UserBlockResult> unblockUser(BuildContext context, {required int uid, required String username}) async {
  final cubit = context.read<UserBlockCubit>();
  final result = await cubit.unblock(uid, expectedOwner: cubit.owner);
  if (context.mounted) {
    showSnackBar(
      context: context,
      message: userBlockResultText(context, result, name: username, block: false),
    );
  }
  return result;
}

/// Block or unblock [uid] locally for the current account.
///
/// Hidden for the current account itself and while the list of the current account is not known. Never sends any
/// request.
class UserBlockButton extends StatelessWidget {
  /// Constructor.
  const UserBlockButton({required this.uid, required this.username, super.key});

  /// Target uid.
  final int uid;

  /// Target username.
  final String username;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock;
    final (owner, known, blocked) = context.select<UserBlockCubit, (int?, bool, bool)>(
      (c) => (c.state.ownerUid, c.state.status == UserBlockListStatus.ready, c.state.isBlocked(uid)),
    );
    if (owner == null || owner == uid || uid <= 0 || !known) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: Icon(blocked ? Icons.remove_moderator_outlined : Icons.block_outlined),
      tooltip: blocked ? tr.unblock : tr.block,
      onPressed: () async {
        if (blocked) {
          await unblockUser(context, uid: uid, username: username);
        } else {
          await confirmAndBlockUser(context, uid: uid, username: username);
        }
      },
    );
  }
}
