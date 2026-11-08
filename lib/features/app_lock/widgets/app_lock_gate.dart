import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/view/app_lock_screen.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Navigator of the lock screen: its dialogs ("forgot PIN") open above it, not in the app it covers.
final _lockNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'app lock');

/// Covers the whole app with the lock screen while it is locked: every page and dialog, also the ones opened from a
/// notification, as it wraps the root navigator (the `builder` of the `MaterialApp`).
///
/// The app stays mounted underneath, with pointers, focus (so its keyboard shortcuts) and semantics cut off; the back
/// button is taken by [AppLockBackGuard].
class AppLockGate extends StatefulWidget {
  /// Constructor.
  const AppLockGate({required this.cubit, required this.child, this.forgetAccounts, super.key});

  /// The app lock.
  final AppLockCubit cubit;

  /// The app.
  final Widget child;

  /// Replaces the removal of every account of "forgot PIN" (tests).
  final ForgetAccounts? forgetAccounts;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: widget.cubit.onLifecycleChanged);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<AppLockCubit, AppLockState>(
    bloc: widget.cubit,
    buildWhen: (prev, curr) => prev.covering != curr.covering,
    builder: (context, state) {
      final covering = state.covering;
      return Stack(
        fit: StackFit.expand,
        children: [
          // The same widgets whether covered or not: locking never rebuilds the app from scratch.
          ExcludeSemantics(
            excluding: covering,
            child: IgnorePointer(
              ignoring: covering,
              child: ExcludeFocus(excluding: covering, child: widget.child),
            ),
          ),
          if (covering)
            // Its own heroes: the app's navigator keeps the hero controller of the MaterialApp.
            HeroControllerScope.none(
              child: Navigator(
                key: _lockNavigatorKey,
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) => widget.forgetAccounts == null
                      ? AppLockScreen(cubit: widget.cubit)
                      : AppLockScreen(cubit: widget.cubit, forgetAccounts: widget.forgetAccounts!),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Takes the system back button (and the predictive back gesture) while the lock screen is shown, before the app's
/// router gets it: registered before `runApp`, so first in line.
///
/// Closes a dialog of the lock screen first, then cancels a cancellable unlock; on the lock itself Android moves the
/// app to the background, elsewhere nothing happens.
final class AppLockBackGuard with WidgetsBindingObserver {
  /// Constructor.
  AppLockBackGuard(this.cubit);

  /// The app lock.
  final AppLockCubit cubit;

  @override
  Future<bool> didPopRoute() async {
    final state = cubit.state;
    if (!state.covering) {
      return false;
    }
    final navigator = _lockNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return true;
    }
    if (state.verifying && !state.locked) {
      cubit.cancelVerification();
      return true;
    }
    if (isAndroid) {
      unawaited(androidExitApp());
    }
    return true;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => cubit.state.covering;

  @override
  void handleCommitBackGesture() => unawaited(didPopRoute());

  @override
  void handleCancelBackGesture() {}

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {}
}
