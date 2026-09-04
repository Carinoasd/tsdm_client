import 'dart:async';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/login_parser.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Repository of authentication.
///
/// Provides login, logout.
///
/// **Need to call dispose.**
class AuthenticationRepository with LoggerMixin {
  /// Constructor.
  AuthenticationRepository({UserLoginInfo? user}) : _authedUser = user;

  static const _checkAuthUrl = '$baseUrl/home.php?mod=spacecp';

  /// Url of the login form.
  ///
  /// Response is an xml wrapping the html form in CDATA, the same one used by the web page when opening the login
  /// floating window.
  static const _loginFormUrl =
      '$baseUrl/member.php?mod=logging&action=login&infloat=yes&handlekey=login&inajax=1&ajaxtarget=fwin_content_login';

  /// Url to post the login form, `loginhash` is the one parsed from login form.
  static const _loginBaseUrl = '$baseUrl/member.php?mod=logging&action=login&loginsubmit=yes&handlekey=login&inajax=1';
  static const _logoutBaseUrl = '$baseUrl/member.php?mod=logging&action=logout&formhash=';
  static final _formHashRe = RegExp(r'formhash" value="(?<FormHash>\w+)"');

  static String _buildLoginUrl(String loginHash) {
    return '$_loginBaseUrl&loginhash=$loginHash';
  }

  static String _buildLogoutUrl(String formHash) {
    return '$_logoutBaseUrl$formHash';
  }

  /// Provide a stream of [AuthStatus].
  ///
  /// Be aware that the data contained in stream is not the state in auth bloc.
  final _controller = BehaviorSubject<AuthStatus>();

  UserLoginInfo? _authedUser;

  /// Cookie used in the current login session.
  CookieProvider? _loginCookie;

  /// Hashes in the current login session.
  LoginHash? _loginHash;

  /// The current logged user.
  UserLoginInfo? get currentUser => _authedUser;

  /// Authentication status stream.
  Stream<AuthStatus> get status => _controller.asBroadcastStream();

  /// Dispose the resources.
  Future<void> dispose() async {
    await _controller.close();
  }

  /// Fetch the login form with [netClient] and parse hashes in it.
  ///
  /// Note that `formhash` is bound to the cookie session, so the login request MUST be sent with the same
  /// cookie used here.
  AsyncEither<LoginHash> _fetchHashWithClient(NetClientProvider netClient) => netClient.get(_loginFormUrl).flatMap((v) {
    if (v.statusCode != HttpStatus.ok) {
      return taskLeft(HttpRequestFailedException(v.statusCode));
    }
    return AsyncEither.fromEither(LoginParser.parseLoginHash(v.data as String));
  });

  /// Start a new login session: use a clean cookie and fetch the login form.
  ///
  /// Form hash and captcha are bound to the cookie session, so all requests in the login progress ([fetchHash],
  /// [fetchCaptchaImage] and [loginWithPassword]) share the same [_loginCookie].
  ///
  /// Use a clean cookie because:
  ///
  /// * Want to use a pure and clean cookie when start login, to avoid using current authed user's cookie.
  /// * Control when and what user info to save with the cookie stored in it, so that the token is successfully saved
  ///   in storage.
  AsyncEither<LoginHash> fetchHash() {
    final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
    _loginCookie = cookie;
    _loginHash = null;
    return _fetchHashWithClient(NetClientProvider.buildNoCookie(cookie: cookie)).map((v) {
      _loginHash = v;
      return v;
    });
  }

  /// Fetch the captcha image in current login session.
  ///
  /// Only available when [LoginHash.needCaptcha] is true.
  AsyncEither<Response<dynamic>> fetchCaptchaImage() {
    final cookie = _loginCookie;
    final secCodeHash = _loginHash?.secCodeHash;
    if (cookie == null || secCodeHash == null) {
      return taskLeft(LoginFormHashNotFoundException());
    }
    final rand = DateTime.now().millisecondsSinceEpoch;
    return NetClientProvider.buildNoCookie(
      cookie: cookie,
    ).getImage('$baseUrl/misc.php?mod=seccode&update=$rand&idhash=$secCodeHash');
  }

