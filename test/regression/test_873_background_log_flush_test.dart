/// The log file of the isolates without a page (`BackgroundLogSink`): the ticks of the background message service
/// overlap (the notification tick, the followed threads, the watched forums), each ending with a flush of the same
/// file, and lines are logged while one of them is flushing.
///
/// Seen on the Android 14 emulator, twice a minute: `Unhandled Exception: Bad state: StreamSink is bound to a stream`
/// at the `await logSink.flush()` of `tick` and `watchTick` (`background_sync_entry.dart`). An `IOSink` takes neither
/// a second flush nor a write while a flush is running.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/background_sync/background_isolate.dart';

/// A file sink whose disk can fail: while [broken], a flush fails and a write is refused.
final class _FailingSink extends Fake implements IOSink {
  final written = StringBuffer();
  bool broken = false;

  @override
  void write(Object? object) {
    if (broken) {
      throw StateError('StreamSink is closed');
    }
    written.write(object);
  }

  @override
  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    if (broken) {
      throw const FileSystemException('no space left on device');
    }
  }
}

void main() {
  late Directory dir;
  late File file;
  late IOSink raw;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tsdm_bg_log_');
    file = File('${dir.path}/bg.log');
    raw = file.openWrite(mode: FileMode.append);
  });

  tearDown(() async {
    try {
      await raw.flush();
    } on Object {
      // Already failed in the test.
    }
    await raw.close();
    dir.deleteSync(recursive: true);
  });

  test('what the sink is for: a plain IOSink refuses a second flush and a write during a flush', () async {
    raw.write('a\n');
    final first = raw.flush();
    expect(raw.flush, throwsStateError);
    expect(() => raw.write('b\n'), throwsStateError);
    await first;
  });

  test('flushes asked at the same time all complete, nothing thrown', () async {
    final sink = BackgroundLogSink(raw)..write('tick\n');
    // As the ticks do: each ends with `await logSink.flush()` while the others are still flushing.
    final flushes = [for (var i = 0; i < 6; i++) sink.flush()];
    await expectLater(Future.wait(flushes), completes);
    expect(file.readAsStringSync(), 'tick\n');
  });

  test('lines written during a flush are kept, in the order they were written', () async {
    final sink = BackgroundLogSink(raw);
    final flushes = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      sink.write('line $i\n');
      if (i.isEven) {
        flushes.add(sink.flush());
      }
      if (i % 5 == 0) {
        // Let the running flush get somewhere before the next lines.
        await Future<void>.delayed(Duration.zero);
      }
    }
    await Future.wait(flushes);
    await sink.flush();
    expect(file.readAsLinesSync(), [for (var i = 0; i < 20; i++) 'line $i']);
  });

  test('a flush is done only when what was written before it is in the file', () async {
    final sink = BackgroundLogSink(raw)..write('one\n');
    final first = sink.flush();
    // Held back: the first flush is running.
    sink.write('two\n');
    final second = sink.flush();
    sink.write('three\n');
    final third = sink.flush();
    expect(identical(second, third), isTrue, reason: 'one flush waits for the running one, shared');

    await first;
    expect(file.readAsStringSync(), startsWith('one\n'));
    await second;
    expect(file.readAsStringSync(), 'one\ntwo\nthree\n');

    // Nothing running any more: the next line goes straight to the file's sink.
    sink.write('four\n');
    await sink.flush();
    expect(file.readAsLinesSync(), ['one', 'two', 'three', 'four']);
  });

  test('a flush that fails gives its own error, the lines the sink did not take wait for the next, in order', () async {
    final failing = _FailingSink();
    final sink = BackgroundLogSink(failing)..write('one\n');
    failing.broken = true;
    final first = sink.flush();
    // Held back while the flush runs; the sink does not take them when it ends.
    sink.write('two\n');
    await expectLater(first, throwsA(isA<FileSystemException>()));
    sink.write('three\n');
    expect(failing.written.toString(), 'one\n');

    failing.broken = false;
    await sink.flush();
    sink.write('four\n');
    expect(failing.written.toString(), 'one\ntwo\nthree\nfour\n');
  });

  test('the ticks of the service, overlapping for a while: no unhandled error', () async {
    final sink = BackgroundLogSink(raw);
    final errors = <Object>[];
    await runZonedGuarded(
      () async {
        Future<void> tick(String name, int steps) async {
          try {
            for (var i = 0; i < steps; i++) {
              sink.write('$name $i\n');
              await Future<void>.delayed(Duration.zero);
            }
          } finally {
            await sink.flush();
          }
        }

        // Not awaited one by one, as the timers of the service start them.
        final ticks = <Future<void>>[];
        for (var round = 0; round < 5; round++) {
          ticks
            ..add(tick('tick$round', 3))
            ..add(tick('follow$round', 2))
            ..add(tick('watch$round', 2));
        }
        // An error thrown in the zone may leave these undone: failed by the timeout, not hung.
        await Future.wait(ticks).timeout(const Duration(seconds: 10));
        await sink.flush();
      },
      (e, _) => errors.add(e),
    );
    expect(errors, isEmpty);
    final lines = file.readAsLinesSync();
    expect(lines, hasLength(5 * (3 + 2 + 2)));
    for (var round = 0; round < 5; round++) {
      expect(lines.where((e) => e.startsWith('tick$round ')), ['tick$round 0', 'tick$round 1', 'tick$round 2']);
    }
  });
}
