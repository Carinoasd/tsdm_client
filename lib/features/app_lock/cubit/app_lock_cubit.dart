import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/utils/logger.dart';

/// When the app locks after leaving the screen, apart from the widgets so it can be tested with a fake clock.
///
/// Only [AppLifecycleState.hidden] and [AppLifecycleState.paused] (and detached) count as leaving: losing the focus
/// ([AppLifecycleState.inactive]) does not, the system biometric prompt itself makes the app inactive.
final class AppLockTimer {
  DateTime? _leftAt;

  /// When the app left the screen, null while it is on it.
  DateTime? get leftAt => _leftAt;

  /// The app left the screen at [now]; a second call before [returned] keeps the first time (the way back passes
  /// through hidden again).
  void left(DateTime now) => _leftAt ??= now;

  /// The app is back on the screen at [now]: whether it was away for [timing] or longer. Forgets the time it left.
  bool returned(DateTime now, AppLockTiming timing) {
    final at = _leftAt;
    _leftAt = null;
    return at != null && !now.difference(at).isNegative && now.difference(at) >= timing.delay;
  }

  /// Forget the time the app left.
  void reset() => _leftAt = null;
}

/// State of the app lock.
@immutable
final class AppLockState {
  /// Constructor.
  const AppLockState({
    required this.config,
    this.locked = false,
    this.verifying = false,
    this.biometricAvailable = false,
    this.checking = false,
    this.wrongPin = false,
  });

  /// Saved settings.
  final AppLockConfig config;

  /// The app is locked: the lock screen covers it until unlocked.
  final bool locked;

  /// The lock screen asks to unlock again before an action (switching accounts, changing the lock) and can be
  /// cancelled.
  final bool verifying;

  /// The system unlock can be used now.
  final bool biometricAvailable;

  /// A PIN is being checked.
  final bool checking;

  /// The last PIN entered was wrong.
  final bool wrongPin;

  /// Whether the lock screen is shown.
  bool get covering => locked || verifying;

  /// Whether the system unlock is offered on the lock screen.
  bool get offersBiometric => config.method == AppLockMethod.biometric && biometricAvailable;

  /// A copy with the given fields replaced.
  AppLockState copyWith({
    AppLockConfig? config,
    bool? locked,
    bool? verifying,
    bool? biometricAvailable,
    bool? checking,
    bool? wrongPin,
  }) => AppLockState(
    config: config ?? this.config,
    locked: locked ?? this.locked,
    verifying: verifying ?? this.verifying,
    biometricAvailable: biometricAvailable ?? this.biometricAvailable,
    checking: checking ?? this.checking,
    wrongPin: wrongPin ?? this.wrongPin,
  );
}

/// The app lock: its settings, whether the app is locked, and unlocking with the PIN or the system unlock.
final class AppLockCubit extends Cubit<AppLockState> with LoggerMixin {
  /// Constructor; the app starts locked when [config] has the lock on.
  AppLockCubit({
    required AppLockConfig config,
    required AppLockStore store,
    required BiometricAuthenticator biometrics,
    PinHasher hasher = const PinHasher(),
    DateTime Function()? now,
  }) : _store = store,
       _biometrics = biometrics,
       _hasher = hasher,
       _now = now ?? DateTime.now,
       super(AppLockState(config: _boundLockout(config, (now ?? DateTime.now)()), locked: config.enabled));

  /// A wait saved longer than the one of its count of wrong PINs (the clock went back, by hand or by a correction)
  /// is cut to that, counted from [now]: it must not keep the PIN pad closed for days.
  static AppLockConfig _boundLockout(AppLockConfig config, DateTime now) {
    final until = config.lockedOutUntil;
    final allowed = appLockLockoutFor(config.failedAttempts) ?? Duration.zero;
    if (until == null || until.difference(now) <= allowed) {
      return config;
    }
    return config.copyWith(lockedOutUntil: now.add(allowed));
  }

  /// The clock of the lock (tests replace it).
  DateTime now() => _now();