  /// Login with password and other parameters in [credential].
  ///
  /// Will not change authentication status if failed to login.
  AsyncVoidEither loginWithPassword(UserCredential credential) => AsyncVoidEither(() async {
    debug('login with passwd');
    await _markUnauthenticated();

    // Reuse the login session if exists.
    if (_loginCookie == null || _loginHash == null) {
      final hashEither = await fetchHash().run();
      if (hashEither.isLeft()) {
        return left(hashEither.unwrapErr());
      }
    }
    final cookie = _loginCookie!;
    final hash = _loginHash!;
    // Inject cookie provider.
    final netClient = NetClientProvider.buildNoCookie(cookie: cookie);

    final respEither = await netClient
        .postForm(_buildLoginUrl(hash.loginHash), data: credential.toFormData(hash))
        .run();
    // Every login attempt requires a new form hash.
    _loginCookie = null;
    _loginHash = null;
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    final data = resp.data as String;
    final resultEither = LoginParser.parseLoginResult(data);
    if (resultEither.isLeft()) {
      error('failed to login: ${resultEither.unwrapErr()}, response: ${data.truncate(300)}');
      return left(resultEither.unwrapErr());
    }
    // Here we get complete user info.
    final userInfo = resultEither.unwrap();
    // First combine user info and cookie together.
    await cookie.updateUserInfo(userInfo);
    // Second, save credential in storage.
    await cookie.saveCookieToStorage();
    // Refresh the cookie in global cookie provider.
    await getIt.get<CookieProvider>().loadCookieFromStorage(userInfo);
    // Finally save authed user info and update authentication status to
    // let auth stream subscribers update their status.
    await _markAuthenticated(userInfo);
    debug('end login with success');

    return rightVoid();
  });

  /// Parse logged user info from html [document].
  AsyncVoidEither loginWithDocument(uh.Document document) => AsyncVoidEither(() async {
    // Do NOT mark as unauthenticated here because auth with document is
    // only used as a verification of a token that intend to be valid. It's
    // outside the regular login progress.
    final userInfo = _parseUserInfoFromDocument(document);
    if (userInfo == null) {
      debug('failed to login with document: user info not found');
      return left(LoginUserInfoNotFoundException());
    }

    // Here we get complete user info.
    await getIt.get<CookieProvider>().saveCookieToStorage();
    await _markAuthenticated(userInfo);

    debug('login with document: user $userInfo');
    return rightVoid();
  });

  /// Logout the current user.
  ///
  /// Check authentication status first then try to logout.
  /// Do nothing if already unauthenticated.
  AsyncVoidEither logout() => AsyncVoidEither(() async {
    if (_authedUser == null) {
      return rightVoid();
    }
    final netClient = NetClientProvider.build(
      userLoginInfo: UserLoginInfo(username: _authedUser!.username, uid: _authedUser!.uid),
    );
    final respEither = await netClient.get(_checkAuthUrl).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }
    final document = parseHtmlDocument(resp.data as String);
    final userInfo = _parseUserInfoFromDocument(document);
    if (userInfo == null) {
      // Not logged in.
      await _markUnauthenticated();
      return rightVoid();
    }
    final formHash = _formHashRe.firstMatch(document.body?.innerHtml ?? '')?.namedGroup('FormHash');
    if (formHash == null) {
      return left(LogoutFormHashNotFoundException());
    }

    final logoutRespEither = await netClient.get(_buildLogoutUrl(formHash)).run();
    if (logoutRespEither.isLeft()) {
      return left(logoutRespEither.unwrapErr());
    }
    final logoutResp = logoutRespEither.unwrap();
    if (logoutResp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(logoutResp.statusCode));
    }
    final logoutDocument = parseHtmlDocument(logoutResp.data as String);
    final logoutMessage = logoutDocument.getElementById('messagetext');
    if (logoutMessage == null || !logoutMessage.innerHtmlEx().contains('已退出')) {
      // TODO: Here we'd better to check the failed reason.
      return left(LogoutFailedException());
    }

