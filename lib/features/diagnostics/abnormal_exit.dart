/// Whether the last run of the app ended abnormally, asked once at the next start (the home page offers the
/// diagnostics export then).
///
/// Two marks, small files in a folder of the app's own (never synced, never sent anywhere):
///
/// * the *error* mark ([AbnormalExitRecorder.recordError]): an uncaught error of the UI isolate (`FlutterError.onError`,
///   `PlatformDispatcher.onError`, the zone of `main`), one line of its time, the app version and the type of the
///   error. Written once per run, synchronously, never throwing: it is written from inside the error handlers.
/// * the *running* mark ([AbnormalExitRecorder.lifecycleChanged]), on Android and iOS only: present while the app is
///   in the front ([AppLifecycleState.resumed]), deleted as soon as it leaves it. A swipe away, the system reclaiming
///   the app, an update installed: each one sends the app to the back first, the mark is gone. Found at the next start,
///   it means the app vanished while in the front: a crash of the native side, which no Dart handler saw.
///
/// Only the UI isolate arms a recorder ([AbnormalExitRecorder.arm], from `main`); the background isolates (the
/// background message service, the reply typed in a notification) have their own statics and write nothing.
library;

import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

/// What ended the last run.
enum AbnormalExitKind {
  /// An uncaught error of the UI isolate.
  error,

  /// The app vanished while in the front (a native crash).
  vanished,
}

/// The abnormal end of the last run, as the marks tell it.
@immutable
final class AbnormalExit {
  /// Constructor.
  const AbnormalExit({required this.kind, required this.id, this.summary = ''});

  /// What ended it.
  final AbnormalExitKind kind;

  /// Tells one abnormal end from another: the time its mark was written (milliseconds since epoch, as text).
  final String id;

  /// The line of the mark (time, version, type of error); empty when it could not be read.
  final String summary;

  @override
  bool operator ==(Object other) =>
      other is AbnormalExit && other.kind == kind && other.id == id && other.summary == summary;

  @override
  int get hashCode => Object.hash(kind, id, summary);

  @override
  String toString() => 'AbnormalExit(${kind.name}, $id)';
}

/// The last abnormal end the user was asked about: its [AbnormalExit.id] and when.
typedef AbnormalExitAsked = ({String id, DateTime at});

/// How often the user is asked at most.
const abnormalExitAskInterval = Duration(hours: 24);

/// Whether to ask about [previous] now ([now]), the last time being [asked]: once per abnormal end, at most once in
/// [abnormalExitAskInterval]. A clock moved back counts the same way as one moved on: the distance of the two times.
bool shouldAskAboutAbnormalExit({
  required AbnormalExit? previous,
  required AbnormalExitAsked? asked,
  required DateTime now,
}) {
  if (previous == null) {
    return false;
  }
  if (asked == null) {
    return true;
  }
  if (asked.id == previous.id) {
    return false;
  }
  return now.difference(asked.at).abs() >= abnormalExitAskInterval;
}

