import 'dart:convert';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Cookie names the server uses as a per-session flag and the app must never keep.
///
/// Discuz! sets `<prefix>_nofavfid=1` (one year) when a session first lists the forum index while the account has no
/// favorite forums, and then skips the "我收藏的版块" panel for that session as long as the cookie is there. It is
/// only cleared for the session that adds a favorite, so a favorite added in the browser stayed invisible to the app
/// until a new login (issue #1). Without the flag the server simply queries the favorites on every index page.
const serverFlagCookieSuffixes = ['_nofavfid'];

bool _isServerFlagCookie(String name) => serverFlagCookieSuffixes.any(name.endsWith);

Object? _stripServerFlagsInJson(Object? node) {
  if (node is Map) {
    final out = <String, Object?>{};
    for (final entry in node.entries) {
      final key = '${entry.key}';
      if (_isServerFlagCookie(key)) {
        continue;
      }
      out[key] = _stripServerFlagsInJson(entry.value);
    }
    return out;
  }
  if (node is List) {
    return node.map(_stripServerFlagsInJson).toList();
  }
  return node;
}

/// Remove the server flag cookies (see [serverFlagCookieSuffixes]) from a persisted cookie jar map.
///
/// Values are the JSON documents `cookie_jar` stores per key (domain -> path -> name -> cookie), names are map keys,
/// so they are removed at any depth; values that are not JSON objects are kept as they are.
Map<String, String> stripServerFlagCookies(Map<String, String> cookieMap) {
  final out = <String, String>{};
  for (final entry in cookieMap.entries) {
    if (_isServerFlagCookie(entry.key)) {
      continue;
    }
    var value = entry.value;
    if (value.contains('_nofavfid')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          value = jsonEncode(_stripServerFlagsInJson(decoded));
        }
      } on FormatException {
        // Not JSON, keep as is.
      }
    }
    out[entry.key] = value;
  }
  return out;
}

/// Manage cookie in http requests.
///
/// Provides ability to read/write cookie in storage, also keeps the current
/// user's info and cookie in memory.
final class CookieProvider with LoggerMixin implements Storage {
  /// Constructor.
  CookieProvider(this._userLoginInfo, this._cookieMap);

  /// Build a [CookieProvider].
  ///
  /// Load current user's info and cookie from settings and storage.
  factory CookieProvider.build() {
    final settings = getIt.get<SettingsRepository>().currentSettings;
    final loggedUid = settings.loginUid;
    final userInfo = UserLoginInfo(
      username: settings.loginUsername,
      uid: loggedUid,
      // email: settings.loginEmail,
    );
    // Valid uid > 0.
    if (loggedUid <= 0) {
      talker.warning('load empty cookie');
      return CookieProvider(userInfo, {});
    }

    talker.debug(
      'load cookie from database with login user '
      'uid: ${"$loggedUid".obscured(4)}',
    );
    // Has user login before, load cookie.
    final databaseCookie = getIt.get<StorageProvider>().getCookieByUidSync(loggedUid);
    if (databaseCookie == null) {
      talker.error(
        'failed to init cookie: current login user '
        'id not found in database',
      );
      return CookieProvider(userInfo, {});
    }

    // Loaded from a row like [loadCookieFromStorage]: must not bring the row back once the account was removed.
    return CookieProvider(userInfo, stripServerFlagCookies(Map.castFrom(databaseCookie))).._mirrorsStoredRow = true;
  }

  /// Construct a instance with no preload cookie or user info
  factory CookieProvider.buildEmpty() => CookieProvider(UserLoginInfo.empty(), {});

  /// Cookie data.
  Map<String, String> _cookieMap;

  /// Info of the user currently login.
  UserLoginInfo _userLoginInfo;

  /// Whether [_cookieMap] mirrors a row of the cookie table, loaded through [loadCookieFromStorage],
  /// [loadCookieFromDatabase] or [CookieProvider.build], or stored by this provider.
  ///
  /// Such a provider must not bring its row back once the user removed the account, nor write its session back over
  /// another one stored since (a login with the password, of the same account too): the per-account clients of auto
  /// check-in and of the sync of all accounts keep running after a removal on the manage accounts page or a new
  /// login, the global provider keeps serving the current account while the new login is stored, and every
  /// `Set-Cookie` they receive lands in [_syncCookie]. A provider that got its identity from a login
  /// ([updateUserInfo]) still creates its row, and mirrors it from then on.
  bool _mirrorsStoredRow = false;

