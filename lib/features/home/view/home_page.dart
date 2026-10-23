import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/stream.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/root/bloc/root_location_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

const _drawerWidth = 250.0;

/// Page of the homepage of the app.
///
// Partial global singleton page, provides global functionalities.
class HomePage extends StatefulWidget {
  /// Constructor.
  const HomePage({required this.showNavigationBar, required this.child, super.key});

  /// Control to show the app level navigation bar or not.
  ///
  /// Only show in top pages.
  final bool showNavigationBar;

  /// Child widget, or call it the body widget.
  final Widget child;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with LoggerMixin {
  /// Location stream subscription.
  late final StreamSubscription<String?> rootLocationSub;

  /// Selected home tab, owned here so it can follow the router ([_syncTabWithRouter]).
  final _homeCubit = HomeCubit();

  /// Router whose changes [_syncTabWithRouter] listens to.
  GoRouter? _router;

  /// Select the tab of the home shell page on top, when one is.
  ///
  /// The navigation bar only changed the tab when tapped itself; the home button on the notification pages switches
  /// the branch through the router and the bar has to follow (GitHub #117).
  void _syncTabWithRouter() {
    final router = _router;
    if (router == null || !mounted) {
      return;
    }
    // The navigation bar rebuilds on the new tab: not while a frame is being built.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _syncTabWithRouter());
      return;
    }
    final tab = homeTabOfLocation(routerTopLocation(router));
    if (tab != null && tab != _homeCubit.state.tab) {
      _homeCubit.setTab(tab);
    }
  }

  void _onLocalNoticeStreamEvent(String? payload) {
    final open = LocalNoticeKeys.parseOpenNotification(payload);
    if (open == null) {
      warning('ignore local notification with unknown payload: $payload');
      return;
    }
    unawaited(_openNoticeOf(open.uid, target: LocalNoticeKeys.parseTarget(payload)));
  }

  /// Open the notice page as the account [uid] of the tapped notification, switching to it first when another one is
  /// in use ([openNoticePageOfAccount]); the page of its [target] instead when it names one.
  ///
  /// Asks the router which page is really on top instead of the location stack, which drifted and refused taps on the
  /// homepage as "already in the notice page" (#14). Both answers stay in the log for the next report. A notice page
  /// already open under the pages on top is shown again instead of pushing another one (#117).
  Future<void> _openNoticeOf(int? uid, {LocalNoticeTarget? target}) async {
    final (:step, :top, :action) = await openNoticePageOfAccount(context, uid: uid, target: target);
    if (!mounted) {
      return;
    }
    info(
      'notification tap: account=${step.name} action=${action?.name} top=$top '
      'location=${context.read<RootLocationCubit>().currentPath}',
    );
  }

  /// Open the page asked for by the notification that cold-started the app, if any (#14).
  ///
  /// The payload was parked at boot ([rememberNotificationLaunch]); it goes through the same handler and login guard
  /// as a tap while the app is alive, once the page can navigate. Consumed once: a rebuilt home page finds nothing.
  void _consumeLaunchPayload(Duration _) {
    if (!mounted) {
      return;
    }
    unawaited(consumePendingLaunchPayload(_onLocalNoticeStreamEvent));
  }

  Widget _buildDrawerBody(BuildContext context) => Scaffold(
    body: Row(
      children: [
        if (widget.showNavigationBar) ...[
          // One side panel: the brand block and the drawer share the low container color of the navigation.
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                // Brand block of the side navigation, in the rounded style of the homepage cards.
                SizedBox(
                  height: 100,
                  width: _drawerWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(appSurfaceRadius),
                      ),
                      child: Center(
                        child: Padding(
                          padding: edgeInsetsL12R12,
                          child: Text(
                            context.t.appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _drawerWidth),
                    child: const HomeNavigationDrawer(),
                  ),
                ),
              ],
            ),
          ),
          const HomeNavigationDivider(),
        ],
        Expanded(child: widget.child),
      ],
    ),
  );

  @override
  void initState() {
    super.initState();
    rootLocationSub = localNoticeStream.stream.listen(_onLocalNoticeStreamEvent);
    WidgetsBinding.instance.addPostFrameCallback(_consumeLaunchPayload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (!identical(router, _router)) {
      _router?.routerDelegate.removeListener(_syncTabWithRouter);
      _router = router?..routerDelegate.addListener(_syncTabWithRouter);
    }
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_syncTabWithRouter);
    unawaited(_homeCubit.close());
    unawaited(rootLocationSub.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context);

    // The page used to wait here for the clean up of the outdated images (a spinner instead of the homepage); that
    // runs in the background now, long after the first frame (InitCubit.scheduleImageCacheTrim).
    return MultiBlocProvider(
      providers: [BlocProvider.value(value: _homeCubit)],
      child: Builder(
        builder: (context) {
          if (ResponsiveBreakpoints.of(context).largerThan(WindowSize.expanded.name)) {
            return _buildDrawerBody(context);
          } else if (ResponsiveBreakpoints.of(context).largerThan(WindowSize.compact.name)) {
            return Scaffold(
              body: Row(
                children: [
                  if (widget.showNavigationBar) ...[
                    const HomeNavigationRail(),
                    const HomeNavigationDivider(),
                  ],
                  Expanded(child: widget.child),
                ],
              ),
            );
          } else {
            return Scaffold(
              body: widget.child,
              bottomNavigationBar: widget.showNavigationBar ? const HomeNavigationBar() : null,
            );
          }
        },
      ),
    );
  }
}
