import 'dart:async';

import 'package:tsdm_client/features/authentication/repository/models/models.dart';

/// How the check-in shortcut ended, see [startCheckinWhenVerified].
enum ShortcutCheckinOutcome {
  /// The check-in was started.
  started,

  /// The stored session is expired, or the account logged out: the login page is for the user.
  notAuthed,

  /// The login check did not answer in time (an offline start): nothing started.
  timedOut,
}

/// Start the check-in ([start]) once the account in use is [verified].
///
/// The check-in only runs for a verified session (`AuthenticationRepository.currentUser`), which at a cold start is
/// null until the homepage's fetch verified the stored one; a `CheckinRequested` sent before that only answered "need
/// login" and was dropped. So the first answer is awaited, up to [timeout] for a start without network:
///
/// * `AuthStatusAuthed` on [status]: the check-in starts (loading states are not answers);
/// * [expired] telling true (the session of the account in use is known to be expired, told by the storage: the
///   homepage records a guest page there and emits no status for it) or `AuthStatusNotAuthed` on [status] (a logout
///   meanwhile): the login page is for the user. An expiry recorded at an earlier start answers right away.
///
/// The answer is checked against [verified] again: a session verified meanwhile wins.
Future<ShortcutCheckinOutcome> startCheckinWhenVerified({
  required bool Function() verified,
  required Stream<AuthStatus> status,
  required Stream<bool> expired,
  required void Function() start,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!verified()) {
    final notAuthed = await _firstAnswer(status, expired, timeout);
    if (!verified()) {
      return notAuthed ?? false ? ShortcutCheckinOutcome.notAuthed : ShortcutCheckinOutcome.timedOut;
    }
  }
  start();
  return ShortcutCheckinOutcome.started;
}

/// Whether the first answer says "not authed"; null when none came within [timeout].
///
/// The subscriptions and the timer end with the first answer, whatever it is.
Future<bool?> _firstAnswer(Stream<AuthStatus> status, Stream<bool> expired, Duration timeout) async {
  final done = Completer<bool?>();
  void answer({required bool? notAuthed}) {
    if (!done.isCompleted) {
      done.complete(notAuthed);
    }
  }

  final timer = Timer(timeout, () => answer(notAuthed: null));
  final statusSub = status.listen((s) {
    if (s is AuthStatusAuthed) {
      answer(notAuthed: false);
    } else if (s is AuthStatusNotAuthed) {
      answer(notAuthed: true);
    }
  });
  final expiredSub = expired.listen((e) {
    if (e) {
      answer(notAuthed: true);
    }
  });
  try {
    return await done.future;
  } finally {
    timer.cancel();
    await statusSub.cancel();
    await expiredSub.cancel();
  }
}
