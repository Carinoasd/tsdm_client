import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

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

/// Go back to the homepage, without starting anything: the check-in asked for by a link from outside the app.
final class AppShortcutHome extends AppShortcutAction {
  /// Constructor.
  const AppShortcutHome();
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

/// Open the page of [route], a forum or a thread pinned to the home screen, the way a link opens it.
final class AppShortcutOpenRoute extends AppShortcutAction {
  /// Constructor.
  const AppShortcutOpenRoute(this.route);

  /// The page.
  final RecognizedRoute route;
}

/// Decide what [shortcut] does with ([loggedIn]) or without an account in use.
///
/// The search is open to guests; the check-in, the notices and the favorites belong to an account, so without one the
/// login page opens instead.
///
/// A shortcut a link from outside the app asked for ([external]: a web page opening `tsdm://shortcut/checkin` on iOS)
/// only opens its page: the check-in goes back to the homepage, whose button checks in when the user taps it.
///
/// A forum or a thread pinned to the home screen opens its page, with or without an account (the page asks for a login
/// when the forum wants one), and from a link of another app as well: a page is all it opens, what any app can open
/// with a link of the forum already.
AppShortcutAction decideAppShortcut(ShortcutTarget shortcut, {required bool loggedIn, bool external = false}) =>
    switch (shortcut) {
      PinnedForum(:final fid) => AppShortcutOpenRoute(
        RecognizedRoute(ScreenPaths.forum, pathParameters: {'fid': '$fid'}),
      ),
      PinnedThread(:final tid) => AppShortcutOpenRoute(
        RecognizedRoute(ScreenPaths.threadV1, queryParameters: {'tid': '$tid'}),
      ),
      AppShortcut.checkin when external => const AppShortcutHome(),
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
/// * A pinned forum or thread opens as a link tapped on the page in view: a thread goes to the detail pane of the list
///   page in view while it shows two panes ([listInView], see [twoPaneListContextInView]), anything else is pushed
///   above the page on top, unless that page is the one on top already.
void performAppShortcut(
  GoRouter router,
  AppShortcutAction action, {
  required VoidCallback checkin,
  required bool hasPopup,
  BuildContext? Function() listInView = twoPaneListContextInView,
}) {
  switch (action) {
    case AppShortcutLogin():
      _pushUnlessOnTop(router, ScreenPaths.login);
    case AppShortcutOpenPage(:final path):
      _pushUnlessOnTop(router, path);
    case AppShortcutOpenRoute(:final route):
      _openRoute(router, route, listInView: listInView);
    case AppShortcutNotice():
      openNoticePageForTap(router, loggedIn: true, hasPopup: hasPopup);
    case AppShortcutHome():
      if (!hasPopup) {
        returnToHome(router);
      }
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

void _openRoute(GoRouter router, RecognizedRoute route, {required BuildContext? Function() listInView}) {
  if (route.screenPath == ScreenPaths.threadV1) {
    final list = listInView();
    if (list != null && list.mounted && openThreadInPane(list, route.queryParameters, newTab: false)) {
      return;
    }
  }
  if (_isOnTop(router, route)) {
    return;
  }
  // Completes only when the pushed page is closed, nothing to wait for.
  router
      .pushNamed(route.screenPath, pathParameters: route.pathParameters, queryParameters: route.queryParameters)
      .ignore();
}

/// Whether the page on top of [router] is the one of [route]: the same location, and the same values of the query
/// parameters [route] has (another floor or page of the same thread is that thread).
bool _isOnTop(GoRouter router, RecognizedRoute route) {
  final configuration = router.routerDelegate.currentConfiguration;
  final top = configuration.lastOrNull;
  if (top == null) {
    return false;
  }
  // A pushed page keeps its own location; the last page of the stack otherwise.
  final uri = top is ImperativeRouteMatch ? top.matches.uri : configuration.uri;
  final location = Uri.parse(router.namedLocation(route.screenPath, pathParameters: route.pathParameters));
  return uri.path == location.path && route.queryParameters.entries.every((e) => uri.queryParameters[e.key] == e.value);
}
