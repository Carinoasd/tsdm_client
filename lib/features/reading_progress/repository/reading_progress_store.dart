import 'dart:async';

import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Where the reading progress of the accounts is kept: with the visit records of the threads.
abstract interface class ReadingProgressStore {
  /// The threads account [uid] visited (by tid) with where it stopped reading them, again whenever it changes.
  ///
  /// A thread visited before its progress was kept is there with an empty [ReadingProgress].
  Stream<Map<int, ReadingProgress>> watch(int uid);

  /// Keep [progress] as where account [uid] stopped reading thread [tid].
  Future<void> save(int uid, int tid, ReadingProgress progress);
}

/// The reading progress kept with the visit records of the database (`ThreadVisitHistory`, schema 17).
///
/// A visit is recorded by the thread page when a page of the thread loads; the progress is written on that record
/// afterwards, and is nothing without it (a thread whose visit is not kept: a blocked author, a guest).
final class StorageReadingProgressStore implements ReadingProgressStore {
  /// Constructor.
  const StorageReadingProgressStore(this._storage);

  final StorageProvider _storage;

  @override
  Stream<Map<int, ReadingProgress>> watch(int uid) => _storage
      .watchThreadVisitProgress(uid)
      .map(
        (rows) => {
          for (final MapEntry(key: tid, value: row) in rows.entries)
            tid: ReadingProgress(page: row.page, pid: row.pid, floor: row.floor, seenReplies: row.seenReplies),
        },
      );

  @override
  Future<void> save(int uid, int tid, ReadingProgress progress) => _storage.updateThreadVisitProgress(
    uid: uid,
    tid: tid,
    page: progress.page,
    pid: progress.pid,
    floor: progress.floor,
    seenReplies: progress.seenReplies,
  );
}

/// A [ReadingProgressStore] in memory: nothing outlives the app (tests).
final class MemoryReadingProgressStore implements ReadingProgressStore {
  final _progress = <int, Map<int, ReadingProgress>>{};
  final _changes = StreamController<int>.broadcast();

  Map<int, ReadingProgress> _snapshot(int uid) => Map.unmodifiable(_progress[uid] ?? const <int, ReadingProgress>{});

  @override
  Stream<Map<int, ReadingProgress>> watch(int uid) {
    StreamSubscription<int>? changes;
    late final StreamController<Map<int, ReadingProgress>> controller;
    controller = StreamController(
      onListen: () {
        controller.add(_snapshot(uid));
        changes = _changes.stream.where((e) => e == uid).listen((_) => controller.add(_snapshot(uid)));
      },
      onCancel: () => changes?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<void> save(int uid, int tid, ReadingProgress progress) async {
    (_progress[uid] ??= {})[tid] = progress;
    _changes.add(uid);
  }

  /// Forget everything (tests).
  void clear() {
    final uids = _progress.keys.toList();
    _progress.clear();
    uids.forEach(_changes.add);
  }
}
