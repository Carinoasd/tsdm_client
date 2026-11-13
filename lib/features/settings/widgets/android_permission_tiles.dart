import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// Whether the background message service is on while the system may stop it for good (P13): without the battery
/// optimization exemption Android 12+ refuses to start it again once the process was killed, until the app is opened.
/// Unknown (not read yet) is not at risk.
bool backgroundReceiveAtRisk({required bool serviceOn, required PermissionStatus? ignoreBattery}) =>
    serviceOn && ignoreBattery != null && ignoreBattery != PermissionStatus.granted;

/// The two Android-only rows in the behavior section: notification permission and battery optimization (#13, #3).
///
/// With the background message service on and no exemption, the battery row is drawn in the error color
/// ([backgroundReceiveAtRisk]); its tap asks the system for the exemption.
///
/// Needs an [AndroidPermissionCubit] above it.
class AndroidPermissionTiles extends StatelessWidget {
  /// Constructor.
  const AndroidPermissionTiles({this.backgroundServiceOn = false, super.key});

  /// Whether the background message service is switched on.
  final bool backgroundServiceOn;

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
        final atRisk = backgroundReceiveAtRisk(serviceOn: backgroundServiceOn, ignoreBattery: state.ignoreBattery);
        final error = Theme.of(context).colorScheme.error;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionListTile(
              leading: Icon(MdiIcons.bellCogOutline), // 注意这里去掉了 const
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
              key: const ValueKey('settings-ignore-battery'),
              leading: Icon(Icons.battery_saver_outlined, color: atRisk ? error : null),
              title: Text(tr.ignoreBatteryOptimizations.title),
              subtitle: Text(tr.ignoreBatteryOptimizations.detail),
              trailing: Text(battery, style: atRisk ? style?.copyWith(color: error) : style),
              onTap: () async => context.read<AndroidPermissionCubit>().requestIgnoreBattery(),
            ),
          ],
        );
      },
    );
  }
}
