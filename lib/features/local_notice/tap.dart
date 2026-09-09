import 'package:go_router/go_router.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// What the app does with a tap on the auto sync notification.
enum LocalNoticeTapAction {
  /// No account in use: the notice page needs a login, stay where we are.
  needLogin,

  /// The notice page is already the page on top, nothing to open.
  alreadyOnNoticePage,

  /// Push the notice page.
  openNoticePage,
}

/// Decide what a tap on the auto sync notification does.
///
/// [topLocation] is the location of the page the router shows on top ([routerTopLocation]). That is the only thing
/// telling whether the notice page is really in front: the location stack kept by `RootLocationCubit` is fed by page
/// enter/leave events and used to drift, so a tap on the homepage was answered "already in the notice page" after the
/// notice page had been left once (GitHub #14).
LocalNoticeTapAction decideLocalNoticeTap({required bool loggedIn, required String? topLocation}) {
  if (!loggedIn) {
    return LocalNoticeTapAction.needLogin;
  }
  if (topLocation == ScreenPaths.notice) {
    return LocalNoticeTapAction.alreadyOnNoticePage;
  }
  return LocalNoticeTapAction.openNoticePage;
}

/// Location of the page on top of [router], `null` before the first route matched.
///
/// Walks into shell routes, so a page inside the home shell reports its own location instead of the shell's, and a
/// page opened with `pushNamed` reports itself. Dialogs and bottom sheets are not routes of the router: the page
/// under them is reported, which is what a tap wants to know.
String? routerTopLocation(GoRouter router) => router.routerDelegate.currentConfiguration.lastOrNull?.matchedLocation;
