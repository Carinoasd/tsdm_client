import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Where the notification permission is asked from.
enum NotificationPermissionTrigger {
  /// Right after a login.
  login,

  /// The first visit of the notice page.
  noticePage,

  /// The auto sync or the background service turned on in the settings.
  settings,
}

/// Ask for the notification permission (Android 13+) from [trigger], with a card explaining why before the system
/// dialog. The app used to ask before its first frame, so a new install showed a bare system dialog over a blank
/// screen.
///
/// Never for a guest ([loggedIn] false): nothing would notify. After a login and on the notice page only once
/// ([SettingsKeys.notificationPermissionPrompted]) and only while the auto sync or the background service is on; never
/// when the permission is granted already or the system will not show its dialog any more (permanently denied: the
/// settings page leads to the app settings for that). Turning the sync on in the settings asks whenever the permission
/// is missing.
///
/// [cubit] is the permission state to request through (the settings page's, so its tiles follow), one of its own when
/// null; [gateway] and [enabled] (Android by default) are for tests. Returns whether the system dialog was asked for.
Future<bool> askNotificationPermission(
  BuildContext context, {
  required NotificationPermissionTrigger trigger,
  required bool loggedIn,
  AndroidPermissionCubit? cubit,
  AndroidPermissionGateway? gateway,
  bool? enabled,
}) async {
  final settingsRepository = getIt.get<SettingsRepository>();
  final settings = settingsRepository.currentSettings;
  final once = trigger != NotificationPermissionTrigger.settings;
  if (!loggedIn) {
    return false;
  }
  if (once &&
      (settings.notificationPermissionPrompted ||
          (settings.autoSyncNoticeSeconds <= 0 && !settings.enableBackgroundMessageService))) {
    return false;
  }
  final permissions = cubit ?? AndroidPermissionCubit(gateway: gateway, enabled: enabled);
  try {
    if (!permissions.enabled) {
      return false;
    }
    await permissions.refresh();
    final status = permissions.state.notification;
    if (status == null || status.isGranted || status.isLimited || status.isProvisional) {
      if (once && status != null) {
        await settingsRepository.setValue(SettingsKeys.notificationPermissionPrompted, true);
      }
      return false;
    }
    if (once && status.isPermanentlyDenied) {
      await settingsRepository.setValue(SettingsKeys.notificationPermissionPrompted, true);
      return false;
    }
    if (!context.mounted) {
      return false;
    }
    final allow = await showNotificationPermissionCard(context);
    if (once) {
      // Shown once, whatever the answer: the settings page keeps the way to ask again.
      await settingsRepository.setValue(SettingsKeys.notificationPermissionPrompted, true);
    }
    if (!allow) {
      talker.info('notification permission card dismissed ($trigger)');
      return false;
    }
    await permissions.requestNotification(openSettingsWhenPermanentlyDenied: false);
    talker.info('notification permission asked ($trigger): ${permissions.state.notification}');
    return true;
  } finally {
    if (cubit == null) {
      await permissions.close();
    }
  }
}

/// [askNotificationPermission] right after a login: on the page below the login page once it is gone (the login page
/// pops or replaces itself), from the root navigator.
void askNotificationPermissionAfterLogin() {
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final context = router.routerDelegate.navigatorKey.currentState?.overlay?.context;
    if (context == null || !context.mounted) {
      return;
    }
    await askNotificationPermission(context, trigger: NotificationPermissionTrigger.login, loggedIn: true);
  });
}

/// The card explaining the notification permission before the system asks for it; true to go on to the system
/// dialog.
Future<bool> showNotificationPermissionCard(BuildContext context) async {
  final allow = await showDialog<bool>(
    context: context,
    builder: (context) {
      final tr = context.t.settingsPage.behaviorSection.notificationPermission;
      return RootPage(
        DialogPaths.question,
        CustomAlertDialog.sync(
          title: AppDialogTitle(icon: Icons.notifications_active_outlined, title: tr.promptTitle),
          content: Text(tr.promptMessage),
          actions: [
            TextButton(
              key: const ValueKey('notification-permission-later'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.promptLater),
            ),
            FilledButton(
              key: const ValueKey('notification-permission-allow'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.promptAllow),
            ),
          ],
        ),
      );
    },
  );
  return allow ?? false;
}
