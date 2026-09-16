import 'dart:async';
import 'dart:convert';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  /// Whether [_cookieMap] mirrors a row of the cookie table, loaded through [loadCookieFromStorage] or
  /// [CookieProvider.build].
  ///
  /// Such a provider must not bring its row back once the user removed the account: the per-account clients of auto
  /// check-in keep running after a removal on the manage accounts page, the global provider keeps serving the
  /// current account until its session is verified, and every `Set-Cookie` they receive lands in [_syncCookie]. A
  /// provider that got its identity from a login ([updateUserInfo]) still creates its row.
  bool _mirrorsStoredRow = false;

  /// Info of the user this cookie belongs to.
  UserLoginInfo get userLoginInfo => _userLoginInfo;

  /// Update current recorded user info.
  Future<void> updateUserInfo(UserLoginInfo userInfo) async {
    debug('update user info: $userInfo');
    _userLoginInfo = userInfo;
    _mirrorsStoredRow = false;
    if (_userLoginInfo.isComplete) {
      debug('complete user info updated, sync cookie');
      await _syncCookie();
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

  /// Delete current login user info and cookie from memory and database.
  ///
  /// 同时清理该账号在 SharedPreferences 里留下的"背景身份"副本。
  /// 因为这是登出/移除账号的必经之路，用户下次不再使用此账号时，
  /// 后台服务不应该再读到此账号的 cookie 和 uid。
  void clearUserInfoAndCookie() {
    debug('clear user info and cookie');
    final oldUid = _userLoginInfo.uid;
    _userLoginInfo = const UserLoginInfo(username: null, uid: null);
    _cookieMap = {};
    _mirrorsStoredRow = false;

    if (oldUid != null && oldUid > 0) {
      // 不阻塞同步方法：清理失败也只是留下一个孤儿键，后台服务在
      // 下次读到 uid 时会检查 cookie 是否还存在。
      unawaited(_clearBackgroundKeysForUser(oldUid));
    }
  }

  /// 清掉指定 uid 在 SharedPreferences 里留下的背景身份副本。
  ///
  /// 只在 `background_login_uid` 正好指向该 uid 时才清，避免误删
  /// 其他账号留下的数据。
  Future<void> _clearBackgroundKeysForUser(int uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentBgUid = prefs.getInt('background_login_uid');
      if (currentBgUid == uid) {
        await prefs.remove('background_login_uid');
        await prefs.remove('background_cookie_$uid');
        await prefs.remove('background_last_fetch_time_$uid');
      }
    } on Object catch (_) {
      // 插件不可用或写入失败，忽略。
    }
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
  Future<bool> _syncCookie() async {
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
    if (_mirrorsStoredRow && storage.getCookieByUidSync(_userLoginInfo.uid!) == null) {
      // The account was removed after this provider loaded it: keep the cookie in memory for the request in flight
      // but do not recreate the row.
      info('account ${"${_userLoginInfo.uid}".obscured(4)} was removed, only keep cookie in memory');
      return false;
    }

    await storage.saveCookie(
      username: _userLoginInfo.username!,
      uid: _userLoginInfo.uid!,
      cookie: _cookieMap,
    );

    // 把 Cookie 和 uid 同步到 SharedPreferences，供后台服务读取。
    //
    // 关键：只有当前登录账号才写这些键。多账号场景下（自动签到、
    // 同步所有账号）会创建临时 CookieProvider 去抓取别的账号，
    // 它们的 _syncCookie 也会跑，如果无差别写入，后台服务读到的
    // 就会是"最后一个跑过 _syncCookie 的账号"，而不是用户当前登录
    // 的那个账号。
    try {
      final settings = getIt.get<SettingsRepository>().currentSettings;
      if (settings.loginUid > 0 && settings.loginUid == _userLoginInfo.uid) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'background_cookie_${_userLoginInfo.uid}',
          jsonEncode(_cookieMap),
        );
        await prefs.setInt('background_login_uid', _userLoginInfo.uid!);
      }
    } on Object catch (_) {
      // 插件不可用（测试环境）或 settings 读取失败，忽略。
    }

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
    _cookieMap.remove(key);
    // If user cookie is empty, delete that item from database.
    if (_cookieMap.isEmpty) {
      debug(
        'delete user ($_userLoginInfo) cookie from database '
        'because cookie value is empty',
      );
      await _deleteUserCookie();
    } else {
      await _syncCookie();
    }
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
    _cookieMap[key] = value;
    if (value.contains('_nofavfid')) {
      _cookieMap = stripServerFlagCookies(_cookieMap);
    }
    await _syncCookie();
  }

  @override
  String toString() {
    return 'CookieProvider{ userInfo=$_userLoginInfo, cookie=*** }';
  }
}
