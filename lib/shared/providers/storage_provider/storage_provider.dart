import 'dart:convert';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
// Only for unwrapping the sqlite error that the database isolate sends back, see `isDatabaseBusy`.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:flutter/foundation.dart' show setEquals, visibleForTesting;
import 'package:fpdart/fpdart.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/notification_type.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/dao/dao.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/utils/logger.dart';

/// A time to fetch notice or save notice.
///
/// Use this model to gather different types of notice, so that makes calling
/// APIs less times.
final class NotificationGroup {
  /// Constructor.
  const NotificationGroup({
    required this.noticeList,
    required this.personalMessageList,
    required this.broadcastMessageList,
  });

  /// All fetched notice.
  final List<NoticeEntity> noticeList;

  /// All fetched personal message.
  final List<PersonalMessageEntity> personalMessageList;

  /// All fetched broadcast message.
  final List<BroadcastMessageEntity> broadcastMessageList;
}

/// One account saved on this device with what the app knows about it, for pages listing every account.
///
/// `lastCheckin` is when it last checked in from this device (null when never); `sessionExpiredAt` is when the app
/// last learned that its forum session is dead (null while nothing is known, see [StorageProvider.markSessionExpired]).
typedef StoredAccount = ({UserLoginInfo user, DateTime? lastCheckin, DateTime? sessionExpiredAt});

final _authCookieRe = RegExp('${cookiePrefix}_auth=([^;"\\\\\\s]*)');

/// The forum session [cookie] (a cookie jar map, as stored per account) holds: the value of its auth cookie
/// (`<prefix>_auth`), every distinct one when several hosts hold one; null when it has none.
///
/// A login with the password (also of the same account) stores another one; the forum renewing the other cookies
/// of the session (`lastact`, `sid`) leaves it as it is. A cookie provider loaded from a stored row writes back into
/// it, and records its session expired, only while the row still holds the session the provider holds
/// ([StorageProvider.saveCookieOfSession], [StorageProvider.markSessionExpiredIfHeld]): a request of the previous
/// session answered after the new login must not bring that session back.
String? cookieSessionOf(Map<String, dynamic>? cookie) {
  if (cookie == null) {
    return null;
  }
  final tokens = <String>{
    for (final value in cookie.values)
      for (final m in _authCookieRe.allMatches('$value')) m[1]!,
  };
  return tokens.isEmpty ? null : (tokens.toList()..sort()).join(',');
}

/// Load all cookie info from database without any dependency except [db].
///
/// Only use this function to preload cookie before initializing
/// [StorageProvider].
Future<Map<UserLoginInfo, Cookie>> preloadCookie(AppDatabase db) async {
  final allCookie = await CookieDao(db).selectAll();
  final mappedCookie = allCookie.map(
    (e) => MapEntry(
      UserLoginInfo(
        username: e.username,
        uid: e.uid,
        // email: e.email,
      ),
      jsonDecode(e.cookie) as Map<String, dynamic>,
    ),
  );

  return Map.fromEntries(mappedCookie);
}

/// Load all image cache info from database without any dependency except [db].
///
/// Only use this function to preload cookie before initializing
/// [StorageProvider].
Future<Map<String, ImageEntity>> preloadImageCache(AppDatabase db) async {
  final allImageCache = await ImageDao(db).selectAll();
  final mappedImageCache = allImageCache.map((e) => MapEntry(e.url, e));
  return Map.fromEntries(mappedImageCache);
}

/// [StorageProvider] should be used by other providers.
class StorageProvider with LoggerMixin {
  /// Constructor.
  StorageProvider(this._db, this._cookieCache, this._imageCache);

  /// Reload the cookie cache from the database.
  ///
  /// The cache is filled once at start and kept in sync by this provider's own writes. Another isolate on the same
  /// database (the Android background message service) never sees the app's logins and logouts otherwise (#80).
  Future<void> refreshCookieCache() async {
    final fresh = await preloadCookie(_db);
    _cookieCache
      ..clear()
      ..addAll(fresh);
  }

  /// Injected database
  final AppDatabase _db;

  /// All cookie cached in memory.
  ///
  /// Read cache to avoid disk IO and make it synchronous.
  ///
  /// MUST update during cookie setter calls.
  final Map<UserLoginInfo, Cookie> _cookieCache;

  /// All image cache cached in memory.
  ///
  /// Access this field to avoid disk IO and make it synchronous.
  ///
  /// MUST update during image cache setter calls.
  Map<String, ImageEntity> _imageCache;

  /// Get the stream of all users in storage.
  Stream<List<UserLoginInfo>> allUsersStream() {
    return CookieDao(
      _db,
    ).watchAll().map((e) => e.map((entity) => UserLoginInfo(username: entity.username, uid: entity.uid)).toList());
  }

  /// Get the stream of all users in storage together with the time of their last check-in.
  ///
  /// Emits again whenever the cookie table changes, including [updateLastCheckinTime], so a page showing the
  /// check-in state of every account stays current while auto check-in runs.
  Stream<List<(UserLoginInfo, DateTime?)>> allUsersWithTimeStream() {
    return CookieDao(_db).watchAll().map(
      (e) =>
          e.map((entity) => (UserLoginInfo(username: entity.username, uid: entity.uid), entity.lastCheckin)).toList(),
    );
  }

  /// Get the stream of every account in storage with its last check-in and session expiry state.
  ///
  /// Emits again whenever the cookie table changes ([updateLastCheckinTime], [markSessionExpired], a login...), so
  /// the manage accounts page stays current.
  Stream<List<StoredAccount>> allAccountsStream() {
    return CookieDao(_db).watchAll().map(
      (e) => e
          .map(
            (entity) => (
              user: UserLoginInfo(username: entity.username, uid: entity.uid),
              lastCheckin: entity.lastCheckin,
              sessionExpiredAt: entity.sessionExpiredAt,
            ),
          )
          .toList(),
    );
  }