/// The marks of [AbnormalExit] in [directory].
final class AbnormalExitRecorder {
  /// Constructor.
  ///
  /// [trackForeground]: whether the running mark is kept (Android and iOS; a desktop may end in the front when its
  /// window is closed).
  AbnormalExitRecorder({
    required this.directory,
    required this.appVersion,
    required this.trackForeground,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The folder of the marks.
  final Directory directory;

  /// Version of the app, told by the error mark.
  final String appVersion;

  /// Whether the running mark is kept.
  final bool trackForeground;

  final DateTime Function() _now;

  /// The recorder of the UI isolate, null until [arm]ed (and always in a background isolate): the error handlers
  /// write through it.
  static AbnormalExitRecorder? get armed => _armed;
  static AbnormalExitRecorder? _armed;

  /// The abnormal end of the last run read at [arm], until taken by [takePrompt].
  AbnormalExit? _previous;

  /// Whether the error mark of this run was written (or tried): written once.
  bool _errorRecorded = false;

  /// Whether a mark is being written: an error thrown while writing one does not write again.
  bool _writing = false;

  /// Whether the running mark is there now, as far as this recorder knows.
  bool _running = false;

  /// File of the error mark.
  static const errorFileName = 'error';

  /// File of the running mark.
  static const runningFileName = 'running';

  /// File of the last abnormal end asked about.
  static const askedFileName = 'asked';

  File _file(String name) => File('${directory.path}${Platform.pathSeparator}$name');

  /// Read the marks the last run left ([previous]) and remove them, then make this the recorder of the isolate. Called
  /// once, early in `main`, before anything can fail: the marks of this run are written after the last run's are read.
  void arm({AppLifecycleState? lifecycle}) {
    _previous = _readPrevious();
    _armed = this;
    if (lifecycle != null) {
      lifecycleChanged(lifecycle);
    }
  }

  /// Forget the armed recorder (tests).
  @visibleForTesting
  static void disarm() => _armed = null;

  /// The abnormal end of the last run, read at [arm]; null when it ended normally (or [takePrompt] took it).
  AbnormalExit? get previous => _previous;

  AbnormalExit? _readPrevious() {
    final error = _file(errorFileName);
    final running = _file(runningFileName);
    AbnormalExit? found;
    try {
      if (error.existsSync()) {
        final line = error.readAsStringSync().trim();
        found = AbnormalExit(kind: AbnormalExitKind.error, id: _idOf(line, error), summary: line);
      } else if (running.existsSync()) {
        final line = running.readAsStringSync().trim();
        found = AbnormalExit(kind: AbnormalExitKind.vanished, id: _idOf(line, running), summary: line);
      }
    } on Object catch (_) {
      // A mark that can not be read: not asked about.
      found = null;
    }
    _delete(error);
    _delete(running);
    return found;
  }

  /// The id of a mark: the milliseconds its line starts with, else the time the file was changed.
  String _idOf(String line, File file) {
    final head = line.split('\t').first;
    if (int.tryParse(head) != null) {
      return head;
    }
    try {
      return '${file.lastModifiedSync().millisecondsSinceEpoch}';
    } on Object catch (_) {
      return line;
    }
  }

  void _delete(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object catch (_) {
      // Nothing to do: the mark stays, at worst asked about once.
    }
  }

  /// Write [line] to the mark [name]; false when it could not be written.
  bool _write(String name, String line, {bool flush = false}) {
    if (_writing) {
      return false;
    }
    _writing = true;
    try {
      directory.createSync(recursive: true);
      _file(name).writeAsStringSync(line, flush: flush);
      return true;
    } on Object catch (_) {
      return false;
    } finally {
      _writing = false;
    }
  }

  String _line(String what) {
    final now = _now();
    return '${now.millisecondsSinceEpoch}\t${now.toIso8601String()}\t$appVersion\t$what';
  }

  /// Keep the error mark of this run, for an uncaught [error]: its type only, never its message (which may hold user
  /// content). Once per run; never throws.
  void recordError(Object error) {
    if (_errorRecorded) {
      return;
    }
    _errorRecorded = true;
    try {
      // Flushed: the process may end right after it. The running mark is not (the page cache outlives the process,
      // and it is written at every return to the front).
      _write(errorFileName, _line(error.runtimeType.toString()), flush: true);
    } on Object catch (_) {
      // Never from an error handler.
    }
  }

  /// The app moved to [state]: the running mark is kept in the front only ([trackForeground]).
  void lifecycleChanged(AppLifecycleState state) {
    if (!trackForeground) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_running) {
        _running = _write(runningFileName, _line('running'));
      }
    } else if (_running) {
      _delete(_file(runningFileName));
      _running = false;
    }
  }

  /// The abnormal end of the last run, when the user is to be asked about it now: once per abnormal end, at most once
  /// in [abnormalExitAskInterval]. Taken once: a second call (a home page built again) returns null. A returned one is
  /// counted as asked at once, whether the user acts on it or not.
  AbnormalExit? takePrompt() {
    final previous = _previous;
    _previous = null;
    if (previous == null) {
      return null;
    }
    final now = _now();
    if (!shouldAskAboutAbnormalExit(previous: previous, asked: _readAsked(), now: now)) {
      return null;
    }
    _write(askedFileName, '${previous.id}\t${now.millisecondsSinceEpoch}');
    return previous;
  }

  AbnormalExitAsked? _readAsked() {
    try {
      final file = _file(askedFileName);
      if (!file.existsSync()) {
        return null;
      }
      final parts = file.readAsStringSync().trim().split('\t');
      final at = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (at == null) {
        return null;
      }
      return (id: parts[0], at: DateTime.fromMillisecondsSinceEpoch(at));
    } on Object catch (_) {
      return null;
    }
  }
}

/// Keep the error mark for [error] through the armed recorder, if any (the UI isolate). Never throws.
void recordAbnormalError(Object error) => AbnormalExitRecorder.armed?.recordError(error);
