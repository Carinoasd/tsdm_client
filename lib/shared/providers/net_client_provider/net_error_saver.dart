import 'package:tsdm_client/exceptions/exceptions.dart';

/// Global instance class for saving network inner errors for
/// later error handling.
///
/// MUST only used by error handler in http client (for save) and ui shows
/// network error (for load).
class NetErrorSaver {
  ///  Reserved error;
  String? _error;

  /// The failure of the request that failed last, as the callers get it ([AppException]).
  AppException? _failure;

  /// Clear current saved error;
  void clear() {
    _error = null;
    _failure = null;
  }

  /// Get error
  String? error() => _error;

  /// The failure of the request that failed last, null when the last request succeeded.
  ///
  /// A page that did not keep the failure of its own request tells this one instead (`LoadFailure.lastRequest`).
  AppException? failure() => _failure;

  /// Save error, and the [failure] it was.
  void save(String? error, {AppException? failure}) {
    _error = error;
    _failure = failure;
  }
}
