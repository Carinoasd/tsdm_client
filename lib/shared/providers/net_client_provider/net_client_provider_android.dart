import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart';
import 'package:http/http.dart' as http;
import 'package:tsdm_client/instance.dart';

/// Internal Dio metadata; never transmitted in an HTTP header or form body.
const singleAttemptHttpRequestKey = 'tsdm_single_attempt';

/// The host of a request was not reached at all: no network, the name not resolved, the connection refused or timed out
/// while connecting (`KT_HTTP_UNREACHABLE` of the Android channel, see `HttpClient.errorCode` in `HttpClient.kt`).
///
/// Its own type, not a [SocketException]: a socket failing after the connection was made (reset, closed while
/// reading) means the forum was reached, and must not count as no network.
final class HostUnreachableException implements IOException {
  /// Constructor.
  const HostUnreachableException(this.message);

  /// What the platform said.
  final String message;

  @override
  String toString() => 'HostUnreachableException: $message';
}

/// The method channel for [KotlinHttpClient].
abstract class _AndroidHttpMethodChannel {
  static const _httpChannel = MethodChannel('kzs.th000.tsdm_client/httpChannel');

  /// Error code of a request whose host was not reached at all (no network, name not resolved, connection refused or timed
  /// out while connecting), see `HttpClient.errorCode` in `HttpClient.kt`.
  static const _unreachable = 'KT_HTTP_UNREACHABLE';

  /// [e] as the failure the caller sees: [HostUnreachableException] when the host was not reached at all
  /// ([_unreachable]), so a post that never left is told apart from one that may have reached the forum (a reply
  /// failed after the connect may be stored); null for every other failure, a failed request without status.
  static HostUnreachableException? _unreachableOf(PlatformException e) =>
      e.code == _unreachable ? HostUnreachableException('${e.details ?? e.message ?? 'host unreachable'}') : null;

  static const _methodGet = 'get';
  static const _methodPost = 'postForm';
  static const _methodPostMultipart = 'postMultipart';
  static const _methodPostJson = 'postJson';

  /// Called from Kotlin while a GET that carried a `progressId` downloads: `id`, `received` and `total` (-1 when the
  /// server did not tell the size).
  static const _methodProgress = 'progress';

  /// Who is told the progress of the GETs downloading now, by the id sent with them.
  static final _progressListeners = <int, ProgressCallback>{};

  static int _nextProgressId = 0;

  static bool _progressHandlerSet = false;

  /// Take the progress Kotlin reports ([_methodProgress]) from now on.
  static void _ensureProgressHandler() {
    if (_progressHandlerSet) {
      return;
    }
    _progressHandlerSet = true;
    _httpChannel.setMethodCallHandler((call) async => _handleProgressCall(call));
  }

  /// Hand a progress report of Kotlin ([call]) to the listener of its request; a report of a request already done is
  /// dropped.
  static void _handleProgressCall(MethodCall call) {
    if (call.method != _methodProgress || call.arguments is! Map<Object?, Object?>) {
      return;
    }
    final args = call.arguments as Map<Object?, Object?>;
    final id = args['id'];
    final received = args['received'];
    final total = args['total'];
    if (id is! int || received is! int) {
      return;
    }
    _progressListeners[id]?.call(received, total is int ? total : -1);
  }

  /// Make a GET request.
  ///
  /// [onProgress] is told how much of the body arrived while it downloads (an image showing its progress); Kotlin then
  /// reads the body in pieces.
  static Future<_KotlinHttpResponse?> _get({
    required String url,
    required Map<String, String> headers,
    bool singleAttempt = false,
    ProgressCallback? onProgress,
  }) async {
    int? progressId;
    if (onProgress != null) {
      _ensureProgressHandler();
      progressId = _nextProgressId++;
      _progressListeners[progressId] = onProgress;
    }
    try {
      final resp = await _httpChannel.invokeMethod<Map<Object?, Object?>>(_methodGet, {
        'url': url,
        'headers': headers,
        'singleAttempt': singleAttempt,
        'progressId': ?progressId,
      });
      if (resp == null) {
        return null;
      }
      return _KotlinHttpResponse._fromRawResp(resp);
    } on PlatformException catch (e, st) {
      talker.handle(e, st, '[KtHttp] GET failed on $url');
      if (_unreachableOf(e) case final unreachable?) {
        // Its own exception, as dio's connection error and connection timeout are on the other platforms, so a thread
        // page can be read from its offline copy (see mapException); still a failed request without status for every
        // other caller.
        throw unreachable;
      }
      return null;
    } finally {
      if (progressId != null) {
        _progressListeners.remove(progressId);
      }
    }
  }

