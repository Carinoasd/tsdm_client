import 'package:talker/talker.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// A [Talker] that redacts secrets before a log entry exists.
///
/// Every message, and the text of every handled exception, goes through [redactSensitive]; so the in-app log viewer,
/// the log files and the exported logs only ever see the redacted form.
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
  void log(dynamic message, {LogLevel logLevel = LogLevel.debug, Object? exception, StackTrace? stackTrace, AnsiPen? pen}) =>
      super.log(
        _clean(message),
        logLevel: logLevel,
        exception: exception == null ? null : _cleanException(exception),
        stackTrace: stackTrace,
        pen: pen,
      );

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
