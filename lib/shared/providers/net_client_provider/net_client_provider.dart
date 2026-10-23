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
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/antitheft_interceptor.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart';
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
      error.message ?? error.error?.toString() ?? error.type.name,
      statusCode: response?.statusCode,
      headers: response?.headers,
      // Dio reports a failed connect as a connection error or timeout; the Android channel as its own exception. A
      // socket failing after the connect (reset, closed) is no such failure: the forum was reached.
      connectionFailed:
          response == null &&
          (error.type == DioExceptionType.connectionError ||
              error.type == DioExceptionType.connectionTimeout ||
              error.error is HostUnreachableException),
      // Connected, but the answer did not come in time: a slow forum or network, told apart from a dropped
      // connection.
      timedOut:
          response == null &&
          (error.type == DioExceptionType.sendTimeout ||
              error.type == DioExceptionType.receiveTimeout ||
              error.error is RequestTimedOutException),
      connectionLost:
          response == null &&
          error.error is IOException &&
          error.error is! HostUnreachableException &&
          error.error is! RequestTimedOutException,
    );
  }
  return HttpRequestFailedException(null);
}

/// The header the forum's own `ajaxget`/`ajaxpost` send with an AJAX request.
const _ajaxHeader = 'X-Requested-With';

/// [options] with `X-Requested-With: XMLHttpRequest` when [path] is a request the forum is asked as an AJAX one
/// (`inajax=1` in its query), as the forum's own scripts send it; a header the caller set is kept.
///
/// A forum set to verify its AJAX requests (`ajaxvalidate`) takes a GET without the header for a plain page request
/// and answers the whole page instead of the fragment (a POST is taken as AJAX either way). Set on the request itself
/// rather than by an interceptor: no extra hop on the event loop for every request.
Options? _withAjaxHeader(String path, Options? options) {
  if (Uri.tryParse(path)?.queryParameters['inajax'] != '1') {
    return options;
  }
  final headers = <String, dynamic>{...?options?.headers};
  if (headers.keys.any((k) => k.toLowerCase() == _ajaxHeader.toLowerCase())) {
    return options;
  }
  headers[_ajaxHeader] = 'XMLHttpRequest';
  return (options ?? Options()).copyWith(headers: headers);
}

