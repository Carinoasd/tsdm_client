import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// What the app does for an [AppShortcut], decided by [decideAppShortcut] and carried out by [performAppShortcut].
sealed class AppShortcutAction {
  const AppShortcutAction();
}

/// No account in use and the shortcut needs one: open the login page.
final class AppShortcutLogin extends AppShortcutAction {
  /// Constructor.
  const AppShortcutLogin();
}

/// Show the homepage and start the check-in, whose button there tells the result.
final class AppShortcutCheckin extends AppShortcutAction {
  /// Constructor.
  const AppShortcutCheckin();
}

/// Show the notice page, the way a tap on the auto sync notification does.
final class AppShortcutNotice extends AppShortcutAction {
  /// Constructor.
  const AppShortcutNotice();
}

/// Open the page at [path] above the page on top, unless it is on top already.
final class AppShortcutOpenPage extends AppShortcutAction {
  /// Constructor.
  const AppShortcutOpenPage(this.path);

  /// The route of the page, one of `ScreenPaths`.
  final String path;
}

/// Decide what [shortcut] does with ([loggedIn]) or without an account in use.
///
/// The search is open to guests; the check-in, the notices and the favorites belong to an account, so without one the
/// login page opens instead.
AppShortcutAction decideAppShortcut(AppShortcut shortcut, {required bool loggedIn}) => switch (shortcut) {
  AppShortcut.search => const AppShortcutOpenPage(ScreenPaths.search),
  _ when !loggedIn => const AppShortcutLogin(),
  AppShortcut.checkin => const AppShortcutCheckin(),
  AppShortcut.notice => const AppShortcutNotice(),
  AppShortcut.favorite => const AppShortcutOpenPage(ScreenPaths.favorite),
};

/// Carry out [action] on [router].
///
/// [checkin] starts the check-in of the account in use (the app's `CheckinBloc`). [hasPopup] tells whether a dialog or
/// sheet is open: the pages under it are then left as they are.
///
/// * Login and other pages are pushed above the page on top, and not again when they are on top already (a shortcut
///   tapped twice).
/// * The check-in first goes back to the homepage tab the way the home button does ([returnToHome]): the pages that
///   can be closed quietly are closed, a form stays; then the check-in starts, and the button of the homepage tells the
///   result.
/// * The notices follow the tap on the auto sync notification ([openNoticePageForTap]): the notifications tab when the
///   home shell is alone, else the notice page above the page on top.
void performAppShortcut(
  GoRouter router,
  AppShortcutAction action, {
  required VoidCallback checkin,
  required bool hasPopup,
}) {
  switch (action) {
    case AppShortcutLogin():
      _pushUnlessOnTop(router, ScreenPaths.login);
    case AppShortcutOpenPage(:final path):
      _pushUnlessOnTop(router, path);
    case AppShortcutNotice():
      openNoticePageForTap(router, loggedIn: true, hasPopup: hasPopup);
    case AppShortcutCheckin():
      if (!hasPopup) {
        returnToHome(router);
      }
      checkin();
  }
}

void _pushUnlessOnTop(GoRouter router, String path) {
  if (routerTopLocation(router) == path) {
    return;
  }
  // Completes only when the pushed page is closed, nothing to wait for.
  router.pushNamed(path).ignore();
}
