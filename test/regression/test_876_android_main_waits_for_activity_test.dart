import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/android_activity.dart';
import 'package:tsdm_client/utils/method_channel.dart';

/// The app opened for the first time after the phone started or the app was updated: the home page said its update
/// failed and took the account as signed out until "retry", the app lock found no biometrics, the icon and the
/// refresh rate were not applied.
///
/// On Android the app runs in the engine of the audio service, which makes it and runs `main()` whenever the service
/// is created while the engine does not exist: bound by the Bluetooth stack at boot, or by the audio service's plugin
/// of the engine of the background message service or of the notification plugin. With no activity the channels the
/// activity sets up do not exist: every call of that `main()` ended in a `MissingPluginException`, the requests of the
/// home page among them, and the app opened later showed that failed start.
///
/// `main()` waits for the activity now, before it starts anything.
void main() {
  group('the wait', () {
    late StreamController<void> lifecycle;
    late bool there;
    late bool inFront;
    late int asked;
    late int toldWaiting;
    ({Duration waited, bool answered})? result;

    setUp(() {
      lifecycle = StreamController<void>.broadcast();
      there = false;
      inFront = false;
      asked = 0;
      toldWaiting = 0;
      result = null;
    });
    tearDown(() => lifecycle.close());

    void start() => unawaited(
      waitForActivity(
        attached: () async {
          asked++;
          return there;
        },
        lifecycleChanges: lifecycle.stream,
        inFront: () => inFront,
        onWaiting: () => toldWaiting++,
      ).then((value) => result = value),
    );

    testWidgets('an activity that is there: nothing is waited for', (tester) async {
      there = true;
      start();
      await tester.pump();
      expect(result, (waited: Duration.zero, answered: true));
      expect(asked, 1);
      expect(toldWaiting, 0);
      expect(lifecycle.hasListener, isFalse);
    });

    testWidgets('no activity: held until one attaches, which the lifecycle tells at once', (tester) async {
      start();
      await tester.pump();
      expect(result, isNull);
      expect(toldWaiting, 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(asked, 1, reason: 'asked again on a change or two seconds later, not in between');

      there = true;
      lifecycle.add(null);
      await tester.pump();
      expect(result?.answered, isTrue);
      expect(result!.waited, greaterThan(Duration.zero));
      expect(asked, 2);
      expect(lifecycle.hasListener, isFalse, reason: 'nothing is left listening or ticking');
    });

    testWidgets('a change of the lifecycle with still no activity keeps waiting', (tester) async {
      start();
      await tester.pump();
      lifecycle.add(null);
      await tester.pump();
      expect(asked, 2);
      expect(result, isNull);

      // Days later.
      await tester.pump(const Duration(hours: 1));
      expect(result, isNull);
      there = true;
      lifecycle.add(null);
      await tester.pump();
      expect(result?.answered, isTrue);
    });

    testWidgets('an activity that told nothing is found by asking again', (tester) async {
      start();
      await tester.pump();
      there = true;
      await tester.pump(const Duration(seconds: 1));
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(result?.answered, isTrue);
      expect(asked, 2);
    });

    testWidgets('an activity in front that never answers does not keep the app behind its splash screen', (
      tester,
    ) async {
      start();
      await tester.pump();
      // Not in front: asked for as long as it takes.
      await tester.pump(const Duration(seconds: 20));
      expect(result, isNull);

      inFront = true;
      lifecycle.add(null);
      await tester.pump();
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(result?.answered, isFalse);
      expect(lifecycle.hasListener, isFalse);
    });

    testWidgets('unanswered rounds count in a row only', (tester) async {
      start();
      await tester.pump();
      inFront = true;
      lifecycle.add(null);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(asked, 3);
      // Gone to the background again before the third.
      inFront = false;
      lifecycle.add(null);
      await tester.pump();
      inFront = true;
      lifecycle.add(null);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(result?.answered, isFalse);
    });

    testWidgets('with nothing in front it asks less and less often, and at once again when the lifecycle changes', (
      tester,
    ) async {
      start();
      await tester.pump();
      // After 2, 4, 8 and 16 seconds, then every 30.
      await tester.pump(const Duration(seconds: 14));
      expect(asked, 4);
      await tester.pump(const Duration(seconds: 16));
      expect(asked, 5);
      await tester.pump(const Duration(seconds: 29));
      expect(asked, 5);
      await tester.pump(const Duration(seconds: 1));
      expect(asked, 6);
      await tester.pump(const Duration(hours: 1));
      expect(asked, 6 + 120, reason: 'two questions a minute, days long if it takes that');

      lifecycle.add(null);
      await tester.pump();
      expect(asked, 6 + 120 + 1);
      // From the short time again.
      await tester.pump(const Duration(seconds: 4));
      expect(asked, 6 + 120 + 2);
      there = true;
      await tester.pump(const Duration(seconds: 30));
      expect(result?.answered, isTrue);
    });
  });

  group('whether the activity is there', () {
    const channel = MethodChannel('kzs.th000.tsdm_client/mainChannel');
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('nothing answers on the main channel: no activity', () async {
      expect(await androidActivityAttached(), isFalse);
    });

    test('the main channel answers: the activity set it up', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return false;
      });
      expect(await androidActivityAttached(), isTrue);
      // A question with no effect on the activity.
      expect(calls, ['isActiveNetworkMetered']);
    });

    test('an error is an answer too', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'failed'));
      expect(await androidActivityAttached(), isTrue);
    });
  });

  // These read the sources: what they guard cannot run in a test. A failure after a refactoring that keeps the
  // behaviour told in each `reason` means the test is to follow the new text, not the other way round.
  group('the sources', () {
    test('main() waits before it starts anything of the app', () {
      final source = File('lib/main.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _boot(List<String> args) async {');
      expect(start, isNonNegative, reason: 'the body of main() is read from _boot');
      final boot = source.substring(start);
      final wait = boot.indexOf('await waitForAndroidActivity();');
      expect(wait, isNonNegative, reason: 'main() must wait for the Android activity before it starts the app');
      expect(
        boot.indexOf('await initLogger();'),
        allOf(isNonNegative, lessThan(wait)),
        reason: 'the log is opened first: the wait is told in it',
      );
      for (final later in [
        'await initProviders();',
        'await AppLockCubit.load();',
        'flnp = FlutterLocalNotificationsPlugin();',
        'await rememberNotificationLaunch();',
        'await initAudioPlayer();',
        'runApp(',
      ]) {
        expect(
          boot.indexOf(later),
          greaterThan(wait),
          reason: '$later calls the channels of the activity, or follows what does: after the wait',
        );
      }
    });

    test('the activity sets the main channel up when it attaches, and answers the question asked', () {
      final source = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
      final start = source.indexOf('override fun configureFlutterEngine(flutterEngine: FlutterEngine)');
      expect(start, isNonNegative, reason: 'the activity configures its engine in configureFlutterEngine');
      final configure = source.substring(start, source.indexOf('\n    }\n', start));
      expect(
        configure,
        contains(
          RegExp(
            r'mainChannel = MethodChannel\(flutterEngine\.dartExecutor\.binaryMessenger, MAIN_CHANNEL\)\.also \{\s*'
            r'it\.setMethodCallHandler \{ call, result -> handleMainChannelCall\(call, result\) \}',
          ),
        ),
        reason:
            'the wait ends when the main channel answers: its handler must be set when the activity attaches to the '
            'engine (before its lifecycle is told), nowhere that runs without an activity',
      );
      expect(
        source,
        contains('const val MAIN_CHANNEL = "kzs.th000.tsdm_client/mainChannel"'),
        reason: 'the channel asked by androidActivityAttached()',
      );
      expect(
        source,
        allOf(
          contains('const val IS_ACTIVE_NETWORK_METERED = "isActiveNetworkMetered"'),
          contains('IS_ACTIVE_NETWORK_METERED -> {'),
        ),
        reason: 'the method asked by androidActivityAttached(): answered, with no effect',
      );
    });
  });
}
