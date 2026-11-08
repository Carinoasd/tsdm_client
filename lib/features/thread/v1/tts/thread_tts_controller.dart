import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/thread/v1/tts/thread_tts_text.dart';
import 'package:tsdm_client/features/thread/v1/tts/tts_engine.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Slowest and fastest speed the reader goes at.
const ttsMinRate = 0.8;

/// See [ttsMinRate].
const ttsMaxRate = 1.5;

/// What the reader is doing.
enum TtsStatus {
  /// Not reading.
  idle,

  /// Saying a floor.
  speaking,

  /// Paused by the user or by the system; resumes from the part it stopped in.
  paused,

  /// Waiting for the page after the loaded floors.
  waitingPage,
}

/// Reads the floors of a thread one after the other, loading the next page when the loaded floors are over.
///
/// It reads what [updateFloors] was told last: floors by their post id, in the order given. A floor is left out when
/// [skip] says so (a copy of a floor as a hot reply, a blocked author's floor).
class ThreadTtsController extends ChangeNotifier {
  /// Constructor.
  ThreadTtsController({
    required this.engine,
    required this.speechOf,
    required this.languageTag,
    required this.requestNextPage,
    this.skip = _skipNothing,
    this.onFailed,
  }) {
    _interruptions = engine.interruptions.listen((_) => unawaited(pause()));
  }

  /// What says the words.
  final TtsEngine engine;

  /// What is said for a floor.
  final FloorSpeech Function(Post post) speechOf;

  /// Voice asked for.
  final String languageTag;

  /// Asks for the page after the last loaded floor.
  final VoidCallback requestNextPage;

  /// Floors not read.
  final bool Function(Post post) skip;

  /// Called when the engine fails.
  final VoidCallback? onFailed;

  static bool _skipNothing(Post _) => false;

  late final StreamSubscription<void> _interruptions;

  List<Post> _floors = const [];
  bool _canLoadMore = false;
  bool _nextFailed = false;
  TtsStatus _status = TtsStatus.idle;
  String? _pid;
  int _part = 0;
  double _rate = 1;
  int _token = 0;
  int? _requestedAt;
  FloorSpeech? _speech;
  bool _pausedWaiting = false;
  bool _disposed = false;

  /// What the reader is doing.
  TtsStatus get status => _status;

  /// Whether a floor is being read, paused or waited for.
  bool get active => _status != TtsStatus.idle;

  /// The post id of the floor being read.
  String? get currentPid => _pid;

  /// The speed, 1.0 being the normal one.
  double get rate => _rate;

  /// Tells the floors loaded now. [canLoadMore]: the thread goes on after the last of them. [nextFailed]: the page
  /// after them could not be loaded.
  void updateFloors(List<Post> floors, {required bool canLoadMore, bool nextFailed = false}) {
    _floors = floors;
    _canLoadMore = canLoadMore;
    _nextFailed = nextFailed;
    if (!active) {
      return;
    }
    final pid = _pid;
    if (pid != null && _indexOf(pid) < 0) {
      // The floor being read left the floors (the thread was loaded anew).
      unawaited(stop());
      return;
    }
    if (_status == TtsStatus.waitingPage) {
      final next = _playableAfter(pid);
      if (next != null) {
        _begin(next.postID);
      } else {
        // Nothing to read in what arrived (every floor skipped): the page after it, or the end.
        _waitForPage();
      }
    }
  }

  /// Starts reading at the floor with [pid], or the first one after it that is read.
  Future<void> start(String pid) async {
    final from = _indexOf(pid);
    if (from < 0) {
      return;
    }
    final first = _floors.skip(from).where((e) => !skip(e)).firstOrNull;
    if (first == null) {
      return;
    }
    final token = ++_token;
    await engine.stop();
    await engine.prepare(languageTag: languageTag);
    await engine.setRate(_rate);
    if (token != _token || _disposed) {
      return;
    }
    _begin(first.postID);
  }

  /// Pauses; [resume] goes on from the part that was being said.
  Future<void> pause() async {
    if (_status == TtsStatus.waitingPage) {
      // Nothing is being said: the floor after the loaded ones is read when the reader is resumed.
      _token++;
      _pausedWaiting = true;
      _status = TtsStatus.paused;
      _notify();
      return;
    }
    if (_status != TtsStatus.speaking) {
      return;
    }
    _token++;
    _status = TtsStatus.paused;
    _notify();
    await engine.stop();
  }

