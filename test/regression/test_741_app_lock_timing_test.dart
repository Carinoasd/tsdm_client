/// When the app lock locks: at every start with the lock on, each time the app leaves the screen ("every time"), or
/// after one or five minutes away; losing the focus (the system biometric prompt, a dialog of another app) is not
/// leaving. Unlocking before an account switch can be cancelled, waits for the lock screen when the app is locked,
/// and counts an unlock of the last seconds.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/instance.dart';

final class _FakeBiometrics implements BiometricAuthenticator {
  bool result = true;
  int calls = 0;
  void Function()? during;

  @override
  Future<bool> authenticate(String reason) async {
    calls += 1;
    during?.call();
    return result;
  }

  @override
  Future<bool> isAvailable() async => true;
}

const List<AppLifecycleState> _away = [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused];
const List<AppLifecycleState> _back = [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed];

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const hasher = PinHasher(iterations: 10);
  late DateTime now;
  late _FakeBiometrics biometrics;

  setUp(() {
    now = DateTime(2026, 11, 9, 12);
    biometrics = _FakeBiometrics();
  });

  Future<AppLockCubit> unlocked(AppLockTiming timing, {AppLockMethod method = AppLockMethod.pin}) async {
    final cubit = AppLockCubit(
      config: AppLockConfig(method: method, pin: await hasher.hash('1234'), timing: timing),
      store: AppLockStore.memory(),
      biometrics: biometrics,
      hasher: hasher,
      now: () => now,
    );
    await cubit.refreshBiometricAvailability();
    expect(cubit.state.locked, isTrue);
    expect(await cubit.unlockWithPin('1234'), isTrue);
    return cubit;
  }

  void go(AppLockCubit cubit, List<AppLifecycleState> states) => states.forEach(cubit.onLifecycleChanged);

  group('AppLockTimer', () {
    test('keeps the first time the app left and locks after the delay', () {
      final timer = AppLockTimer()..left(now);
      timer.left(now.add(const Duration(seconds: 30)));
      expect(timer.leftAt, now);
      expect(timer.returned(now.add(const Duration(seconds: 59)), AppLockTiming.oneMinute), isFalse);
      expect(timer.leftAt, isNull);
      timer.left(now);
      expect(timer.returned(now.add(const Duration(minutes: 1)), AppLockTiming.oneMinute), isTrue);
      expect(timer.returned(now.add(const Duration(hours: 1)), AppLockTiming.oneMinute), isFalse, reason: 'not left');
    });

    test('a clock set back does not lock', () {
      final timer = AppLockTimer()..left(now);
      expect(timer.returned(now.subtract(const Duration(minutes: 10)), AppLockTiming.immediately), isFalse);
    });
  });

  test('"every time" locks as soon as the app is hidden, before it is seen again', () async {
    final cubit = await unlocked(AppLockTiming.immediately);
    cubit.onLifecycleChanged(AppLifecycleState.inactive);
    expect(cubit.state.locked, isFalse, reason: 'losing the focus is not leaving');
    cubit.onLifecycleChanged(AppLifecycleState.resumed);
    cubit.onLifecycleChanged(AppLifecycleState.inactive);
    cubit.onLifecycleChanged(AppLifecycleState.hidden);
    expect(cubit.state.locked, isTrue);
    go(cubit, [AppLifecycleState.paused, ..._back]);
    expect(cubit.state.locked, isTrue);
    await cubit.close();
  });

  for (final (timing, delay) in [
    (AppLockTiming.oneMinute, const Duration(minutes: 1)),
    (AppLockTiming.fiveMinutes, const Duration(minutes: 5)),
  ]) {
    test('${timing.name} locks only after that long away', () async {
      final cubit = await unlocked(timing);
      go(cubit, _away);
      expect(cubit.state.locked, isFalse);
      now = now.add(delay - const Duration(seconds: 1));
      go(cubit, _back);
      expect(cubit.state.locked, isFalse, reason: 'back in time');

      go(cubit, _away);
      now = now.add(delay);
      go(cubit, _back);
      expect(cubit.state.locked, isTrue);
      expect(await cubit.unlockWithPin('1234'), isTrue);

      // The time away counts from the first leaving, not from the hidden of the way back.
      go(cubit, _away);
      now = now.add(delay);
      cubit.onLifecycleChanged(AppLifecycleState.hidden);
      cubit.onLifecycleChanged(AppLifecycleState.inactive);
      expect(cubit.state.locked, isTrue);
      await cubit.close();
    });
  }

  test('a lifecycle change while the system biometric prompt is up is not leaving', () async {
    final cubit = await unlocked(AppLockTiming.immediately, method: AppLockMethod.biometric);
    cubit.onLifecycleChanged(AppLifecycleState.hidden);
    expect(cubit.state.locked, isTrue);
    biometrics.during = () =>
        go(cubit, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    expect(await cubit.unlockWithBiometric('unlock'), isTrue);
    expect(cubit.state.locked, isFalse);
    go(cubit, _back);
    expect(cubit.state.locked, isFalse, reason: 'the prompt closing must not lock again');
    await cubit.close();
  });

  test('a failed system unlock keeps the app locked, the PIN still unlocks', () async {
    final cubit = await unlocked(AppLockTiming.immediately, method: AppLockMethod.biometric);
    cubit.onLifecycleChanged(AppLifecycleState.hidden);
    biometrics.result = false;
    expect(await cubit.unlockWithBiometric('unlock'), isFalse);
    expect(cubit.state.locked, isTrue);
    expect(await cubit.unlockWithPin('1234'), isTrue);
    await cubit.close();
  });

  test('the system unlock is not offered with the PIN only', () async {
    final cubit = await unlocked(AppLockTiming.immediately);
    cubit.onLifecycleChanged(AppLifecycleState.hidden);
    expect(cubit.state.offersBiometric, isFalse);
    expect(await cubit.unlockWithBiometric('unlock'), isFalse);
    expect(biometrics.calls, 0);
    await cubit.close();
  });

  group('requestVerification', () {
    test('is true at once with the lock off', () async {
      final cubit = AppLockCubit(config: const AppLockConfig(), store: AppLockStore.memory(), biometrics: biometrics);
      expect(await cubit.requestVerification(always: true), isTrue);
      expect(cubit.state.covering, isFalse);
      await cubit.close();
    });

    test('shows the lock screen until unlocked or cancelled', () async {
      final cubit = await unlocked(AppLockTiming.fiveMinutes);
      now = now.add(const Duration(minutes: 1));
      final first = cubit.requestVerification();
      expect(cubit.state.verifying, isTrue);
      expect(cubit.state.locked, isFalse);
      cubit.cancelVerification();
      expect(await first, isFalse);
      expect(cubit.state.covering, isFalse);

      final second = cubit.requestVerification();
      expect(await cubit.unlockWithPin('1234'), isTrue);
      expect(await second, isTrue);

      expect(await cubit.requestVerification(), isTrue, reason: 'an unlock of the last seconds counts');
      expect(cubit.state.covering, isFalse);
      final always = cubit.requestVerification(always: true);
      expect(cubit.state.verifying, isTrue, reason: 'unless always asked');
      cubit.cancelVerification();
      expect(await always, isFalse);
      await cubit.close();
    });

    test('waits for the lock screen of a locked app, which can not be cancelled', () async {
      final cubit = await unlocked(AppLockTiming.immediately);
      now = now.add(const Duration(minutes: 1));
      cubit.onLifecycleChanged(AppLifecycleState.hidden);
      var done = false;
      final pending = cubit.requestVerification().then((v) {
        done = true;
        return v;
      });
      cubit.cancelVerification();
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(cubit.state.locked, isTrue);
      expect(await cubit.unlockWithPin('1234'), isTrue);
      expect(await pending, isTrue);
      await cubit.close();
    });

    test('is false when the lock was reset by "forgot PIN"', () async {
      final cubit = await unlocked(AppLockTiming.immediately);
      cubit.onLifecycleChanged(AppLifecycleState.hidden);
      final pending = cubit.requestVerification();
      await cubit.disable();
      expect(await pending, isFalse);
      expect(cubit.state.covering, isFalse);
      await cubit.close();
    });
  });
}
