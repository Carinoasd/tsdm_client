import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// How long the record of a removed bookmark is kept on the device (for the cross-device sync to remove it on the
/// other devices too), as long as the sync document keeps one.
const floorBookmarkTombstoneKeptFor = Duration(days: 180);

/// The floor bookmarks of every account on this device: one settings row per account (`floorBookmarks.<uid>`) holding
/// the items by key as the sync document has them ([FloorBookmark]), the records of removed ones included.
///
/// Writes of one store go one after another; [changes] tells the account of each change.
final class FloorBookmarkStore with LoggerMixin {
  /// Constructor: the app's storage, read when first needed.
  FloorBookmarkStore({DateTime Function()? now})
    : _read = ((key) => getIt.get<StorageProvider>().getString(key)),
      _write = ((key, value) => getIt.get<StorageProvider>().saveString(key, value)),
      _delete = ((key) => getIt.get<StorageProvider>().deleteKey(key)),
      _now = now ?? DateTime.now;

  /// A store in memory (tests).
  @visibleForTesting
  FloorBookmarkStore.memory({DateTime Function()? now, Map<String, String>? rows})
    : this._custom(rows ?? <String, String>{}, now: now);

  FloorBookmarkStore._custom(Map<String, String> rows, {DateTime Function()? now})
    : _read = ((key) async => rows[key]),
      _write = ((key, value) async => rows[key] = value),
      _delete = ((key) async => rows.remove(key)),
      _now = now ?? DateTime.now;

  /// The app's store, null when none is registered (tests of other features): nothing is kept then.
  static FloorBookmarkStore? get app =>
      getIt.isRegistered<FloorBookmarkStore>() ? getIt.get<FloorBookmarkStore>() : null;

  /// The settings row of the bookmarks of account [uid].
  static String rowKeyOf(int uid) => 'floorBookmarks.$uid';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _delete;
  final DateTime Function() _now;

  /// The items of each account read so far, by key.
  final _accounts = <int, Map<String, FloorBookmark>>{};

  final _changes = StreamController<int>.broadcast();
  Future<void> _queue = Future.value();

  /// The account of every change of its bookmarks (added, changed, removed, taken from the sync).
  Stream<int> get changes => _changes.stream;

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<Map<String, FloorBookmark>> _load(int uid) async {
    if (_accounts[uid] case final items?) {
      return items;
    }
    final items = <String, FloorBookmark>{};
    try {
      final text = await _read(rowKeyOf(uid));
      if (text != null && text.isNotEmpty) {
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          for (final MapEntry(:key, :value) in json.entries) {
            if (value is Map<String, dynamic>) {
              if (FloorBookmark.fromItem(key, value) case final bookmark?) {
                items[key] = bookmark;
              }
            }
          }
        }
      }
    } on FormatException catch (e) {
      // Damaged: read as none, replaced at the next write.
      error('failed to read the floor bookmarks of $uid: $e');
    }
    return _accounts[uid] = items;
  }

  Future<void> _save(int uid, Map<String, FloorBookmark> items) async {
    final keepSince = _now().millisecondsSinceEpoch - floorBookmarkTombstoneKeptFor.inMilliseconds;
    items.removeWhere((_, b) => b.deleted && b.updated < keepSince);
    if (items.isEmpty) {
      await _delete(rowKeyOf(uid));
    } else {
      await _write(rowKeyOf(uid), jsonEncode({for (final MapEntry(:key, :value) in items.entries) key: value.raw}));
    }
    _accounts[uid] = items;
    _changes.add(uid);
  }

  /// A time for a change of [previous]: now, but always later than the previous change, so the change wins over it
  /// on every device even when the clock went back.
  int _stamp(FloorBookmark? previous) {
    final now = _now().millisecondsSinceEpoch;
    final before = previous?.updated ?? 0;
    return now > before ? now : before + 1;
  }

  /// The live bookmarks of account [uid], the latest changed first.
  Future<List<FloorBookmark>> list(int uid) => _serial(() async {
    final items = (await _load(uid)).values.where((e) => !e.deleted).toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    return items;
  });

  /// Every item of account [uid], the records of removed bookmarks included (the cross-device sync).
  Future<List<FloorBookmark>> items(int uid) => _serial(() async => (await _load(uid)).values.toList());

  /// Mark floor [pid] of thread [tid] for account [uid], or change the bookmark it has; returns the bookmark kept.
  Future<FloorBookmark> put(
    int uid, {
    required int tid,
    required int pid,
    int? floor,
    int? page,
    String note = '',
    String excerpt = '',
    String threadTitle = '',
  }) => _serial(() async {
    final items = {...await _load(uid)};
    final key = FloorBookmark.keyOf(tid: tid, pid: pid);
    final previous = items[key];
    final bookmark = FloorBookmark(
      tid: tid,
      pid: pid,
      updated: _stamp(previous),
      floor: floor,
      page: page,
      note: note,
      excerpt: excerpt,
      threadTitle: threadTitle,
      unknown: previous == null || previous.deleted ? const {} : previous.raw,
    );
    items[key] = bookmark;
    await _save(uid, items);
    return bookmark;
  });

  /// Remove the bookmark under [key] of account [uid] (kept as the record of its deletion).
  Future<void> remove(int uid, String key) => _serial(() async {
    final items = {...await _load(uid)};
    final previous = items[key];
    if (previous == null || previous.deleted) {
      return;
    }
    items[key] = FloorBookmark.deletedAt(key, _stamp(previous));
    await _save(uid, items);
  });

  /// Keep [save] (bookmarks and records of deletions the cross-device sync took) for account [uid], each replacing the
  /// item of its key unless that one changed later meanwhile.
  Future<void> applySynced(int uid, List<FloorBookmark> save) => _serial(() async {
    if (save.isEmpty) {
      return;
    }
    final items = {...await _load(uid)};
    var changed = false;
    for (final bookmark in save) {
      final mine = items[bookmark.key];
      if (mine != null && mine.updated >= bookmark.updated) {
        continue;
      }
      items[bookmark.key] = bookmark;
      changed = true;
    }
    if (changed) {
      await _save(uid, items);
    }
  });

  /// Drop every bookmark of account [uid] (the account was removed from the device).
  Future<void> forget(int uid) => _serial(() async {
    _accounts.remove(uid);
    await _delete(rowKeyOf(uid));
    _changes.add(uid);
  });

  /// Stop.
  Future<void> dispose() => _changes.close();
}
