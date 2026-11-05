import 'dart:async';

import 'package:tsdm_client/features/authentication/repository/models/models.dart';

/// How the check-in shortcut ended, see [startCheckinWhenVerified].
enum ShortcutCheckinOutcome {
  /// The check-in was started.
  started,

  /// The stored session turned out expired: the login page is for the user.
  notAuthed,

  /// The login check did not answer in time (an offline start): nothing started.
  timedOut,
}

/// Start the check-in ([start]) once the account in use is [verified].
///
/// The check-in only runs for a verified session (`AuthenticationRepository.currentUser`), which at a cold start is
/// null until the homepage's fetch verified the stored one; a `CheckinRequested` sent before that only answered "need
/// login" and was dropped. So the first answer of [status] is awaited (`AuthStatusAuthed` or `AuthStatusNotAuthed`;
/// loading states are not answers), up to [timeout] for a start without network.
Future<ShortcutCheckinOutcome> startCheckinWhenVerified({
  required bool Function() verified,
  required Stream<AuthStatus> status,
  required void Function() start,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!verified()) {
    final answer = await status
        .where((s) => s is AuthStatusAuthed || s is AuthStatusNotAuthed)
        .first
        .timeout(timeout, onTimeout: () => const AuthStatusUnknown());
    if (!verified()) {
      return answer is AuthStatusNotAuthed ? ShortcutCheckinOutcome.notAuthed : ShortcutCheckinOutcome.timedOut;
    }
  }
  start();
  return ShortcutCheckinOutcome.started;
}
