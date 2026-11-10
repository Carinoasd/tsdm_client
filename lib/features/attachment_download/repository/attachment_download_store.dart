import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The attachment downloads of every account on this device: one settings row per account
/// (`attachmentDownloads.<uid>`, a JSON list, the newest first), never shown to another account.
///
/// Writes go one after another; a write asked before the account was forgotten ([forget]) is dropped.
final class AttachmentDownloadStore with LoggerMixin {
  /// Constructor: the app's storage.
  AttachmentDownloadStore()
    : _read = ((key) => getIt.get<StorageProvider>().getString(key)),
      _write = ((key, value) => getIt.get<StorageProvider>().saveString(key, value)),
      _delete = ((key) => getIt.get<StorageProvider>().deleteKey(key));

  /// A store in memory (tests), its rows in [rows].
  @visibleForTesting
  AttachmentDownloadStore.memory([Map<String, String>? rows]) : this._custom(rows ?? <String, String>{});

  AttachmentDownloadStore._custom(Map<String, String> rows)
    : _read = ((key) async => rows[key]),
      _write = ((key, value) async => rows[key] = value),
      _delete = ((key) async => rows.remove(key));

  /// The app's store, null when none is registered (tests of other features).
  static AttachmentDownloadStore? get app =>
      getIt.isRegistered<AttachmentDownloadStore>() ? getIt.get<AttachmentDownloadStore>() : null;

  /// The settings row of the downloads of account [uid].
  static String rowKeyOf(int uid) => 'attachmentDownloads.$uid';

  /// The most downloads an account keeps: the oldest finished ones go first.
  static const maxItems = 300;

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _delete;

  final _generations = <int, int>{};
  Future<void> _queue = Future.value();

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

  /// The downloads of account [uid], the newest first.
  Future<List<AttachmentDownload>> load(int uid) => _serial(() async {
    try {
      final text = await _read(rowKeyOf(uid));
      if (text == null || text.isEmpty) {
        return const [];
      }
      final json = jsonDecode(text);
      if (json is! List) {
        return const [];
      }
      return json.map(AttachmentDownload.fromJson).nonNulls.where((e) => e.uid == uid).toList();
    } on FormatException catch (e) {
      // Damaged: read as none, replaced at the next write.
      error('failed to read the attachment downloads of $uid: $e');
      return const [];
    }
  });

  /// Keep [items] as the downloads of account [uid] (the newest first, at most [maxItems]).
  Future<void> save(int uid, List<AttachmentDownload> items) {
    final generation = _generations[uid] ?? 0;
    final kept = items.where((e) => e.uid == uid).take(maxItems).map((e) => e.toJson()).toList();
    return _serial(() async {
      if (generation != (_generations[uid] ?? 0)) {
        return;
      }
      if (kept.isEmpty) {
        await _delete(rowKeyOf(uid));
      } else {
        await _write(rowKeyOf(uid), jsonEncode(kept));
      }
    });
  }

  /// Account [uid] was removed from this device: what is queued for it is not written (its row is deleted by the
  /// caller).
  void forget(int uid) => _generations[uid] = (_generations[uid] ?? 0) + 1;
}
