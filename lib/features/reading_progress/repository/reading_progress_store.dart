import 'dart:async';

import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';

/// Where the reading progress of the accounts is kept: with the visit records of the threads.
abstract interface class ReadingProgressStore {
  /// The threads account [uid] visited (by tid) with where it stopped reading them, again whenever it changes.
  ///
  /// A thread visited before its progress was kept is there with an empty [ReadingProgress].
  Stream<Map<int, ReadingProgress>> watch(int uid);

  /// Keep [progress] as where account [uid] stopped reading thread [tid].
  Future<void> save(int uid, int tid, ReadingProgress progress);
}

/// A [ReadingProgressStore] in memory: nothing outlives the app (tests, and until the stored one is there).
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

/// The store of the app.
// TODO(reading-progress): the visit records of the database (schema 17) once the notification center's schema 16 is
//  in; in memory until then.
final ReadingProgressStore appReadingProgressStore = MemoryReadingProgressStore();
