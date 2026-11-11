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
      expect(asked, 1, reason: 'asked again on a change or every two seconds, not in between');

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
      // Gone to the background again before the third.
      inFront = false;
      await tester.pump(const Duration(seconds: 2));
      inFront = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(result?.answered, isFalse);
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

  group('the sources', () {
    test('main() waits before it starts anything of the app', () {
      final source = File('lib/main.dart').readAsStringSync();
      final boot = source.substring(source.indexOf('Future<void> _boot(List<String> args) async {'));
      final wait = boot.indexOf('await waitForAndroidActivity();');
      expect(wait, isNonNegative);
      // The log first: the wait is told in it.
      expect(boot.indexOf('await initLogger();'), lessThan(wait));
      for (final later in [
        'await initProviders();',
        'await AppLockCubit.load();',
        'flnp = FlutterLocalNotificationsPlugin();',
        'await rememberNotificationLaunch();',
        'await initAudioPlayer();',
        'runApp(',
      ]) {
        expect(boot.indexOf(later), greaterThan(wait), reason: '$later needs the activity or follows what does');
      }
    });

    test('the activity sets the main channel up when it attaches, and answers the question asked', () {
      final source = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
      final start = source.indexOf('override fun configureFlutterEngine(flutterEngine: FlutterEngine)');
      final configure = source.substring(start, source.indexOf('\n    }\n', start));
      expect(
        configure,
        contains(
          RegExp(
            r'mainChannel = MethodChannel\(flutterEngine\.dartExecutor\.binaryMessenger, MAIN_CHANNEL\)\.also \{\s*'
            r'it\.setMethodCallHandler \{ call, result -> handleMainChannelCall\(call, result\) \}',
          ),
        ),
      );
      expect(source, contains('const val MAIN_CHANNEL = "kzs.th000.tsdm_client/mainChannel"'));
      expect(source, contains('const val IS_ACTIVE_NETWORK_METERED = "isActiveNetworkMetered"'));
      expect(source, contains('IS_ACTIVE_NETWORK_METERED -> {'));
    });
  });
}