  /// Goes on after [pause].
  void resume() {
    if (_status != TtsStatus.paused) {
      return;
    }
    final pid = _pid;
    if (pid == null) {
      return;
    }
    if (_pausedWaiting) {
      _pausedWaiting = false;
      final target = _playableAfter(pid);
      if (target != null) {
        _begin(target.postID);
      } else {
        _waitForPage();
      }
      return;
    }
    _status = TtsStatus.speaking;
    _notify();
    unawaited(_play());
  }

  /// Reads the floor after the one being read.
  Future<void> next() async {
    final pid = _pid;
    if (!active || pid == null) {
      return;
    }
    final token = ++_token;
    await engine.stop();
    if (token != _token || _disposed) {
      // Closed, paused or moved on meanwhile.
      return;
    }
    final target = _playableAfter(pid);
    if (target != null) {
      _begin(target.postID);
    } else {
      _waitForPage();
    }
  }

  /// Reads the floor before the one being read.
  Future<void> previous() async {
    final pid = _pid;
    if (!active || pid == null) {
      return;
    }
    final token = ++_token;
    await engine.stop();
    if (token != _token || _disposed) {
      return;
    }
    final index = _indexOf(pid);
    Post? target;
    for (var i = (index < 0 ? _floors.length : index) - 1; i >= 0; i--) {
      if (!skip(_floors[i])) {
        target = _floors[i];
        break;
      }
    }
    // The first floor is read again from its start.
    _begin((target ?? _floors.elementAtOrNull(index))?.postID ?? pid);
  }

  /// Changes the speed, from [ttsMinRate] to [ttsMaxRate]; the part being said starts over at the new one.
  Future<void> setRate(double value) async {
    final rate = value.clamp(ttsMinRate, ttsMaxRate);
    if (rate == _rate) {
      return;
    }
    _rate = rate;
    _notify();
    await engine.setRate(rate);
    if (_status == TtsStatus.speaking) {
      final token = ++_token;
      await engine.stop();
      if (token != _token || _disposed || _status != TtsStatus.speaking) {
        return;
      }
      unawaited(_play());
    }
  }

  /// Stops reading.
  Future<void> stop() async {
    _token++;
    final wasActive = active;
    _status = TtsStatus.idle;
    _pid = null;
    _part = 0;
    _speech = null;
    _requestedAt = null;
    _pausedWaiting = false;
    _notify();
    if (wasActive) {
      await engine.stop();
      await engine.release();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    unawaited(_interruptions.cancel());
    unawaited(engine.dispose());
    super.dispose();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  int _indexOf(String pid) => _floors.indexWhere((e) => e.postID == pid);

  Post? _playableAfter(String? pid) {
    final index = pid == null ? -1 : _indexOf(pid);
    for (var i = index + 1; i < _floors.length; i++) {
      if (!skip(_floors[i])) {
        return _floors[i];
      }
    }
    return null;
  }

  void _begin(String pid) {
    final post = _floors.where((e) => e.postID == pid).firstOrNull;
    if (post == null) {
      unawaited(stop());
      return;
    }
    _pid = pid;
    _part = 0;
    _speech = speechOf(post);
    _status = TtsStatus.speaking;
    _requestedAt = null;
    _pausedWaiting = false;
    _notify();
    unawaited(_play());
  }

  void _waitForPage() {
    if (!_canLoadMore || _nextFailed) {
      if (_nextFailed) {
        onFailed?.call();
      }
      unawaited(stop());
      return;
    }
    _status = TtsStatus.waitingPage;
    _notify();
    if (_requestedAt != _floors.length) {
      _requestedAt = _floors.length;
      requestNextPage();
    }
  }

  Future<void> _play() async {
    final token = ++_token;
    final speech = _speech;
    if (speech == null) {
      return;
    }
    while (token == _token && _part < speech.utterances.length) {
      final outcome = await engine.speak(speech.utterances[_part]);
      if (token != _token) {
        return;
      }
      switch (outcome) {
        case TtsOutcome.completed:
          _part++;
        case TtsOutcome.cancelled:
          return;
        case TtsOutcome.failed:
          onFailed?.call();
          unawaited(stop());
          return;
      }
    }
    if (token != _token) {
      return;
    }
    final target = _playableAfter(_pid);
    if (target != null) {
      _begin(target.postID);
    } else {
      _waitForPage();
    }
  }
}
