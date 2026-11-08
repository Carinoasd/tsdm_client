import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/login_device/login_device_coordinator.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Tells the user that another device logged this one out of an account ([LoginDeviceCoordinator.revocations]), with
/// the way back to the login page.
final class LoginDeviceRevokedWatcher extends StatefulWidget {
  /// Constructor.
  const LoginDeviceRevokedWatcher({super.key});

  @override
  State<LoginDeviceRevokedWatcher> createState() => _LoginDeviceRevokedWatcherState();
}

final class _LoginDeviceRevokedWatcherState extends State<LoginDeviceRevokedWatcher> {
  StreamSubscription<LoginDeviceRevocation>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = context.readOrNull<LoginDeviceCoordinator>()?.revocations.listen(_show);
  }

  void _show(LoginDeviceRevocation revocation) {
    if (!mounted) {
      return;
    }
    final tr = context.t.loginDevicesPage;
    final name = revocation.username;
    showSnackBar(
      context: context,
      message: name == null || name.isEmpty ? tr.revokedUnknown : tr.revoked(name: name),
      actionOverflowThreshold: 0.6,
      action: SnackBarAction(label: tr.login, onPressed: () async => router.pushNamed(ScreenPaths.login)),
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
