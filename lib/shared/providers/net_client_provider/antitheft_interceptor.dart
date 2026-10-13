import 'package:dio/dio.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/antitheft/antitheft_decoder.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Interceptor that solves the Discuz! antitheft (防采集) challenge.
///
/// When the server returns a challenge page instead of the real content, decode the
/// `_dsign` value from it, remember the sign for the thread and resend GET/HEAD
/// requests with `_dsign` attached. Mutating requests are never replayed.
///
/// Signs are cached in memory: once we know the sign of a thread, later requests to
/// the same thread carry `_dsign` directly and skip the challenge round trip.
///
/// A thread page asked in the JSON mode of the forum's app API ([tsdmAppJsonQuery]) cannot carry the challenge, see
/// [hidesChallenge]: that page is asked again as the web page, where the challenge is solved as above.
///
/// See [AntitheftDecoder] for details on the challenge.
final class AntitheftInterceptor extends Interceptor with LoggerMixin {
  /// Constructor.
  ///
  /// The dio instance is used to resend the request.
  AntitheftInterceptor(this._dio);

  final Dio _dio;

  /// Key in request extra recording how many times the request has been resent, avoid resolving challenge endlessly.
  ///
  /// A resent request may be challenged again when the thread redirects to another thread (e.g. merged threads).
  static const _retryCountKey = 'tsdm_antitheft_retry';

  /// Maximum times to resend a request.
  static const _maxRetry = 3;

  /// Cache of `tid` -> `_dsign`.
  ///
  /// Shared across all client instances because the sign only depends on the thread.
  static final Map<String, String> _signCache = {};

  static bool _isForumHost(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == baseHost || host == baseHostAlt;
  }

  /// Whether the challenge may redirect us to [target]: https, on a forum host.
  ///
  /// The redirect url is taken from a script in the server's answer; a tampered page must not be able to make the
  /// client resend the request (with its cookies) somewhere else or over plain http.
  static bool isAllowedRedirect(Uri target) => target.scheme == 'https' && _isForumHost(target);

  /// Look up the cached sign for [uri] if it's a thread page.
  static String? cachedSignOf(Uri uri) {
    final query = uri.queryParameters;
    if (query['mod'] != 'viewthread') {
      return null;
    }
    final tid = query['tid'];
    if (tid == null) {
      return null;
    }
    return _signCache[tid];
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final uri = options.uri;
    if (_isForumHost(uri) && !uri.queryParameters.containsKey(AntitheftDecoder.dsignKey)) {
      final sign = cachedSignOf(uri);
      if (sign != null) {
        options.queryParameters[AntitheftDecoder.dsignKey] = sign;
      }
    }
    handler.next(options);
  }

  /// Whether [data], the answer to [options], is a thread page asked in JSON mode that may hide the challenge.
  ///
  /// The JSON answer of a challenged thread holds neither the thread nor a forum message, and the challenge script is
  /// lost in it ([tsdmAppAnswerWithoutContent]). An answer without a page (the plugin failed to build it, or an empty
  /// body) is asked again as well. An answer holding the posts is never asked again, whatever its `ok`: the thread
  /// cache a guest is served is answered `unknown` with the whole post list, and asking again would read (and count a
  /// view of) the thread twice. Thread pages, and the `findpost` redirect ending on one, are the only JSON mode pages
  /// the forum guards.
  ///
  /// Marked as public for testing.
  static bool hidesChallenge(RequestOptions options, Object? data) {
    final uri = options.uri;
    final query = uri.queryParameters;
    return const {'GET', 'HEAD'}.contains(options.method.toUpperCase()) &&
        _isForumHost(uri) &&
        query['tsdmapp'] == 'json' &&
        uri.pathSegments.lastOrNull == 'forum.php' &&
        (query['mod'] == 'viewthread' || query['mod'] == 'redirect') &&
        tsdmAppAnswerWithoutContent(data);
  }

