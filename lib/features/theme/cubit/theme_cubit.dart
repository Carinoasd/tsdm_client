import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/features/theme/dark_schedule.dart';

part 'theme_cubit.mapper.dart';

part 'theme_state.dart';

/// Cubit controlling app theme.
///
/// While [ThemeState.scheduled] the clock decides: dark inside the [DarkSchedule], light outside. The cubit wakes up
/// at the next boundary of the window ([Timer]), at most [maxTimerWait] away so a sleeping device or a changed clock
/// is caught up with soon, and works the time out again when the app comes back to the foreground
/// ([observeLifecycle]), as the timer does not run while the app sleeps.
class ThemeCubit extends Cubit<ThemeState> with WidgetsBindingObserver {
  /// Constructor.
  ///
  /// [now] tells the time of day, the clock of the device by default.
  ThemeCubit({
    Color? accentColor,
    int themeModeIndex = 0,
    String fontFamily = '',
    bool scheduled = false,
    DarkSchedule schedule = DarkSchedule.defaults,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(
         ThemeState(
           accentColor: accentColor,
           themeModeIndex: themeModeIndex,
           fontFamily: fontFamily,
           scheduled: scheduled,
           scheduleStart: schedule.start,
           scheduleEnd: schedule.end,
           scheduleDark: schedule.isDark((now ?? DateTime.now)()),
         ),
       ) {
    _arm();
  }

  /// The longest the timer sleeps: the monotonic clock behind [Timer] stops while a desktop sleeps, and the wall clock
  /// or the time zone may be changed under the app, so wake up now and then and look at the clock again.
  static const Duration maxTimerWait = Duration(minutes: 15);

  final DateTime Function() _now;

  Timer? _timer;

  bool _observing = false;

  /// Set the accent color.
  void setAccentColor(Color accentColor) => emit(state.copyWith(accentColor: accentColor));

  /// Set the theme mode to the [ThemeMode] at [themeModeIndex]; it shows once the clock is not in charge.
  void setThemeModeIndex(int themeModeIndex) => emit(state.copyWith(themeModeIndex: themeModeIndex));

  /// Hand the theme to the clock, or take it back.
  void setScheduled({required bool scheduled}) {
    emit(state.copyWith(scheduled: scheduled, scheduleDark: state.schedule.isDark(_now())));
    _arm();
  }

  /// Set the font family to [fontFamily].
  void setFontFamily(String fontFamily) => emit(state.copyWith(fontFamily: fontFamily));

  /// Set the dark hours.
  void setSchedule(DarkSchedule schedule) {
    emit(
      state.copyWith(
        scheduleStart: schedule.start,
        scheduleEnd: schedule.end,
        scheduleDark: schedule.isDark(_now()),
      ),
    );
    _arm();
  }

  /// Work out again whether it is inside the dark hours, and wake up at the next boundary.
  void refreshSchedule() {
    if (isClosed) {
      return;
    }
    final dark = state.schedule.isDark(_now());
    if (dark != state.scheduleDark) {
      emit(state.copyWith(scheduleDark: dark));
    }
    _arm();
  }

  /// Follow the app coming back to the foreground.
  void observeLifecycle() {
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  // The parameter keeps the name of the overridden method (lint avoid_renaming_method_parameters); it is the lifecycle
  // state, not the state of the cubit.
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshSchedule();
    }
  }

  /// Wake up at the next moment the dark hours begin or end (or after [maxTimerWait], whichever comes first), not on
  /// every tick; no timer unless the clock is in charge.
  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (!state.scheduled) {
      return;
    }
    final now = _now();
    final next = state.schedule.nextBoundary(now);
    if (next == null) {
      return;
    }
    final wait = next.difference(now);
    _timer = Timer(wait > maxTimerWait ? maxTimerWait : wait, refreshSchedule);
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      _observing = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    return super.close();
  }
}