  /*             User             */

  /// Get all recorded login user.
  ///
  /// Those users are the ones ever login before.
  Future<List<UserLoginInfo>> getAllUsers() async {
    final cookies = await CookieDao(_db).selectAll();

    return cookies.map((e) => UserLoginInfo(username: e.username, uid: e.uid)).toList();
  }

  /// Get all recorded login user with datetime of last checkin.
  ///
  /// Last checkin time is in milliseconds level.
  Future<List<(UserLoginInfo, DateTime?)>> getAllUsersWithTime() async {
    final cookies = await CookieDao(_db).selectAll();

    return cookies.map((e) => (UserLoginInfo(username: e.username, uid: e.uid), e.lastCheckin)).toList();
  }

  /// Delete the user login info for the user specified by [uid], with the local marks and the offline thread pages of
  /// the account.
  Future<int> deleteUserLoginInfo(int uid) async {
    _wroteCookieOf(uid);
    // As every removal: a client of the account must not find its cookie in the cache any more.
    _cookieCache.removeWhere((e, _) => e.uid == uid);
    final deleted = await CookieDao(_db).deleteCookieByUid(uid);
    await _deleteAccountMarks(uid);
    return deleted;
  }

  /// Settings name of the time account [uid] was last polled for notifications (`NotificationPollSlot`).
  static String notificationPolledAtKey(int uid) => 'notificationPolledAt.$uid';

  /// Settings name of the time account [uid] was last polled by the sync of all accounts the user asked for
  /// (`NotificationPollSlot.takeForManualSync`).
  static String notificationPolledManuallyAtKey(int uid) => 'notificationPolledManuallyAt.$uid';

  /// How many times the cookie of each uid was saved or removed through this provider: a read of its row that one of
  /// them overtook does not put what it read into the cache ([fetchCookieOfUid]).
  final _cookieWrites = <int, int>{};

  void _wroteCookieOf(int uid) {
    _cookieWrites[uid] = (_cookieWrites[uid] ?? 0) + 1;
  }

  /// Delete the local marks of account [uid] removed from this device: the threads it replied to, its offline thread
  /// pages and the times it was polled for notifications.
  Future<void> _deleteAccountMarks(int uid) async {
    _wroteCookieOf(uid);
    await RepliedThreadDao(_db).deleteByUid(uid);
    await OfflineThreadDao(_db).deleteByUid(uid);
    final settings = SettingsDao(_db);
    await settings.deleteByName(notificationPolledAtKey(uid));
    await settings.deleteByName(notificationPolledManuallyAtKey(uid));
  }

  /*             cookie             */

  /// Whether the account [uid] is still stored on this device, read from the database, not the cache.
  ///
  /// The cache only follows this provider's own writes. Another isolate on the same database (the app while the
  /// Android background message service fetches, #80) removes an account without this provider noticing.
  Future<bool> hasCookieOfUid(int uid) async => await CookieDao(_db).selectCookieByUid(uid) != null;

  /// The [Cookie] of [uid] read from the database, not the cache; null when the account is not stored.
  ///
  /// For a caller that must see what another isolate on the same database wrote (the Android background message
  /// service renews the cookies of the accounts it polls) without reloading the whole cache of this provider. The
  /// cache entry of [uid] is brought in line with the row (dropped when the row is gone): the account switch and the
  /// cookie provider's check for a removed account ([getCookieByUidSync]) see what was read.
  ///
  /// The cookie saved or removed through this provider while the row was read (a login with the password stored a
  /// new session of the account, the account was removed): what the cache holds since, newer than the row read, which
  /// stays out of the cache; null when removed.
  Future<Cookie?> fetchCookieOfUid(int uid) async {
    final writes = _cookieWrites[uid] ?? 0;
    final row = await CookieDao(_db).selectCookieByUid(uid);
    if ((_cookieWrites[uid] ?? 0) != writes) {
      return getCookieByUidSync(uid);
    }
    _cookieCache.removeWhere((e, _) => e.uid == uid);
    if (row == null) {
      return null;
    }
    final cookie = jsonDecode(row.cookie) as Map<String, dynamic>;
    _cookieCache[UserLoginInfo(username: row.username, uid: row.uid)] = cookie;
    return cookie;
  }

  /// Get [Cookie] with [uid] from cookie cached saved in memory.
  ///
  /// Return null if not found.
  ///
  /// Generally the cookie cache is synced with database cookie values.
  /// So may not need to use the async version API to retry to read.
  Cookie? getCookieByUidSync(int uid) {
    return _cookieCache.entries.firstWhereOrNull((e) => e.key.uid == uid)?.value;
  }

  /// Get [Cookie] with [username] from cookie cached saved in memory.
  ///
  /// Return null if not found.
  ///
  /// Generally the cookie cache is synced with database cookie values.
  /// So may not need to use the async version API to retry to read.
  Cookie? getCookieByUsernameSync(String username) {
    return _cookieCache.entries.firstWhereOrNull((e) => e.key.username == username)?.value;
  }

  /// Get [Cookie] with [email] from cookie cached saved in memory.
  ///
  /// Return null if not found.
  ///
  /// Generally the cookie cache is synced with database cookie values.
  /// So may not need to use the async version API to retry to read.
  @Deprecated('email APIs are deprecated when migrate to v1')
  Cookie? getCookieByEmailSync(String email) {
    return null;
    // return _cookieCache.entries
    //     .firstWhereOrNull((e) => e.key.email == email)
    //     ?.value;
  }

