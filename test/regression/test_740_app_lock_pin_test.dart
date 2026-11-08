/// The app lock PIN: only 4 to 6 digits are accepted, it is stored as a salted PBKDF2 hash, a wrong PIN does not
/// unlock, and wrong PINs in a row make the PIN pad wait longer and longer, also after a restart (the count is in
/// the saved settings).
library;

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

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const hasher = PinHasher(iterations: 10);

  test('only 4 to 6 ASCII digits are PINs', () {
    for (final pin in ['1234', '12345', '000000']) {
      expect(isValidAppLockPin(pin), isTrue, reason: pin);
    }
    for (final pin in ['', '123', '1234567', '12a4', '１２３４', '12 34']) {
      expect(isValidAppLockPin(pin), isFalse, reason: pin);
    }
  });

  test('the hash is salted and checks only the PIN it was made from', () async {
    final a = await hasher.hash('1234');
    final b = await hasher.hash('1234');
    expect(a.salt, isNot(b.salt), reason: 'a new salt each time');
    expect(a.hash, isNot(b.hash));
    expect(a.hash, hasLength(32));
    expect(await hasher.verify('1234', a), isTrue);
    expect(await hasher.verify('1235', a), isFalse);
    expect(await hasher.verify('12345', a), isFalse);

    final restored = PinHash.fromJson(a.toJson())!;
    expect(await hasher.verify('1234', restored), isTrue, reason: 'the saved form round-trips');
    expect(a.toJson().values.join(), isNot(contains('1234')), reason: 'the PIN itself is never saved');
  });

  test('a file naming a lock without a readable PIN is no lock', () {
    final config = AppLockConfig.fromJson({
      'v': 1,
      'method': 'pin',
      'pin': {'iterations': 10, 'salt': '%%'},
    });
    expect(config.enabled, isFalse);
    expect(config.method, AppLockMethod.off);
  });

  test('wrong PINs in a row wait longer and longer', () {
    for (var i = 0; i < appLockFreeAttempts; i++) {
      expect(appLockLockoutFor(i), isNull, reason: '$i');
    }
    expect(appLockLockoutFor(5), const Duration(seconds: 30));
    expect(appLockLockoutFor(6), const Duration(minutes: 1));
    expect(appLockLockoutFor(7), const Duration(minutes: 2));
    expect(appLockLockoutFor(11), const Duration(minutes: 30));
    expect(appLockLockoutFor(100), const Duration(minutes: 30));
  });

  test('the cubit unlocks with the right PIN, counts wrong ones and keeps the count across a restart', () async {
    var now = DateTime(2026, 11, 9, 12);
    final store = AppLockStore.memory();
    final setup = AppLockCubit(
      config: const AppLockConfig(),
      store: store,
      biometrics: _NoBiometrics(),
      hasher: hasher,
      now: () => now,
    );
    await setup.setPin('4321');
    await setup.pendingWrites;
    expect(setup.state.config.enabled, isTrue);
    expect(setup.state.config.method, AppLockMethod.pin);
    expect(setup.state.locked, isFalse, reason: 'setting the PIN does not lock right away');
    await setup.close();

    AppLockCubit start() => AppLockCubit(
      config: setup.state.config,
      store: store,
      biometrics: _NoBiometrics(),
      hasher: hasher,
      now: () => now,
    );

    var cubit = AppLockCubit(
      config: await store.load(),
      store: store,
      biometrics: _NoBiometrics(),
      hasher: hasher,
      now: () => now,
    );
    expect(cubit.state.locked, isTrue, reason: 'a start with the lock on is locked');
    for (var i = 1; i <= 4; i++) {
      expect(await cubit.unlockWithPin('0000'), isFalse);
      expect(cubit.state.wrongPin, isTrue);
      expect(cubit.lockedOutUntil, isNull);
    }
    expect(await cubit.unlockWithPin('0000'), isFalse);
    expect(cubit.lockedOutUntil, now.add(const Duration(seconds: 30)));
    expect(await cubit.unlockWithPin('4321'), isFalse, reason: 'nothing is checked while waiting');
    expect(cubit.state.locked, isTrue);
    await cubit.pendingWrites;
    await cubit.close();

    // A restart does not reset the count.
    final saved = await store.load();
    expect(saved.failedAttempts, 5);
    cubit = AppLockCubit(config: saved, store: store, biometrics: _NoBiometrics(), hasher: hasher, now: () => now);
    expect(cubit.lockedOutUntil, isNotNull);
    now = now.add(const Duration(seconds: 31));
    expect(cubit.lockedOutUntil, isNull);
    expect(await cubit.unlockWithPin('1111'), isFalse);
    expect(cubit.lockedOutUntil, now.add(const Duration(minutes: 1)), reason: 'the 6th waits twice as long');
    now = now.add(const Duration(minutes: 2));
    expect(await cubit.unlockWithPin('4321'), isTrue);
    expect(cubit.state.locked, isFalse);
    await cubit.pendingWrites;
    expect((await store.load()).failedAttempts, 0, reason: 'the right PIN resets the count');
    expect((await store.load()).lockedOutUntil, isNull);
    await cubit.close();
    await start().close();
  });

  test('turning the lock off forgets the PIN', () async {
    final store = AppLockStore.memory();
    final cubit = AppLockCubit(
      config: const AppLockConfig(),
      store: store,
      biometrics: _NoBiometrics(),
      hasher: hasher,
    );
    await cubit.setPin('123456', method: AppLockMethod.biometric);
    expect(cubit.state.config.method, AppLockMethod.biometric);
    await cubit.disable();
    await cubit.pendingWrites;
    final saved = await store.load();
    expect(saved.enabled, isFalse);
    expect(saved.pin, isNull);
    await cubit.close();
  });
}
