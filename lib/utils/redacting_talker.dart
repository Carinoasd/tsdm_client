import 'package:talker/talker.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// A [Talker] that redacts secrets before a log entry exists.
///
/// Every message, and the text of every handled exception, goes through [redactSensitive]; so the in-app log viewer,
/// the console, the log files and the exported logs only ever see the redacted form. A log made outside the methods
/// taking a message ([logCustom]) is redacted as it is turned into text.
class RedactingTalker extends Talker {
  /// Constructor, same parameters as [Talker].
  RedactingTalker({super.logger, super.observer, super.settings, super.filter, super.errorHandler, super.history});

  static dynamic _clean(dynamic message) => message == null ? null : redactSensitive('$message');

  /// Keep the exception type when its text carries a secret, replace the text.
  static Object _cleanException(Object exception) {
    final text = '$exception';
    final redacted = redactSensitive(text);
    if (redacted == text) {
      return exception;
    }
    return RedactedException(exception.runtimeType.toString(), redacted);
  }

  @override
  void log(
    dynamic message, {
    LogLevel logLevel = LogLevel.debug,
    Object? exception,
    StackTrace? stackTrace,
    AnsiPen? pen,
  }) => super.log(
    _clean(message),
    logLevel: logLevel,
    exception: exception == null ? null : _cleanException(exception),
    stackTrace: stackTrace,
    pen: pen,
  );

  @override
  void logCustom(TalkerLog log) => super.logCustom(_RedactedLog(log));

  @override
  void critical(dynamic msg, [Object? exception, StackTrace? stackTrace]) =>
      super.critical(_clean(msg), exception == null ? null : _cleanException(exception), stackTrace);

  @override
  void debug(dynamic msg, [Object? exception, StackTrace? stackTrace]) =>
      super.debug(_clean(msg), exception == null ? null : _cleanException(exception), stackTrace);

  @override
  void error(dynamic msg, [Object? exception, StackTrace? stackTrace]) =>
      super.error(_clean(msg), exception == null ? null : _cleanException(exception), stackTrace);

  @override
  void info(dynamic msg, [Object? exception, StackTrace? stackTrace]) =>
      super.info(_clean(msg), exception == null ? null : _cleanException(exception), stackTrace);

  @override
  void verbose(dynamic msg, [Object? exception, StackTrace? stackTrace]) =>
      super.verbose(_clean(msg), exception == null ? null : _cleanException(exception), stackTrace);

  @override
  void warning(dynamic msg, [Object? exception, StackTrace? stackTrace]) =>
      super.warning(_clean(msg), exception == null ? null : _cleanException(exception), stackTrace);

  @override
  void handle(Object exception, [StackTrace? stackTrace, dynamic msg]) =>
      super.handle(_cleanException(exception), stackTrace, _clean(msg));
}

/// A log made with [Talker.logCustom], its message and exception redacted; its text (which a subclass of [TalkerLog]
/// may build from fields of its own) redacted as well.
final class _RedactedLog extends TalkerLog {
  _RedactedLog(this._inner)
    : super(
        _inner.message == null ? null : redactSensitive(_inner.message!),
        key: _inner.key,
        title: _inner.title,
        exception: _inner.exception == null ? null : RedactingTalker._cleanException(_inner.exception!),
        error: _inner.error,
        stackTrace: _inner.stackTrace,
        time: _inner.time,
        pen: _inner.pen,
        logLevel: _inner.logLevel,
      );

  final TalkerLog _inner;

  @override
  String generateTextMessage({TimeFormat timeFormat = TimeFormat.timeAndSeconds}) {
    _inner
      ..title = title
      ..pen = pen;
    return redactSensitive(_inner.generateTextMessage(timeFormat: timeFormat));
  }
}

/// The line written to a log file for [data]: its text, redacted once more so a file never carries a secret even if
/// an entry was built outside the talker methods. The format of the app's log file and of the background isolates'
/// (`tsdm_client_bg_<day>.log`).
String formatLogLine(TalkerData data) => '${redactSensitive(data.generateTextMessage())}\n';

/// Writes every log entry of a [Talker] as a line ([formatLogLine]) to [write]: the log file of the app, of a
/// background isolate.
final class RedactingLogObserver implements TalkerObserver {
  /// Constructor.
  const RedactingLogObserver(this.write);

  /// Takes each line.
  final void Function(String line) write;

  @override
  void onError(TalkerError err) => write(formatLogLine(err));

  @override
  void onException(TalkerException err) => write(formatLogLine(err));

  @override
  void onLog(TalkerData log) => write(formatLogLine(log));
}

/// The logger of the app and of its background isolates: a [RedactingTalker] whose console output goes to [console]
/// and whose entries go as lines to [writeLine] ([RedactingLogObserver]).
RedactingTalker buildRedactingTalker({
  required void Function(String message) console,
  required void Function(String line) writeLine,
}) => RedactingTalker(
  logger: TalkerLogger(output: console),
  settings: TalkerSettings(colors: {TalkerKey.debug: AnsiPen()..xterm(60)}),
  observer: RedactingLogObserver(writeLine),
);

/// Stands in for an exception whose text contained a secret.
final class RedactedException implements Exception {
  /// Constructor.
  const RedactedException(this.originalType, this.text);

  /// Runtime type name of the original exception.
  final String originalType;

  /// Redacted text of the original exception.
  final String text;

  @override
  String toString() => text.startsWith(originalType) ? text : '$originalType: $text';
}
