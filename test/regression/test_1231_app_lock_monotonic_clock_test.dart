/// The waits of the app lock can not be skipped by setting the time of the device. The wait after too many wrong
/// PINs is counted on the monotonic clock (time since the device started): setting the wall clock ahead neither ends
/// it within a run of the app nor after a restart of the app; after a restart of the device, a wall clock that went
/// back or past the whole wait starts the whole wait again. The time away before the app locks again reads both
/// clocks, and a wall clock set back while away locks.
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

final class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<bool> isAvailable() async => false;
}

const List<AppLifecycleState> _away = [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused];
const List<AppLifecycleState> _back = [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed];

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const hasher = PinHasher(iterations: 10);
  const thirtySeconds = Duration(seconds: 30);
  late DateTime wall;
  late Duration boot;
  late AppLockStore store;
  late PinHash pin;

  setUpAll(() async => pin = await hasher.hash('4321'));

  setUp(() {
    wall = DateTime(2026, 11, 14, 12);
    boot = const Duration(hours: 3);
    store = AppLockStore.memory();
  });

  /// Real time passing: both clocks move.
  void pass(Duration d) {
    wall = wall.add(d);
    boot += d;
  }

  AppLockCubit start(AppLockConfig config) => AppLockCubit(
    config: config,
    store: store,
    biometrics: _NoBiometrics(),
    hasher: hasher,
    now: () => wall,
    sinceBoot: () => boot,
  );

  /// A locked app with five wrong PINs entered: the PIN pad waits 30 seconds.
  Future<AppLockCubit> lockedOut() async {
    final cubit = start(AppLockConfig(method: AppLockMethod.pin, pin: pin));
    for (var i = 0; i < appLockFreeAttempts; i++) {
      expect(await cubit.unlockWithPin('0000'), isFalse);
    }
    expect(cubit.lockedOutUntil, wall.add(thirtySeconds));
    await cubit.pendingWrites;
    return cubit;
  }

  group('the wait after wrong PINs', () {
    test('setting the clock ahead does not end it', () async {
      final cubit = await lockedOut();
      wall = wall.add(const Duration(days: 1));
      expect(cubit.lockedOutUntil, isNotNull, reason: 'the wall clock alone moved');
      expect(await cubit.unlockWithPin('4321'), isFalse);
      expect(cubit.state.locked, isTrue);
      boot += thirtySeconds;
      expect(cubit.lockedOutUntil, isNull, reason: 'thirty seconds really passed');
      expect(await cubit.unlockWithPin('4321'), isTrue);
      await cubit.close();
    });

    test('setting the clock back does not stretch it', () async {
      final cubit = await lockedOut();
      wall = wall.subtract(const Duration(days: 1));
      boot += thirtySeconds;
      expect(cubit.lockedOutUntil, isNull);
      await cubit.close();
    });

    test('a restart of the app with the clock set ahead goes on with the wait', () async {
      final first = await lockedOut();
      await first.close();
      pass(const Duration(seconds: 10));
      wall = wall.add(const Duration(days: 1));
      final cubit = start(await store.load());
      expect(cubit.lockedOutUntil, wall.add(const Duration(seconds: 20)));
      expect(await cubit.unlockWithPin('4321'), isFalse);
      boot += const Duration(seconds: 20);
      expect(cubit.lockedOutUntil, isNull);
      expect(await cubit.unlockWithPin('4321'), isTrue);
      await cubit.close();
    });

    test('after a restart of the device a wall clock past the whole wait starts it again', () async {
      final first = await lockedOut();
      await first.close();
      // The device restarts: the monotonic clock begins again near zero, the wall clock was set a day ahead.
      boot = const Duration(minutes: 1);
      wall = wall.add(const Duration(days: 1));
      final cubit = await AppLockCubit.load(
        store: store,
        biometrics: _NoBiometrics(),
        hasher: hasher,
        now: () => wall,
        sinceBoot: () => boot,
      );
      expect(cubit.lockedOutUntil, wall.add(thirtySeconds));
      await cubit.pendingWrites;
      // The next restart of the app on this start of the device goes on from there.
      await cubit.close();
      pass(const Duration(seconds: 25));
      final again = start(await store.load());
      expect(again.lockedOutUntil, wall.add(const Duration(seconds: 5)));
      await again.close();
    });

    test('after a restart of the device a wall clock set back starts the whole wait again', () async {
      final first = await lockedOut();
      await first.close();
      boot = const Duration(minutes: 1);
      wall = wall.subtract(const Duration(hours: 2));
      final cubit = start(await store.load());
      expect(cubit.lockedOutUntil, wall.add(thirtySeconds));
      await cubit.close();
    });

    test('after a restart of the device the time that passed inside the wait counts', () async {
      final first = await lockedOut();
      await first.close();
      boot = const Duration(minutes: 1);
      wall = wall.add(const Duration(seconds: 20));
      final cubit = start(await store.load());
      expect(cubit.lockedOutUntil, wall.add(const Duration(seconds: 10)));
      await cubit.close();
    });

    test('the monotonic start of the wait is saved with it', () async {
      final cubit = await lockedOut();
      final saved = await store.load();
      expect(saved.lockedOutSinceBoot, boot);
      expect(saved.lockedOutAt, wall);
      expect(AppLockConfig.fromJson(saved.toJson()).lockedOutSinceBoot, boot);
      boot += thirtySeconds;
      expect(await cubit.unlockWithPin('4321'), isTrue);
      await cubit.pendingWrites;
      final cleared = await store.load();
      expect(cleared.lockedOutUntil, isNull);
      expect(cleared.lockedOutAt, isNull);
      expect(cleared.lockedOutSinceBoot, isNull);
      await cubit.close();
    });

    test('a file of an older version keeps its wall clock wait', () {
      final config = AppLockConfig(
        method: AppLockMethod.pin,
        pin: pin,
        failedAttempts: 5,
        lockedOutUntil: wall.add(const Duration(seconds: 12)),
      );
      final resumed = AppLockCubit.resumeLockout(config, now: wall, sinceBoot: boot);
      expect(resumed.endsAt, boot + const Duration(seconds: 12));
      final over = AppLockCubit.resumeLockout(config, now: wall.add(const Duration(minutes: 1)), sinceBoot: boot);
      expect(over.endsAt, isNull);
    });
  });

  group('locking again after time away', () {
    Future<AppLockCubit> unlocked(AppLockTiming timing) async {
      final cubit = start(AppLockConfig(method: AppLockMethod.pin, pin: pin, timing: timing));
      expect(await cubit.unlockWithPin('4321'), isTrue);
      return cubit;
    }

    void go(AppLockCubit cubit, List<AppLifecycleState> states) => states.forEach(cubit.onLifecycleChanged);

    test('the wall clock set back while away locks', () async {
      final cubit = await unlocked(AppLockTiming.fiveMinutes);
      go(cubit, _away);
      pass(const Duration(seconds: 10));
      wall = wall.subtract(const Duration(hours: 1));
      go(cubit, _back);
      expect(cubit.state.locked, isTrue);
      await cubit.close();
    });

    test('the monotonic clock reaching the delay locks, whatever the wall clock says', () async {
      final cubit = await unlocked(AppLockTiming.oneMinute);
      go(cubit, _away);
      boot += const Duration(minutes: 1);
      go(cubit, _back);
      expect(cubit.state.locked, isTrue);
      await cubit.close();
    });

    test('a short time away on both clocks does not lock', () async {
      final cubit = await unlocked(AppLockTiming.oneMinute);
      go(cubit, _away);
      pass(const Duration(seconds: 59));
      go(cubit, _back);
      expect(cubit.state.locked, isFalse);
      await cubit.close();
    });

    test('the device asleep (the wall clock went on, the monotonic one did not) still locks', () async {
      final cubit = await unlocked(AppLockTiming.fiveMinutes);
      go(cubit, _away);
      wall = wall.add(const Duration(minutes: 10));
      go(cubit, _back);
      expect(cubit.state.locked, isTrue);
      await cubit.close();
    });
  });

  test('the default monotonic clock moves forward', () async {
    final a = appLockSinceBoot();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(appLockSinceBoot(), greaterThan(a));
  });
}
