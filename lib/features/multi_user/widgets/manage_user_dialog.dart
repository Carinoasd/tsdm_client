import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

/// Open the user management dialog for the given user with [userInfo].
///
/// [heroTag] is used to specify the unique hero animation on user avatar.
///
/// Set [isCurrentUser] when [userInfo] is the account currently logged in: the dialog then offers to log out or to
/// remove the account from this device instead of the switch / delete / login-again actions.
Future<void> openManageUserDialog({
  required BuildContext context,
  required UserLoginInfo userInfo,
  required String heroTag,
  bool isCurrentUser = false,
}) async {
  // Resolve the bloc once, outside the dialog builder. The builder runs again whenever the dialog rebuilds, and
  // by then the list tile that opened it may already be gone (e.g. its account was logged out), so looking up an
  // ancestor through that tile's context would throw "Looking up a deactivated widget's ancestor is unsafe".
  final switchUserBloc = context.read<SwitchUserBloc>();
  return showDialog(
    context: context,
    builder: (_) => BlocProvider.value(
      value: switchUserBloc,
      child: RootPage(
        DialogPaths.manageUser,
        _ManageUserDialog(userInfo: userInfo, heroTag: heroTag, isCurrentUser: isCurrentUser),
      ),
    ),
  );
}

/// Dialog to manage a given user, single one.
class _ManageUserDialog extends StatefulWidget {
  /// Constructor.
  const _ManageUserDialog({required this.userInfo, required this.heroTag, this.isCurrentUser = false});

  /// The info about user to manage.
  final UserLoginInfo userInfo;

  /// Tag for user avatar hero.
  final String heroTag;

  /// Whether [userInfo] is the account currently logged in.
  final bool isCurrentUser;

  @override
  State<_ManageUserDialog> createState() => _ManageUserDialogState();
}

class _ManageUserDialogState extends State<_ManageUserDialog> with LoggerMixin {
  /// Whether switching to this account is running: the dialog stays open, cannot be dismissed and shows the progress.
  bool _switching = false;

  /// The account this dialog is about.
  UserLoginInfo get userInfo => widget.userInfo;

  /// Whether [userInfo] is the account currently logged in.
  bool get isCurrentUser => widget.isCurrentUser;

