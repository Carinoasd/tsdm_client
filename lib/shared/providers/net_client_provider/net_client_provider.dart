import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_brotli_transformer/dio_brotli_transformer.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/map.dart';
import 'package:tsdm_client/features/points/stream.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/antitheft_interceptor.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:universal_html/parsing.dart';

/// Map exception to [AppException].
AppException mapException(Object error, StackTrace st) {
  // Exceptions raised on purpose inside a tryCatch body already carry the right type.
  if (error is AppException) {
    return error;
  }
  // Interceptors reject with an app exception wrapped in a DioException.
  if (error case DioException(error: final AppException inner)) {
    return inner;
  }
  if (error case DioException(:final response)) {
    return HttpHandshakeFailedException(
      error.message ?? '<unknown error>',
      statusCode: response?.statusCode,
      headers: response?.headers,
    );
  }
  return HttpRequestFailedException(null);
}

extension _WithFormExt<T> on Dio {
  AsyncEither<Response<T>> postWithForm(String path, {Object? data, Map<String, dynamic>? queryParameters}) =>
      AsyncEither.tryCatch(
        () async => post(
          path,
          data: data,
          queryParameters: queryParameters,
          options: Options(headers: {HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded'}),
        ),
        mapException,
      );
}

/// Http client acts on web request.
///
/// Also a wrapper of [Dio] instance.
///
/// Instance should be unique when making requests.
final class NetClientProvider with LoggerMixin {
  /// Constructor.
  NetClientProvider._(Dio dio) : _dio = dio;

  /// Build a [NetClientProvider] instance.
  ///
  /// ## Parameters
  ///
  /// * [userLoginInfo] is the account this client acts for, the current account by default. The client is bound to
  ///   that account: once another account becomes current, pending requests of this client are dropped and their
  ///   cookies are neither read nor saved, see [_IdentityGuard] and [_IdentityScopedStorage].
  /// * Set [forceDesktop] to false when desire server response with a mobile
  ///   layout page.
  factory NetClientProvider.build({Dio? dio, UserLoginInfo? userLoginInfo, bool forceDesktop = true}) {
    final d = dio ?? getIt.get<SettingsRepository>().buildDefaultDio();
    if (!isWeb) {
      talker.debug('build client with cookie');
      final cookie = getIt.get<CookieProvider>();
      final identity = userLoginInfo?.uid ?? cookie.userLoginInfo.uid;
      final cookieJar = PersistCookieJar(ignoreExpires: true, storage: _IdentityScopedStorage(cookie, identity));
      d.interceptors.add(_IdentityGuard(cookie, identity));
      d.interceptors.add(_DropServerFlagCookies());
      d.interceptors.add(CookieManager(cookieJar));
      if (forceDesktop) {
        d.interceptors.add(_ForceDesktopLayoutInterceptor());
      }

      d.interceptors.add(_ErrorHandler());
      d.interceptors.add(_PointsChangesChecker());
      d.interceptors.add(_GzipEncodingChecker());
      d.interceptors.add(AntitheftInterceptor(d));
      // decode br content-type.
      d.transformer = DioBrotliTransformer();
    }

    return NetClientProvider._(d);
  }

  /// Build a [NetClientProvider] instance that does NOT load cookie.
  ///
  /// ## Parameters
  ///
  /// * [cookie] is an optional parameters used to inject cookie. Sometimes
  ///   some actions are required to apply on [cookie] at a specified time.
  /// * Set [forceDesktop] to false when desire server response with a mobile
  ///   layout page.
  factory NetClientProvider.buildNoCookie({Dio? dio, bool forceDesktop = true, CookieProvider? cookie}) {
    talker.debug('build client without stored cookie');
    final d = dio ?? getIt.get<SettingsRepository>().buildDefaultDio();
    d.interceptors.add(_ErrorHandler());
    final cookieJar = PersistCookieJar(
      ignoreExpires: true,
      storage: cookie ?? getIt.get<CookieProvider>(instanceName: ServiceKeys.empty),
    );
    d.interceptors.add(_DropServerFlagCookies());
    d.interceptors.add(CookieManager(cookieJar));
    if (forceDesktop) {
      d.interceptors.add(_ForceDesktopLayoutInterceptor());
    }
    d.interceptors.add(AntitheftInterceptor(d));
    // decode br content-type.
    d.transformer = DioBrotliTransformer();
    return NetClientProvider._(d);
  }

  final Dio _dio;

  /// Make a GET request to [path].
  AsyncEither<Response<dynamic>> get(String path, {Map<String, dynamic>? queryParameters}) =>
      AsyncEither.tryCatch(() async => _dio.get<dynamic>(path, queryParameters: queryParameters), mapException);

  /// Make a GET request to the given [uri].
  AsyncEither<Response<dynamic>> getUri(Uri uri) =>
      AsyncEither.tryCatch(() async => _dio.getUri<dynamic>(uri), mapException);

  /// Make a GET request to [path], with options set to image types.
  AsyncEither<Response<dynamic>> getImage(String path, {Map<String, dynamic>? queryParameters}) =>
      AsyncEither.tryCatch(() async {
        final resp = await _dio.get<dynamic>(
          path,
          queryParameters: queryParameters,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              HttpHeaders.acceptHeader: 'image/avif,image/webp,*/*;q=0.8',
              HttpHeaders.acceptEncodingHeader: 'gzip, deflate, br',
            },
          ),
        );

        if (resp.statusCode != HttpStatus.ok) {
          throw HttpRequestFailedException(resp.statusCode);
        }
        _ensureImageBody(resp);
        return resp;
      }, mapException);

