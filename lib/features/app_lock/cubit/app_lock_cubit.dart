import 'dart:async';
import 'dart:developer' show Timeline;

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Time since the device started, on a clock that can not be set by hand (the wall clock can): what the waits of the
/// app lock are counted on. The same clock for every process of one start of the device.
///
/// `Timeline.now` is documented only as the trace clock: since boot and shared by processes is how the Dart VM
/// implements it (`CLOCK_MONOTONIC`, `mach_absolute_time`, QPC), checked in an AOT build. Check again (lock out,
/// restart the app after the wait: no wait again) when the Flutter version changes.
Duration appLockSinceBoot() => Duration(microseconds: Timeline.now);

/// When the app locks after leaving the screen, apart from the widgets so it can be tested with a fake clock.
///
/// Only [AppLifecycleState.hidden] and [AppLifecycleState.paused] (and detached) count as leaving: losing the focus
/// ([AppLifecycleState.inactive]) does not, the system biometric prompt itself makes the app inactive.
///
/// The time away is read on both the wall clock and the monotonic one ([appLockSinceBoot]): the wall clock goes on
/// while the device sleeps, the monotonic one can not be set by hand. Either reaching the delay locks, and so does the
/// wall clock going back (set back while away, the time away can not be told).
final class AppLockTimer {
  DateTime? _leftAt;
  Duration? _leftSinceBoot;

  /// When the app left the screen, null while it is on it.
  DateTime? get leftAt => _leftAt;

  /// The app left the screen at [now] ([sinceBoot] on the monotonic clock); a second call before [returned] keeps the
  /// first time (the way back passes through hidden again).
  void left(DateTime now, {Duration? sinceBoot}) {
    if (_leftAt != null) {
      return;
    }
    _leftAt = now;
    _leftSinceBoot = sinceBoot;
  }

  /// The app is back on the screen at [now] ([sinceBoot] on the monotonic clock): whether it was away for [timing]
  /// or longer. Forgets the time it left.
  bool returned(DateTime now, AppLockTiming timing, {Duration? sinceBoot}) {
    final at = _leftAt;
    final atSinceBoot = _leftSinceBoot;
    reset();
    if (at == null) {
      return false;
    }
    final away = now.difference(at);
    if (away.isNegative || away >= timing.delay) {
      return true;
    }
    return atSinceBoot != null && sinceBoot != null && sinceBoot - atSinceBoot >= timing.delay;
  }

  /// Forget the time the app left.
  void reset() {
    _leftAt = null;
    _leftSinceBoot = null;
  }
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
  /// Constructor; the app starts locked when [config] has the lock on. [now] is the wall clock, [sinceBoot] the
  /// monotonic one ([appLockSinceBoot]); tests replace both.
  factory AppLockCubit({
    required AppLockConfig config,
    required AppLockStore store,
    required BiometricAuthenticator biometrics,
    PinHasher hasher = const PinHasher(),
    DateTime Function()? now,
    Duration Function()? sinceBoot,
  }) {
    final wall = now ?? DateTime.now;
    final monotonic = sinceBoot ?? appLockSinceBoot;
    final resumed = resumeLockout(config, now: wall(), sinceBoot: monotonic());
    return AppLockCubit._(
      resumed.config,
      resumed.endsAt,
      store: store,
      biometrics: biometrics,
      hasher: hasher,
      now: wall,
      sinceBoot: monotonic,
    );
  }

  AppLockCubit._(
    AppLockConfig config,
    this._lockoutEndsAt, {
    required AppLockStore store,
    required BiometricAuthenticator biometrics,
    required PinHasher hasher,
    required DateTime Function() now,
    required Duration Function() sinceBoot,
  }) : _store = store,
       _biometrics = biometrics,
       _hasher = hasher,
       _now = now,
       _sinceBoot = sinceBoot,
       super(AppLockState(config: config, locked: config.enabled));

