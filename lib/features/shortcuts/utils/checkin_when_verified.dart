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
///   meanwhile): the login page is for the user. An expiry recorded at an earlier start is told first thing; such a
///   record may be wrong, so it answers after [knownExpiryGrace] unless the session is verified meanwhile.
///
/// The answer is checked against [verified] again: a session verified meanwhile wins. An error of either stream ends
/// the wait as a timeout would.
Future<ShortcutCheckinOutcome> startCheckinWhenVerified({
  required bool Function() verified,
  required Stream<AuthStatus> status,
  required Stream<bool> expired,
  required void Function() start,
  Duration timeout = const Duration(seconds: 20),
  Duration knownExpiryGrace = const Duration(seconds: 3),
}) async {
  if (!verified()) {
    final notAuthed = await _firstAnswer(status, expired, timeout, knownExpiryGrace);
    if (!verified()) {
      return notAuthed ?? false ? ShortcutCheckinOutcome.notAuthed : ShortcutCheckinOutcome.timedOut;
    }
  }
  start();
  return ShortcutCheckinOutcome.started;
}

/// Whether the first answer says "not authed"; null when none came within [timeout] (or a stream failed).
///
/// The first value of [expired] is the record of the storage as it is: true there is an expiry recorded earlier, which
/// answers after [knownExpiryGrace]. The subscriptions and the timers end with the first answer, whatever it is.
Future<bool?> _firstAnswer(
  Stream<AuthStatus> status,
  Stream<bool> expired,
  Duration timeout,
  Duration knownExpiryGrace,
) async {
  final done = Completer<bool?>();
  void answer({required bool? notAuthed}) {
    if (!done.isCompleted) {
      done.complete(notAuthed);
    }
  }

  final timer = Timer(timeout, () => answer(notAuthed: null));
  Timer? grace;
  final statusSub = status.listen((s) {
    if (s is AuthStatusAuthed) {
      answer(notAuthed: false);
    } else if (s is AuthStatusNotAuthed) {
      answer(notAuthed: true);
    }
  }, onError: (Object _) => answer(notAuthed: null));
  var first = true;
  final expiredSub = expired.listen((e) {
    if (e) {
      if (first) {
        grace ??= Timer(knownExpiryGrace, () => answer(notAuthed: true));
      } else {
        answer(notAuthed: true);
      }
    }
    first = false;
  }, onError: (Object _) => answer(notAuthed: null));
  try {
    return await done.future;
  } finally {
    timer.cancel();
    grace?.cancel();
    await statusSub.cancel();
    await expiredSub.cancel();
  }
}
