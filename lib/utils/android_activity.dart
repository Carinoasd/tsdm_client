import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// How often the activity is asked for again while nothing tells of one. An activity that attaches changes the
/// lifecycle state, which ends the wait at once: this is for one that did not tell.
const _askAgainEvery = Duration(seconds: 2);

/// How many times in a row an activity that is in front may leave the question unanswered before the app starts
/// anyway: never left waiting behind its splash screen for a channel that does not come.
const _unansweredInFront = 3;

/// Hold `main()` until the Android activity is there.
///
/// The app runs in the engine of the audio service (`MainActivityImpl`, `AudioServicePlugin.getFlutterEngine`), and
/// the service makes that engine and runs `main()` in it whenever it is created while the engine does not exist,
/// with no activity at all:
///
/// * the Bluetooth stack binds every media browser service when it starts (at boot, when Bluetooth is turned on),
///   as other media browsers of the system do;
/// * every other engine made in the process brings the audio service's plugin, which binds the service: the engine
///   of the background message service (started at boot and after an update of the app) and the one of the
///   notification plugin (a reply typed in a notification with the app closed);
/// * a media button pressed when this app was the last one to play.
///
/// The channels the activity sets up do not exist then (`MainActivityImpl.configureFlutterEngine`): every call ended
/// in a `MissingPluginException`. The requests of the home page go through one of them, so the app opened later
/// showed that failed start (the home page said its update failed and took the account as signed out, until a
/// retry); the app lock found no biometrics, the icon and the refresh rate were not applied.
///
/// Nothing of the app is started before an activity answers: whatever made the engine, the app then starts as it
/// does when it is opened. What the activity was launched with (a link, a share, a shortcut, a tap on a
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

/// Wait until [attached] says the activity is there, asked at once, then after each of [lifecycleChanges] and every
/// [askAgainEvery]. [onWaiting] is called when the first answer is no.
///
/// Returns how long that took (nothing when the activity was there at once) and whether the activity answered: an
/// activity [inFront] that does not is not waited for any longer.
@visibleForTesting
Future<({Duration waited, bool answered})> waitForActivity({
  required Future<bool> Function() attached,
  required Stream<void> lifecycleChanges,
  required bool Function() inFront,
  Duration askAgainEvery = _askAgainEvery,
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

  // Listening from here on: a change that comes while the activity is being asked wakes the next round.
  final changes = lifecycleChanges.listen((_) => ring());
  final again = Timer.periodic(askAgainEvery, (_) => ring());
  var unanswered = 0;
  try {
    while (true) {
      await wake.future;
      wake = Completer<void>();
      if (await attached()) {
        return (waited: waited.elapsed, answered: true);
      }
      unanswered = inFront() ? unanswered + 1 : 0;
      if (unanswered >= _unansweredInFront) {
        return (waited: waited.elapsed, answered: false);
      }
    }
  } finally {
    again.cancel();
    unawaited(changes.cancel());
  }
}