  /// Get a image from the given [uri].
  AsyncEither<Response<dynamic>> getImageFromUri(Uri uri) => AsyncEither.tryCatch(() async {
    final resp = await _dio.getUri<dynamic>(
      uri,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          HttpHeaders.acceptHeader: 'image/avif,image/webp,*/*;q=0.8',
          HttpHeaders.acceptEncodingHeader: 'gzip, deflate, br',
        },
      ),
    );

    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }
    _ensureImageBody(resp);
    return resp;
  }, mapException);

  /// Post [data] to [path] with [queryParameters].
  ///
  /// When post a form data, use [postForm] instead.
  AsyncEither<Response<dynamic>> post(String path, {Object? data, Map<String, dynamic>? queryParameters}) =>
      AsyncEither.tryCatch(
        () async => _dio.post<dynamic>(path, data: data, queryParameters: queryParameters),
        mapException,
      );

  /// Post a form [data] to url [path] with [queryParameters].
  ///
  /// Automatically set `Content-Type` to `application/x-www-form-urlencoded`.
  AsyncEither<Response<dynamic>> postForm(String path, {Object? data, Map<String, dynamic>? queryParameters}) =>
      _dio.postWithForm(path, data: data, queryParameters: queryParameters);

  /// Post a form [data] to url [path] in `Content-Type` multipart/form-data.
  ///
  /// Automatically set `Content-Type` to `multipart/form-data`.
  AsyncEither<Response<dynamic>> postMultipartForm(
    String path, {
    required Map<String, String> data,
    Map<String, String>? header,
  }) => AsyncEither.tryCatch(
    () async => _dio.post<dynamic>(
      path,
      options: Options(
        headers: <String, String>{
          HttpHeaders.contentTypeHeader: Headers.multipartFormDataContentType,
        }.copyWith(header ?? {}),
        validateStatus: (code) {
          if (code == 301 || code == 200) {
            return true;
          }
          return false;
        },
      ),
      // Use plain map for kotlin native http client.
      data: isAndroid ? data : FormData.fromMap(data),
    ),
    mapException,
  );

  /// Download the file from url [path] and save to [savePath].
  AsyncVoidEither download(
    String path,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) => AsyncVoidEither.tryCatch(
    () async => _dio.download(
      path,
      savePath,
      onReceiveProgress: onReceiveProgress,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      deleteOnError: deleteOnError,
      lengthHeader: lengthHeader,
      data: data,
      options: options,
    ),
    mapException,
  );
}