  @override
  Future<void> onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) async {
    final data = response.data;
    final options = response.requestOptions;
    if (hidesChallenge(options, data)) {
      await _askWebPage(response, handler);
      return;
    }
    if (data is! String || !_isForumHost(options.uri) || !AntitheftDecoder.isChallenge(data)) {
      handler.next(response);
      return;
    }
    if (!const {'GET', 'HEAD'}.contains(options.method.toUpperCase())) {
      // A challenge may be the final page after a successful POST redirect. Copying that request would resend its
      // form body, so mutating requests are never replayed. Report an error instead of handing the challenge html to
      // the caller as if it were the result; confirmation is left to the caller's own fresh GET (e.g. PollCubit).
      warning('antitheft: ${options.method} ${options.uri} answered with a challenge, not replayed');
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
          error: AntitheftChallengedRequestException(options.method, options.uri.toString()),
        ),
      );
      return;
    }

    final retryCount = (options.extra[_retryCountKey] as int?) ?? 0;
    if (retryCount >= _maxRetry) {
      error('antitheft: still challenged after $retryCount retries: ${options.uri}');
      handler.next(response);
      return;
    }

    final challenge = AntitheftDecoder.decode(data);
    if (challenge == null) {
      error('antitheft: failed to decode challenge from ${options.uri}');
      handler.next(response);
      return;
    }

    // The redirect url is relative to the server root. Note that when the request was redirected
    // (e.g. `forum.php?mod=redirect&goto=findpost`), `realUri` may be a relative url, so resolve it
    // with the request uri first.
    final target = options.uri.resolveUri(response.realUri).resolve(challenge.redirectUrl);
    if (!isAllowedRedirect(target)) {
      error('antitheft: refuse redirect to ${target.scheme}://${target.host} from ${options.uri}');
      handler.next(response);
      return;
    }
    final tid = target.queryParameters['tid'];
    if (tid != null) {
      _signCache[tid] = challenge.dsign;
    }
    debug('antitheft: solved challenge, tid=$tid, dsign=${challenge.dsign}, retrying ${options.uri}');

    // Query parameters appended by other interceptors (e.g. `mobile=no`) are already in the
    // redirect url, remove them to avoid duplication when the resent request passes through
    // interceptors again.
    final retryQuery = Map.of(target.queryParameters)
      ..remove('mobile')
      ..remove(AntitheftDecoder.dsignKey);
    try {
      final resp = await _dio.fetch<dynamic>(
        options.copyWith(
          path: target.replace(queryParameters: retryQuery).toString(),
          queryParameters: {AntitheftDecoder.dsignKey: challenge.dsign},
          extra: {...options.extra, _retryCountKey: retryCount + 1},
        ),
      );
      handler.resolve(resp);
    } on DioException catch (e) {
      handler.reject(e);
    }
  }

  /// Ask the page of [response] again without the JSON mode (see [hidesChallenge]), once.
  ///
  /// The forum then answers the challenge itself, which is solved here and its sign cached: later JSON mode requests
  /// to the thread carry it and get the thread. Without a challenge (an answer the plugin failed to build, or an empty
  /// body) the web page comes back, which every JSON mode caller parses as well.
  Future<void> _askWebPage(Response<dynamic> response, ResponseInterceptorHandler handler) async {
    final options = response.requestOptions;
    final retryCount = (options.extra[_retryCountKey] as int?) ?? 0;
    if (retryCount >= _maxRetry) {
      handler.next(response);
      return;
    }
    // As for the challenge retry: other interceptors add their parameters again; a sign that did not help is dropped.
    final query = Map.of(options.uri.queryParametersAll)
      ..remove('tsdmapp')
      ..remove('mobile')
      ..remove(AntitheftDecoder.dsignKey);
    debug('antitheft: ${options.uri} answered JSON without the thread, asking the web page');
    try {
      final resp = await _dio.fetch<dynamic>(
        options.copyWith(
          path: options.uri.replace(queryParameters: query).toString(),
          queryParameters: <String, dynamic>{},
          extra: {...options.extra, _retryCountKey: retryCount + 1},
        ),
      );
      handler.resolve(resp);
    } on DioException catch (e) {
      handler.reject(e);
    }
  }
}
