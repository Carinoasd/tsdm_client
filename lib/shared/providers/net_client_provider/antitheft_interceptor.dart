import 'package:dio/dio.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/utils/antitheft/antitheft_decoder.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Interceptor that solves the Discuz! antitheft (防采集) challenge.
///
/// When the server returns a challenge page instead of the real content, decode the
/// `_dsign` value from it, remember the sign for the thread and resend the request
/// with `_dsign` attached.
///
/// Signs are cached in memory: once we know the sign of a thread, later requests to
/// the same thread carry `_dsign` directly and skip the challenge round trip.
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

  @override
  Future<void> onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) async {
    final data = response.data;
    final options = response.requestOptions;
    if (data is! String || !_isForumHost(options.uri) || !AntitheftDecoder.isChallenge(data)) {
      handler.next(response);
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
}