  /// Post form data.
  static Future<_KotlinHttpResponse?> _postForm({
    required String url,
    required Map<String, String> headers,
    required Map<String, String> body,
    bool singleAttempt = false,
  }) async {
    try {
      final resp = await _httpChannel.invokeMethod<Map<Object?, Object?>>(_methodPost, {
        'url': url,
        'headers': headers,
        'body': body,
        'singleAttempt': singleAttempt,
      });
      if (resp == null) {
        return null;
      }
      return _KotlinHttpResponse._fromRawResp(resp);
    } on PlatformException catch (e, st) {
      talker.handle(e, st, '[KtHttp] POST form failed on $url');
      if (_unreachableOf(e) case final unreachable?) {
        throw unreachable;
      }
      return null;
    }
  }

  /// Post multipart data.
  static Future<_KotlinHttpResponse?> _postMultipart({
    required String url,
    required Map<String, String> headers,
    required Map<String, String> body,
  }) async {
    try {
      final resp = await _httpChannel.invokeMethod<Map<Object?, Object?>>(_methodPostMultipart, {
        'url': url,
        'headers': headers,
        'body': body,
      });
      if (resp == null) {
        return null;
      }
      return _KotlinHttpResponse._fromRawResp(resp);
    } on PlatformException catch (e, st) {
      talker.handle(e, st, '[KtHttp] POST multipart failed on $url');
      if (_unreachableOf(e) case final unreachable?) {
        throw unreachable;
      }
      return null;
    }
  }

  /// Post a raw JSON body.
  static Future<_KotlinHttpResponse?> _postJson({
    required String url,
    required Map<String, String> headers,
    required String body,
    required bool singleAttempt,
  }) async {
    try {
      final resp = await _httpChannel.invokeMethod<Map<Object?, Object?>>(_methodPostJson, {
        'url': url,
        'headers': headers,
        'body': body,
        'singleAttempt': singleAttempt,
      });
      if (resp == null) {
        return null;
      }
      return _KotlinHttpResponse._fromRawResp(resp);
    } on PlatformException catch (e, st) {
      talker.handle(e, st, '[KtHttp] POST json failed on $url');
      if (_unreachableOf(e) case final unreachable?) {
        throw unreachable;
      }
      return null;
    }
  }
}

/// The http response.
///
/// Note that the response is not derived from `Response` or `BaseResponse` from `dart:http` package,
/// because we want to keep the header with multiple values as `Map<String, List<String>>` instead of
/// `Map<String, String>`.
final class _KotlinHttpResponse {
  const _KotlinHttpResponse._({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.isRedirect,
  });

  factory _KotlinHttpResponse._fromRawResp(Map<Object?, Object?> resp) => _KotlinHttpResponse._(
    statusCode: resp['statusCode']! as int,
    // headers: Map.castFrom(resp['headers']! as Map<Object?, Object?>),
    headers: _collectHeaders(resp['headers']! as Map<Object?, Object?>),
    body: resp['body']! as Uint8List,
    isRedirect: resp['isRedirect']! as bool,
  );

  final int statusCode;
  final Map<String, List<String>> headers;
  final Uint8List body;
  final bool isRedirect;

  static Map<String, List<String>> _collectHeaders(Map<Object?, Object?> headers) {
    final ret = <String, List<String>>{};
    for (final entry in headers.entries) {
      ret[entry.key! as String] = (entry.value! as List<Object?>).whereType<String>().toList();
    }

    return ret;
  }
}

