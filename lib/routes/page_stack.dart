import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Pages the app may close on its own: when a notification tap goes back to the notice page already open, or when the
/// home button leaves the notification pages (GitHub #117).
///
/// Only pages for reading: what they show is fetched again when opened again. Any other page may hold a form the user
/// is filling in, and closing it would throw the input away, so the navigation leaves it open instead. The reply bar on
/// some of these pages is checked through [RouteDrafts].
const quietlyClosablePages = <String>{
  ScreenPaths.notice,
  ScreenPaths.reply,
  ScreenPaths.broadcastMessageDetail,
  ScreenPaths.chat,
  ScreenPaths.chatHistory,
  ScreenPaths.threadV1,
  ScreenPaths.threadV2,
  ScreenPaths.forum,
  ScreenPaths.forumGroup,
  ScreenPaths.profile,
  ScreenPaths.loggedUserProfile,
  ScreenPaths.imageDetail,
  ScreenPaths.rateLog,
  ScreenPaths.packetDetail,
  ScreenPaths.latestThread,
  ScreenPaths.myThread,
  ScreenPaths.favorite,
  ScreenPaths.threadVisitHistory,
};

/// Text typed on a page and not sent yet, asked for by the route showing the page.
///
/// The back button still leaves such a page as it always did: no page guards its reply with a `PopScope`. Only the
/// navigation the app starts by itself asks here first, so a notification tap or the home button never throws away a
/// reply being written.
abstract final class RouteDrafts {
  static final Map<Route<dynamic>, Set<bool Function()>> _checks = {};

  /// Let [hasDraft] tell whether [route] holds unsent text, until [unregister]ed.
  static void register(Route<dynamic> route, bool Function() hasDraft) => (_checks[route] ??= {}).add(hasDraft);

  /// Undo [register].
  static void unregister(Route<dynamic> route, bool Function() hasDraft) {
    final checks = _checks[route];
    if (checks == null) {
      return;
    }
    checks.remove(hasDraft);
    if (checks.isEmpty) {
      _checks.remove(route);
    }
  }

  /// Whether [route] holds unsent text.
  static bool hasDraft(Route<dynamic> route) => _checks[route]?.any((check) => check()) ?? false;

  /// Whether the route currently showing [page] holds unsent text.
  static bool pageHasDraft(Page<dynamic> page) =>
      _checks.entries.any((e) => identical(e.key.settings, page) && e.value.any((check) => check()));
}

/// Whether the app may close [route] on its own, see [quietlyClosablePages].
///
/// Never the first route (the home shell), a dialog or sheet route, a page refusing to pop (`PopScope`) or a page
/// holding a draft.
bool canCloseQuietly(Route<dynamic> route) =>
    !route.isFirst &&
    route is! PopupRoute<dynamic> &&
    quietlyClosablePages.contains(route.settings.name) &&
    route.popDisposition != RoutePopDisposition.doNotPop &&
    !RouteDrafts.hasDraft(route);

NavigatorState? _rootNavigator(GoRouter router) => router.routerDelegate.navigatorKey.currentState;

/// Whether every page above the topmost [name] page of [router] can be closed quietly, so that page can be shown again
/// instead of opening another one on top.
///
/// False when there is no such page, when it is already on top, or when a dialog or sheet is open ([hasPopup]): the
/// pages under a dialog are not closed behind the user's back.
bool canReturnToPage(GoRouter router, String name, {required bool hasPopup}) {
  if (hasPopup) {
    return false;
  }
  final pages = _rootNavigator(router)?.widget.pages ?? const <Page<dynamic>>[];
  final index = pages.lastIndexWhere((page) => page.name == name);
  if (index < 0 || index == pages.length - 1) {
    return false;
  }
  return pages
      .skip(index + 1)
      .every((page) => quietlyClosablePages.contains(page.name) && !RouteDrafts.pageHasDraft(page));
}

/// Close the pages above the topmost [name] page of [router]; true when that page is on top afterwards.
///
/// Stops early at a page that cannot be closed quietly, check [canReturnToPage] first to avoid half the way.
bool returnToPage(GoRouter router, String name) {
  final navigator = _rootNavigator(router);
  if (navigator == null) {
    return false;
  }
  Route<dynamic>? stoppedAt;
  navigator.popUntil((route) {
    if ((route.settings.name == name && route is! PopupRoute<dynamic>) || !canCloseQuietly(route)) {
      stoppedAt = route;
      return true;
    }
    return false;
  });
  return stoppedAt?.settings.name == name && stoppedAt is! PopupRoute<dynamic>;
}

/// Close the pages above the home shell of [router] and show the homepage tab (GitHub #117).
///
/// Pages that cannot be closed quietly stay: the closing stops on the first one, which is then on top, and false is
/// returned so the caller can tell why the homepage did not show.
bool returnToHome(GoRouter router) {
  final navigator = _rootNavigator(router);
  if (navigator == null) {
    return false;
  }
  var reachedFirst = false;
  navigator.popUntil((route) {
    if (route.isFirst) {
      reachedFirst = true;
      return true;
    }
    return !canCloseQuietly(route);
  });
  // Switching tabs replaces the bottom page: only do it when that page is the home shell, not some other page the app
  // was started on.
  final matches = router.routerDelegate.currentConfiguration.matches;
  if (!reachedFirst || matches.isEmpty || matches.first is! ShellRouteMatch) {
    return false;
  }
  router.goNamed(ScreenPaths.homepage);
  return true;
}

/// The home tab showing [location], `null` when it is not a page of the home shell.
HomeTab? homeTabOfLocation(String? location) {
  if (location == ScreenPaths.homepage) {
    return HomeTab.home;
  }
  if (location == ScreenPaths.topic) {
    return HomeTab.topic;
  }
  final settings = ScreenPaths.settings.fullPath;
  if (location != null && (location == settings || location.startsWith('$settings/'))) {
    return HomeTab.settings;
  }
  return null;
}