  /// Bumped whenever this provider starts holding another session: a stored row loaded ([loadCookieFromStorage],
  /// [loadCookieFromDatabase]), the cookies cleared ([clearUserInfoAndCookie]).
  ///
  /// A request of a client built on this provider (`NetClientProvider.build`) reads and saves its cookies, and its
  /// answer is taken, only while the provider still holds the session it was sent with: after a new login of the same
  /// account (with the password, or the switch's check) a request of the previous session answered late must not
  /// write that session over the new one, here and in the stored row. The account alone ([userLoginInfo]) did not
  /// tell. The next requests of the client send the new session.
  int _generation = 0;

  /// The session generation of this provider, see [_generation].
  int get generation => _generation;

  /// The forum session this provider holds ([cookieSessionOf]), the one its requests are sent with.
  String? get session => cookieSessionOf(_cookieMap);

  /// Info of the user this cookie belongs to.
  UserLoginInfo get userLoginInfo => _userLoginInfo;

  /// Update current recorded user info.
  Future<void> updateUserInfo(UserLoginInfo userInfo) async {
    debug('update user info: $userInfo');
    _userLoginInfo = userInfo;
    _mirrorsStoredRow = false;
    if (_userLoginInfo.isComplete) {
      debug('complete user info updated, sync cookie');
      await _syncCookie(held: session);
    }
  }

  /// Load cookie of [userInfo] from storage.
  ///
  /// Return false if any error occurred.
  Future<bool> loadCookieFromStorage(UserLoginInfo userInfo) async {
    final username = userInfo.username;
    final uid = userInfo.uid;
    if (username == null && uid == null) {
      error('failed to switch cookie: invalid user info');
      return false;
    }

    Map<String, dynamic>? databaseCookie;

    final storage = getIt.get<StorageProvider>();

    if (uid != null) {
      info(
        'load cookie from database with given '
        'uid: ${"$uid".obscured(4)}',
      );
      databaseCookie = storage.getCookieByUidSync(uid);
    } else if (username != null) {
      info(
        'load cookie from database with given '
        'username: ${username.obscured()}',
      );
      databaseCookie = storage.getCookieByUsernameSync(username);
      // } else if (email != null) {
      //   databaseCookie = storage.getCookieByEmailSync(email);
    }

    if (databaseCookie == null) {
      error('failed to switch cookie: cookie not found in database');
      return false;
    }
    debug('cookie switch to user $userInfo');
    _userLoginInfo = userInfo;
    _cookieMap = stripServerFlagCookies(Map.castFrom(databaseCookie));
    _mirrorsStoredRow = true;
    _generation++;
    return true;
  }

  /// [loadCookieFromStorage] for [userInfo] (its uid) read from the database instead of the cache of the storage
  /// provider, see `StorageProvider.fetchCookieOfUid`.
  Future<bool> loadCookieFromDatabase(UserLoginInfo userInfo) async {
    final uid = userInfo.uid;
    if (uid == null) {
      error('failed to load cookie from database: no uid');
      return false;
    }
    final databaseCookie = await getIt.get<StorageProvider>().fetchCookieOfUid(uid);
    if (databaseCookie == null) {
      error('failed to load cookie from database: uid ${"$uid".obscured(4)} not found');
      return false;
    }
    _userLoginInfo = userInfo;
    _cookieMap = stripServerFlagCookies(Map.castFrom(databaseCookie));
    _mirrorsStoredRow = true;
    _generation++;
    return true;
  }

  /// Save current user's info and cookie to storage.
  Future<void> saveCookieToStorage() async {
    if (!_userLoginInfo.isComplete) {
      warning('can not save user info incomplete cookie to storage');
      return;
    }
    debug('save authed cookie to storage');
    await getIt.get<StorageProvider>().saveCookie(
      username: _userLoginInfo.username!,
      uid: _userLoginInfo.uid!,
      cookie: _cookieMap,
    );
  }

