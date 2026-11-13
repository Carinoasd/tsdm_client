import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/diagnostics/abnormal_exit.dart';
import 'package:tsdm_client/utils/error_reporting.dart';

/// E: the marks of an abnormal end of the run ([AbnormalExitRecorder]). The error mark is written once per run and only
/// through the recorder the UI isolate armed (a background isolate writes nothing); the running mark only stands while
/// the app is in the front, so only an app that vanished in the front is asked about; asked once per abnormal end, at
/// most once in 24 hours.

late Directory _dir;
var _clock = DateTime(2026, 11, 15, 10);

AbnormalExitRecorder _recorder({bool trackForeground = true}) => AbnormalExitRecorder(
  directory: _dir,
  appVersion: '1.57.0+172',
  trackForeground: trackForeground,
  now: () => _clock,
);

File _mark(String name) => File('${_dir.path}${Platform.pathSeparator}$name');

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('abnormal_exit_');
    _clock = DateTime(2026, 11, 15, 10);
    AbnormalExitRecorder.disarm();
  });

  tearDown(() {
    AbnormalExitRecorder.disarm();
    _dir.deleteSync(recursive: true);
  });

  group('error mark', () {
    test('written once per run, with the type of the error and not its message', () {
      final recorder = _recorder()..arm();
      recordAbnormalError(StateError('secret message 123'));
      final first = _mark(AbnormalExitRecorder.errorFileName).readAsStringSync();
      expect(first, contains('StateError'));
      expect(first, contains('1.57.0+172'));
      expect(first, isNot(contains('secret message')));

      _clock = _clock.add(const Duration(minutes: 1));
      recorder.recordError(ArgumentError('second'));
      expect(_mark(AbnormalExitRecorder.errorFileName).readAsStringSync(), first);
    });

    test('nothing without an armed recorder', () {
      recordAbnormalError(StateError('x'));
      expect(_dir.listSync(), isEmpty);
    });

    test('a background isolate writes nothing, even while the UI isolate is armed', () async {
      _recorder().arm();
      final path = _dir.path;
      final armedThere = await Isolate.run(() {
        recordAbnormalError(StateError('in the background'));
        return AbnormalExitRecorder.armed != null || Directory(path).listSync().isNotEmpty;
      });
      expect(armedThere, isFalse);
      expect(_mark(AbnormalExitRecorder.errorFileName).existsSync(), isFalse);
    });

    test('never throws, even when the folder can not be written', () {
      final file = File('${_dir.path}${Platform.pathSeparator}blocked')..writeAsStringSync('');
      final recorder = AbnormalExitRecorder(directory: Directory(file.path), appVersion: 'v', trackForeground: true)
        ..arm();
      expect(() => recorder.recordError(StateError('x')), returnsNormally);
      expect(() => recorder.lifecycleChanged(AppLifecycleState.resumed), returnsNormally);
    });

    test('read and removed at the next start', () {
      _recorder().arm();
      recordAbnormalError(StateError('x'));
      AbnormalExitRecorder.disarm();

      final next = _recorder()..arm();
      expect(next.previous?.kind, AbnormalExitKind.error);
      expect(next.previous?.summary, contains('StateError'));
      expect(_mark(AbnormalExitRecorder.errorFileName).existsSync(), isFalse);

      final third = _recorder()..arm();
      expect(third.previous, isNull);
    });

    test('a failed image and a silent error do not count', () {
      FlutterErrorDetails details({String? library, bool silent = false}) =>
          FlutterErrorDetails(exception: StateError('x'), library: library, silent: silent);
      expect(countsAsAbnormal(details(library: 'widgets library')), isTrue);
      expect(countsAsAbnormal(details(library: 'image resource service')), isFalse);
      expect(countsAsAbnormal(details(library: 'widgets library', silent: true)), isFalse);
    });
  });

  group('running mark', () {
    test('kept in the front only', () {
      final recorder = _recorder()..arm(lifecycle: AppLifecycleState.resumed);
      expect(_mark(AbnormalExitRecorder.runningFileName).existsSync(), isTrue);
      recorder.lifecycleChanged(AppLifecycleState.inactive);
      expect(_mark(AbnormalExitRecorder.runningFileName).existsSync(), isFalse);
      recorder.lifecycleChanged(AppLifecycleState.resumed);
      expect(_mark(AbnormalExitRecorder.runningFileName).existsSync(), isTrue);
      recorder.lifecycleChanged(AppLifecycleState.paused);
      expect(_mark(AbnormalExitRecorder.runningFileName).existsSync(), isFalse);
    });

    test('vanished in the front: asked at the next start', () {
      _recorder().arm(lifecycle: AppLifecycleState.resumed);
      AbnormalExitRecorder.disarm();
      final next = _recorder()..arm(lifecycle: AppLifecycleState.resumed);
      expect(next.previous?.kind, AbnormalExitKind.vanished);
    });

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      test('ended after going to ${state.name} (swiped away, reclaimed, updated): not asked', () {
        _recorder()
          ..arm(lifecycle: AppLifecycleState.resumed)
          ..lifecycleChanged(state);
        AbnormalExitRecorder.disarm();
        expect((_recorder()..arm()).previous, isNull);
      });
    }

    test('started in the back: no mark until it comes to the front', () {
      _recorder().arm(lifecycle: AppLifecycleState.paused);
      expect(_mark(AbnormalExitRecorder.runningFileName).existsSync(), isFalse);
    });

    test('not kept where it is not tracked (desktop, debug)', () {
      _recorder(trackForeground: false).arm(lifecycle: AppLifecycleState.resumed);
      expect(_dir.existsSync() && _dir.listSync().isNotEmpty, isFalse);
      AbnormalExitRecorder.disarm();
      expect((_recorder()..arm()).previous, isNull);
    });
  });

  group('asking', () {
    const one = AbnormalExit(kind: AbnormalExitKind.error, id: '1');
    const two = AbnormalExit(kind: AbnormalExitKind.vanished, id: '2');
    final now = DateTime(2026, 11, 15, 10);

    test('nothing to ask without an abnormal end', () {
      expect(shouldAskAboutAbnormalExit(previous: null, asked: null, now: now), isFalse);
    });

    test('asked the first time', () {
      expect(shouldAskAboutAbnormalExit(previous: one, asked: null, now: now), isTrue);
    });

    test('the same abnormal end once only', () {
      final asked = (id: '1', at: now.subtract(const Duration(days: 3)));
      expect(shouldAskAboutAbnormalExit(previous: one, asked: asked, now: now), isFalse);
    });

    test('at most once in 24 hours', () {
      final recent = (id: '1', at: now.subtract(const Duration(hours: 23, minutes: 59)));
      expect(shouldAskAboutAbnormalExit(previous: two, asked: recent, now: now), isFalse);
      final dayAgo = (id: '1', at: now.subtract(const Duration(hours: 24)));
      expect(shouldAskAboutAbnormalExit(previous: two, asked: dayAgo, now: now), isTrue);
      final clockBack = (id: '1', at: now.add(const Duration(hours: 2)));
      expect(shouldAskAboutAbnormalExit(previous: two, asked: clockBack, now: now), isFalse);
    });

    test('taken once per run and counted as asked at once', () {
      _recorder().arm();
      recordAbnormalError(StateError('x'));
      AbnormalExitRecorder.disarm();

      final next = _recorder()..arm();
      expect(next.takePrompt()?.kind, AbnormalExitKind.error);
      expect(next.takePrompt(), isNull);

      // Another abnormal end an hour later: within the 24 hours, not asked.
      recordAbnormalError(StateError('y'));
      AbnormalExitRecorder.disarm();
      _clock = _clock.add(const Duration(hours: 1));
      final third = _recorder()..arm();
      expect(third.previous, isNotNull);
      expect(third.takePrompt(), isNull);

      // A day later, a new one is asked again.
      recordAbnormalError(StateError('z'));
      AbnormalExitRecorder.disarm();
      _clock = _clock.add(const Duration(hours: 25));
      final fourth = _recorder()..arm();
      expect(fourth.takePrompt(), isNotNull);
    });
  });
}
