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
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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

  /// The identity write in progress, the next one waits for it ([_identityWrite]).
  Future<void> _identityQueue = Future<void>.value();

  /// Bumped by every change of the session this device acts with ([_changedIdentity]): a login with the password, a
  /// switch, a logout, a removal of the account in use, the adoption of the account a page was served to.
  int _identityEpoch = 0;

  /// The identity epoch now: a page asked now is recorded only while it is still the same
  /// ([loginWithServedUser], [loginWithDocument]), whatever account the cookie names by then.
  ///
  /// The account alone did not tell: after a new login of the same account (with the password, or after a logout) a
  /// page asked with its previous session still named it, and its guest page marked the fresh login expired, or a
  /// page served to another account moved the fresh session into that account's row.
  int get identityEpoch => _identityEpoch;

  void _changedIdentity() => _identityEpoch++;

  /// Run right before the session this device acts with is replaced (a switch, a login with the password, a logout, a
  /// removal of the account in use), while requests still go as the account in use: what is bound to that account on
  /// the forum is ended with it (the admin token, see `AdminRepository.logoutBeforeIdentityChange`). Set once by the
  /// app; bounded by the hook itself, a failure changes nothing.
  static Future<void> Function()? beforeIdentityChange;

  Future<void> _beforeIdentityChange() async {
    try {
      await beforeIdentityChange?.call();
    } on Object catch (e) {
      warning('before the identity change: $e');
    }
  }

  /// Run [action], a read-check-write of the identity this device acts as (the global cookie, the stored rows of the
  /// accounts, the account named in the settings and [currentUser]), after every such write started before it.
  ///
  /// Held by the account switch, the password login, the logout and the removal of the account in use, and the
  /// homepage's record of the account a page was served to ([loginWithServedUser], [loginWithDocument]): a switch
  /// that loaded another account's cookie between the homepage's check and its writes saved that cookie into the row
  /// of the account the page was served to (a tap on another account's notification at a cold start). Never call one
  /// of them from inside another: the second would wait for the first forever.
  Future<T> _identityWrite<T>(Future<T> Function() action) {
    final result = _identityQueue.then((_) => action());
    _identityQueue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

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

  /// The account this device acts as, also before the stored session was verified: [currentUser], else the account
  /// named by the global [CookieProvider] or the settings, like [effectiveCurrentUid].
  ///
  /// Pages show it so users with several accounts see which one they post as (GitHub #184), also after an offline
  /// start or when the app was opened from a link before the homepage verified the session. Null when no account is in
  /// use or its username is unknown.
  UserLoginInfo? get effectiveCurrentUser {
    if (_authedUser != null) {
      return _authedUser;
    }
    final cookieUser = getIt.get<CookieProvider>().userLoginInfo;
    if (_validUid(cookieUser.uid) != null && (cookieUser.username?.isNotEmpty ?? false)) {
      return cookieUser;
    }
    final settings = getIt.get<SettingsRepository>().currentSettings;
    if (_validUid(settings.loginUid) != null && settings.loginUsername.isNotEmpty) {
      return UserLoginInfo(username: settings.loginUsername, uid: settings.loginUid);
    }
    return null;
  }

  static int? _validUid(int? uid) => uid != null && uid > 0 ? uid : null;

  /// Whether [document] is the page the forum renders for a guest: the login form without the user node.
  ///
  /// Same rule as the check-in and notification fetches.
  static bool _isGuestPage(uh.Document document) =>
      document.querySelector('form#lsform') != null && document.querySelector('div#um') == null;

  /// Authentication status stream.
  Stream<AuthStatus> get status => _controller.asBroadcastStream();

  /// The latest status of [status], the one it replays to a new listener; null before the first.
  ///
  /// A listener acting on the statuses that come after it subscribed tells the replayed one by identity: a login of
  /// the account in use again carries the same account as the replayed status (see listenLoginsOf).
  AuthStatus? get latestStatus => _controller.valueOrNull;

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
  AsyncVoidEither loginWithPassword(UserCredential credential) => AsyncVoidEither(
    () => _identityWrite(() async {
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

      // The login (`member.php`) is not a write the forum's app API answers for: sent as it is.
      final respEither = await netClient
          .postForm(_buildLoginUrl(hash.loginHash), data: credential.toFormData(hash), tsdmAppJson: false)
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
      await _beforeIdentityChange();
      _changedIdentity();
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
    }),
  );

  /// Parse logged user info from html [document].
  ///
  /// [fetchedAs] is the account whose cookie the page was asked with (the homepage passes it). The record runs under
  /// the identity lock ([_identityWrite]) and checks right before it writes that the cookie in use still names that
  /// account: when it does not (switched meanwhile), the page says nothing about the account in use now and is
  /// dropped ([IdentityChangedException]), its guest page included (it would mark the new account expired); the
  /// caller reloads for the new account. A page served to another account than [fetchedAs] (the stored row held that
  /// account's session) is recorded as that account, as it always was: the app follows the session the forum serves.
  ///
  /// [epoch] is the [identityEpoch] when the page was asked (the time of this call when not given): a page asked
  /// before a later change of the session (a login, a switch, a logout) records nothing, its guest page marks nothing,
  /// and the account a page was served to is adopted only while the session it was asked with is still the one.
  AsyncVoidEither loginWithDocument(uh.Document document, {int? fetchedAs, int? epoch}) {
    final asked = epoch ?? _identityEpoch;
    return AsyncVoidEither(
      () => _identityWrite(() => _recordServedUser(fetchedAs: fetchedAs, epoch: asked, page: document)),
    );
  }

  /// [loginWithDocument] for a page the forum's app API answered as structured fields (the homepage of plugin
  /// 2.3.0, `schema: 5`): [user] is the account the page was served to, null for a guest or the forum's message.
  /// [guest] tells the guest's page (served to nobody, or the login prompt) from any other page without an
  /// account: fetched with the cookie of the account in use, the guest's page means that session is dead (issue
  /// #25), as the guest web page does. [fetchedAs] and [epoch] as for [loginWithDocument].
  AsyncVoidEither loginWithServedUser(UserLoginInfo? user, {required bool guest, int? fetchedAs, int? epoch}) {
    final asked = epoch ?? _identityEpoch;
    return AsyncVoidEither(
      () => _identityWrite(
        () => _recordServedUser(fetchedAs: fetchedAs, epoch: asked, served: (user: user, guest: guest)),
      ),
    );
  }

  /// The record of [loginWithDocument] ([page]) or [loginWithServedUser] ([served]), under the identity lock.
  Future<Either<AppException, void>> _recordServedUser({
    required int? fetchedAs,
    required int epoch,
    uh.Document? page,
    ({UserLoginInfo? user, bool guest})? served,
  }) async {
    if (epoch != _identityEpoch) {
      warning('page asked under identity epoch $epoch, now $_identityEpoch: the session changed, nothing recorded');
      return left(IdentityChangedException());
    }
    if (_accountChangedSince(fetchedAs)) {
      return left(IdentityChangedException());
    }
    final UserLoginInfo? user;
    final bool guest;
    if (page != null) {
      // Do NOT mark as unauthenticated here because auth with document is only used as a verification of a token
      // that intend to be valid. It's outside the regular login progress.
      user = _parseUserInfoFromDocument(page);
      guest = user == null && _isGuestPage(page);
    } else {
      final complete = served?.user;
      user = complete != null && complete.uid != null && complete.username != null ? complete : null;
      guest = served?.guest ?? false;
    }
    if (user == null) {
      debug('failed to record the served user: user info not found');
      if (guest) {
        // The page was fetched with the cookie of the account in use and the forum treats it as a guest: that
        // session is dead (issue #25). The account stays in use, only its expiry is recorded.
        await markCurrentSessionExpired();
      }
      return left(LoginUserInfoNotFoundException());
    }

    if (getIt.get<CookieProvider>().userLoginInfo.uid != user.uid) {
      // Served to another account than the cookie in use names (its row held that account's session): the session
      // is that account's from now on.
      _changedIdentity();
    }
    // Here we get complete user info.
    await getIt.get<CookieProvider>().saveCookieToStorage();
    await _markAuthenticated(user);

    debug('record the served user: user $user');
    return rightVoid();
  }

  /// Whether the cookie in use names another account than [fetchedAs], the one a page was asked as (see
  /// [loginWithDocument]); false when the caller does not know. Read under the identity lock: nothing changes it
  /// between this check and the record's writes.
  bool _accountChangedSince(int? fetchedAs) {
    if (fetchedAs == null) {
      return false;
    }
    final inUse = getIt.get<CookieProvider>().userLoginInfo.uid;
    if (inUse == fetchedAs) {
      return false;
    }
    warning(
      'page asked as uid ${"$fetchedAs".obscured(4)} while the cookie in use is uid ${"$inUse".obscured(4)} now: the '
      'account changed meanwhile, nothing recorded',
    );
    return true;
  }

  /// Record in storage that the forum session of the account in use ([effectiveCurrentUid]) is dead (issue #25).
  ///
  /// For code that got the guest page with the current account's cookie and has no other way to say so; nothing
  /// happens when no account is in use. The mark is cleared by the next successful login or switch of that account.
  Future<void> markCurrentSessionExpired() async {
    final uid = effectiveCurrentUid;
    if (uid == null) {
      return;
    }
    await getIt.get<StorageProvider>().markSessionExpired(uid);
  }

  /// Logout the current user.
  ///
  /// Check authentication status first then try to logout.
  /// Do nothing if already unauthenticated.
  ///
  /// When the forum answers with the guest page (session expired, or logged out elsewhere) the saved login is removed
  /// like after a successful logout: keeping the row left the account listed as online with nothing able to remove
  /// it. Any other page without a logged user (maintenance, an unresolved interstitial) only leaves the authed state
  /// and keeps the saved login, it says nothing about the session.
  ///
  /// [uid] is the account to log out (the one a page shows), the account in use when this is called by default: a
  /// switch still running when the logout was asked must not make it log out the account switched to. When the
  /// account in use ([effectiveCurrentUid]) is another one, or none, by the time the logout runs, nothing is done
  /// ([IdentityChangedException]).
  ///
  /// The account in use is logged out also before its stored session was verified ([currentUser] still null: an
  /// offline start, a homepage that failed), as the manage accounts page offers: the forum is asked like for a
  /// verified one, and a failed request is the caller's error instead of a success with nothing done.
  AsyncVoidEither logout({int? uid}) {
    final target = uid ?? effectiveCurrentUid;
    return AsyncVoidEither(() => _identityWrite(() => _logout(target)));
  }

  Future<Either<AppException, void>> _logout(int? target) async {
    if (target == null) {
      return rightVoid();
    }
    final current = effectiveCurrentUid;
    if (current != target) {
      warning('logout of uid ${"$target".obscured(4)} asked, the account in use changed meanwhile: nothing done');
      return left(IdentityChangedException());
    }
    await _beforeIdentityChange();
    final user = effectiveCurrentUser;
    final netClient = _currentUserClientFactory(
      UserLoginInfo(username: user?.uid == target ? user?.username : null, uid: target),
    );
    // The forum's app API tells the account of the session and its form hash (`status`); the settings page is read
    // only when it does not (no plugin, a failed or busy request) or names another account.
    final String formHash;
    final served = await _statusIdentityOf(netClient);
    if (served != null && served.uid == 0) {
      info('logout: session already gone on the server (app api), remove the saved login');
      await _forgetCurrentUser();
      return rightVoid();
    }
    if (served case (:final uid, formHash: final String hash) when uid == target) {
      formHash = hash;
    } else {
      // No API, no hash, or the session of another account than the one logged out: the settings page, as before.
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
      final pageHash = _formHashRe.firstMatch(document.body?.innerHtml ?? '')?.namedGroup('FormHash');
      if (pageHash == null) {
        return left(LogoutFormHashNotFoundException());
      }
      formHash = pageHash;
    }

    final logoutRespEither = await netClient.get(_buildLogoutUrl(formHash)).run();
    if (logoutRespEither.isLeft()) {
      return left(logoutRespEither.unwrapErr());
    }
    final logoutResp = logoutRespEither.unwrap();
    if (logoutResp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(logoutResp.statusCode));
    }
    // The session is a guest's now (`status` of the forum's app API, asked with the cookies the logout left: the
    // forum deletes the auth cookie), whatever the words of the page; the words decide only without the API.
    final after = await _statusIdentityOf(netClient, waiting: true);
    if (after != null) {
      if (after.uid != 0) {
        error('logout: the session is still uid ${"${after.uid}".obscured(4)} (app api)');
        return left(LogoutFailedException());
      }
    } else {
      final logoutDocument = parseHtmlDocument(tsdmAppAnswerText(logoutResp.data));
      final logoutMessage = logoutDocument.getElementById('messagetext');
      if (logoutMessage == null || !logoutMessage.innerHtmlEx().contains('已退出')) {
        // No reason to read here: the forum names none for a logout it did not do. A form hash that does not match
        // is answered as a logout is (`logout_succeed`, `class_member.php` `on_logout()`; Discuz! X5 redirects to the
        // index) and the session is kept, which only the API above tells; anything else is not the logout's answer.
        return left(LogoutFailedException());
      }
    }

    await _forgetCurrentUser();
    return rightVoid();
  }

  /// Remove the current account from this device without telling the forum.
  ///
  /// Clears the cookie in memory, deletes the saved login and marks the app as unauthenticated; no request is sent,
  /// so it works offline and the forum session stays valid elsewhere. The account is [effectiveCurrentUid], so it
  /// also works when the stored session was never verified in this run; does nothing when no account is in use.
  ///
  /// [uid] is the account to remove, the account in use when this is called by default: when the account in use is
  /// another one by the time the removal runs (a switch was still running), nothing is removed
  /// ([IdentityChangedException]).
  AsyncVoidEither forgetCurrentUser({int? uid}) {
    final target = uid ?? effectiveCurrentUid;
    return AsyncVoidEither(
      () => _identityWrite(() async {
        final current = effectiveCurrentUid;
        if (target == null || current == null) {
          return rightVoid();
        }
        if (current != target) {
          warning('removal of uid ${"$target".obscured(4)} asked, the account in use changed meanwhile: nothing done');
          return left(IdentityChangedException());
        }
        await _forgetCurrentUser();
        return rightVoid();
      }),
    );
  }

  Future<void> _forgetCurrentUser() async {
    await _beforeIdentityChange();
    _changedIdentity();
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
  ///
  /// Runs under the identity lock ([_identityWrite]) from the check to the commit: a page of the previous account
  /// recorded meanwhile could otherwise write the new account's cookie into its row.
  AsyncVoidEither switchUser(UserLoginInfo userInfo) => AsyncVoidEither(
    () => _identityWrite(() async {
      final candidate = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
      if (!await candidate.loadCookieFromStorage(userInfo)) {
        return left(LoginInvalidCredentialException());
      }
      // Validate with an isolated session; failures must leave the active account untouched.
      final client = _clientFactory(candidate);
      // The forum's app API tells the account of the session (`status`, no name: the saved one is kept); the settings
      // page is read when it does not (no plugin, a failed or busy request), or when the saved login has no name.
      final UserLoginInfo? parsedUserInfo;
      final bool guest;
      final served = await _statusIdentityOf(client);
      final savedName = userInfo.username;
      if (served != null && (served.uid != userInfo.uid || (savedName != null && savedName.isNotEmpty))) {
        parsedUserInfo = served.uid == userInfo.uid ? UserLoginInfo(username: savedName, uid: served.uid) : null;
        guest = served.uid == 0;
      } else {
        final resp = await client.get(_checkAuthUrl).run();
        if (resp.isLeft()) {
          return left(resp.unwrapErr());
        }
        if (resp.unwrap().statusCode != HttpStatus.ok) {
          return left(HttpRequestFailedException(resp.unwrap().statusCode));
        }

        final document = parseHtmlDocument(resp.unwrap().data as String);
        parsedUserInfo = _parseUserInfoFromDocument(document);
        guest = parsedUserInfo == null && _isGuestPage(document);
      }
      if (parsedUserInfo == null || parsedUserInfo.uid != userInfo.uid) {
        error(
          'failed to switch user to uid=${"${userInfo.uid}".obscured(4)}, '
          'parsed uid=${"${parsedUserInfo?.uid}".obscured(4)}',
        );
        if (parsedUserInfo == null && userInfo.uid != null && guest) {
          // The stored cookie of that account is dead: remember it (issue #25), the current account is untouched.
          // Only while its row holds the session checked: another one stored meanwhile says nothing of it.
          await getIt.get<StorageProvider>().markSessionExpiredIfHeld(userInfo.uid!, session: candidate.session);
        }
        return left(SwitchUserNotAuthedException());
      }

      // Commit the verified session before notifying authentication subscribers. Only into the row it was loaded
      // from: the manage accounts page removes another account without waiting for the switch, and a row removed
      // while it was checked must not come back. Nothing switched then, the account in use stays.
      if (!await candidate.saveCookieToStoredRow()) {
        warning('switch to uid ${"${userInfo.uid}".obscured(4)}: its saved login was removed meanwhile');
        return left(LoginInvalidCredentialException());
      }
      await _beforeIdentityChange();
      _changedIdentity();
      if (!await getIt.get<CookieProvider>().loadCookieFromStorage(parsedUserInfo)) {
        return left(LoginInvalidCredentialException());
      }
      await _markAuthenticated(parsedUserInfo);

      debug('login with document: user $userInfo');
      return rightVoid();
    }),
  );

  /// The account the forum's app API says the session of [netClient] is (`status`: its `uid`, 0 for a guest) with the
  /// session's form hash (null when it names none); null when the API does not tell (no plugin, a failed request, an
  /// answer "too soon", one without a uid).
  ///
  /// [waiting] waits for an answer "too soon" ([TsdmAppApi.askWaiting]): the plugin takes one `status` per session
  /// every few seconds, and the logout asks it again right after.
  static Future<({int uid, String? formHash})?> _statusIdentityOf(
    NetClientProvider netClient, {
    bool waiting = false,
  }) async {
    final status = waiting
        ? await TsdmAppApi.askWaiting(netClient, 'status')
        : await TsdmAppApi.ask(netClient, 'status');
    if (status == null || status['ok'] != 1) {
      return null;
    }
    final uid = switch (status['uid']) {
      final int n => n,
      final String text => int.tryParse(text),
      _ => null,
    };
    if (uid == null || uid < 0) {
      return null;
    }
    final hash = status['formhash'];
    return (uid: uid, formHash: hash is String && _statusFormHashRe.hasMatch(hash) ? hash : null);
  }

  static final _statusFormHashRe = RegExp(r'^\w+$');

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
    // The session was just verified: forget an expiry recorded earlier for this account (issue #25).
    await getIt.get<StorageProvider>().clearSessionExpired(userInfo.uid!);
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
    _changedIdentity();
    final settings = getIt.get<SettingsRepository>();
    await settings.deleteValue(SettingsKeys.loginUsername);
    await settings.deleteValue(SettingsKeys.loginUid);
    await settings.deleteValue(SettingsKeys.loginEmail);
    _authedUser = null;
    _controller.add(const AuthStatusNotAuthed());
  }
}