  /// [saveCookieToStorage] for a provider loaded from a stored row ([loadCookieFromStorage]): only while the row still
  /// holds the session this provider holds ([StorageProvider.saveCookieOfSession]). False when the account was removed
  /// meanwhile (its row must not come back) or another session of it was stored.
  Future<bool> saveCookieToStoredRow() async {
    if (!_userLoginInfo.isComplete) {
      warning('can not save user info incomplete cookie to storage');
      return false;
    }
    final storage = getIt.get<StorageProvider>();
    if (session == null) {
      // No session to compare (only a cookie with the auth cookie reaches the database): as [saveCookieToStorage],
      // while the account is still stored.
      if (storage.getCookieByUidSync(_userLoginInfo.uid!) == null) {
        return false;
      }
      await saveCookieToStorage();
      return true;
    }
    return storage.saveCookieOfSession(
      username: _userLoginInfo.username!,
      uid: _userLoginInfo.uid!,
      cookie: _cookieMap,
      session: session,
    );
  }

  /// Delete current login user info and cookie from memory and database.
  void clearUserInfoAndCookie() {
    debug('clear user info and cookie');
    _userLoginInfo = const UserLoginInfo(username: null, uid: null);
    _cookieMap = {};
    _mirrorsStoredRow = false;
    _generation++;
  }

  /// Save cookie in database.
  ///
  /// This function is private because saving a cookie should only be triggered
  /// by web request update.
  /// This function should be called every time after cookie value updated.
  /// If user info still incomplete, do not save to database, which shall not
  /// happen.
  ///
  /// Return false if user info is incomplete.
  ///
  /// [held] is the session this provider held before the change ([session]): a provider mirroring a stored row writes
  /// into it only while the row still holds that session ([StorageProvider.saveCookieOfSession]).
  Future<bool> _syncCookie({required String? held}) async {
    // Do not save cookie if we don't know which user it belongs to.
    // This shall not happen.
    if (!_userLoginInfo.isComplete) {
      info('only save cookie in memory: user info incomplete: $_userLoginInfo');
      return false;
    }

    // Only save authed cookie into storage.
    if (!_cookieMap.values.any((e) => e.contains('${cookiePrefix}_auth'))) {
      return false;
    }

    final storage = getIt.get<StorageProvider>();
    if (_mirrorsStoredRow) {
      // The account was removed after this provider loaded it, or another session of it was stored since (a login
      // with the password): keep the cookie in memory for the request in flight but neither recreate the row nor
      // write the previous session over the new one.
      final saved = await storage.saveCookieOfSession(
        username: _userLoginInfo.username!,
        uid: _userLoginInfo.uid!,
        cookie: _cookieMap,
        session: held,
      );
      if (!saved) {
        info(
          'account ${"${_userLoginInfo.uid}".obscured(4)} was removed or holds another session now, only keep cookie '
          'in memory',
        );
      }
      return saved;
    }

    await storage.saveCookie(
      username: _userLoginInfo.username!,
      uid: _userLoginInfo.uid!,
      cookie: _cookieMap,
    );
    // The row holds this session now: what the forum renews in it later is written back only while it still does.
    // The window between storing a new login and loading it into the global provider is covered too: an answer of
    // the previous session landing then is not written over the new one.
    _mirrorsStoredRow = true;

    return true;
  }

  /// Delete current user [_userLoginInfo]'s cookie from database.
  ///
  /// Return false if delete failed (maybe user not found in database) or
  /// missing
  /// user info.
  /// Return true is success.
  Future<bool> _deleteUserCookie() async {
    if (!_userLoginInfo.isComplete) {
      info(
        'refuse to delete single user cookie from database: '
        'user info incomplete',
      );
      return false;
    }

    debug('CookieData $hashCode: delete cookie for uid: $_userLoginInfo');
    await getIt.get<StorageProvider>().deleteCookieByUserInfo(_userLoginInfo);
    return true;
  }

  // TODO: Try set webpage style in cookie.
  /// To parse web page correctly, set a certain web page style id here.
  ///
  /// The main difference between web page styles are homepage layout.
  ///
  /// ```console
  /// name    id     avatar   forum-info-layout
  /// 水晶     4    no avatar  <dd> <em> <font>主题</font> <font>123</font> </em> </dd>
  /// 爱丽丝   5       avatar  <dd> <em>主题</em> , <em>123></em> </dd>
  /// 羽翼     6    no avatar  Same with style 4
  /// 旅行者   13      avatar  Same with style 5
  /// 自由之翼 12      avatar  Same with style 5
  /// ```
  void _setupWebPageStyle() {}