/// The Http client implemented with Kotlin and OkHttp.
///
/// This http client is only available on Android platform, to solve the following issues:
///
/// 1. `dart:http` can not perform requests when app goes to background. It has been reported to the GitHub issue
///   tracker but no fix or workaround available.
/// 2. `dart:http` is slow on Android, compared to Kotlin ones and `cronet_http` package.
/// 3. The `cronet_http` package is not configurable and has issue on proxy detection.
///
/// Use kotlin native http client to overcome these issues.
///
/// Note that this class is not derived form `dart:http:BaseClient`, unlike `cronet_http`, because we want to keep
/// multiple header structure as `Map<String, List<String>>` instead of `Map<String, String>`.
final class KotlinHttpClient {
  /// Constructor; [android] overrides the platform check (tests driving the method channel).
  KotlinHttpClient({@visibleForTesting bool? android}) : _android = android ?? Platform.isAndroid;

  final bool _android;

  Future<_KotlinHttpResponse> _get(
    Uri url, {
    Map<String, String>? headers,
    bool singleAttempt = false,
    ProgressCallback? onProgress,
  }) async {
    if (!_android) {
      throw http.ClientException('Only available on Android');
    }
    final rawResp = await _AndroidHttpMethodChannel._get(
      url: url.toString(),
      headers: headers ?? {},
      singleAttempt: singleAttempt,
      onProgress: onProgress,
    );
    if (rawResp == null) {
      throw http.ClientException('null raw response');
    }
    return rawResp;
  }

  Future<_KotlinHttpResponse> _post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    bool singleAttempt = false,
  }) async {
    if (!_android) {
      throw http.ClientException('Only available on Android');
    }

    if (body == null) {
      throw http.ClientException('post body is null');
    }

    final contentType = headers?[HttpHeaders.contentTypeHeader]?.split(';').firstOrNull ?? '';
    if (singleAttempt && contentType != 'application/x-www-form-urlencoded' && contentType != 'application/json') {
      throw UnsupportedError('Single-attempt requests require a URL-encoded form or a JSON body');
    }

    final rawResp = switch (contentType) {
      'application/x-www-form-urlencoded' => await _AndroidHttpMethodChannel._postForm(
        url: url.toString(),
        headers: headers ?? {},
        body: body as Map<String, String>,
        singleAttempt: singleAttempt,
      ),
      'multipart/form-data' => await _AndroidHttpMethodChannel._postMultipart(
        url: url.toString(),
        headers: headers ?? {},
        body: body as Map<String, String>,
      ),
      'application/json' => await _AndroidHttpMethodChannel._postJson(
        url: url.toString(),
        headers: headers ?? {},
        body: body as String,
        singleAttempt: singleAttempt,
      ),
      final v => throw UnsupportedError('unsupported content type: $v'),
    };
    if (rawResp == null) {
      throw http.ClientException('null raw response');
    }
    return rawResp;
  }
}

/// The adaptor for [KotlinHttpClient] to run together with `dio`.
class KotlinHttpClientAdapter implements HttpClientAdapter {
  /// Constructor.
  const KotlinHttpClientAdapter(this._client);

  final KotlinHttpClient _client;

  @override
  void close({bool force = false}) {
    // Do nothing.
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Remove accept encoding header to let kotlin side handle it.
    final resp = await switch (options.method) {
      'GET' => _client._get(
        options.uri,
        headers: Map.from(options.headers.filter((v) => v is String))
          ..removeWhere((k, v) => k.toLowerCase() == HttpHeaders.acceptEncodingHeader),
        singleAttempt: options.extra[singleAttemptHttpRequestKey] == true,
        // The body arrives here at once, dio would only tell its progress at the end: Kotlin tells it while it loads.
        onProgress: options.onReceiveProgress,
      ),
      'POST' => _client._post(
        options.uri,
        headers: Map.from(options.headers.filter((v) => v is String))
          ..removeWhere((k, v) => k.toLowerCase() == HttpHeaders.acceptEncodingHeader),
        body: options.data,
        singleAttempt: options.extra[singleAttemptHttpRequestKey] == true,
      ),
      final v => throw UnsupportedError('unsupported http method $v'),
    };

    return ResponseBody.fromBytes(
      resp.body,
      resp.statusCode,
      isRedirect: resp.isRedirect,
      headers: Map.castFrom(resp.headers),
    );
  }
}
