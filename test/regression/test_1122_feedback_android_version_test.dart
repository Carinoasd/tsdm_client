import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/diagnostics/feedback.dart';
import 'package:tsdm_client/features/thread/v1/models/thread_reply_prefill.dart';
import 'package:tsdm_client/utils/method_channel.dart';

/// F2-3: the reply to the feedback thread told no system version on Android (the one Dart gives there is the build's
/// display id, which names the device model and was left out). The activity now tells the release and the API level
/// (`Build.VERSION.RELEASE`, `SDK_INT`) on the main channel: `android 14 (API 34)`, never the model or a vendor's
/// build string.

const _channel = 'kzs.th000.tsdm_client/mainChannel';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the environment line on Android', () {
    test('release and API level', () {
      expect(
        feedbackEnvironmentLine(appVersion: '1.57.1', platform: 'android', androidRelease: '14', androidSdk: 34),
        'tsdm_client 1.57.1 · android 14 (API 34)',
      );
      expect(
        feedbackEnvironmentLine(appVersion: '1.57.1', platform: 'android', androidRelease: ' 8.1.0 ', androidSdk: 27),
        'tsdm_client 1.57.1 · android 8.1.0 (API 27)',
      );
    });

    test("the build's display id is never told, whatever Dart gives", () {
      expect(
        feedbackEnvironmentLine(
          appVersion: '1.57.1',
          platform: 'android',
          osVersion: 'TP1A.220624.014.S908EXXU2CWA2',
          androidRelease: '13',
          androidSdk: 33,
        ),
        'tsdm_client 1.57.1 · android 13 (API 33)',
      );
    });

    test('nothing told: as before; an odd release is left out, the API level kept', () {
      expect(feedbackEnvironmentLine(appVersion: '1.57.1', platform: 'android'), 'tsdm_client 1.57.1 · android');
      expect(
        feedbackEnvironmentLine(appVersion: '1.57.1', platform: 'android', androidRelease: '', androidSdk: 0),
        'tsdm_client 1.57.1 · android',
      );
      expect(
        feedbackEnvironmentLine(
          appVersion: '1.57.1',
          platform: 'android',
          androidRelease: 'HUAWEI ANA-AN00 2.0.0(C00E160R5P3)',
          androidSdk: 29,
        ),
        'tsdm_client 1.57.1 · android (API 29)',
      );
    });

    test('other platforms are not touched by the Android values', () {
      expect(
        feedbackEnvironmentLine(
          appVersion: '1.57.1',
          platform: 'ios',
          osVersion: 'Version 17.0',
          androidRelease: '14',
          androidSdk: 34,
        ),
        'tsdm_client 1.57.1 · ios Version 17.0',
      );
    });
  });

  group('the main channel', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(const MethodChannel(_channel), null));

    void answer(Object? Function(MethodCall call) handler) => messenger.setMockMethodCallHandler(
      const MethodChannel(_channel),
      (call) async => handler(call),
    );

    test('systemVersion: release and sdk', () async {
      final calls = <String>[];
      answer((call) {
        calls.add(call.method);
        return {'release': '14', 'sdk': 34};
      });
      expect(await androidSystemVersion(), (release: '14', sdk: 34));
      expect(calls, ['systemVersion']);
    });

    test('no answer, an error or a malformed one: null', () async {
      expect(await androidSystemVersion(), isNull, reason: 'no handler');
      answer((_) => throw PlatformException(code: 'x'));
      expect(await androidSystemVersion(), isNull);
      answer((_) => {'release': 14, 'sdk': '34'});
      expect(await androidSystemVersion(), isNull);
      answer((_) => null);
      expect(await androidSystemVersion(), isNull);
    });
  });

  test('the opener waits for the environment of the app and puts it in the reply', () async {
    final opened = <ThreadReplyPrefill>[];
    final opener = FeedbackThreadOpener(
      isLoggedIn: () => true,
      login: () async {},
      open: (route, prefill) async => opened.add(prefill),
      environment: () async => 'tsdm_client 1.57.1 · android 14 (API 34)',
    );
    expect(await opener.openWith('Blank page.'), isTrue);
    expect(opened.single.text, 'Blank page.\n\ntsdm_client 1.57.1 · android 14 (API 34)');
  });

  group('Android side', () {
    final activity = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
    final channel = File('lib/utils/method_channel.dart').readAsStringSync();

    test('the names agree on both sides', () {
      expect(activity, contains('SYSTEM_VERSION = "systemVersion"'));
      expect(channel, contains("_methodSystemVersion = 'systemVersion'"));
    });

    test('the activity answers with the release and the API level only', () {
      final branch = RegExp(r'SYSTEM_VERSION -> result\.success\([\s\S]*?\n            \)').firstMatch(activity);
      expect(branch, isNotNull);
      final body = branch!.group(0)!;
      expect(body, contains('"release" to Build.VERSION.RELEASE'));
      expect(body, contains('"sdk" to Build.VERSION.SDK_INT'));
      for (final leak in ['MODEL', 'MANUFACTURER', 'DISPLAY', 'FINGERPRINT', 'BRAND', 'DEVICE']) {
        expect(body, isNot(contains('Build.$leak')), reason: leak);
      }
    });
  });
}