  @override
  Future<void> delete(String key) async {
    final held = session;
    _cookieMap.remove(key);
    // If user cookie is empty, delete that item from database.
    if (_cookieMap.isEmpty) {
      debug(
        'delete user ($_userLoginInfo) cookie from database '
        'because cookie value is empty',
      );
      await _deleteUserCookie();
    } else {
      await _syncCookie(held: held);
    }
  }

  /// Remove every cookie whose name [test] accepts from what this provider holds (the JSON documents of the jar:
  /// domain, path, name, or path, name for a host-only cookie), and store the rest; nothing is stored when none
  /// matched. The jars built from now on read what is left.
  Future<void> dropCookiesWhere(bool Function(String name) test) async {
    final held = session;
    var changed = false;
    Object? strip(Object? node) {
      if (node is Map) {
        final out = <String, Object?>{};
        for (final entry in node.entries) {
          final key = '${entry.key}';
          // A cookie is a name and its serialized value, under its path (and domain).
          if (entry.value is String && test(key)) {
            changed = true;
            continue;
          }
          out[key] = strip(entry.value);
        }
        return out;
      }
      return node;
    }

    final out = <String, String>{};
    for (final MapEntry(:key, :value) in _cookieMap.entries) {
      try {
        final decoded = jsonDecode(value);
        out[key] = decoded is Map ? jsonEncode(strip(decoded)) : value;
      } on FormatException {
        out[key] = value;
      }
    }
    if (!changed) {
      return;
    }
    _cookieMap = out;
    await _syncCookie(held: held);
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    _cookieMap.clear();
    await _deleteUserCookie();
  }

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) async {
    _setupWebPageStyle();
    return _cookieMap[key];
  }

  @override
  Future<void> write(String key, String value) async {
    // Do not update authed cookie with not authed one.
    //
    // TODO: Key is always ".domains" or ".index"
    if ((_cookieMap[key]?.contains('${cookiePrefix}_auth') ?? false) && !value.contains('${cookiePrefix}_auth')) {
      return;
    }
    final held = session;
    _cookieMap[key] = value;
    if (value.contains('_nofavfid')) {
      _cookieMap = stripServerFlagCookies(_cookieMap);
    }
    await _syncCookie(held: held);

    // Check points changes events.
    if (key == '.domains') {
      // The following code are not used because we do it in `NetClientProvider` interceptors.
      //
      // Here is the storage layer of the cookie where it's hard to know the response state and also not possible to
      // tell the difference between all these requests, make it impossible to combine the action result message we used
      // before and the points changes together.
      //
      // // The value of ".domains" is expected to be:
      // //
      // // "$DOMAIN": {
      // //     "$PATH": {
      // //         "$COOKIE_NAME": "$COOKIE_VALUE",
      // //     }
      // // }
      // Option.fromPredicate(jsonDecode(value), (v) => v is Map<String, dynamic>)
      //     .map((x) => x as Map<String, dynamic>)
      //     // Assume only one domain.
      //     .flatMap((x) => x.values.firstOption)
      //     .filterMap((x) => x is Map<String, dynamic> ? Option.fromNullable(x.values.firstOrNull) : const None())
      //     // Assume only one path.
      //     .filterMap((x) => x is Map<String, dynamic> ? Option.of(x) : const None())
      //     // Here we get all cookie pairs.
      //     .filterMap((x) => x.containsKey(_creditNotice) ? Option.of(x[_creditNotice]) : const None())
      //     .filterMap((x) => x is String ? Option.of(_creditNoticeRe.firstMatch(x)) : const None())
      //     .filterMap((x) => x != null ? Option.of(x.namedGroup('value')) : const None())
      //     // Add to cookie stream.
      //     .map((v) => pointsChangesStream.add(v!));
    }
  }

  @override
  String toString() {
    return 'CookieProvider{ userInfo=$_userLoginInfo, cookie=*** }';
  }
}
