import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What one saved thread page is kept under: the account it was served to and the request (thread, page, order,
/// author filter), so a page is only ever shown again for the same account and the same request.
@immutable
final class OfflineThreadKey {
  /// Constructor.
  const OfflineThreadKey({
    required this.uid,
    required this.tid,
    required this.page,
    required this.orderType,
    required this.authorId,
  });

  /// The account, never a guest.
  final int uid;

  /// Thread id.
  final int tid;

  /// Page number.
  final int page;

  /// `ordertype` of the request, 0 when none.
  final int orderType;

  /// `authorid` of the request, 0 when none.
  final int authorId;

  @override
  bool operator ==(Object other) =>
      other is OfflineThreadKey &&
      other.uid == uid &&
      other.tid == tid &&
      other.page == page &&
      other.orderType == orderType &&
      other.authorId == authorId;

  @override
  int get hashCode => Object.hash(uid, tid, page, orderType, authorId);

  @override
  String toString() => 'OfflineThreadKey(tid=$tid, page=$page, ordertype=$orderType, authorid=$authorId)';
}

/// The app's offline thread pages: the one instance registered in `initProviders`, so every page, the settings and the
/// cache sheet share one write queue; a new instance where none is registered (tests of other features), which reads
/// and writes nothing while the setting is off.
OfflineThreadRepository get appOfflineThreads =>
    getIt.isRegistered<OfflineThreadRepository>() ? getIt.get<OfflineThreadRepository>() : OfflineThreadRepository();

/// A saved page read back: the answer of the forum as it came, and when it was loaded.
typedef OfflineThreadPage = ({String body, DateTime savedAt});

/// Thread pages saved for reading without network ("離線保存看過的帖子", off by default).
///
/// While [enabled], the thread page hands every answer it loaded to [save] (only what the forum served to the account
/// in use, no extra request) and asks [load] when a load failed because the forum could not be reached at all. Writes
/// run one after another in the background, never holding the page; a failed write is logged and dropped. Nothing is
/// read or written while the setting is off.
class OfflineThreadRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [storage], [settings] and [currentUid] default to the app's own (the account of the global cookie, the one every
  /// request is sent as), resolved when used: a page that never saves needs none of them.
  OfflineThreadRepository({StorageProvider? storage, SettingsRepository? settings, int? Function()? currentUid})
    : _storage = storage,
      _settings = settings,
      _currentUid = currentUid;

  final StorageProvider? _storage;
  final SettingsRepository? _settings;
  final int? Function()? _currentUid;

  StorageProvider get _store => _storage ?? getIt.get<StorageProvider>();

  SettingsRepository? get _settingsRepo =>
      _settings ?? (getIt.isRegistered<SettingsRepository>() ? getIt.get<SettingsRepository>() : null);

  /// Whether pages are saved and read back.
  bool get enabled => _settingsRepo?.currentSettings.offlineThreads ?? false;

  /// How many threads are kept, of every account together.
  int get limit => _settingsRepo?.currentSettings.offlineThreadsLimit ?? 50;

  /// How many pages of one thread (of one account, any order and author filter) are kept, the least recently used ones
  /// going first.
  static const pagesPerThread = 20;

  /// The account requests are sent as now, null for a guest.
  int? currentUid() {
    final uid = _currentUid != null
        ? _currentUid()
        : (getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null);
    return uid != null && uid > 0 ? uid : null;
  }

  Future<void> _writes = Future<void>.value();

  /// Run [write] after the writes queued before it; errors are logged, never thrown.
  void _queue(String what, Future<void> Function() write) {
    _writes = _writes.then((_) async {
      try {
        await write();
      } on Object catch (e, st) {
        error('offline threads: failed to $what: $e');
        handleRaw(e, st);
      }
    });
  }

  /// Completes once every write queued so far is done.
  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  /// The answer [data] as text: the web page, or the JSON answer encoded again. Null for anything else.
  static String? bodyOf(Object? data) => switch (data) {
    final String s => s,
    final Map<dynamic, dynamic> m => jsonEncode(m),
    final List<dynamic> l => jsonEncode(l),
    _ => null,
  };

  /// Save the answer [data] of [key], loaded now, then keep the [pagesPerThread] most recently used pages of its thread
  /// and the [limit] most recently used threads.
  void save(OfflineThreadKey key, Object? data) {
    final now = DateTime.now();
    _queue('save $key', () async {
      // Checked again when the write runs: the setting may have been turned off (and the pages cleared) meanwhile.
      if (!enabled) {
        return;
      }
      // Encoded in the queue: a failure here is logged like any other, the page loaded all the same.
      final body = bodyOf(data);
      if (body == null || body.isEmpty) {
        return;
      }
      final written = await _store.saveOfflineThreadPage(
        uid: key.uid,
        tid: key.tid,
        page: key.page,
        orderType: key.orderType,
        authorId: key.authorId,
        body: body,
        savedAt: now,
        // The account may have been logged out or removed while the write waited: its pages are gone, keep it so.
        onlyStoredAccount: true,
      );
      if (!written) {
        debug('offline threads: account of $key no longer stored, page dropped');
        return;
      }
      final limit = this.limit;
      final pages = await _store.trimOfflineThreadPages(uid: key.uid, tid: key.tid, limit: pagesPerThread);
      if (pages > 0) {
        debug('offline threads: evicted $pages pages of thread ${key.tid} beyond $pagesPerThread');
      }
      final evicted = await _store.trimOfflineThreads(limit);
      if (evicted > 0) {
        debug('offline threads: evicted $evicted pages beyond $limit threads');
      }
    });
  }

  /// Delete every saved page of thread [tid] for account [uid]: the forum refused the thread to that account.
  void forgetThread({required int uid, required int tid}) {
    _queue('forget thread $tid', () async {
      final deleted = await _store.deleteOfflineThread(uid: uid, tid: tid);
      if (deleted > 0) {
        debug('offline threads: thread $tid refused, $deleted saved pages deleted');
      }
    });
  }

  /// The saved page of [key], null when none (or when reading failed).
  Future<OfflineThreadPage?> load(OfflineThreadKey key) async {
    try {
      final entity = await _store.fetchOfflineThreadPage(
        uid: key.uid,
        tid: key.tid,
        page: key.page,
        orderType: key.orderType,
        authorId: key.authorId,
      );
      return entity == null ? null : (body: entity.body, savedAt: entity.savedAt);
    } on Object catch (e, st) {
      error('offline threads: failed to read $key: $e');
      handleRaw(e, st);
      return null;
    }
  }

  /// The saved page of the thread of [key] (same account, order and author) with the highest page number, whatever
  /// the page of [key]; null when none (or when reading failed). For a page asked past the last one on purpose
  /// (`goto=lastpost`), saved under the page the forum answered.
  Future<OfflineThreadPage?> loadLast(OfflineThreadKey key) async {
    try {
      final entity = await _store.fetchLastOfflineThreadPage(
        uid: key.uid,
        tid: key.tid,
        orderType: key.orderType,
        authorId: key.authorId,
      );
      return entity == null ? null : (body: entity.body, savedAt: entity.savedAt);
    } on Object catch (e, st) {
      error('offline threads: failed to read the last page of $key: $e');
      handleRaw(e, st);
      return null;
    }
  }

  /// Size of every saved page in bytes.
  Future<int> size() async => _store.offlineThreadsSize();

  /// Delete every saved page of every account, after the writes queued before.
  Future<void> clear() {
    _queue('clear', () async {
      final deleted = await _store.clearOfflineThreads();
      info('offline threads: cleared $deleted saved pages');
    });
    return _writes;
  }

  /// Keep the [limit] most recently used threads now, for example after the limit was lowered.
  Future<void> trim(int limit) {
    _queue('trim', () async => _store.trimOfflineThreads(limit));
    return _writes;
  }
}
