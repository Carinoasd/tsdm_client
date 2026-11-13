import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/diagnostics/abnormal_exit.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_export.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Ask, once the home page shows, about the abnormal end of the last run ([AbnormalExitRecorder.takePrompt]): a snack
/// bar offering the diagnostics export. Not over the lock screen: asked once unlocked.
Future<void> askAboutAbnormalExit(BuildContext context, {AbnormalExitRecorder? recorder}) async {
  final armed = recorder ?? AbnormalExitRecorder.armed;
  if (armed?.previous == null) {
    return;
  }
  if (getIt.isRegistered<AppLockCubit>()) {
    final lock = getIt.get<AppLockCubit>();
    if (lock.state.covering) {
      // The lock closed meanwhile (the app is closing): still covering, not asked.
      final unlocked = await lock.stream.firstWhere((s) => !s.covering, orElse: () => lock.state);
      if (unlocked.covering) {
        return;
      }
    }
  }
  // Counted as asked once taken: only taken when it can be shown.
  if (!context.mounted || snackbarKey.currentState == null) {
    return;
  }
  final exit = armed!.takePrompt();
  if (exit == null) {
    return;
  }
  talker.info('asking about the abnormal end of the last run');
  final tr = context.t.diagnostics;
  showSnackBar(
    context: context,
    message: switch (exit.kind) {
      AbnormalExitKind.vanished => tr.abnormalExit,
      // An uncaught error does not end the app by itself.
      AbnormalExitKind.error => tr.lastRunError,
    },
    // Asked once only: longer than a hint.
    duration: const Duration(seconds: 10),
    action: SnackBarAction(
      label: tr.export,
      onPressed: () {
        if (context.mounted) {
          unawaited(exportDiagnostics(context));
        }
      },
    ),
  );
}