    getIt.get<CookieProvider>().clearUserInfoAndCookie();
    await getIt.get<StorageProvider>().deleteCookieByUid(_authedUser!.uid!);
    await _markUnauthenticated();
    return rightVoid();
  });

  /// Switch to another user described in [userInfo].
  ///
  /// Return [SwitchUserNotAuthedException] if failed.
  AsyncVoidEither switchUser(UserLoginInfo userInfo) => AsyncVoidEither(() async {
    if (!await getIt.get<CookieProvider>().loadCookieFromStorage(userInfo)) {
      return left(LoginInvalidCredentialException());
    }
    final resp = await getIt.get<NetClientProvider>().get(_checkAuthUrl).run();
    if (resp.isLeft()) {
      return left(resp.unwrapErr());
    }

    final document = parseHtmlDocument(resp.unwrap().data as String);
    final parsedUserInfo = _parseUserInfoFromDocument(document);
    if (parsedUserInfo == null || parsedUserInfo.uid != userInfo.uid) {
      error(
        'failed to switch user to uid=${"${userInfo.uid}".obscured(4)}, '
        'parsed uid=${"${parsedUserInfo?.uid}".obscured(4)}',
      );
      return left(SwitchUserNotAuthedException());
    }

    // Succeed.
    // Here we get complete user info.
    await getIt.get<CookieProvider>().saveCookieToStorage();
    await _markAuthenticated(userInfo);

    debug('login with document: user $userInfo');
    return rightVoid();
  });

  /// Parse html [document], find current logged in user uid in it.
  UserLoginInfo? _parseUserInfoFromDocument(uh.Document document) {
    final userNode =
        // Style 1: With avatar.
        document.querySelector('div#hd div.wp div.hdc.cl div#um p strong.vwmy a') ??
        // Style 2: Without avatar.
        document.querySelector('div#inner_stat > strong > a');
    if (userNode == null) {
      debug('auth failed: user node not found');
      return null;
    }
    final username = userNode.firstEndDeepText();
    if (username == null) {
      debug('auth failed: user name not found');
      return null;
    }
    final uid = userNode.firstHref()?.split('uid=').lastOrNull?.parseToInt();
    if (uid == null) {
      debug('auth failed: user id not found');
      return null;
    }

    // String? email;
    // if (parseEmail) {
    //   email = document.querySelector('input#emailnew')?.attributes['value'];
    // }
    return UserLoginInfo(uid: uid, username: username /*email: email*/);
  }

  Future<void> _saveLoggedUserInfo(UserLoginInfo userInfo) async {
    debug('save logged user info: $userInfo');
    // Save logged user info in settings.
    final settings = getIt.get<SettingsRepository>();
    await settings.setValue<String>(SettingsKeys.loginUsername, userInfo.username!);
    await settings.setValue<int>(SettingsKeys.loginUid, userInfo.uid!);
    // await settings.setValue<String>(
    //   SettingsKeys.loginEmail,
    //   userInfo.email!,
    // );

    _authedUser = userInfo;
  }

  /// All steps need to execute when state should change to authed except saving
  /// cookies because sometimes the cookie provider holding latest authed cookie
  /// is not the one global wide.
  ///
  /// This function does something that need to be completed before auth state
  /// changes so that all auth stream subscribers are using the correct data in
  /// authed state.
  Future<void> _markAuthenticated(UserLoginInfo userInfo) async {
    // Save user info to memory and storage.
    await _saveLoggedUserInfo(userInfo);
    // Clear cookie.
    await getIt<CookieProvider>().updateUserInfo(UserLoginInfo(username: userInfo.username, uid: userInfo.uid));
    // Do NOT save cookie to storage here, because it's not always the normal
    // global cookie provider doing the auth work, maybe another local cookie in
    // some scope.
    // Instead, save cookie outside this function when necessary.
    // await getIt<CookieProvider>().saveCookieToStorage();
    // Finally change state to authed.
    _controller.add(AuthStatusAuthed(userInfo));
  }

  /// All actions need to execute when state should change to unauthenticated.
  ///
  /// This function does something that need to be completed before auth state
  /// changes so that all auth stream subscribers are using the correct data in
  /// unauthenticated state.
  Future<void> _markUnauthenticated() async {
    final settings = getIt.get<SettingsRepository>();
    await settings.deleteValue(SettingsKeys.loginUsername);
    await settings.deleteValue(SettingsKeys.loginUid);
    await settings.deleteValue(SettingsKeys.loginEmail);
    _authedUser = null;
    _controller.add(const AuthStatusNotAuthed());
  }
}