  /// Save cookie with completed user info.
  ///
  /// Required full user info and save by [uid] so that we handled some extreme
  /// situation when username or email changed.
  ///
  /// Stored as it is, whatever the row holds: for a session the app takes as the account's own (a login, the switch's
  /// check, the session a page was served to). A cookie provider writing back what the forum renewed in the session it
  /// loaded uses [saveCookieOfSession].
  Future<void> saveCookie({required String username, required int uid, required Cookie cookie}) async {
    _wroteCookieOf(uid);
    final allCookie = getCookieByUidSync(uid) ?? <String, dynamic>{};

    // Combine two map together, do not directly use [cookie].
    // ignore: cascade_invocations
    allCookie.addAll(Map.castFrom<String, dynamic, String, String>(cookie));
    // Update cookie cache.
    final userInfo = UserLoginInfo(username: username, uid: uid /*, email: email*/);
    _cookieCache[userInfo] = allCookie;

    if (!allCookie.toString().contains('${cookiePrefix}_auth')) {
      // Only save cookie when cookie is authed.
      info('refuse to save not authed cookie');
      return;
    }

    await CookieDao(_db).upsertCookie(
      CookieCompanion(
        username: Value(username),
        uid: Value(uid),
        // email: Value(email),
        cookie: Value(jsonEncode(allCookie)),
      ),
    );
  }

  /// [saveCookie] for a cookie provider that loaded the row of [uid] and writes back what the forum renewed: only while
  /// the row still holds [session], the session the provider holds ([cookieSessionOf]). False when it does not: another
  /// session of the account was stored meanwhile (a login with the password, of the same account too) or the account
  /// was removed, and a request of the previous session answered late must not bring it back.
  ///
  /// Checked in the cache (this isolate's writes) and in the database, which the Android background message service
  /// writes from its own isolate ([exclusively]: nothing is written between the check and the write).
  Future<bool> saveCookieOfSession({
    required String username,
    required int uid,
    required Cookie cookie,
    required String? session,
  }) async {
    bool held(Cookie? stored) => stored != null && cookieSessionOf(stored) == session;
    if (!held(getCookieByUidSync(uid))) {
      return false;
    }
    return exclusively(() async {
      final row = await CookieDao(_db).selectCookieByUid(uid);
      if (row == null || cookieSessionOf(jsonDecode(row.cookie) as Map<String, dynamic>) != session) {
        return false;
      }
      // Read again: this isolate may have stored another session while the row was read.
      final allCookie = getCookieByUidSync(uid);
      if (!held(allCookie)) {
        return false;
      }
      _wroteCookieOf(uid);
      allCookie!.addAll(Map.castFrom<String, dynamic, String, String>(cookie));
      _cookieCache[UserLoginInfo(username: username, uid: uid)] = allCookie;
      await CookieDao(_db).upsertCookie(
        CookieCompanion(username: Value(username), uid: Value(uid), cookie: Value(jsonEncode(allCookie))),
      );
      return true;
    });
  }

  /// Delete cookie for [uid].
  ///
  /// The local marks ([recordRepliedThread]) and the offline thread pages ([saveOfflineThreadPage]) of the account go
  /// with it.
  Future<bool> deleteCookieByUid(int uid) async {
    _wroteCookieOf(uid);
    // Update cookie cache.
    _cookieCache.removeWhere((e, _) => e.uid == uid);
    final affectedRows = await CookieDao(_db).deleteCookieByUid(uid);
    await _deleteAccountMarks(uid);
    return affectedRows != 0;
  }