  /// Read the saved settings first, so the first frame is already the lock screen.
  static Future<AppLockCubit> load({
    AppLockStore? store,
    BiometricAuthenticator? biometrics,
    PinHasher hasher = const PinHasher(),
  }) async {
    final s = store ?? AppLockStore();
    final saved = await s.load();
    final cubit = AppLockCubit(
      config: saved,
      store: s,
      biometrics: biometrics ?? LocalBiometricAuthenticator(),
      hasher: hasher,
    );
    if (cubit.state.config.lockedOutUntil != saved.lockedOutUntil) {
      // Cut to its count: the next start must not wait the whole time again.
      unawaited(cubit._save(cubit.state.config));
    }
    unawaited(cubit.refreshBiometricAvailability());
    return cubit;
  }

  /// An unlock this recent also counts for [requestVerification]: a tap on the notification of another account asks
  /// to unlock the app and then to switch, it should ask once.
  static const recentUnlock = Duration(seconds: 5);

  final AppLockStore _store;
  final BiometricAuthenticator _biometrics;
  final PinHasher _hasher;
  final DateTime Function() _now;
  final _timer = AppLockTimer();

  bool _authenticating = false;
  AppLifecycleState? _lifecycle;
  DateTime? _unlockedAt;
  Completer<bool>? _verification;

  /// Writes one after the other, in the order asked.
  Future<void> _writes = Future<void>.value();

  /// Whether account switches ask to unlock first.
  bool get requiresUnlockForAccountSwitch => state.config.enabled && state.config.requireForAccountSwitch;

  /// Completes once every write asked so far is done.
  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  Future<void> _save(AppLockConfig config) {
    if (!isClosed) {
      emit(state.copyWith(config: config));
    }
    return _writes = _writes.then((_) => _store.save(config)).catchError((Object e) {
      error('app lock: failed to save: $e');
    });
  }

  /// Check again whether the system unlock can be used (it may have been set up meanwhile).
  Future<void> refreshBiometricAvailability() async {
    final available = await _biometrics.isAvailable();
    if (!isClosed) {
      emit(state.copyWith(biometricAvailable: available));
    }
  }

  /// Whether the system unlock can be used on this device now.
  Future<bool> biometricAvailable() => _biometrics.isAvailable();

  /// The app lifecycle changed.
  ///
  /// The app leaves on its way from inactive to hidden, or paused; hidden right after paused is its way back (it
  /// also passes through hidden then). While the system unlock is asked only a leave counts: the prompt itself moves
  /// the app between inactive and resumed, but the user may still leave from it.
  void onLifecycleChanged(AppLifecycleState lifecycle) {
    final previous = _lifecycle;
    _lifecycle = lifecycle;
    final leaving = switch (lifecycle) {
      AppLifecycleState.hidden => previous != AppLifecycleState.paused,
      AppLifecycleState.paused || AppLifecycleState.detached => true,
      AppLifecycleState.inactive || AppLifecycleState.resumed => false,
    };
    if (!state.config.enabled || (_authenticating && !leaving)) {
      return;
    }
    if (leaving) {
      if (state.locked) {
        return;
      }
      _timer.left(_now());
      if (state.config.timing == AppLockTiming.immediately) {
        // Covered before it is seen again, also in the app switcher where the system takes the picture later.
        _lock();
      }
      return;
    }
    if (lifecycle == AppLifecycleState.hidden || _timer.leftAt == null) {
      return;
    }
    if (_timer.returned(_now(), state.config.timing) && !state.locked) {
      _lock();
    }
    if (state.locked) {
      unawaited(refreshBiometricAvailability());
    }
  }

  void _lock() {
    info('app lock: locked');
    _timer.reset();
    emit(state.copyWith(locked: true, wrongPin: false));
  }

  /// Lock the app now (the lock was just turned on, tests).
  void lock() {
    if (state.config.enabled) {
      _lock();
    }
  }

  /// When the PIN pad accepts a PIN again, null when it does now.
  DateTime? get lockedOutUntil {
    final until = state.config.lockedOutUntil;
    return until != null && until.isAfter(_now()) ? until : null;
  }

  /// Check [pin]; unlocks when it is the one set. False also while too many wrong ones wait ([lockedOutUntil]).
  Future<bool> unlockWithPin(String pin) async {
    final stored = state.config.pin;
    if (stored == null || state.checking || lockedOutUntil != null) {
      return false;
    }
    emit(state.copyWith(checking: true, wrongPin: false));
    final ok = await _hasher.verify(pin, stored);
    if (isClosed) {
      return ok;
    }
    if (ok) {
      await _unlocked();
      return true;
    }
    final failed = state.config.failedAttempts + 1;
    final wait = appLockLockoutFor(failed);
    info('app lock: wrong PIN ($failed in a row)');
    emit(state.copyWith(checking: false, wrongPin: true));
    await _save(state.config.copyWith(failedAttempts: failed, lockedOutUntil: wait == null ? null : _now().add(wait)));
    return false;
  }