/// Cookie storage of one account.
///
/// Reads and writes reach the shared [CookieProvider] only while that account is still the current one. After a
/// switch, a client built for the previous account neither sends its cookies nor saves the cookies of a late answer
/// into the new account.
final class _IdentityScopedStorage with LoggerMixin implements Storage {
  _IdentityScopedStorage(this._provider, this._uid);

  final CookieProvider _provider;
  final int? _uid;

  bool get _current => _provider.userLoginInfo.uid == _uid;

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) => _provider.init(persistSession, ignoreExpires);

  @override
  Future<String?> read(String key) async => _current ? _provider.read(key) : null;

  @override
  Future<void> write(String key, String value) async {
    if (!_current) {
      warning('drop cookie write of a client bound to a previous account');
      return;
    }
    await _provider.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (_current) {
      await _provider.delete(key);
    }
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    if (_current) {
      await _provider.deleteAll(keys);
    }
  }
}

/// Drops requests and answers of a client whose account is no longer the current one.
///
/// A request started as account A must not go out as account B (reply, rate, favorite with A's form hash but B's
/// cookies), and an answer for A must not land on B's screen.
final class _IdentityGuard extends Interceptor with LoggerMixin {
  _IdentityGuard(this._provider, this._uid);

  final CookieProvider _provider;
  final int? _uid;

  bool get _changed => _provider.userLoginInfo.uid != _uid;

  DioException _dropped(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: IdentityChangedException(),
    message: 'account changed, request dropped',
  );

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_changed) {
      warning('drop request of a previous account: ${options.method} ${options.uri.path}');
      handler.reject(_dropped(options));
      return;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (_changed) {
      warning('drop answer for a previous account: ${response.requestOptions.uri.path}');
      handler.reject(_dropped(response.requestOptions), true);
      return;
    }
    handler.next(response);
  }
}

/// Handle exceptions during web request.
class _ErrorHandler extends Interceptor with LoggerMixin {
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    getIt.get<NetErrorSaver>().clear();
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    error('${err.requestOptions.uri} ${err.type}: error: ${err.error}, status code: ${err.response?.statusCode}');
    getIt.get<NetErrorSaver>().save(err.message);

    if (err.type == DioExceptionType.badResponse) {
      // Till now we can do nothing if encounter a bad response.
    }

    if (err.type == DioExceptionType.unknown && err.error.runtimeType == HandshakeException) {
      // Likely we have an error in SSL handshake.
    }

    // Do not block error handling.
    handler.next(err);
  }
}

/// Force request url with desktop, only for server site.
///
/// Works by append query parameter "mobile=no".
///
/// Only use this class when sending request to forum server.
class _ForceDesktopLayoutInterceptor extends Interceptor with LoggerMixin {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Only append query parameter if request is target forum server host.
    final host = options.uri.host;
    if (host == baseHost || host == baseHostAlt) {
      options.queryParameters['mobile'] = 'no';
    }

    handler.next(options);
  }
}

/// Drop the server's per-session flag cookies before the cookie jar sees them.
///
/// Runs before [CookieManager] so `Set-Cookie: <prefix>_nofavfid=1` never enters the jar: with that flag Discuz!
/// skips the "我收藏的版块" panel of the forum index for the whole session (issue #1). Rows persisted earlier are
/// cleaned when the cookie provider loads them ([stripServerFlagCookies]).
class _DropServerFlagCookies extends Interceptor {
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final setCookie = response.headers[HttpHeaders.setCookieHeader];
    if (setCookie != null && setCookie.any(_isFlag)) {
      response.headers.set(HttpHeaders.setCookieHeader, setCookie.where((e) => !_isFlag(e)).toList());
    }
    handler.next(response);
  }

  static bool _isFlag(String header) {
    final name = header.split('=').first.trim();
    return serverFlagCookieSuffixes.any(name.endsWith);
  }
}

