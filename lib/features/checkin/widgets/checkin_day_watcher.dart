import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Keeps the check-in of an app that stays open across days up to date.
///
/// The check-in button and the auto check-in only looked at the day when the app started or the homepage loaded: a
/// desktop app left open overnight still showed yesterday's "checked in" the next morning and never checked in again
/// by itself. Just after midnight the button state is asked again (it is no longer checked), and once check-in opens
/// at 1:00 the auto check-in runs again when it is enabled. Timers do not run while the computer sleeps, so the same
/// check is made whenever the app comes back to the foreground.
class CheckinDayWatcher extends StatefulWidget {
  /// Constructor.
  const CheckinDayWatcher({required this.autoCheckinStarted, super.key});

  /// Whether the auto check-in was started when the app launched.
  final bool autoCheckinStarted;

  @override
  State<CheckinDayWatcher> createState() => _CheckinDayWatcherState();
}

class _CheckinDayWatcherState extends State<CheckinDayWatcher> with WidgetsBindingObserver, LoggerMixin {
  Timer? _timer;
  DateTime? _autoCheckinRun;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoCheckinStarted) {
      _autoCheckinRun = DateTime.now();
    }
    _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check(resumed: true);
    }
  }

  void _schedule() {
    _timer?.cancel();
    final now = DateTime.now();
    _timer = Timer(nextCheckinDayBoundary(now).difference(now), () {
      _check();
      _schedule();
    });
  }

  void _check({bool resumed = false}) {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    context.read<CheckinBloc>().add(const CheckinStatusRequested());
    final enabled =
        getIt.isRegistered<SettingsRepository>() && getIt.get<SettingsRepository>().currentSettings.autoCheckin;
    if (enabled && autoCheckinDue(_autoCheckinRun, now)) {
      info('new check-in day${resumed ? ' (resumed)' : ''}: start auto check-in again');
      _autoCheckinRun = now;
      context.read<AutoCheckinBloc>().add(const AutoCheckinStartRequested());
    }
    if (resumed) {
      // A sleep may have skipped the boundary the timer waited for.
      _schedule();
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
