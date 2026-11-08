import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/login_device/cubit/login_devices_cubit.dart';
import 'package:tsdm_client/features/login_device/login_device_coordinator.dart';
import 'package:tsdm_client/features/login_device/models/login_device.dart';
import 'package:tsdm_client/features/notification/utils/relative_time.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The devices the account in use logged in on with the app (plugin 3.6.0): this one marked, the others to log out,
/// those logged out to take off the list.
class LoginDevicesPage extends StatelessWidget {
  /// Constructor.
  const LoginDevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.repo<AuthenticationRepository>().effectiveCurrentUid;
    final tr = context.t.loginDevicesPage;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.title)),
        body: AppStateView(icon: Icons.login_outlined, message: context.t.general.needLogin),
      );
    }
    return BlocProvider(
      create: (context) {
        final cubit = LoginDevicesCubit(repository: context.repo<LoginDeviceCoordinator>().repository, uid: uid);
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocConsumer<LoginDevicesCubit, LoginDevicesState>(
        listenWhen: (prev, curr) => prev.writeSeq != curr.writeSeq,
        listener: (context, state) => showSnackBar(context: context, message: tr.writeFailed),
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: Text(tr.title)),
          body: SafeArea(bottom: false, child: _body(context, state)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, LoginDevicesState state) {
    final tr = context.t.loginDevicesPage;
    final cubit = context.read<LoginDevicesCubit>();
    switch (state.status) {
      case LoginDevicesStatus.loading:
        return const CenteredCircularIndicator();
      case LoginDevicesStatus.unsupported:
        return AppStateView(icon: Icons.devices_outlined, message: tr.unsupported);
      case LoginDevicesStatus.failed:
        return AppStateView(
          icon: Icons.error_outline,
          error: true,
          message: context.t.general.failedToLoad,
          action: FilledButton.tonal(onPressed: cubit.load, child: Text(context.t.general.retry)),
        );
      case LoginDevicesStatus.ready:
        break;
    }
    final active = state.active;
    final revoked = state.revoked;
    return RefreshIndicator(
      onRefresh: cubit.load,
      child: AppCenteredList(
        maxWidth: appFormMaxWidth,
        builder: (context, padding, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
          children: [
            if (active.isNotEmpty)
              AppTileGroup(
                children: [for (final d in active) _DeviceTile(d, busy: state.writing.contains(d.id))],
              ),
            if (revoked.isNotEmpty) ...[
              if (active.isNotEmpty) const SizedBox(height: appSurfaceGap),
              AppTileGroup(
                title: tr.loggedOut,
                icon: Icons.logout_outlined,
                children: [for (final d in revoked) _DeviceTile(d, busy: state.writing.contains(d.id))],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The name of [platform] as the system calls itself.
String _platformName(String platform) => switch (platform) {
  'android' => 'Android',
  'ios' => 'iOS',
  'windows' => 'Windows',
  'macos' => 'macOS',
  'linux' => 'Linux',
  final other => other,
};

IconData _platformIcon(String platform) => switch (platform) {
  'android' => Icons.phone_android_outlined,
  'ios' => Icons.phone_iphone_outlined,
  'macos' => Icons.laptop_mac_outlined,
  'windows' => Icons.desktop_windows_outlined,
  _ => Icons.computer_outlined,
};

class _DeviceTile extends StatelessWidget {
  const _DeviceTile(this.device, {required this.busy});

  final LoginDevice device;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.loginDevicesPage;
    final theme = Theme.of(context);
    final platform = _platformName(device.platform);
    final title = device.name.isNotEmpty ? device.name : platform;
    final lastSeen = device.lastSeen;
    final subtitle = [
      if (device.name.isNotEmpty) platform,
      if (device.appVersion.isNotEmpty) device.appVersion,
      if (lastSeen != null) relativeTimeOf(context.t, lastSeen),
    ].join(' · ');
    final Widget? trailing;
    if (busy) {
      trailing = sizedCircularProgressIndicator;
    } else if (device.current) {
      trailing = null;
    } else if (device.revoked) {
      trailing = TextButton(onPressed: () => context.read<LoginDevicesCubit>().remove(device), child: Text(tr.remove));
    } else {
      trailing = TextButton(
        style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
        onPressed: () async {
          final cubit = context.read<LoginDevicesCubit>();
          final yes = await showQuestionDialog(
            context: context,
            title: tr.logOutTitle,
            message: subtitle.isEmpty ? title : '$title\n$subtitle',
            dangerous: true,
          );
          if (yes ?? false) {
            await cubit.revoke(device);
          }
        },
        child: Text(tr.logOut),
      );
    }
    return ListTile(
      leading: AppIconTile(_platformIcon(device.platform)),
      title: Row(
        children: [
          Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (device.current) ...[
            const SizedBox(width: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                child: Text(
                  tr.current,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}
