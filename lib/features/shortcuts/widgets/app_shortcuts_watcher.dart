import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/features/shortcuts/utils/app_shortcut_action.dart';
import 'package:tsdm_client/features/shortcuts/utils/checkin_when_verified.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Carries out the shortcuts of a long press on the app icon (Android) and the taps on the home screen widget (Android,
/// iOS).
///
/// Lives under the app's providers and draws nothing. The shortcut the app was started with is carried out after the
/// first frame, when the router shows its first page; a shortcut tapped while the app runs is carried out as it comes.
/// The account in use decides between the page and the login ([decideAppShortcut]); the stored session counts, as it
/// does for a notification tap: at a cold start the homepage has its first frame before the login is verified. The
/// check-in itself waits for that verification ([startCheckinWhenVerified]).
class AppShortcutsWatcher extends StatefulWidget {
  /// Constructor.
  const AppShortcutsWatcher({super.key});

  @override
  State<AppShortcutsWatcher> createState() => _AppShortcutsWatcherState();
}

class _AppShortcutsWatcherState extends State<AppShortcutsWatcher> with LoggerMixin {
  final _channel = const AppShortcutsChannel();

  /// Whether the platform hands shortcuts over: the launcher shortcuts and the widget on Android, the widget on iOS.
  static final _supported = isAndroid || isIOS;

  /// Whether a check-in shortcut is waiting for the login check: another one meanwhile is the same wish.
  var _checkinWaiting = false;

  @override
  void initState() {
    super.initState();
    if (!_supported) {
      return;
    }
    _channel.listen(_run);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final shortcut = await _channel.initial();
      if (shortcut != null && mounted) {
        _run(shortcut);
      }
    });
  }

  @override
  void dispose() {
    if (_supported) {
      _channel.dispose();
    }
    super.dispose();
  }

  void _run(AppShortcut shortcut) {
    if (!mounted) {
      return;
    }
    final loggedIn = context.repo<AuthenticationRepository>().effectiveCurrentUid != null;
    final action = decideAppShortcut(shortcut, loggedIn: loggedIn);
    info('app shortcut ${shortcut.id}: ${action.runtimeType}, top=${routerTopLocation(router)}');
    performAppShortcut(router, action, hasPopup: popupRouteObserver.hasPopupRoute, checkin: _checkin);
  }

  void _checkin() {
    if (_checkinWaiting) {
      return;
    }
    _checkinWaiting = true;
    unawaited(_checkinWhenVerified().whenComplete(() => _checkinWaiting = false));
  }

  Future<void> _checkinWhenVerified() async {
    final auth = context.repo<AuthenticationRepository>();
    final bloc = context.read<CheckinBloc>();
    final uid = auth.effectiveCurrentUid;
    final outcome = await startCheckinWhenVerified(
      verified: () => auth.currentUser != null,
      status: auth.status,
      // The homepage records the guest page it got for an expired session here, without a status (issue #25).
      expired: getIt.get<StorageProvider>().watchExpiredSessionUids().map((uids) => uids.contains(uid)),
      start: () => bloc.add(const CheckinRequested()),
    );
    info('app shortcut checkin: ${outcome.name}');
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case ShortcutCheckinOutcome.started:
        break;
      case ShortcutCheckinOutcome.notAuthed:
        // The login action never starts a check-in: the callback is not called.
        performAppShortcut(
          router,
          const AppShortcutLogin(),
          hasPopup: popupRouteObserver.hasPopupRoute,
          checkin: () {},
        );
      case ShortcutCheckinOutcome.timedOut:
        showSnackBar(context: context, message: context.t.appShortcuts.checkinNotVerified);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
