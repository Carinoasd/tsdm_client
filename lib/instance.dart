import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/cmd.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/redacting_talker.dart';

/// Global service locator instance.
final GetIt getIt = GetIt.instance;

/// Global logger instance.
late final Talker talker;

/// The log file instance.
///
/// This is a global instance because we have to reinit the log sink
/// after deleting logs.
late File _logFile;

/// The sink of log file.
///
/// This is a global instance because we have to release the file first
/// when deleting logs.
late IOSink _logSink;

/// Flag indicating [_logSink] is in closed state or not.
bool _logSinkClosed = false;

/// Global cmdline args.
///
/// Only used in desktop platforms.
///
/// Init in [parseCmdArgs]
late final CmdArgs cmdArgs;

/// Global instance.
late final FlutterLocalNotificationsPlugin flnp;

/// The global snackbar key.
///
/// Because we have global BlocListeners outside of `MaterialApp` that calls `showSnackBar`, use this global key to
/// access a context with `Scaffold` to show the snack bar.
///
/// Do NOT use this global key directly, call `showSnackBar` function instead.
final GlobalKey<ScaffoldMessengerState> snackbarKey = GlobalKey<ScaffoldMessengerState>();

/// Lines logged while [flushLogSink] waits: an [IOSink] takes no write until its flush is done.
List<String>? _linesDuringFlush;

/// The running [flushLogSink], joined by a second call.
Future<void>? _flushing;

/// Write a log line ([formatLogLine], already redacted) to the log file, unless the file is closed.
void _writeLogLine(String line) {
  if (_logSinkClosed) {
    return;
  }
  final held = _linesDuringFlush;
  if (held != null) {
    held.add(line);
    return;
  }
  _logSink.write(line);
}

/// Write everything logged so far to the log file, so that reading the file (the diagnostics export) sees the last
/// lines too, the error that made the user export them among them. Lines logged meanwhile are written after it.
Future<void> flushLogSink() async {
  if (_logSinkClosed) {
    return;
  }
  if (_flushing != null) {
    return _flushing;
  }
  final held = _linesDuringFlush = <String>[];
  final sink = _logSink;
  final done = Completer<void>();
  _flushing = done.future;
  Future<void> run() async {
    try {
      await sink.flush();
    } on Object catch (e) {
      // Not worth more than a line on the console: the export reads what reached the file.
      debugPrint('log sink flush failed: $e');
    } finally {
      _linesDuringFlush = null;
      if (identical(_flushing, done.future)) {
        _flushing = null;
      }
      // Waiters go first: a sink that broke must not keep an export waiting for ever.
      done.complete();
      if (!_logSinkClosed) {
        try {
          held.forEach(_logSink.write);
        } on Object catch (e) {
          debugPrint('log sink write after flush failed: $e');
        }
      }
    }
  }

  unawaited(run());
  return done.future;
}

/// Init talker logger.
///
/// This function MUST be called as early as possible.
Future<void> initLogger() async {
  final nowTime = DateTime.now();
  final sep = Platform.pathSeparator;
  final logDir = await getLogDir();

  final hadLogs = logDir.existsSync();
  if (!hadLogs) {
    await logDir.create();
  }

  final logFileTime = '${nowTime.year}${"${nowTime.month}".padLeft(2, "0")}${"${nowTime.day}".padLeft(2, "0")}';
  _logFile = File('${logDir.path}${sep}tsdm_client_$logFileTime.log');
  _logSink = _logFile.openWrite(mode: FileMode.append);

  // Secrets (cookies, passwords, form hashes, private form contents) are redacted before a log entry exists, see
  // [RedactingTalker]; the console output mirrors TalkerFlutter.init on Android.
  talker = buildRedactingTalker(console: (message) => debugPrint(message), writeLine: _writeLogLine);

  if (hadLogs) {
    // Not waited for: the start of the app does not depend on it.
    unawaited(deleteOldLogs(logDir, nowTime));
  }
}

/// Delete the logs of [logDir] last written more than 7 days before [now].
///
/// Listed and deleted without blocking the isolate (the first frame is being built meanwhile). Best effort: what
/// could not be deleted is tried again at the next start.
@visibleForTesting
Future<void> deleteOldLogs(Directory logDir, DateTime now) async {
  try {
    await for (final entity in logDir.list(followLinks: false)) {
      try {
        if (now.difference((await entity.stat()).modified).inDays.abs() > 7) {
          await entity.delete();
        }
      } on FileSystemException catch (e) {
        talker.warning('could not delete the old log ${entity.uri.pathSegments.last}: ${e.message}');
      }
    }
  } on FileSystemException catch (e) {
    talker.warning('could not list the logs: ${e.message}');
  }
}

/// Close the log sink.
///
/// Remember to call [openLogSink] otherwise logs are not saved.
Future<void> closeLogSink() async {
  _logSinkClosed = true;
  // A sink takes one flush at a time.
  await _flushing;
  await _logSink.flush();
  await _logSink.close();
}

/// Close the log sink.
Future<void> openLogSink() async {
  _logSink = _logFile.openWrite(mode: FileMode.append);
  _logSinkClosed = false;
}
