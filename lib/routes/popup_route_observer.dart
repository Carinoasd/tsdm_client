import 'package:flutter/widgets.dart';

/// Tracks modal popups so navigation outside the app's widgets respects their barriers.
class PopupRouteObserver extends NavigatorObserver {
  final Set<Route<dynamic>> _popupRoutes = {};

  /// Whether this navigator contains a dialog, menu, or another popup route.
  ///
  /// Keep tracking popups below other routes until they are actually removed.
  bool get hasPopupRoute => _popupRoutes.isNotEmpty;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (route is PopupRoute<dynamic>) {
      _popupRoutes.add(route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _popupRoutes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _popupRoutes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _popupRoutes.remove(oldRoute);
    if (newRoute is PopupRoute<dynamic>) {
      _popupRoutes.add(newRoute);
    }
  }
}
