import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
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
class _ManageUserDialog extends StatelessWidget with LoggerMixin {
  /// Constructor.
  const _ManageUserDialog({required this.userInfo, required this.heroTag, this.isCurrentUser = false});

  /// The info about user to manage.
  final UserLoginInfo userInfo;

  /// Tag for user avatar hero.
  final String heroTag;

  /// Whether [userInfo] is the account currently logged in.
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.manageAccountPage.switchAccount.dialog;
    return CustomAlertDialog.sync(
      clipBehavior: Clip.hardEdge,
      title: Row(
        children: [
          HeroUserAvatar(username: userInfo.username!, avatarUrl: null, disableHero: true, minRadius: 30),
          sizedBoxW12H12,
          Expanded(child: SingleLineText(userInfo.username!, style: Theme.of(context).textTheme.titleLarge)),
        ],
      ),
      content: Column(
        children: [
          if (isCurrentUser) ...[_buildLogoutTile(context), _buildRemoveFromDeviceTile(context)],
          if (!isCurrentUser) ...[
            ListTile(
              title: Text(tr.switchAccount),
              onTap: () async {
                var times = 10;
                while (context.read<AutoNotificationCubit>().pause('switch user')) {
                  info('switch user is waiting for auto sync lock... $times');
                  times -= 1;
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                  if (times <= 0 || !context.mounted) {
                    info('auto sync lock timeout or canceled, do not switch user');
                    return;
                  }
                }
                context.read<SwitchUserBloc>().add(SwitchUserStartRequested(userInfo));
                context.pop();
              },
            ),
            ListTile(
              title: Text(tr.deleteAccount.title),
              subtitle: Text(tr.deleteAccount.detail),
              enabled: userInfo.uid != null,
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
            ListTile(
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
          ],
        ],
      ),
    );
  }

  /// Remove the current account from this device after confirmation, without logging out of the forum.
  ///
  /// The local counterpart of [_buildLogoutTile]: works offline and when the forum session already expired, which
  /// left the account stuck as "online" before (issue #6).
  Widget _buildRemoveFromDeviceTile(BuildContext context) {
    final tr = context.t.manageAccountPage;
    return ListTile(
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
