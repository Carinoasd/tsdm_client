import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/cmd.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
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

class _TalkerObserver implements TalkerObserver {
  _TalkerObserver();

  /// Init the file to save log, this function MUST be called as early as possible.
  Future<void> initLogFile() async {}

  /// Entries are already redacted by [RedactingTalker]; redact the generated text once more so the file never carries
  /// a secret even if an entry was built outside the talker methods.
  void _write(TalkerData data) {
    if (_logSinkClosed) {
      return;
    }
    _logSink.write('${redactSensitive(data.generateTextMessage())}\n');
  }

  @override
  void onError(TalkerError err) => _write(err);

  @override
  void onException(TalkerException err) => _write(err);

  @override
  void onLog(TalkerData log) => _write(log);
}

/// Init talker logger.
///
/// This function MUST be called as early as possible.
Future<void> initLogger() async {
  final nowTime = DateTime.now();
  final sep = Platform.pathSeparator;
  final logDir = await getLogDir();

  // Delete logs from 7 days ago.
  if (logDir.existsSync()) {
    for (final logFileCache in logDir.listSync(followLinks: false)) {
      if (logFileCache.existsSync() && nowTime.difference(logFileCache.statSync().modified).inDays.abs() > 7) {
        await logFileCache.delete();
      }
    }
  } else {
    await logDir.create();
  }

  final logFileTime = '${nowTime.year}${"${nowTime.month}".padLeft(2, "0")}${"${nowTime.day}".padLeft(2, "0")}';
  _logFile = File('${logDir.path}${sep}tsdm_client_$logFileTime.log');
  _logSink = _logFile.openWrite(mode: FileMode.append);

  // Secrets (cookies, passwords, form hashes, private form contents) are redacted before a log entry exists, see
  // [RedactingTalker]; the console output mirrors TalkerFlutter.init on Android.
  talker = RedactingTalker(
    logger: TalkerLogger(output: (message) => debugPrint(message)),
    settings: TalkerSettings(colors: {TalkerKey.debug: AnsiPen()..xterm(60)}),
    observer: _TalkerObserver(),
  );
}

/// Close the log sink.
///
/// Remember to call [openLogSink] otherwise logs are not saved.
Future<void> closeLogSink() async {
  _logSinkClosed = true;
  await _logSink.flush();
  await _logSink.close();
}

/// Close the log sink.
Future<void> openLogSink() async {
  _logSink = _logFile.openWrite(mode: FileMode.append);
  _logSinkClosed = false;
}