/// Check user points changes.
///
/// In user actions' result, points (or call it credit) may change, and the changes info is stored in cookie by the
/// `set-cookie` header in response. Here we should check for those points changes and parse them into points change
/// event which can be sent to user side later.
///
/// Two reasons why we do it here, not in cookie provider:
///
/// 1. We need to identify which action caused the points change event, for some reason we already have result messages
///   on user actions but it only contains success or failure info, without the points change if it exists. If we want
///   to combine the original info result (succeed or not) and the points change (if any), the request side shall have
///   some access to the relevant points change event produced by the request, impossible in cookie provider.
/// 2. It's more expensive to decode and parse points changes in cookie provider because there is literally the storage
///   layer, cookie are passed in format friendly to store but not operating.
final class _PointsChangesChecker extends Interceptor {
  static const _creditNotice = '${cookiePrefix}_creditnotice';

  static final _creditNoticeRe = RegExp('$_creditNotice=(?<value>[^ ;]+)');

  /// Filter credit notice cookie values from cookie strings.
  Option<List<String>> _filterCreditNotice(List<String> cookie) {
    final filtered = cookie
        .filter((v) => v.contains(_creditNotice))
        .map(_creditNoticeRe.firstMatch)
        .whereType<RegExpMatch>();
    if (filtered.isEmpty) {
      return const None();
    }

    return Option.of(filtered.map((v) => v.namedGroup('value')!).toList());
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    response.headers.map
        .lookup('set-cookie')
        .filterMap(_filterCreditNotice)
        // All notice changes cookie value.
        .map((x) => x.forEach(pointsChangesStream.add));

    handler.next(response);
  }
}

/// This interceptor checks if gzip encoding is available in request.
///
/// Ref:
/// https://github.com/flutter/flutter/issues/32558#issuecomment-886022246
///
/// Remove "gzip" encoding in "Accept-Encoding" can fix the issue above.
/// Those requests intend to have a 301 status code need to remove "gzip" encoding in request.
/// But the server may still return gzip content data.
final class _GzipEncodingChecker extends Interceptor with LoggerMixin {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Likely to have redirect on post methods.
    if (options.method != 'GET' || options.uri.queryParameters['goto'] == 'findpost') {
      info('removing gzip encoding in request');
      options.headers[HttpHeaders.acceptEncodingHeader] = 'deflate, br';
    }

    super.onRequest(options, handler);
  }
}

/// Throw [ImageResponseNotImageException] when an image request was answered with an HTML page.
///
/// Discuz! X5 answers permission failures on attachments with HTTP 200 and a 提示信息 page, and serves real
/// attachments with a bare `Content-Type: image`, so only reject what is provably a page: a `text/html` content type
/// or a body that starts with a tag.
void _ensureImageBody(Response<dynamic> resp) {
  final contentType = resp.headers.value(Headers.contentTypeHeader) ?? '';
  final data = resp.data;
  final looksHtml = contentType.startsWith('text/html') || (data is Uint8List && _startsWithTag(data));
  if (!looksHtml) {
    return;
  }
  String? message;
  if (data is Uint8List) {
    final node = parseHtmlDocument(utf8.decode(data, allowMalformed: true)).querySelector('div#messagetext > p');
    node?.querySelectorAll('script').forEach((e) => e.remove());
    message = node?.text?.trim();
  }
  throw ImageResponseNotImageException(message, contentType: contentType);
}

/// Whether [data] starts with `<` after an optional UTF-8 BOM and whitespace.
bool _startsWithTag(Uint8List data) {
  var i = 0;
  if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
    i = 3;
  }
  while (i < data.length && (data[i] == 0x20 || data[i] == 0x09 || data[i] == 0x0A || data[i] == 0x0D)) {
    i++;
  }
  return i < data.length && data[i] == 0x3C;
}
