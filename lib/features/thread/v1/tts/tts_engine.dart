import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:tsdm_client/utils/platform.dart';

/// How a [TtsEngine.speak] ended.
enum TtsOutcome {
  /// The text was said to the end.
  completed,

  /// [TtsEngine.stop] cut it short.
  cancelled,

  /// The engine reported an error.
  failed,
}

/// What reads the thread aloud: a thin face of the platform speech engine, so the order of the floors can be tested
/// with a fake.
abstract interface class TtsEngine {
  /// The system took the audio away (a call, another app playing, the headphones unplugged): reading should pause.
  Stream<void> get interruptions;

  /// Takes the audio session and picks the voice of [languageTag] when the system has one (the default voice
  /// otherwise).
  Future<void> prepare({required String languageTag});

  /// Speed of the voice, 1.0 being the normal one.
  Future<void> setRate(double rate);

  /// Says [text]; completes when it is over, or cut short by [stop].
  Future<TtsOutcome> speak(String text);

  /// Stops what is being said.
  Future<void> stop();

  /// Gives the audio session back.
  Future<void> release();

  /// Frees the engine.
  Future<void> dispose();
}

/// The speed the platform engines take for the normal one: 0.5 on Android (doubled by the plugin), iOS and macOS.
const _normalEngineRate = 0.5;

/// What `flutter_tts` takes for [rate] times the normal speed: on Windows the plugin adds 0.5 to the number (the
/// speaking rate of WinRT, 1.0 being normal).
double engineRateOf(double rate, {required bool windows}) => windows ? rate - 0.5 : _normalEngineRate * rate;

/// [TtsEngine] on `flutter_tts` (Android, iOS, Windows and macOS) and `audio_session` (Android and iOS).
final class FlutterTtsEngine implements TtsEngine {
  /// Constructor.
  FlutterTtsEngine() {
    _tts
      ..setCompletionHandler(() => _finish(TtsOutcome.completed))
      ..setErrorHandler((_) => _finish(TtsOutcome.failed));
    // A cancel handler is left out on purpose: the callback of a text cut by [stop] can come after the next text has
    // begun, and would cut that one short in the eyes of the caller. The caller knows when it stopped the engine.
  }

  final _tts = FlutterTts();
  final _interruptions = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  Completer<TtsOutcome>? _pending;
  AudioSession? _session;

  @override
  Stream<void> get interruptions => _interruptions.stream;

  void _finish(TtsOutcome outcome) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(outcome);
    }
  }

  @override
  Future<void> prepare({required String languageTag}) async {
    if (isMobile) {
      try {
        final session = _session ?? await AudioSession.instance;
        if (_session == null) {
          _session = session;
          // Reading goes on with the screen off (iOS: the `audio` background mode; Android: the engine is a system
          // service), and yields to a call or to other audio.
          await session.configure(const AudioSessionConfiguration.speech());
          _subscriptions
            ..add(
              session.interruptionEventStream.listen((event) {
                // Ducked (a notification sound, a navigation prompt): the reader goes on, quieter.
                if (event.begin && event.type != AudioInterruptionType.duck) {
                  _interruptions.add(null);
                }
              }),
            )
            ..add(session.becomingNoisyEventStream.listen((_) => _interruptions.add(null)));
        }
        await session.setActive(true);
      } on Object {
        // Reading without a session is still reading.
      }
    }
    try {
      final available = await _tts.isLanguageAvailable(languageTag);
      if (available == true || available == 1) {
        await _tts.setLanguage(languageTag);
      }
    } on Object {
      // The default voice.
    }
  }

  @override
  Future<void> setRate(double rate) async {
    try {
      await _tts.setSpeechRate(engineRateOf(rate, windows: isWindows));
    } on Object {
      // Keeps the speed it had.
    }
  }

  @override
  Future<TtsOutcome> speak(String text) async {
    _finish(TtsOutcome.cancelled);
    final pending = Completer<TtsOutcome>();
    _pending = pending;
    try {
      await _tts.speak(text);
    } on Object {
      if (identical(_pending, pending)) {
        _finish(TtsOutcome.failed);
      }
    }
    return pending.future;
  }

  @override
  Future<void> stop() async {
    final pending = _pending;
    try {
      await _tts.stop();
    } on Object {
      // Nothing to stop.
    }
    // Not a text begun while the engine was stopping: [speak] ends the one before it by itself.
    if (identical(_pending, pending)) {
      _finish(TtsOutcome.cancelled);
    }
  }

  @override
  Future<void> release() async {
    try {
      await _session?.setActive(false);
    } on Object {
      // Not held.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await release();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _interruptions.close();
  }
}
