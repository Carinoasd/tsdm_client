import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/stream.dart';
import 'package:tsdm_client/instance.dart';

/// A tap on a notification that makes a new activity over a Dart that runs already: the app was swiped away from the
/// recents while its process lived on (the background service, or the player), or the process was started without an
/// activity (the background service at boot or after an update: the audio service's engine runs `main()` then). That
/// Dart read the launch details once, at its boot: the tap brought the app to the front and opened nothing, and a
/// "reply not sent" notification was gone with its text.
///
/// The Android side (`MainActivity.kt`) hands the launch intent of such an activity to flutter_local_notifications as
/// a new intent, which tells Dart the way it does for an activity that runs; it cannot run here, its source is read.
/// The Dart side keeps a tap nobody listens to yet for the home page.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  tearDown(() => rememberLaunchPayload(null));

  NotificationResponse tap(String? payload) => NotificationResponse(
    notificationResponseType: NotificationResponseType.selectedNotification,
    id: 1,
    payload: payload,
  );

  // A reply typed in a notification that was not sent: the payload carries the text.
  final failedReply = LocalNoticeKeys.withTarget(
    LocalNoticeKeys.openNotificationOf(31),
    const LocalNoticeTarget(tid: 100, pid: 200, draft: 'typed in the notification'),
  );

  group('the activity made by the tap, over a Dart that runs', () {
    final source = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();

    String bodyOf(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '$signature not found');
      final end = source.indexOf('\n    }\n', start);
      return source.substring(start, end);
    }

    test('keeps its launch intent only when it is new', () {
      final onCreate = bodyOf('override fun onCreate(savedInstanceState: Bundle?)');
      final guarded = onCreate.substring(onCreate.indexOf('if (!replayed) {'));
      expect(guarded, contains('initialLaunchIntent = launch'));
      expect(
        onCreate.substring(0, onCreate.indexOf('if (!replayed) {')),
        isNot(contains('initialLaunchIntent = launch')),
        reason: 'an intent replayed from the recents or a restored state is not a tap',
      );
    });

    test('hands it to the notification plugin as a new intent, once', () {
      final push = bodyOf('private fun pushLaunchToRunningDart(flutterEngine: FlutterEngine)');
      expect(push, contains('flutterEngine.plugins.get(FlutterLocalNotificationsPlugin::class.java)'));
      expect(push, contains('.onNewIntent(launch)'));
      expect(
        push.indexOf('initialLaunchIntent = null'),
        lessThan(push.indexOf('.onNewIntent(launch)')),
        reason: 'forgotten before it is handed over',
      );
    });

    test('only a Dart that runs already is told: one that starts reads the launch details itself', () {
      final configure = bodyOf('override fun configureFlutterEngine(flutterEngine: FlutterEngine)');
      expect(
        configure,
        contains(
          '        if (dartRunning) {\n'
          '            pushLaunchToRunningDart(flutterEngine)\n'
          '        } else {\n',
        ),
      );
      expect(configure.substring(configure.indexOf('} else {')), contains('initialLaunchIntent = null'));
      expect(File('lib/main.dart').readAsStringSync(), contains('await rememberNotificationLaunch()'));
    });

    test('a Dart that runs: the engine was there before the activity, whoever made it', () {
      // Not "the engine of the activity before": a process started by the background service runs `main()` with no
      // activity at all, and the first activity is the one the tap makes.
      final onCreate = bodyOf('override fun onCreate(savedInstanceState: Bundle?)');
      const asked =
          'engineRanBefore = FlutterEngineCache.getInstance().contains(AudioServicePlugin.getFlutterEngineId())';
      expect(onCreate, contains(asked));
      expect(
        onCreate.indexOf(asked),
        lessThan(onCreate.indexOf('super.onCreate(savedInstanceState)')),
        reason: 'super.onCreate makes the engine when there is none',
      );
      expect(
        bodyOf('override fun configureFlutterEngine(flutterEngine: FlutterEngine)'),
        contains('val dartRunning = engineRanBefore'),
      );
    });

    test('what a Dart started a moment ago does not take is kept for its question', () {
      final push = bodyOf('private fun pushLaunchToRunningDart(flutterEngine: FlutterEngine)');
      expect(push, contains('links.invokeMethod("onDeepLink", it, unheard { initialDeepLink = it })'));
      expect(push, contains('channel.invokeMethod(ShareIntents.ON_SHARE, payload, unheard {'));
      expect(push.substring(push.indexOf('ShareIntents.ON_SHARE')), contains('initialShareIntent = pending'));
      final shortcuts = File(
        'android/app/src/main/kotlin/kzs/th000/tsdm_client/ShortcutsHandler.kt',
      ).readAsStringSync();
      final pushPending = shortcuts.substring(
        shortcuts.indexOf('fun pushPending()'),
        shortcuts.indexOf('fun onNewIntent'),
      );
      expect(pushPending, contains('override fun notImplemented() {'));
      expect(pushPending.substring(pushPending.indexOf('notImplemented')), contains('pending = it'));
    });
  });

  group('a tap told to Dart', () {
    // The tests run on a desktop, where a tap also brings the window back (`window_manager`).
    TestWidgetsFlutterBinding.ensureInitialized();
    const windowChannel = MethodChannel('window_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    setUp(
      () => messenger.setMockMethodCallHandler(
        windowChannel,
        (call) async => call.method == 'isMinimized' ? false : null,
      ),
    );
    tearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

    test('with the home page listening: forwarded at once, nothing parked', () async {
      final got = <String?>[];
      final sub = localNoticeStream.stream.listen(got.add);
      addTearDown(sub.cancel);
      unawaited(onLocalNotificationOpened(tap(failedReply)));
      await Future<void>.delayed(Duration.zero);
      expect(got, [failedReply]);
      expect(pendingLaunchPayload, isNull);
    });

    test('before the home page listens: kept for it, with the text of the reply', () async {
      expect(localNoticeStream.hasListener, isFalse);
      await onLocalNotificationOpened(tap(failedReply));
      expect(pendingLaunchPayload, failedReply);

      final seen = <String>[];
      expect(await consumePendingLaunchPayload(seen.add), isTrue);
      expect(LocalNoticeKeys.parseTarget(seen.single)?.draft, 'typed in the notification');
      expect(await consumePendingLaunchPayload(seen.add), isFalse, reason: 'handed over once');
    });

    test('the log line of the tap names the draft without its text', () {
      // Used to print a literal "\$1…" in place of "#draft=…": String.replaceAll takes no group references.
      expect(
        LocalNoticeKeys.loggable(failedReply),
        'openNotification:31#tid=100&pid=200&draft=…',
      );
    });

    test('a payload that is not of this app is never parked', () async {
      await onLocalNotificationOpened(tap('something else'));
      await onLocalNotificationOpened(tap(null));
      expect(pendingLaunchPayload, isNull);
    });
  });
}
