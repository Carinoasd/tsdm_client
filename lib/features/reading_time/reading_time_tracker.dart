import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Receives the time read: [seconds] on the local [day] in forum [fid].
typedef ReadingTimeSink = Future<void> Function(DateTime day, int fid, String forumName, int seconds);

/// Counts how long a thread page is read.
///
/// The time runs while the forum is known, the page is the one on top, the app is in the foreground and the setting
/// [enabled] allows it. Time without an [touch] (a tap, a scroll) counts up to [maxIdle] only: someone who left the
/// phone on the page is not reading. The time is handed to the [sink] every [flushEvery], whenever it stops and split
/// at midnight.
final class ReadingTimeTracker with WidgetsBindingObserver, LoggerMixin {
  /// Constructor.
  ReadingTimeTracker({
    required this.sink,
    required this.enabled,
    DateTime Function()? now,
    this.maxIdle = const Duration(minutes: 30),
    this.flushEvery = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now;

  /// Where the time goes.
  final ReadingTimeSink sink;

  /// Whether the time is counted at all (the setting).
  final bool Function() enabled;

  /// The longest stretch counted after the last [touch].
  final Duration maxIdle;

  /// How often the time read is handed over while it runs.
  final Duration flushEvery;

  final DateTime Function() _now;

  int? _fid;
  String _forumName = '';
  bool _onTop = true;
  bool _foreground = true;
  DateTime? _since;
  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);
  int _carryMillis = 0;
  Timer? _timer;
  bool _attached = false;

  /// Whether the time is running now.
  bool get isRunning => _since != null;

  /// Start following the lifecycle of the app.
  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// The forum the thread read belongs to; the time of the previous one is handed over first.
  void setForum(int? fid, String? forumName) {
    if (fid == _fid && (forumName ?? '') == _forumName) {
      return;
    }
    flush();
    _carryMillis = 0;
    _fid = fid;
    _forumName = forumName ?? '';
    _update();
  }

  /// Whether the page is the one on top.
  void setOnTop({required bool onTop}) {
    _onTop = onTop;
    _update();
  }

  /// The app moved between foreground and background.
  void setForeground({required bool foreground}) {
    _foreground = foreground;
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only a resumed app is read: on desktop a window that lost the focus is `inactive`.
    setForeground(foreground: state == AppLifecycleState.resumed);
  }

  /// The user did something on the page.
  void touch() {
    if (_since == null) {
      return;
    }
    final now = _now();
    if (now.difference(_lastTouch) > maxIdle) {
      // The long pause ends here: what it holds up to the limit is counted, the rest is not.
      flush();
    }
    _lastTouch = now;
  }

  /// Hand over the time run so far.
  void flush() {
    final since = _since;
    if (since == null) {
      return;
    }
    final now = _now();
    _since = now;
    final limit = _lastTouch.add(maxIdle);
    final end = now.isBefore(limit) ? now : limit;
    var cursor = since;
    while (cursor.isBefore(end)) {
      final nextMidnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final segmentEnd = end.isBefore(nextMidnight) ? end : nextMidnight;
      _credit(cursor, segmentEnd.difference(cursor));
      cursor = segmentEnd;
    }
  }

  void _credit(DateTime at, Duration duration) {
    final fid = _fid;
    if (fid == null || !enabled()) {
      return;
    }
    final millis = _carryMillis + duration.inMilliseconds;
    final seconds = millis ~/ 1000;
    _carryMillis = millis % 1000;
    if (seconds > 0) {
      unawaited(
        sink(
          DateTime(at.year, at.month, at.day),
          fid,
          _forumName,
          seconds,
        ).catchError((Object e, StackTrace st) => error('failed to keep the reading time', e, st)),
      );
    }
  }

  void _update() {
    final shouldRun = _fid != null && _onTop && _foreground && enabled();
    if (shouldRun && _since == null) {
      final now = _now();
      _since = now;
      _lastTouch = now;
      _carryMillis = 0;
      _timer = Timer.periodic(flushEvery, (_) {
        flush();
        _update();
      });
    } else if (!shouldRun && _since != null) {
      flush();
      _since = null;
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Hand over the time and stop following.
  void dispose() {
    flush();
    _since = null;
    _timer?.cancel();
    _timer = null;
    if (_attached) {
      WidgetsBinding.instance.removeObserver(this);
      _attached = false;
    }
  }
}