extension _WithFormExt<T> on Dio {
  AsyncEither<Response<T>> postWithForm(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    bool singleAttempt = false,
  }) => AsyncEither.tryCatch(
    () async => post(
      path,
      data: data,
      queryParameters: queryParameters,
      options: _withAjaxHeader(
        path,
        Options(
          headers: {HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded'},
          followRedirects: singleAttempt ? false : null,
          extra: singleAttempt ? {singleAttemptHttpRequestKey: true} : null,
        ),
      ),
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
  NetClientProvider._(Dio dio, [this._session]) : _client = dio;

  /// Build a [NetClientProvider] instance.
  ///
  /// ## Parameters
  ///
  /// * [userLoginInfo] is the account this client acts for, the current account by default. The client is bound to
  ///   that account: once another account becomes current, pending requests of this client are dropped and their
  ///   cookies are neither read nor saved, see [_IdentityGuard] and [_IdentityScopedStorage]. Each request is also
  ///   bound to the session of that account the cookie provider holds when it is sent (`CookieProvider.generation`):
  ///   once another session of the account is loaded (a login with the password), the requests in flight are dropped
  ///   the same way and the next ones send the new session ([_SessionCookies]).
  /// * Set [forceDesktop] to false when desire server response with a mobile
  ///   layout page.
  factory NetClientProvider.build({Dio? dio, UserLoginInfo? userLoginInfo, bool forceDesktop = true}) {
    final d = dio ?? getIt.get<SettingsRepository>().buildDefaultDio();
    _SessionCookies? session;
    if (!isWeb) {
      talker.debug('build client with cookie');
      final cookie = getIt.get<CookieProvider>();
      session = _SessionCookies(d, cookie, userLoginInfo?.uid ?? cookie.userLoginInfo.uid)..refresh();
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

    return NetClientProvider._(d, session);
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

  final Dio _client;

  /// The cookie interceptors of a client of the global cookie ([NetClientProvider.build]), null otherwise.
  final _SessionCookies? _session;

  /// The client a request is sent with now, its cookie interceptors those of the session in use
  /// ([_SessionCookies.refresh]). Read when the request is sent.
  Dio get _dio {
    _session?.refresh();
    return _client;
  }

  /// Make a GET request to [path].
  ///
  /// [options] apply to this request only, e.g. a `validateStatus` that keeps the body of an error answer. An AJAX
  /// request (`inajax=1`) carries `X-Requested-With: XMLHttpRequest` as the forum's own scripts send it, unless
  /// [options] sets the header.
  ///
  /// [singleAttempt] marks a GET that writes (the forum's AJAX menus: a debate vote): no transport retry and no
  /// redirect follow up, as [postForm] does for a form, so it is never sent twice.
  AsyncEither<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    bool singleAttempt = false,
  }) => AsyncEither.tryCatch(
    () async => _dio.get<dynamic>(
      path,
      queryParameters: queryParameters,
      options: _withAjaxHeader(
        path,
        singleAttempt
            ? (options ?? Options()).copyWith(
                followRedirects: false,
                extra: {...?options?.extra, singleAttemptHttpRequestKey: true},
              )
            : options,
      ),
    ),
    mapException,
  );

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
  /// [singleAttempt] prevents transport retries and redirects for non-idempotent
  /// transactions. Its caller must reconcile an ambiguous result through GET.
  ///
  /// The form is sent with [tsdmAppJsonWriteQuery] ([withTsdmAppJsonWrite]): the forum's app API (plugin 2.6.0)
  /// then answers the result as JSON ([tsdmAppWriteResultOf]) instead of the forum's AJAX fragment, message page or
  /// redirect, which an older plugin (or none) answers as before; the forum handles the form the same either way. A
  /// form the plugin leaves alone (the login, the plugin's own API) or whose answer is another plugin's JSON (the
  /// red packet, the `@` search) is posted as it is with [tsdmAppJson] false. The readers of every form posted with
  /// the parameter take the JSON result first.
  AsyncEither<Response<dynamic>> postForm(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    bool singleAttempt = false,
    bool tsdmAppJson = true,
  }) => AsyncEither(
    () => _dio
        .postWithForm(
          tsdmAppJson ? withTsdmAppJsonWrite(path) : path,
          data: data,
          queryParameters: queryParameters,
          singleAttempt: singleAttempt,
        )
        .run(),
  );

  /// Post [data] as JSON (`Content-Type: application/json`) to [path].
  ///
  /// The response body is returned as a plain string and every status code is accepted so the caller can read the
  /// plugin's JSON envelope (including its error body) itself. [headers] are added to this request's headers.
  ///
  /// [singleAttempt] marks a write the server may already have carried out: no transport retry and no redirect follow
  /// up, so it is never sent twice (see `postWithForm` for the same idea on form posts).
  AsyncEither<Response<dynamic>> postJson(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Map<String, String>? headers,
    bool singleAttempt = false,
  }) => AsyncEither.tryCatch(
    () async {
      final resp = await _dio.post<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          headers: {HttpHeaders.contentTypeHeader: Headers.jsonContentType, ...?headers},
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          followRedirects: singleAttempt ? false : null,
          extra: singleAttempt ? {singleAttemptHttpRequestKey: true} : null,
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status < HttpStatus.ok || status >= HttpStatus.multipleChoices) {
        // Every status is accepted above so the caller can read the plugin's own envelope; log the bad ones anyway, or a
        // call the server keeps rejecting leaves no trace in an exported log.
        warning('${resp.requestOptions.method} ${resp.requestOptions.uri} answered $status');
      }
      return resp;
    },
    mapException,
  );

  /// Post a form [data] to url [path] in `Content-Type` multipart/form-data.
  ///
  /// Automatically set `Content-Type` to `multipart/form-data`. Sent with [tsdmAppJsonWriteQuery] as [postForm]
  /// sends a form, unless [tsdmAppJson] is false.
  AsyncEither<Response<dynamic>> postMultipartForm(
    String path, {
    required Map<String, String> data,
    Map<String, String>? header,
    bool tsdmAppJson = true,
  }) => AsyncEither.tryCatch(
    () async => _dio.post<dynamic>(
      tsdmAppJson ? withTsdmAppJsonWrite(path) : path,
      options: _withAjaxHeader(
        path,
        Options(
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

/// The account a client was built for and the session of it a request is bound to: the session generation of the
/// shared [CookieProvider] when the request was sent.
final class _Identity {
  const _Identity(this.provider, this.uid, this.generation);

  final CookieProvider provider;
  final int? uid;
  final int generation;

  /// Whether the provider still names that account, whatever session of it it holds.
  bool get sameAccount => provider.userLoginInfo.uid == uid;

  /// Whether the provider still holds that session: neither another account nor another session of the same account
  /// (a login with the password, the switch's check) was loaded since.
  bool get current => sameAccount && provider.generation == generation;
}

/// The cookie interceptors of a client of the global cookie ([_IdentityGuard], [CookieManager] with its jar on
/// [_IdentityScopedStorage]), bound to one session of the client's account ([_Identity]).
///
/// The jar keeps the cookies it read in memory, so a set serves one session. Once the provider holds another session
/// of the account (a login with the password, the switch's check), the next request of the client gets a set of that
/// session with a jar of its own; the requests in flight keep theirs (dio takes the interceptors when a request
/// starts), and their answers are dropped. A client a page or a repository keeps goes on working after a new login of
/// its account, with the new session, as it did after a switch back to its account.
final class _SessionCookies {
  _SessionCookies(this._dio, this._provider, this._uid);

  final Dio _dio;
  final CookieProvider _provider;
  final int? _uid;

  /// The interceptors in place, of the session [_generation].
  List<Interceptor> _installed = const [];
  int? _generation;

  /// Put the interceptors of the session the provider holds now in place: the first ones, or those replacing the
  /// interceptors of a previous session of the same account. A client of another account than the one in use keeps
  /// its interceptors, which drop its requests.
  void refresh() {
    final generation = _provider.generation;
    if (_installed.isNotEmpty && (generation == _generation || _provider.userLoginInfo.uid != _uid)) {
      return;
    }
    final identity = _Identity(_provider, _uid, generation);
    final fresh = <Interceptor>[
      _IdentityGuard(identity),
      _DropServerFlagCookies(),
      CookieManager(PersistCookieJar(ignoreExpires: true, storage: _IdentityScopedStorage(identity))),
    ];
    if (_installed.isEmpty) {
      _dio.interceptors.addAll(fresh);
    } else {
      final at = _dio.interceptors.indexOf(_installed.first);
      for (final (i, interceptor) in fresh.indexed) {
        _dio.interceptors[at + i] = interceptor;
      }
    }
    _installed = fresh;
    _generation = generation;
  }
}

/// Cookie storage of one account's session.
///
/// Reads and writes reach the shared [CookieProvider] only while it still holds the session of that account the jar
/// was made for ([_Identity]). After a switch, a client built for the previous account neither sends its cookies nor
/// saves the cookies of a late answer into the new account; after a new login of the same account, a request of the
/// previous session does not write that session over the new one (any answer may carry a `Set-Cookie`, and the jar
/// writes back every cookie of the host it loaded, the previous auth cookie included).
final class _IdentityScopedStorage with LoggerMixin implements Storage {
  _IdentityScopedStorage(this._identity);

  final _Identity _identity;

  CookieProvider get _provider => _identity.provider;

  bool get _current => _identity.current;

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) => _provider.init(persistSession, ignoreExpires);

  @override
  Future<String?> read(String key) async => _current ? _provider.read(key) : null;

  @override
  Future<void> write(String key, String value) async {
    if (!_current) {
      warning('drop cookie write of a client bound to a previous account or session');
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

/// Drops requests and answers of a client whose account is no longer the current one, or whose session is no longer
/// the one in use ([_Identity]).
///
/// A request started as account A must not go out as account B (reply, rate, favorite with A's form hash but B's
/// cookies), and an answer for A must not land on B's screen. An answer to the previous session of A after a new
/// login of A says nothing of the new session: its guest page must not mark the new login expired.
final class _IdentityGuard extends Interceptor with LoggerMixin {
  _IdentityGuard(this._identity);

  final _Identity _identity;

  /// Key of the request's extra naming the session ([_Identity]) the request was first sent with.
  ///
  /// A request sent again with the same options (the antitheft interceptor's retry, through the client's dio) carries
  /// the cookie header of its first send: sent again under another set of interceptors (another session of the
  /// account was loaded meanwhile), it would go out with the previous auth cookie before the new one, and its answer
  /// be taken as one to the new session.
  static const _identityKey = 'tsdm_identity';

  bool get _changed => !_identity.current;

  DioException _dropped(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: IdentityChangedException(),
    message: 'account changed, request dropped',
  );

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final firstSentAs = options.extra[_identityKey];
    if (_changed || (firstSentAs != null && !identical(firstSentAs, _identity))) {
      warning('drop request of a previous account or session: ${options.method} ${options.uri.path}');
      handler.reject(_dropped(options));
      return;
    }
    options.extra = {...options.extra, _identityKey: _identity};
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (_changed) {
      warning('drop answer for a previous account or session: ${response.requestOptions.uri.path}');
      handler.reject(_dropped(response.requestOptions), true);
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (_changed && err.error is! IdentityChangedException) {
      if (err.response == null && _identity.sameAccount) {
        // No answer (the forum not reached, a timeout): nothing of the previous session to drop, and the failure is
        // the same for the session of the account in use now (a page reads its offline copy on a failed connect).
        handler.next(err);
        return;
      }
      // A failed answer for a previous account or session is no failure of the one in use either.
      warning('drop failed answer for a previous account or session: ${err.requestOptions.uri.path}');
      handler.reject(_dropped(err.requestOptions));
      return;
    }
    handler.next(err);
  }
}

/// Handle exceptions during web request.
class _ErrorHandler extends Interceptor with LoggerMixin {
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    getIt.get<NetErrorSaver>().clear();
    handler.next(response);
  }

  /// Whether a 404 is an answer the app asked for rather than a page it lost.
  ///
  /// A pokemon sprite that is not on the cdn and the plugin's `recover` (which answers 404 while no battle is running)
  /// are normal answers, kept out of the error log and the network error banner. A plugin that is disabled or renamed
  /// answers 404 as well, and that is not an answer anybody asked for: it keeps reporting.
  bool _isExpectedMissing(RequestOptions options) {
    final accept = options.headers[HttpHeaders.acceptHeader]?.toString() ?? '';
    if (accept.contains('image/')) return true;
    final query = options.uri.queryParameters;
    return query['id'] == 'pokemon:pokemon' && query['endpoint'] == 'battle' && query['action'] == 'recover';
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    if (err.type == DioExceptionType.badResponse && status == 404 && _isExpectedMissing(err.requestOptions)) {
      debug('${err.requestOptions.uri} ${err.type}: status code: $status');
      handler.next(err);
      return;
    }
    error('${err.requestOptions.uri} ${err.type}: error: ${err.error}, status code: $status');
    // The failure as the caller gets it, so a page that did not keep its own can still tell what went wrong.
    getIt.get<NetErrorSaver>().save(err.message, failure: mapException(err, err.stackTrace));

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
      // The method and the url belong in the line: without them a burst of these lines cannot be traced back to a caller
      // from an exported log, where a repeating write request otherwise leaves no trace at all.
      info('removing gzip encoding in request: ${options.method} ${options.uri}');
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