  /// Switch to this account the same way the avatar menu does (see [switchAccount]); closes the dialog on success.
  Future<void> _switchAccount() async {
    setState(() => _switching = true);
    final result = await switchAccount(context, bloc: context.read<SwitchUserBloc>(), userInfo: userInfo);
    if (!mounted) {
      return;
    }
    if (result == SwitchAccountResult.switched) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _switching = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.manageAccountPage.switchAccount.dialog;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final enabled = !_switching;
    // Only this account's own name and uid: nothing of another account is shown here.
    // While switching, neither back nor a tap beside the dialog closes it, and every action waits.
    return PopScope(
      canPop: !_switching,
      child: CustomAlertDialog.sync(
        clipBehavior: Clip.hardEdge,
        title: Row(
          children: [
            HeroUserAvatar(username: userInfo.username!, avatarUrl: null, disableHero: true, minRadius: 30),
            sizedBoxW12H12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SingleLineText(
                    userInfo.username!,
                    style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (userInfo.uid != null) AppInfoPill(icon: Icons.tag, label: '${userInfo.uid}'),
                      if (isCurrentUser) AppInfoPill(icon: Icons.circle, label: context.t.manageAccountPage.online),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          children: [
            if (isCurrentUser) ...[_buildLogoutTile(context), _buildRemoveFromDeviceTile(context)],
            if (!isCurrentUser) ...[
              ListTile(
                leading: const Icon(Icons.switch_account_outlined),
                shape: _tileShape,
                title: Text(tr.switchAccount),
                trailing: _switching ? sizedCircularProgressIndicator : null,
                enabled: enabled,
                onTap: _switchAccount,
              ),
              ListTile(
                leading: const Icon(Icons.login_outlined),
                shape: _tileShape,
                enabled: enabled,
                title: Text(tr.loginAgain.title),
                subtitle: Text(tr.loginAgain.detail),
                onTap: () async {
                  await context.pushNamed(
                    ScreenPaths.login,
                    queryParameters: {if (userInfo.username != null) 'username': '${userInfo.username}'},
                  );
                  if (!context.mounted) {
                    return;
                  }
                  context.pop();
                },
              ),
              Divider(height: 9, color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
              // Destructive, last and in the error color.
              ListTile(
                leading: Icon(Icons.person_remove_outlined, color: colorScheme.error),
                shape: _tileShape,
                textColor: colorScheme.error,
                title: Text(tr.deleteAccount.title),
                subtitle: Text(tr.deleteAccount.detail),
                enabled: enabled && userInfo.uid != null,
                onTap: () async {
                  final confirmed = await showQuestionDialog(
                    context: context,
                    title: tr.deleteAccount.title,
                    message: tr.deleteAccount.confirm(username: userInfo.username ?? ''),
                    dangerous: true,
                  );
                  if (confirmed != true || !context.mounted) {
                    return;
                  }
                  final deleted = await getIt.get<StorageProvider>().deleteCookieByUid(userInfo.uid!);
                  if (!context.mounted) {
                    return;
                  }
                  showSnackBar(
                    context: context,
                    message: context.t.manageAccountPage.selection.deleted(count: deleted ? 1 : 0),
                  );
                  context.pop();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  static final _tileShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius));

  /// Remove the current account from this device after confirmation, without logging out of the forum.
  ///
  /// The local counterpart of [_buildLogoutTile]: works offline and when the forum session already expired, which
  /// left the account stuck as "online" before (issue #6).
  Widget _buildRemoveFromDeviceTile(BuildContext context) {
    final tr = context.t.manageAccountPage;
    final error = Theme.of(context).colorScheme.error;
    return ListTile(
      leading: Icon(Icons.phonelink_erase_outlined, color: error),
      shape: _tileShape,
      textColor: error,
      title: Text(tr.removeFromDevice.title),
      subtitle: Text(tr.removeFromDevice.detail),
      onTap: () async {
        final confirmed = await showQuestionDialog(
          context: context,
          title: tr.removeFromDevice.title,
          message: tr.removeFromDevice.confirm(username: userInfo.username ?? ''),
          dangerous: true,
        );
        if (!context.mounted || confirmed != true) {
          return;
        }
        final result = await context.repo<AuthenticationRepository>().forgetCurrentUser().run();
        if (!context.mounted) {
          return;
        }
        if (result.isLeft()) {
          showSnackBar(context: context, message: context.t.general.failedToLoad);
          return;
        }
        showSnackBar(context: context, message: tr.selection.deleted(count: 1));
        context.pop();
      },
    );
  }

  /// Log out the current account after confirmation.
  ///
  /// Reuses the same logout flow as the profile page: ends the forum session, deletes the cookie saved for this
  /// account and marks the app as unauthenticated.
  Widget _buildLogoutTile(BuildContext context) {
    final tr = context.t.manageAccountPage;
    return ListTile(
      leading: const Icon(Icons.logout_outlined),
      shape: _tileShape,
      title: Text(tr.logout),
      subtitle: Text(tr.logoutDetail),
      onTap: () async {
        final confirmed = await showQuestionDialog(
          context: context,
          title: tr.logout,
          message: context.t.profilePage.areYouSureToLogout,
          dangerous: true,
        );
        if (!context.mounted || confirmed != true) {
          return;
        }
        // Cover the screen while logging out so the action cannot be repeated by tapping again.
        final repo = context.repo<AuthenticationRepository>();
        final navigator = Navigator.of(context, rootNavigator: true);
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
          ),
        );
        final result = await repo.logout().run();
        navigator.pop();
        if (!context.mounted) {
          return;
        }
        if (result.isLeft()) {
          showSnackBar(context: context, message: context.t.general.failedToLoad);
          return;
        }
        context.pop();
      },
    );
  }
}