  /// The wait after too many wrong PINs saved in [config], carried into this run of the app: the settings to start
  /// with and when, on the monotonic clock, the wait ends (null: no wait).
  ///
  /// The wait is counted on the monotonic clock, which setting the time of the device does not move. Within one start
  /// of the device the clock saved with the wait ([AppLockConfig.lockedOutSinceBoot]) tells how long it ran. After
  /// the device restarted only the wall clock is left: when it went back, or past the whole wait (a clock set
  /// forward can not be told from time that really passed), the whole wait begins again. A file of an older version
  /// (no monotonic time saved) keeps its wall clock wait, cut to the length of its count.
  @visibleForTesting
  static ({AppLockConfig config, Duration? endsAt}) resumeLockout(
    AppLockConfig config, {
    required DateTime now,
    required Duration sinceBoot,
  }) {
    final until = config.lockedOutUntil;
    if (until == null) {
      return (config: config, endsAt: null);
    }
    final wait = appLockLockoutFor(config.failedAttempts);
    if (wait == null) {
      return (config: config.copyWith(clearLockout: true), endsAt: null);
    }
    final startedSinceBoot = config.lockedOutSinceBoot;
    if (startedSinceBoot != null && sinceBoot >= startedSinceBoot) {
      final ends = startedSinceBoot + wait;
      return (config: config, endsAt: sinceBoot < ends ? ends : null);
    }
    final at = config.lockedOutAt ?? until.subtract(wait);
    final away = now.difference(at);
    final Duration ran;
    if (away.isNegative) {
      ran = Duration.zero;
    } else if (away < wait) {
      ran = away;
    } else if (startedSinceBoot == null) {
      // An older version's file whose wait is over.
      return (config: config, endsAt: null);
    } else {
      ran = Duration.zero;
    }
    final anchor = sinceBoot - ran;
    final start = anchor.isNegative ? Duration.zero : anchor;
    final left = start + wait - sinceBoot;
    return (
      config: config.copyWith(
        lockedOutUntil: now.add(left),
        lockedOutAt: now.subtract(sinceBoot - start),
        lockedOutSinceBoot: start,
      ),
      endsAt: start + wait,
    );
  }

  /// The clock of the lock (tests replace it).
  DateTime now() => _now();

  /// Read the saved settings first, so the first frame is already the lock screen.
  static Future<AppLockCubit> load({
    AppLockStore? store,
    BiometricAuthenticator? biometrics,
    PinHasher hasher = const PinHasher(),
    DateTime Function()? now,
    Duration Function()? sinceBoot,
  }) async {
    final s = store ?? AppLockStore();
    final saved = await s.load();
    final cubit = AppLockCubit(
      config: saved,
      store: s,
      biometrics: biometrics ?? LocalBiometricAuthenticator(),
      hasher: hasher,
      now: now,
      sinceBoot: sinceBoot,
    );
    if (cubit.state.config.lockedOutUntil != saved.lockedOutUntil ||
        cubit.state.config.lockedOutSinceBoot != saved.lockedOutSinceBoot) {
      // Carried into this start of the device: the next start of the app goes on from here.
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
  final Duration Function() _sinceBoot;
  final _timer = AppLockTimer();

  /// When the wait after too many wrong PINs ends on the monotonic clock, null when there is none.
  Duration? _lockoutEndsAt;

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
      _timer.left(_now(), sinceBoot: _sinceBoot());
      if (state.config.timing == AppLockTiming.immediately) {
        // Covered before it is seen again, also in the app switcher where the system takes the picture later.
        _lock();
      }
      return;
    }
    if (lifecycle == AppLifecycleState.hidden || _timer.leftAt == null) {
      return;
    }
    if (_timer.returned(_now(), state.config.timing, sinceBoot: _sinceBoot()) && !state.locked) {
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

  /// When the PIN pad accepts a PIN again, null when it does now. Counted on the monotonic clock: setting the time
  /// of the device neither ends nor stretches the wait.
  DateTime? get lockedOutUntil {
    final ends = _lockoutEndsAt;
    if (ends == null) {
      return null;
    }
    final left = ends - _sinceBoot();
    return left > Duration.zero ? _now().add(left) : null;
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
    if (wait == null) {
      _lockoutEndsAt = null;
      await _save(state.config.copyWith(failedAttempts: failed, clearLockout: true));
      return false;
    }
    final now = _now();
    final sinceBoot = _sinceBoot();
    _lockoutEndsAt = sinceBoot + wait;
    await _save(
      state.config.copyWith(
        failedAttempts: failed,
        lockedOutUntil: now.add(wait),
        lockedOutAt: now,
        lockedOutSinceBoot: sinceBoot,
      ),
    );
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
    _lockoutEndsAt = null;
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
    _lockoutEndsAt = null;
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
    _lockoutEndsAt = null;
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