  /// Run [action] as one read-modify-write that no other connection interleaves with.
  ///
  /// The Android background message service opens the same file from its own isolate, and a plain transaction
  /// (`BEGIN`, deferred) takes no lock until it writes: two syncs could both read the stored copies, both decide what
  /// is new and both write, the later one over the other's newer rows. The first statement here is a write that
  /// matches no row: it reserves the write lock before anything is read, so the other connection's own first
  /// statement fails with "database is locked" at once and is retried after the winner committed, reading what the
  /// winner wrote. The busy timeout of the connection does not cover this case (a deferred transaction that already
  /// holds a read lock is refused immediately to avoid a deadlock), hence the retry loop: up to about five seconds,
  /// then the error is the caller's.
  ///
  /// Nested drift transactions (a DAO batch inside [action]) are fine, they become savepoints.
  Future<T> exclusively<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _db.transaction(() async {
          await _db.customStatement('UPDATE notice SET uid = uid WHERE 0');
          return action();
        });
      } on Object catch (e) {
        if (!isDatabaseBusy(e) || attempt >= _exclusiveRetries) {
          rethrow;
        }
        await Future<void>.delayed(_exclusiveRetryDelay);
      }
    }
  }

  static const _exclusiveRetries = 100;
  static const _exclusiveRetryDelay = Duration(milliseconds: 50);

  /// Whether [e] is sqlite refusing a statement because another connection holds the lock (`SQLITE_BUSY`,
  /// `SQLITE_LOCKED`), also when it arrives from the database isolate wrapped in a [DriftRemoteException].
  static bool isDatabaseBusy(Object e) {
    final cause = e is DriftRemoteException ? e.remoteCause : e;
    return cause is SqliteException && (cause.resultCode == 5 || cause.resultCode == 6);
  }

  /// Delete the cookies of every uid in [uids] in one transaction.
  ///
  /// Returns the number of rows removed. The in-memory cache is cleared first so a client of a removed account can
  /// not find its cookie any more, and the single transaction makes the users stream emit once for the batch.
  Future<int> deleteCookiesByUids(Iterable<int> uids) async {
    final targets = uids.toSet();
    if (targets.isEmpty) {
      return 0;
    }
    targets.forEach(_wroteCookieOf);
    _cookieCache.removeWhere((e, _) => targets.contains(e.uid));
    final dao = CookieDao(_db);
    return _db.transaction(() async {
      var deleted = 0;
      for (final uid in targets) {
        deleted += await dao.deleteCookieByUid(uid);
        await _deleteAccountMarks(uid);
      }
      return deleted;
    });
  }

  /// Delete stored cookie with [userInfo].
  ///
  /// uid > username > email.
  Future<bool> deleteCookieByUserInfo(UserLoginInfo userInfo) async {
    final username = userInfo.username;
    final uid = userInfo.uid;
    // final email = userInfo.email;
    final int affectedRows;
    if (uid != null) {
      _wroteCookieOf(uid);
      _cookieCache.removeWhere((e, _) => e.uid == uid);
      affectedRows = await CookieDao(_db).deleteCookieByUid(uid);
      await _deleteAccountMarks(uid);
    } else if (username != null) {
      // Every row of that name (the name is no key: two rows may carry it), read before anything is removed.
      final uids = (await CookieDao(_db).selectAll()).where((e) => e.username == username).map((e) => e.uid).toList()
        ..forEach(_wroteCookieOf);
      _cookieCache.removeWhere((e, _) => e.username == username);
      affectedRows = await CookieDao(_db).deleteCookieByUsername(username);
      for (final uid in uids) {
        await _deleteAccountMarks(uid);
      }
      // } else if (email != null) {
      //   _cookieCache.removeWhere((e, _) => e.email == email);
      //   affectedRows = await CookieDao(_db).deleteCookieByEmail(email);
    } else {
      error('intend to delete cookie with empty user info');
      affectedRows = 0;
    }
    return affectedRows != 0;
  }

  /*            image cache           */

  /// Get the image cache for image from [url].
  ///
  /// A lookup by key: the table holds every cached image (a hundred thousand rows are no exception), and walking it
  /// for every image shown slowed the first frame down.
  ImageEntity? getImageCacheSync(String url) => _imageCache[url];

  /// Get user avatar cache info on [username].
  Future<UserAvatarEntity?> getUserAvatarEntityCache({required String username, required String? imageUrl}) async =>
      UserAvatarDao(_db).selectAvatar(username: username, imageUrl: imageUrl);

  /// Insert or update cache info, update all info.
  Future<void> updateImageCache(
    String url, {
    required String fileName,
    DateTime? lastCacheTime,
    DateTime? lastUsedTime,
  }) async {
    final now = DateTime.now();
    _imageCache[url] = ImageEntity(
      url: url,
      fileName: fileName,
      lastCachedTime: lastCacheTime ?? now,
      lastUsedTime: lastUsedTime ?? now,
    );
    await ImageDao(_db).upsertImageCache(
      ImageCompanion(
        url: Value(url),
        fileName: Value(fileName),
        lastCachedTime: lastCacheTime != null ? Value(lastCacheTime) : Value(now),
        lastUsedTime: lastUsedTime != null ? Value(lastUsedTime) : Value(now),
      ),
    );
  }

  /// Insert or update cache info, only update last used time.
  Future<void> updateImageCacheUsedTime(String url) async {
    final now = DateTime.now();
    if (_imageCache.containsKey(url)) {
      _imageCache[url] = _imageCache[url]!.copyWith(lastUsedTime: now);
    }
    await ImageDao(_db).updateImageCache(url: url, lastUsedTime: now);
  }

  /// Clear all image cache in database.
  Future<void> clearImageCache() async {
    _imageCache.clear();
    await ImageDao(_db).deleteAll();
  }

  /// Clear all image cache have a older not-used-time then [dateTime].
  ///
  /// Return all deleted image cache entity.
  Future<List<ImageEntity>> clearImageCacheOutdated(DateTime dateTime) async {
    final deletedCache = await ImageDao(_db).deleteByLastUsedDuration(dateTime);
    _imageCache = await preloadImageCache(_db);
    return deletedCache;
  }

  /*             settings             */

  /// Load all saved settings.
  Future<List<SettingsEntity>> getAllSettings() async {
    return SettingsDao(_db).getAll();
  }

  /// Remove a settings with given [name].
  Future<bool> removeByKey(String name) async {
    final affectedRows = await SettingsDao(_db).deleteByName(name);
    return affectedRows != 0;
  }

  /// Get string type value of specified key.
  Future<String?> getString(String key) async => SettingsDao(_db).getValueByName<String>(key);

  /// Save string type value of specified key.
  Future<void> saveString(String key, String value) async {
    await SettingsDao(_db).setValue<String>(key, value);
  }

  /// Get int type value of specified key.
  Future<int?> getInt(String key) async => SettingsDao(_db).getValueByName<int>(key);

  /// Sae int type value of specified key.
  Future<void> saveInt(String key, int value) async {
    await SettingsDao(_db).setValue<int>(key, value);
  }

  /// Get bool type value of specified key.
  Future<bool?> getBool(String key) async => SettingsDao(_db).getValueByName<bool>(key);

  /// Save bool type value of specified value.
  Future<void> saveBool(String key, {required bool value}) async {
    await SettingsDao(_db).setValue<bool>(key, value);
  }

  /// Get double type value of specified key.
  Future<double?> getDouble(String key) async => SettingsDao(_db).getValueByName<double>(key);

  /// Save double type value of specified key.
  Future<void> saveDouble(String key, double value) async {
    await SettingsDao(_db).setValue<double>(key, value);
  }

  /// Get [DateTime] type value of specified key.
  Future<DateTime?> getDateTime(String key) async => SettingsDao(_db).getValueByName(key);

  /// Save [DateTime] type value of specified key.
  Future<void> saveDateTime(String key, DateTime value) async => SettingsDao(_db).setValue<DateTime>(key, value);

  /// Get [Offset] type value of specified key.
  Future<Offset?> getOffset(String key) async => SettingsDao(_db).getValueByName(key);

  /// Save [Offset] type value of specified key.
  Future<void> saveOffset(String key, Offset value) async => SettingsDao(_db).setValue<Offset>(key, value);

  /// Get [Size] type value of specified key.
  Future<Size?> getSize(String key) async => SettingsDao(_db).getValueByName(key);

  /// Save [Size] type value of specified key.
  Future<void> saveSize(String key, Size value) async => SettingsDao(_db).setValue<Size>(key, value);

  /// Get [List] of [String] type value of specified key.
  Future<List<String>?> getStringList(String key) async => SettingsDao(_db).getValueByName(key);

  /// Save [List] of [String] type value of specified key.
  Future<void> saveStringList(String key, List<String> value) async =>
      SettingsDao(_db).setValue<List<String>>(key, value);

  /// Get [List] of [int] type value of specified key.
  Future<List<int>?> getIntList(String key) async => SettingsDao(_db).getValueByName(key);

  /// Save [List] of [int] type value of specified key.
  Future<void> saveIntList(String key, List<int> value) async => SettingsDao(_db).setValue<List<int>>(key, value);

  /// Delete the given record from database.
  Future<void> deleteKey(String key) async {
    await SettingsDao(_db).deleteByName(key);
  }

  /*        thread visit history        */

  /// Fetch all thread visit history for all users and all threads..
  AsyncEither<List<ThreadVisitHistoryEntity>> fetchAllThreadVisitHistory() => AsyncEither(() async {
    final history = await ThreadVisitHistoryDao(_db).selectAll();
    return Right(history);
  });

  /// Fetch all thread visit history for user [uid].
  AsyncEither<List<ThreadVisitHistoryEntity>> fetchThreadVisitHistoryByUid(int uid) =>
      AsyncEither(() async => Right(await ThreadVisitHistoryDao(_db).selectByUid(uid)));

  /// Delete a history record specified by [uid] and [tid].
  AsyncVoidEither deleteByUidAndTid({required int uid, required int tid}) => AsyncVoidEither(() async {
    await ThreadVisitHistoryDao(_db).deleteByUidOrTid(uid: uid, tid: tid);
    return rightVoid();
  });

  /// Save thread visit history.
  Future<void> updateThreadVisitHistory({
    required int uid,
    required int tid,
    required int fid,
    required String username,
    required String threadTitle,
    required String forumName,
    required DateTime visitTime,
  }) async => ThreadVisitHistoryDao(_db).upsertVisitHistory(
    ThreadVisitHistoryCompanion(
      uid: Value(uid),
      tid: Value(tid),
      fid: Value(fid),
      username: Value(username),
      threadTitle: Value(threadTitle),
      forumName: Value(forumName),
      visitTime: Value(visitTime),
    ),
  );

  /// Delete thread visit history with [uid] and [tid].
  Future<void> deleteThreadVisitHistory({int? uid, int? tid}) async =>
      ThreadVisitHistoryDao(_db).deleteByUidOrTid(uid: uid, tid: tid);

  /// Delete all thread visit history.
  AsyncVoidEither deleteAllThreadVisitHistory() => AsyncVoidEither(() async {
    await ThreadVisitHistoryDao(_db).deleteAll();
    return rightVoid();
  });

  /*        session expiry        */

  /// Remember that the forum session of the account [uid] is dead (issue #25), as of [at] (now by default).
  ///
  /// Call it whenever a request made with that account's cookie got the guest page. Nothing happens when the account
  /// is not stored. Cleared by [clearSessionExpired] once a login or an account switch verified the session again.
  /// A cookie provider loaded from the row marks it with [markSessionExpiredIfHeld].
  Future<void> markSessionExpired(int uid, {DateTime? at}) async {
    final touched = await CookieDao(_db).updateSessionExpiredAt(uid, at ?? DateTime.now());
    if (touched > 0) {
      info('session of uid ${"$uid".obscured(4)} marked expired');
    }
  }

  /// [markSessionExpired] for the guest page answered to [session] ([cookieSessionOf]), the session a cookie provider
  /// loaded from the row of [uid] sent the request with: only while the row still holds it, checked in the database
  /// ([exclusively]). The guest page answered to the previous session after a new login of the account (with the
  /// password, of the same account too) says nothing of the new one, whichever isolate asked.
  Future<void> markSessionExpiredIfHeld(int uid, {required String? session, DateTime? at}) async {
    final dao = CookieDao(_db);
    final touched = await exclusively(() async {
      final row = await dao.selectCookieByUid(uid);
      if (row == null) {
        return 0;
      }
      if (cookieSessionOf(jsonDecode(row.cookie) as Map<String, dynamic>) != session) {
        info('session of uid ${"$uid".obscured(4)} not marked expired: another session is stored now');
        return 0;
      }
      return dao.updateSessionExpiredAt(uid, at ?? DateTime.now());
    });
    if (touched > 0) {
      info('session of uid ${"$uid".obscured(4)} marked expired');
    }
  }

  /// Forget the session expiry of the account [uid]: its session was verified alive again.
  Future<void> clearSessionExpired(int uid) async {
    await CookieDao(_db).updateSessionExpiredAt(uid, null);
  }

  /// The accounts whose session is known to be expired.
  Future<List<StoredAccount>> fetchExpiredSessions() async {
    final rows = await CookieDao(_db).selectAll();
    return rows
        .where((e) => e.sessionExpiredAt != null)
        .map(
          (e) => (
            user: UserLoginInfo(username: e.username, uid: e.uid),
            lastCheckin: e.lastCheckin,
            sessionExpiredAt: e.sessionExpiredAt,
          ),
        )
        .toList();
  }

  /// Watch the uids of the accounts whose session is known to be expired.
  ///
  /// Emits again on every change of the cookie table; identical sets are not repeated.
  Stream<Set<int>> watchExpiredSessionUids() =>
      CookieDao(_db).watchSessionExpired().map((e) => e.map((entity) => entity.uid).toSet()).distinct(setEquals);

  /*        replied threads        */

  /// Remember that user [uid] replied to thread [tid] in forum [fid] (issue #21).
  ///
  /// A local mark only, refreshed when recorded again. Removed with the account.
  Future<void> recordRepliedThread({required int uid, required int tid, required int fid}) async {
    await RepliedThreadDao(_db).record(uid: uid, tid: tid, fid: fid);
  }

  /// The ids of the threads user [uid] replied to, only those in forum [fid] when given.
  Future<Set<int>> fetchRepliedTids(int uid, {int? fid}) async =>
      (await RepliedThreadDao(_db).selectByUid(uid, fid: fid)).map((e) => e.tid).toSet();

  /// Watch the ids of the threads user [uid] replied to, only those in forum [fid] when given.
  ///
  /// Emits the current set first and again after every change of the marks of any user.
  Stream<Set<int>> watchRepliedTids(int uid, {int? fid}) =>
      RepliedThreadDao(_db).watchByUid(uid, fid: fid).map((e) => e.map((entity) => entity.tid).toSet());

  /// Delete every replied mark of user [uid].
  Future<void> deleteRepliedThreadsByUid(int uid) async {
    await RepliedThreadDao(_db).deleteByUid(uid);
  }

  /*        offline threads        */

  /// Save the answer [body] of page [page] of thread [tid] as served to user [uid], asked with [orderType] and
  /// [authorId] (0 when not asked), loaded at [savedAt]; replaces the page saved before.
  ///
  /// With [onlyStoredAccount], nothing is written unless the account [uid] is still stored on this device, checked by
  /// the write itself (one statement): a page whose account was removed while its write waited never comes back (the
  /// removal deletes the account's row before its pages). Returns whether the page was written.
  Future<bool> saveOfflineThreadPage({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
    required String body,
    required DateTime savedAt,
    bool onlyStoredAccount = false,
  }) async {
    final dao = OfflineThreadDao(_db);
    final size = utf8.encode(body).length;
    if (onlyStoredAccount) {
      return dao.upsertForStoredAccount(
        uid: uid,
        tid: tid,
        page: page,
        orderType: orderType,
        authorId: authorId,
        size: size,
        savedAt: savedAt,
        lastUsedAt: savedAt.millisecondsSinceEpoch,
        body: body,
      );
    }
    await dao.upsert(
      OfflineThreadCompanion(
        uid: Value(uid),
        tid: Value(tid),
        page: Value(page),
        orderType: Value(orderType),
        authorId: Value(authorId),
        body: Value(body),
        size: Value(size),
        savedAt: Value(savedAt),
        lastUsedAt: Value(savedAt.millisecondsSinceEpoch),
      ),
    );
    return true;
  }

  /// The saved page of the key ([saveOfflineThreadPage]), null when none; a page found is marked used at [usedAt].
  Future<OfflineThreadEntity?> fetchOfflineThreadPage({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
    DateTime? usedAt,
  }) async {
    final dao = OfflineThreadDao(_db);
    final entity = await dao.selectPage(uid: uid, tid: tid, page: page, orderType: orderType, authorId: authorId);
    if (entity != null) {
      await dao.touch(
        uid: uid,
        tid: tid,
        page: page,
        orderType: orderType,
        authorId: authorId,
        time: usedAt ?? DateTime.now(),
      );
    }
    return entity;
  }

  /// The saved page with the highest page number for the rest of the key ([OfflineThreadDao.selectLastPage]), null
  /// when none; a page found is marked used at [usedAt].
  Future<OfflineThreadEntity?> fetchLastOfflineThreadPage({
    required int uid,
    required int tid,
    required int orderType,
    required int authorId,
    DateTime? usedAt,
  }) async {
    final dao = OfflineThreadDao(_db);
    final entity = await dao.selectLastPage(uid: uid, tid: tid, orderType: orderType, authorId: authorId);
    if (entity != null) {
      await dao.touch(
        uid: uid,
        tid: tid,
        page: entity.page,
        orderType: orderType,
        authorId: authorId,
        time: usedAt ?? DateTime.now(),
      );
    }
    return entity;
  }

  /// Every saved offline thread page of every user, with the bodies. Tests only.
  @visibleForTesting
  Future<List<OfflineThreadEntity>> fetchAllOfflineThreadPages() async => OfflineThreadDao(_db).selectAll();

  /// Delete every saved page of thread [tid] for user [uid].
  Future<int> deleteOfflineThread({required int uid, required int tid}) async =>
      OfflineThreadDao(_db).deleteThread(uid: uid, tid: tid);

  /// Delete every saved page of user [uid].
  Future<int> deleteOfflineThreadsByUid(int uid) async => OfflineThreadDao(_db).deleteByUid(uid);

  /// Delete every saved page of every user.
  Future<int> clearOfflineThreads() async => OfflineThreadDao(_db).deleteAll();

  /// Size of the saved pages in bytes.
  Future<int> offlineThreadsSize() async => OfflineThreadDao(_db).totalSize();

  /// Keep the pages of the [limit] most recently used threads only; returns the number of pages deleted.
  Future<int> trimOfflineThreads(int limit) async => OfflineThreadDao(_db).keepRecentThreads(limit);

  /// Keep the [limit] most recently used pages of thread [tid] for user [uid] only; returns the number of pages
  /// deleted.
  Future<int> trimOfflineThreadPages({required int uid, required int tid, required int limit}) async =>
      OfflineThreadDao(_db).keepRecentPages(uid: uid, tid: tid, limit: limit);

  /// Delete every saved offline thread page when there is any; returns the number of pages deleted.
  ///
  /// Reads first, so an empty table (the usual case) costs no write.
  Future<int> clearOfflineThreadsIfAny() async {
    final dao = OfflineThreadDao(_db);
    if (await dao.isEmpty()) {
      return 0;
    }
    return dao.deleteAll();
  }

  /// Save an image sticker [url] with an optional [name] (#5); returns the row id.
  Future<int> addCustomImage({required String url, String name = ''}) async =>
      CustomImageDao(_db).add(url: url, name: name);

  /// All saved image stickers in display order.
  Future<List<CustomImageEntity>> fetchCustomImages() async => CustomImageDao(_db).selectAll();

  /// Watch the saved image stickers in display order.
  Stream<List<CustomImageEntity>> watchCustomImages() => CustomImageDao(_db).watchAll();

  /// Delete the image sticker with row [id].
  Future<void> deleteCustomImage(int id) async {
    await CustomImageDao(_db).deleteById(id);
  }

  /*        notification        */

  /// Fetch the timestamp for user [uid] when fetch notification last time.
  AsyncEither<DateTime?> fetchLastFetchNoticeTime(int uid) => AsyncEither(() async {
    final user = await CookieDao(_db).selectCookieByUid(uid);
    if (user == null) {
      // User record not found.
      return left(NotificationUserNotFound());
    }
    return right(user.lastFetchNotice);
  });

  /// Update the last fetch notification datetime in storage for user [uid].
  VoidTask updateLastFetchNoticeTime(int uid, DateTime datetime) => VoidTask(() async {
    await CookieDao(_db).updateLastFetchNoticeTime(uid, datetime);
    return;
  });

  /// Time of the last check-in this app made for the account [uid], null when none is recorded or the account is not
  /// stored.
  Future<DateTime?> getLastCheckinTime(int uid) async => (await CookieDao(_db).selectCookieByUid(uid))?.lastCheckin;

  /// Update the last checkin success datetime in storage for user [uid].
  VoidTask updateLastCheckinTime(int uid, DateTime datetime) => VoidTask(() async {
    await CookieDao(_db).updateLastCheckinTime(uid, datetime);
    return;
  });

  /// Fetch all notification for user [uid] since time [timestamp].
  ///
  /// Return a instance of [NotificationGroup] that contains all types of
  /// fetched notice.
  Task<NotificationGroup> fetchNotificationSince({required int uid, required int timestamp}) => Task(() async {
    final dao = NotificationDao(_db);
    // final
    final noticeList = await dao.selectNoticeSince(uid: uid, timestamp: timestamp);

    final personalMessageList = await dao.selectPersonalMessageSince(uid: uid, timestamp: timestamp);
    final broadcastMessageList = await dao.selectBroadcastMessageSince(uid: uid, timestamp: timestamp);

    return NotificationGroup(
      noticeList: noticeList,
      personalMessageList: personalMessageList,
      broadcastMessageList: broadcastMessageList,
    );
  });

  /// Save a group of notice for user [uid] into storage.
  VoidTask saveNotification({required int uid, required NotificationGroup notificationGroup}) => VoidTask(() async {
    await NotificationDao(_db).insertManyNotice(
      noticeList: notificationGroup.noticeList
          .map(
            (e) => NoticeCompanion(
              uid: Value(uid),
              timestamp: Value(e.timestamp),
              data: Value(e.data),
              nid: Value(e.nid),
              alreadyRead: Value(e.alreadyRead),
              // A copy without the metadata keeps the stored one only for the same revision, see
              // `NotificationDao.insertManyNotice`.
              ignoreType: Value(e.ignoreType),
              authorId: Value(e.authorId),
            ),
          )
          .toList(),
      personalMessageList: notificationGroup.personalMessageList
          .map(
            (e) => PersonalMessageCompanion(
              uid: Value(uid),
              timestamp: Value(e.timestamp),
              data: Value(e.data),
              peerUid: Value(e.peerUid),
              peerUsername: Value(e.peerUsername),
              sender: Value(e.sender),
              alreadyRead: Value(e.alreadyRead),
            ),
          )
          .toList(),
      broadcastMessageList: notificationGroup.broadcastMessageList
          .map(
            (e) => BroadcastMessageCompanion(
              uid: Value(uid),
              timestamp: Value(e.timestamp),
              data: Value(e.data),
              pmid: Value(e.pmid),
              alreadyRead: Value(e.alreadyRead),
            ),
          )
          .toList(),
    );
  });

  /// Mark a notice as [read].
  AsyncVoidEither markNoticeAsRead({required int uid, required int nid, required bool read}) =>
      AsyncVoidEither(() async {
        await NotificationDao(_db).markNoticeAsRead(uid: uid, nid: nid, read: read);
        return rightVoid();
      });

  /// Mark a personal message as [read].
  AsyncVoidEither markPersonalMessageAsRead({required int uid, required int peerUid, required bool read}) =>
      AsyncVoidEither(() async {
        await NotificationDao(_db).markPersonalMessageAsRead(uid: uid, peerUid: peerUid, read: read);
        return rightVoid();
      });

  /// Mark a broadcast message as [read].
  AsyncVoidEither markBroadcastMessageAsRead({required int uid, required int timestamp, required bool read}) =>
      AsyncVoidEither(() async {
        await NotificationDao(_db).markBroadcastMessageAsRead(uid: uid, timestamp: timestamp, read: read);
        return rightVoid();
      });

  /// Mark all message of a [notificationType] as [alreadyRead].
  AsyncVoidEither markTypeAsRead({
    required NotificationType notificationType,
    required bool alreadyRead,
    required int uid,
  }) => AsyncVoidEither(() async {
    await NotificationDao(_db).markTypeAsRead(notificationType: notificationType, uid: uid, alreadyRead: alreadyRead);

    return rightVoid();
  });

  /// Delete located notice by given [uid] and [nid].
  ///
  /// At most delete one item.
  AsyncVoidEither deleteNotice({required int uid, required int nid}) => AsyncVoidEither(() async {
    await NotificationDao(_db).deleteNotice(uid: uid, nid: nid);
    return rightVoid();
  });

  /// Delete located personal message by [uid] and [peerUid].
  ///
  /// At most delete one item.
  AsyncVoidEither deletePersonalMessage({required int uid, required int peerUid}) => AsyncVoidEither(() async {
    await NotificationDao(_db).deletePersonalMessage(uid: uid, peerUid: peerUid);
    return rightVoid();
  });

  /// Delete located broadcast message by [uid] and [pmid].
  ///
  /// At most delete one item.
  AsyncVoidEither deleteBroadcastMessage({required int uid, required int pmid}) => AsyncVoidEither(() async {
    await NotificationDao(_db).deleteBroadcastMessage(uid: uid, pmid: pmid);
    return rightVoid();
  });

  /*        user avatar        */

  /// Update recorded user avatar info for [username] with [cacheName].
  AsyncVoidEither updateUserAvatarCacheInfo({
    required String username,
    required String cacheName,
    required String imageUrl,
  }) => AsyncVoidEither(() async {
    await UserAvatarDao(_db).upsertAvatar(
      UserAvatarCompanion(username: Value(username), cacheName: Value(cacheName), imageUrl: Value(imageUrl)),
    );

    return rightVoid();
  });

  /*        Fast rate template       */

  /// Get all fast rate template from storage.
  ///
  /// No matter uid.
  AsyncEither<List<FastRateTemplateModel>> getAllFastRateTemplate() => AsyncEither(() async {
    final rates = (await FastRateTemplateDao(_db).selectAll())
        .map(
          (e) => FastRateTemplateModel(
            name: e.name,
            ww: e.ww,
            tsb: e.tsb,
            xc: e.xc,
            tr: e.tr,
            fh: e.fh,
            jl: e.jl,
            special: e.special,
            special2: e.special2 ?? 0,
          ),
        )
        .toList();
    return right(rates);
  });

  /// Watch all
  Stream<List<FastRateTemplateModel>> watchAllFastRateTemplate() => FastRateTemplateDao(_db).watchAll().map(
    (e) => e
        .map(
          (e2) => FastRateTemplateModel(
            name: e2.name,
            ww: e2.ww,
            tsb: e2.tsb,
            xc: e2.xc,
            tr: e2.tr,
            fh: e2.fh,
            jl: e2.jl,
            special: e2.special,
            special2: e2.special2 ?? 0,
          ),
        )
        .toList(),
  );

  /// Save fast [rate] template to storage.
  AsyncVoidEither saveFastRateTemplate(FastRateTemplateModel rate) => AsyncEither(() async {
    await FastRateTemplateDao(_db).insertOrUpdate(
      FastRateTemplateCompanion(
        name: Value(rate.name),
        ww: Value(rate.ww),
        tsb: Value(rate.tsb),
        xc: Value(rate.xc),
        tr: Value(rate.tr),
        fh: Value(rate.fh),
        jl: Value(rate.jl),
        lastUsedTime: Value(DateTime.now()),
        special: Value(rate.special),
        special2: Value(rate.special2),
      ),
    );

    return rightVoid();
  });

  /// Delete all fast rate templates from storage.
  AsyncVoidEither deleteAllFastRateTemplate() => AsyncEither(() async {
    await FastRateTemplateDao(_db).deleteAll();
    return rightVoid();
  });

  /// Delete the one fast rate template specified by template [name].
  AsyncVoidEither deleteFastRateTemplateByName(String name) => AsyncEither(() async {
    await FastRateTemplateDao(_db).deleteByName(name);
    return rightVoid();
  });

  /*        Fast reply template       */

  /// Get all fast reply templates from storage.
  AsyncEither<List<FastReplyTemplateModel>> getAllFastReplyTemplate() => AsyncEither(() async {
    final rate = (await FastReplyTemplateDao(
      _db,
    ).selectAll()).map((e) => FastReplyTemplateModel(name: e.name, data: e.data)).toList();

    return right(rate);
  });

  /// Watch the changes of fast reply templates in storage.
  Stream<List<FastReplyTemplateModel>> watchAllFastReplyTemplate() => FastReplyTemplateDao(
    _db,
  ).watchAll().map((e) => e.map((e2) => FastReplyTemplateModel(name: e2.name, data: e2.data)).toList());

  /// Save fast [reply] template to storage.
  AsyncVoidEither saveFastReplyTemplate(FastReplyTemplateModel reply) => AsyncEither(() async {
    await FastReplyTemplateDao(_db).insertOrUpdate(
      FastReplyTemplateCompanion(name: Value(reply.name), data: Value(reply.data), lastUsedTime: Value(DateTime.now())),
    );

    return rightVoid();
  });

  /// Delete all fast reply templates from storage.
  AsyncVoidEither deleteAllFastReplyTemplate() => AsyncEither(() async {
    await FastReplyTemplateDao(_db).deleteAll();
    return rightVoid();
  });

  /// Delete fast reply template specified by template [name].
  AsyncVoidEither deleteFastReplyTemplateByName(String name) => AsyncEither(() async {
    await FastReplyTemplateDao(_db).deleteByName(name);
    return rightVoid();
  });

  /// Clear all user avatar cache info.
  Future<void> clearUserAvatarInfo() async {
    await UserAvatarDao(_db).deleteAll();
  }

  /// Dispose the database.
  ///
  /// WARNING: avoid to use this function when possible as reconnect is not in
  /// consideration.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _db.close();
  }

  bool _disposed = false;
}
