/// The app lock with a window the app hides itself (the desktop boss key): the time away counts from the moment it is
/// hidden, whatever the desktop reports for the hidden window, and the lock is decided when it is shown again, before
/// it is seen; with "every time" it locks as it hides. Reported twice (by the boss key and by the desktop), it still
/// locks once. The lock screen it brings up asks for the system unlock (Windows Hello, Touch ID) only once the window
/// is shown again, not as it hides.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/features/app_lock/widgets/app_lock_gate.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

final class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<bool> isAvailable() async => false;
}

final class _CountingBiometrics implements BiometricAuthenticator {
  int calls = 0;

  @override
  Future<bool> authenticate(String reason) async {
    calls += 1;
    return false;
  }

  @override
  Future<bool> isAvailable() async => true;
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  const hasher = PinHasher(iterations: 10);
  late DateTime wall;
  late Duration boot;

  setUp(() {
    wall = DateTime(2026, 11, 17, 12);
    boot = const Duration(hours: 2);
  });

  void pass(Duration d) {
    wall = wall.add(d);
    boot += d;
  }

  Future<AppLockCubit> unlocked(AppLockTiming timing, {bool enabled = true}) async {
    final cubit = AppLockCubit(
      config: enabled
          ? AppLockConfig(method: AppLockMethod.pin, pin: await hasher.hash('1234'), timing: timing)
          : const AppLockConfig(),
      store: AppLockStore.memory(),
      biometrics: _NoBiometrics(),
      hasher: hasher,
      now: () => wall,
      sinceBoot: () => boot,
    );
    if (enabled) {
      expect(cubit.state.locked, isTrue);
      expect(await cubit.unlockWithPin('1234'), isTrue);
    }
    cubit.onLifecycleChanged(AppLifecycleState.resumed);
    return cubit;
  }

  test('locks when shown after the delay, not before', () async {
    final cubit = await unlocked(AppLockTiming.oneMinute);
    cubit.windowHidden();
    expect(cubit.state.locked, isFalse);
    pass(const Duration(seconds: 59));
    cubit.windowShown();
    expect(cubit.state.locked, isFalse);

    cubit.windowHidden();
    pass(const Duration(minutes: 1));
    cubit.windowShown();
    expect(cubit.state.locked, isTrue);
    await cubit.close();
  });

  test('with "every time" it locks as the window hides', () async {
    final cubit = await unlocked(AppLockTiming.immediately);
    cubit.windowHidden();
    expect(cubit.state.locked, isTrue);
    await cubit.close();
  });

  test('what the desktop reports while the window is hidden does not bring it back', () async {
    // Losing the focus as the window goes: inactive, which after leaving otherwise means back.
    final cubit = (await unlocked(AppLockTiming.oneMinute))
      ..windowHidden()
      ..onLifecycleChanged(AppLifecycleState.inactive);
    pass(const Duration(minutes: 2));
    cubit.onLifecycleChanged(AppLifecycleState.inactive);
    expect(cubit.state.locked, isFalse);
    cubit.windowShown();
    expect(cubit.state.locked, isTrue);
    await cubit.close();
  });

  test('told by both, in either order, it locks once', () async {
    for (final desktopFirst in [false, true]) {
      final cubit = await unlocked(AppLockTiming.oneMinute);
      var locks = 0;
      var wasLocked = cubit.state.locked;
      final subscription = cubit.stream.listen((s) {
        if (s.locked && !wasLocked) locks++;
        wasLocked = s.locked;
      });
      if (desktopFirst) {
        cubit
          ..onLifecycleChanged(AppLifecycleState.inactive)
          ..onLifecycleChanged(AppLifecycleState.hidden)
          ..windowHidden();
      } else {
        cubit
          ..windowHidden()
          ..onLifecycleChanged(AppLifecycleState.inactive)
          ..onLifecycleChanged(AppLifecycleState.hidden);
      }
      pass(const Duration(minutes: 5));
      cubit
        ..windowShown()
        ..onLifecycleChanged(AppLifecycleState.inactive)
        ..onLifecycleChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.locked, isTrue, reason: 'desktop first: $desktopFirst');
      expect(locks, 1, reason: 'desktop first: $desktopFirst');
      await subscription.cancel();
      await cubit.close();
    }
  });

  test('shown again without having been hidden by the app: nothing', () async {
    final cubit = await unlocked(AppLockTiming.oneMinute);
    pass(const Duration(minutes: 5));
    cubit.windowShown();
    expect(cubit.state.locked, isFalse);
    await cubit.close();
  });

  test('after the window is back, leaving the screen locks as before', () async {
    final cubit = await unlocked(AppLockTiming.oneMinute);
    cubit
      ..windowHidden()
      ..windowShown();
    [AppLifecycleState.inactive, AppLifecycleState.hidden].forEach(cubit.onLifecycleChanged);
    pass(const Duration(minutes: 1));
    [AppLifecycleState.inactive, AppLifecycleState.resumed].forEach(cubit.onLifecycleChanged);
    expect(cubit.state.locked, isTrue);
    await cubit.close();
  });

  test('with the lock off nothing locks', () async {
    final cubit = await unlocked(AppLockTiming.immediately, enabled: false);
    cubit.windowHidden();
    pass(const Duration(hours: 1));
    cubit.windowShown();
    expect(cubit.state.locked, isFalse);
    await cubit.close();
  });

  testWidgets('the system unlock is asked once the window is back, not as it hides', (tester) async {
    const fastHasher = PinHasher(iterations: 10, offUiIsolate: false);
    final biometrics = _CountingBiometrics();
    final cubit = AppLockCubit(
      config: AppLockConfig(
        method: AppLockMethod.biometric,
        pin: await fastHasher.hash('1234'),
        // The default: locked as it hides.
      ),
      store: AppLockStore.memory(),
      biometrics: biometrics,
      hasher: fastHasher,
    );
    addTearDown(cubit.close);
    await cubit.refreshBiometricAvailability();
    expect(await cubit.unlockWithPin('1234'), isTrue);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: const Scaffold(body: Text('content')),
          builder: (context, child) => AppLockGate(cubit: cubit, forgetAccounts: (_) async => false, child: child!),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    cubit.windowHidden();
    await tester.pumpAndSettle();
    expect(cubit.state.locked, isTrue);
    expect(biometrics.calls, 0, reason: 'the window is going: no system prompt');

    cubit.windowShown();
    await tester.pumpAndSettle();
    expect(biometrics.calls, 1);
  });
}
