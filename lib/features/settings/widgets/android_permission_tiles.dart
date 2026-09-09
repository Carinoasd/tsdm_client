import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// The two Android-only rows in the behavior section: notification permission and battery optimization (#13, #3).
///
/// Needs an [AndroidPermissionCubit] above it.
class AndroidPermissionTiles extends StatelessWidget {
  /// Constructor.
  const AndroidPermissionTiles({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.behaviorSection;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.secondary);
    return BlocBuilder<AndroidPermissionCubit, AndroidPermissionState>(
      builder: (context, state) {
        final notification = switch (state.notification) {
          null => '',
          PermissionStatus.granted ||
          PermissionStatus.limited ||
          PermissionStatus.provisional => tr.notificationPermission.granted,
          PermissionStatus.permanentlyDenied => tr.notificationPermission.permanentlyDenied,
          PermissionStatus.denied || PermissionStatus.restricted => tr.notificationPermission.denied,
        };
        final battery = switch (state.ignoreBattery) {
          null => '',
          PermissionStatus.granted => tr.ignoreBatteryOptimizations.granted,
          _ => tr.ignoreBatteryOptimizations.denied,
        };
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(tr.notificationPermission.title),
              subtitle: Text(tr.notificationPermission.detail),
              trailing: Text(notification, style: style),
              onTap: () async {
                final cubit = context.read<AndroidPermissionCubit>();
                if (!(state.notification?.isPermanentlyDenied ?? false)) {
                  // Ask the system first; the cubit flips to permanently denied when no dialog was (or will be) shown.
                  await cubit.requestNotification(openSettingsWhenPermanentlyDenied: false);
                  if (!context.mounted || !(cubit.state.notification?.isPermanentlyDenied ?? false)) {
                    return;
                  }
                }
                // Android shows no dialog any more; explain before jumping to system settings.
                final go = await showQuestionDialog(
                  context: context,
                  title: tr.notificationPermission.title,
                  message: tr.notificationPermission.openSettingsTip,
                );
                if (go != true) {
                  return;
                }
                await cubit.requestNotification();
              },
            ),
            SectionListTile(
              leading: const Icon(Icons.battery_saver_outlined),
              title: Text(tr.ignoreBatteryOptimizations.title),
              subtitle: Text(tr.ignoreBatteryOptimizations.detail),
              trailing: Text(battery, style: style),
              onTap: () async => context.read<AndroidPermissionCubit>().requestIgnoreBattery(),
            ),
          ],
        );
      },
    );
  }
}
