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
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
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
  ///
  /// [clientFactory] builds the isolated clients of login and account switching, [currentUserClientFactory] the
  /// client acting as the current account (used by [logout]); both are replaceable in tests.
  AuthenticationRepository({
    UserLoginInfo? user,
    NetClientProvider Function(CookieProvider)? clientFactory,
    NetClientProvider Function(UserLoginInfo)? currentUserClientFactory,
  }) : _authedUser = user,
       _clientFactory = clientFactory ?? _defaultClientFactory,
       _currentUserClientFactory = currentUserClientFactory ?? _defaultCurrentUserClientFactory;

  final NetClientProvider Function(CookieProvider) _clientFactory;
  final NetClientProvider Function(UserLoginInfo) _currentUserClientFactory;

  static NetClientProvider _defaultClientFactory(CookieProvider cookie) =>
      NetClientProvider.buildNoCookie(cookie: cookie);

  static NetClientProvider _defaultCurrentUserClientFactory(UserLoginInfo user) =>
      NetClientProvider.build(userLoginInfo: user);

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

  /// Uid of the account this device acts as, also before the stored session was verified.
  ///
  /// [currentUser] is only set by a login or a successful check of the stored session; at an offline start or when
  /// that session expired it stays null although the global [CookieProvider] and the settings still name the account
  /// whose cookie every request carries. The manage accounts page treats that account as the current one so removing
  /// it goes through [forgetCurrentUser] instead of only deleting its row. Null when no account is in use.
  int? get effectiveCurrentUid =>
      _validUid(_authedUser?.uid) ??
      _validUid(getIt.get<CookieProvider>().userLoginInfo.uid) ??
      _validUid(getIt.get<SettingsRepository>().currentSettings.loginUid);

  static int? _validUid(int? uid) => uid != null && uid > 0 ? uid : null;

  /// Whether [document] is the page the forum renders for a guest: the login form without the user node.
  ///
  /// Same rule as the check-in and notification fetches.
  static bool _isGuestPage(uh.Document document) =>
      document.querySelector('form#lsform') != null && document.querySelector('div#um') == null;

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
    _loginCookie = null;
    _loginHash = null;
    return _fetchHashWithClient(_clientFactory(cookie)).map((v) {
      // Publish the cookie and hash from the same response together.
      _loginCookie = cookie;
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
    return _clientFactory(cookie).getImage('$baseUrl/misc.php?mod=seccode&update=$rand&idhash=$secCodeHash');
  }

  /// Login with password and other parameters in [credential].
  ///
  /// Will not change authentication status if failed to login.
  AsyncVoidEither loginWithPassword(UserCredential credential) => AsyncVoidEither(() async {
    debug('login with passwd');
    // Keep the current account active until another login succeeds.

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
    final netClient = _clientFactory(cookie);

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
  ///
  /// When the forum answers with the guest page (session expired, or logged out elsewhere) the saved login is removed
  /// like after a successful logout: keeping the row left the account listed as online with nothing able to remove
  /// it. Any other page without a logged user (maintenance, an unresolved interstitial) only leaves the authed state
  /// and keeps the saved login, it says nothing about the session.
  AsyncVoidEither logout() => AsyncVoidEither(() async {
    if (_authedUser == null) {
      return rightVoid();
    }
    final netClient = _currentUserClientFactory(
      UserLoginInfo(username: _authedUser!.username, uid: _authedUser!.uid),
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
      if (_isGuestPage(document)) {
        // Not logged in any more: nothing to end on the server, drop the saved login.
        info('logout: session already gone on the server, remove the saved login');
        await _forgetCurrentUser();
        return rightVoid();
      }
      warning('logout: no logged user on an unrecognized page, keep the saved login');
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

    await _forgetCurrentUser();
    return rightVoid();
  });

  /// Remove the current account from this device without telling the forum.
  ///
  /// Clears the cookie in memory, deletes the saved login and marks the app as unauthenticated; no request is sent,
  /// so it works offline and the forum session stays valid elsewhere. The account is [effectiveCurrentUid], so it
  /// also works when the stored session was never verified in this run; does nothing when no account is in use.
  AsyncVoidEither forgetCurrentUser() => AsyncVoidEither(() async {
    if (effectiveCurrentUid == null) {
      return rightVoid();
    }
    await _forgetCurrentUser();
    return rightVoid();
  });

  Future<void> _forgetCurrentUser() async {
    // Resolve the account before the provider forgets it.
    final uid = effectiveCurrentUid;
    getIt.get<CookieProvider>().clearUserInfoAndCookie();
    if (uid != null) {
      await getIt.get<StorageProvider>().deleteCookieByUid(uid);
    }
    await _markUnauthenticated();
  }

  /// Switch to another user described in [userInfo].
  ///
  /// Return [SwitchUserNotAuthedException] if failed.
  AsyncVoidEither switchUser(UserLoginInfo userInfo) => AsyncVoidEither(() async {
    final candidate = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
    if (!await candidate.loadCookieFromStorage(userInfo)) {
      return left(LoginInvalidCredentialException());
    }
    // Validate with an isolated session; failures must leave the active account untouched.
    final resp = await _clientFactory(candidate).get(_checkAuthUrl).run();
    if (resp.isLeft()) {
      return left(resp.unwrapErr());
    }
    if (resp.unwrap().statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.unwrap().statusCode));
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

    // Commit the verified session before notifying authentication subscribers.
    await candidate.saveCookieToStorage();
    if (!await getIt.get<CookieProvider>().loadCookieFromStorage(parsedUserInfo)) {
      return left(LoginInvalidCredentialException());
    }
    await _markAuthenticated(parsedUserInfo);

    debug('login with document: user $userInfo');
    return rightVoid();
  });

  /// Parse html [document], find current logged in user uid in it.
  UserLoginInfo? _parseUserInfoFromDocument(uh.Document document) {
    final userInfo = parseLoggedUserFromDocument(document);
    if (userInfo == null) {
      debug('auth failed: logged user not found in document');
    }
    return userInfo;
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
