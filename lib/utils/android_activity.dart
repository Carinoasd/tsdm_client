import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// How long after an unanswered question the activity is asked for again while nothing tells of one, at first. An
/// activity that attaches changes the lifecycle state, which ends the wait at once: this is for one that did not tell.
const _askAgainAfter = Duration(seconds: 2);

/// The longest time between two questions: the time doubles after each one that finds nothing in front. With the
/// background message service on, days can pass before the app is opened.
const _askAgainAtMost = Duration(seconds: 30);

/// How many times in a row an activity that is in front may leave the question unanswered before the app starts
/// anyway: never left waiting behind its splash screen for a channel that does not come.
const _unansweredInFront = 3;

/// Hold `main()` until the Android activity is there.
///
/// The app runs in the engine of the audio service (`MainActivityImpl`, `AudioServicePlugin.getFlutterEngine`), and
/// the service makes that engine and runs `main()` in it whenever it is created while the engine does not exist,
/// with no activity at all:
///
/// * the Bluetooth stack binds every media browser service when it starts (at boot);
/// * every other engine made in the process brings the audio service's plugin, which binds the service: the engine
///   of the background message service (started at boot and after an update of the app) and the one of the
///   notification plugin (a reply typed in a notification with the app closed);
/// * a media button pressed when this app was the last one to play starts the service through its receiver.
///
/// The channels the activity sets up do not exist then (`MainActivityImpl.configureFlutterEngine`): every call ended
/// in a `MissingPluginException`. The requests of the home page go through one of them, so the app opened later
/// showed that failed start (the home page said its update failed and took the account as signed out, until a
/// retry); the app lock found no biometrics, the icon and the refresh rate were not applied.
///
/// Nothing of the app is started before an activity answers: whatever made the engine, the app then starts as it
/// does when it is opened. (The log is open already and stays the file of the day the engine was made, as for any
/// process that lives over midnight.) What the activity was launched with (a link, a share, a shortcut, a tap on a
/// notification) is asked for after this, as at a cold start; Android keeps for that question what it pushed to a
/// Dart that did not listen yet.
Future<void> waitForAndroidActivity() async {
  if (!isAndroid) {
    return;
  }
  final changes = StreamController<void>.broadcast();
  final listener = AppLifecycleListener(onStateChange: (_) => changes.add(null));
  try {
    final wait = await waitForActivity(
      attached: androidActivityAttached,
      lifecycleChanges: changes.stream,
      inFront: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      onWaiting: () => talker.info('started without an activity: the app starts when one is there'),
    );
    if (!wait.answered) {
      talker.warning('the activity in front does not answer: starting anyway');
    } else if (wait.waited > Duration.zero) {
      talker.info('activity attached after ${wait.waited.inSeconds}s');
    }
  } finally {
    listener.dispose();
    unawaited(changes.close());
  }
}

/// Wait until [attached] says the activity is there, asked at once, then after each of [lifecycleChanges] and after
/// [askAgainAfter], a time that doubles up to [askAgainAtMost] for as long as nothing is [inFront]. [onWaiting] is
/// called when the first answer is no.
///
/// Returns how long that took (nothing when the activity was there at once) and whether the activity answered: an
/// activity [inFront] that does not is not waited for any longer.
@visibleForTesting
Future<({Duration waited, bool answered})> waitForActivity({
  required Future<bool> Function() attached,
  required Stream<void> lifecycleChanges,
  required bool Function() inFront,
  Duration askAgainAfter = _askAgainAfter,
  Duration askAgainAtMost = _askAgainAtMost,
  void Function()? onWaiting,
}) async {
  if (await attached()) {
    return (waited: Duration.zero, answered: true);
  }
  onWaiting?.call();
  final waited = Stopwatch()..start();
  var wake = Completer<void>();
  void ring() {
    if (!wake.isCompleted) {
      wake.complete();
    }
  }

  var pause = askAgainAfter;
  // Listening from here on: a change that comes while the activity is being asked wakes the next round.
  final changes = lifecycleChanges.listen((_) {
    pause = askAgainAfter;
    ring();
  });
  Timer? again;
  var unanswered = 0;
  try {
    while (true) {
      again = Timer(pause, ring);
      await wake.future;
      again.cancel();
      wake = Completer<void>();
      if (await attached()) {
        return (waited: waited.elapsed, answered: true);
      }
      if (inFront()) {
        unanswered++;
        pause = askAgainAfter;
      } else {
        unanswered = 0;
        pause = pause * 2 < askAgainAtMost ? pause * 2 : askAgainAtMost;
      }
      if (unanswered >= _unansweredInFront) {
        return (waited: waited.elapsed, answered: false);
      }
    }
  } finally {
    again?.cancel();
    unawaited(changes.cancel());
  }
}
