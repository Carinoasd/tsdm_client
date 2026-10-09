import 'dart:async';

import 'package:flutter/widgets.dart';

/// Builds `builder` with the current time again at every full hour, and when the app comes back to the foreground
/// (timers do not run while the computer sleeps).
///
/// For texts that depend on the hour or the day, such as the date and the greeting of the homepage.
class HourTicker extends StatefulWidget {
  /// Constructor.
  const HourTicker({required this.builder, this.clock = DateTime.now, super.key});

  /// Builds the child for the time `now`.
  final Widget Function(BuildContext context, DateTime now) builder;

  /// Current time (tests pass a fake).
  final DateTime Function() clock;

  @override
  State<HourTicker> createState() => _HourTickerState();
}

class _HourTickerState extends State<HourTicker> with WidgetsBindingObserver {
  Timer? _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(_tick);
    }
  }

  void _tick() {
    _now = widget.clock();
    _timer?.cancel();
    final next = DateTime(_now.year, _now.month, _now.day, _now.hour + 1, 0, 1);
    _timer = Timer(next.difference(_now), () {
      if (mounted) {
        setState(_tick);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
