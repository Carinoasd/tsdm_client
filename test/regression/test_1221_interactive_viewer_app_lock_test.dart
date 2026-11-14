// The interactive post viewer is an Android activity of its own, above the Flutter pages and out of reach of the app
// lock screen. Opening it tells it the lock's time away while the lock is on, so it closes itself where the app would
// lock (the native side, InteractiveHtmlActivityTest); with the lock off the call is as before.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_viewer.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _viewer = MethodChannel('kzs.th000.tsdm_client/interactiveHtmlChannel');
const _html = '<button onclick="this.textContent=\'done\'">Start</button>';

final class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<bool> isAvailable() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const hasher = PinHasher(iterations: 10);
  final calls = <MethodCall>[];

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_viewer, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_viewer, null);
    await getIt.reset();
  });

  Future<void> register(AppLockConfig config) async {
    getIt.registerSingleton<AppLockCubit>(
      AppLockCubit(config: config, store: AppLockStore.memory(), biometrics: _NoBiometrics(), hasher: hasher),
    );
  }

  Future<Map<Object?, Object?>> open() async {
    final result = await openInteractivePost(html: _html, postId: '42', currentUid: 7);
    expect(result, InteractivePostOpenResult.viewer);
    return calls.single.arguments as Map<Object?, Object?>;
  }

  test('without the lock nothing about it is sent', () async {
    expect((await open()).containsKey('appLockDelayMs'), isFalse);
  });

  test('a lock that is not on (no PIN) sends nothing either', () async {
    await register(const AppLockConfig(method: AppLockMethod.pin));
    expect(interactivePostAppLockDelayMs(), isNull);
    expect((await open()).containsKey('appLockDelayMs'), isFalse);
  });

  for (final (timing, ms) in [
    (AppLockTiming.immediately, 0),
    (AppLockTiming.oneMinute, 60000),
    (AppLockTiming.fiveMinutes, 300000),
  ]) {
    test('lock on, ${timing.name}: the viewer gets $ms ms', () async {
      await register(AppLockConfig(method: AppLockMethod.pin, pin: await hasher.hash('1234'), timing: timing));
      expect((await open())['appLockDelayMs'], ms);
    });
  }

  test('the native side reads it into the viewer intent', () {
    // MainActivity hands the number on; InteractiveHtmlActivity closes on its return and on its recreation.
    const root = 'android/app/src/main/kotlin/kzs/th000/tsdm_client';
    final main = File('$root/MainActivity.kt').readAsStringSync();
    expect(main, contains('(call.argument<Any>("appLockDelayMs") as? Number)?.toLong()'));
    final viewer = File('$root/InteractiveHtmlActivity.kt').readAsStringSync();
    expect(viewer, contains('closesWhenRecreated(appLockDelayMs, savedInstanceState != null)'));
    expect(viewer, contains('closesOnReturn(appLockDelayMs, at, SystemClock.elapsedRealtime())'));
  });
}