  /// Ask the system unlock; unlocks when the user was recognized.
  Future<bool> unlockWithBiometric(String reason) async {
    if (!state.offersBiometric || _authenticating || !state.covering) {
      return false;
    }
    _authenticating = true;
    try {
      final ok = await _biometrics.authenticate(reason);
      if (ok && !isClosed) {
        await _unlocked();
      }
      return ok;
    } finally {
      _authenticating = false;
      // Back on the screen before the prompt answered: the return check skipped while it was up.
      if (!isClosed && _lifecycle == AppLifecycleState.resumed && _timer.leftAt != null) {
        onLifecycleChanged(AppLifecycleState.resumed);
      }
    }
  }

  Future<void> _unlocked() async {
    info('app lock: unlocked');
    _unlockedAt = _now();
    _timer.reset();
    emit(state.copyWith(locked: false, verifying: false, checking: false, wrongPin: false));
    _completeVerification(true);
    if (state.config.failedAttempts != 0 || state.config.lockedOutUntil != null) {
      await _save(state.config.copyWith(failedAttempts: 0, clearLockout: true));
    }
  }

  void _completeVerification(bool result) {
    final verification = _verification;
    _verification = null;
    if (verification != null && !verification.isCompleted) {
      verification.complete(result);
    }
  }

  /// Ask to unlock before an action; true when the user did, or when the lock is off.
  ///
  /// When the app is locked it waits for it to be unlocked; an unlock in the last [recentUnlock] counts unless
  /// [always]. False when the user cancelled.
  Future<bool> requestVerification({bool always = false}) async {
    if (!state.config.enabled) {
      return true;
    }
    if (state.locked) {
      // The lock screen is up: its unlock is the one asked for.
      final current = _verification ??= Completer<bool>();
      return current.future;
    }
    final at = _unlockedAt;
    if (!always && at != null && _now().difference(at) < recentUnlock) {
      return true;
    }
    final current = _verification ??= Completer<bool>();
    emit(state.copyWith(verifying: true, wrongPin: false));
    return current.future;
  }

  /// Close the lock screen of [requestVerification] without unlocking; the locked app stays locked.
  void cancelVerification() {
    if (!state.verifying || state.locked) {
      return;
    }
    emit(state.copyWith(verifying: false, wrongPin: false));
    _completeVerification(false);
  }

  /// Turn the lock on, or change the PIN, keeping the other settings; [method] is the way to unlock.
  Future<void> setPin(String pin, {AppLockMethod? method}) async {
    assert(isValidAppLockPin(pin), 'PIN must be 4 to 6 digits');
    final hash = await _hasher.hash(pin);
    final next = method ?? (state.config.enabled ? state.config.method : AppLockMethod.pin);
    _unlockedAt = _now();
    await _save(state.config.copyWith(method: next, pin: hash, failedAttempts: 0, clearLockout: true));
  }

  /// Unlock with the PIN only or also with the system unlock; the lock must be on.
  Future<void> setMethod(AppLockMethod method) async {
    if (!state.config.enabled || method == AppLockMethod.off) {
      return;
    }
    await _save(state.config.copyWith(method: method));
  }

  /// When the app locks again.
  Future<void> setTiming(AppLockTiming timing) => _save(state.config.copyWith(timing: timing));

  /// Ask to unlock before switching accounts.
  Future<void> setRequireForAccountSwitch({required bool value}) =>
      _save(state.config.copyWith(requireForAccountSwitch: value));

  /// Turn the lock off and forget the PIN (also after "forgot PIN" removed every account).
  Future<void> disable() async {
    _timer.reset();
    emit(state.copyWith(locked: false, verifying: false, checking: false, wrongPin: false));
    // A switch waiting for the unlock: the accounts may be gone, it must not go on.
    _completeVerification(false);
    await _save(const AppLockConfig());
  }

  @override
  Future<void> close() {
    _completeVerification(false);
    return super.close();
  }
}
