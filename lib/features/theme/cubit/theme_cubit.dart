import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/features/theme/dark_schedule.dart';

part 'theme_cubit.mapper.dart';

part 'theme_state.dart';

/// Cubit controlling app theme.
///
/// With the theme mode [themeModeScheduled] the clock decides: dark inside the [DarkSchedule], light outside. The
/// cubit wakes up at the next boundary of the window ([Timer]) and works the time out again when the app comes back
/// to the foreground ([observeLifecycle]), as the timer does not run while the app sleeps.
class ThemeCubit extends Cubit<ThemeState> with WidgetsBindingObserver {
  /// Constructor.
  ///
  /// [now] tells the time of day, the clock of the device by default.
  ThemeCubit({
    Color? accentColor,
    int themeModeIndex = 0,
    String fontFamily = '',
    DarkSchedule schedule = DarkSchedule.defaults,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(
         ThemeState(
           accentColor: accentColor,
           themeModeIndex: themeModeIndex,
           fontFamily: fontFamily,
           scheduleStart: schedule.start,
           scheduleEnd: schedule.end,
           scheduleDark: schedule.isDark((now ?? DateTime.now)()),
         ),
       ) {
    _arm();
  }

  final DateTime Function() _now;

  Timer? _timer;

  bool _observing = false;

  /// Set the accent color.
  void setAccentColor(Color accentColor) => emit(state.copyWith(accentColor: accentColor));

  /// Set the theme mode: the index of a [ThemeMode], or [themeModeScheduled].
  void setThemeModeIndex(int themeModeIndex) {
    emit(state.copyWith(themeModeIndex: themeModeIndex, scheduleDark: state.schedule.isDark(_now())));
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshSchedule();
    }
  }

  /// Wake up at the next moment the dark hours begin or end, not on every tick; no timer unless the clock is in
  /// charge.
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
    _timer = Timer(next.difference(now), refreshSchedule);
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
