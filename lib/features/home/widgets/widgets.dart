import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

part 'animated_branch_page_view.dart';
part 'home_navigation_bar.dart';
part 'home_navigation_drawer.dart';
part 'home_navigation_rail.dart';
part 'home_tab_tap.dart';

/// Indicator of the selected destination in the bottom bar, the rail and the drawer: the inner radius of the app
/// surfaces instead of the default pill.
const _navigationIndicatorShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(appInnerRadius)),
);

/// Hairline between the navigation and the content, the border color of the app surfaces.
Color _navigationHairline(ColorScheme colorScheme) => colorScheme.outlineVariant.withValues(alpha: 0.6);

/// Divider between the side navigation (rail or drawer) and the content.
class HomeNavigationDivider extends StatelessWidget {
  /// Constructor.
  const HomeNavigationDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      VerticalDivider(width: 1, thickness: 1, color: _navigationHairline(Theme.of(context).colorScheme));
}

/// Destination of the app navigation: a tab of the home shell.
///
/// The bottom bar (phones), the rail (tablets) and the drawer (desktop windows) show the same four, in the order of
/// [HomeTab]. Their state is kept, a double tap scrolls them to top.
final class _NavigationItem {
  /// Constructor.
  const _NavigationItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.tab,
    this.unreadNoticeBadge = false,
  });

  /// Item icon.
  ///
  /// Use outline style icons.
  final Icon icon;

  /// Item icon when selected.
  ///
  /// Use normal style icons.
  final Icon selectedIcon;

  /// Name of the item.
  final String label;

  /// Tab of the home shell.
  final HomeTab tab;

  /// Show the unread notification count (`NoticeIcon` rules) on the icon.
  final bool unreadNoticeBadge;
}

/// The destinations of every navigation (bottom bar, rail, drawer), in display order: the four tabs of the home shell.
///
/// The pages the side navigation listed besides the tabs (activities, title shop, medal center, bank, the profile) are
/// entries of the "me" tab now, next to the other pages of the account; the settings moved there too.
List<_NavigationItem> _buildNavigationItems(BuildContext context) {
  final tr = context.t.navigation;
  return [
    _NavigationItem(
      icon: const Icon(Icons.home_outlined),
      selectedIcon: const Icon(Icons.home),
      label: tr.homepage,
      tab: HomeTab.home,
    ),
    _NavigationItem(
      icon: const Icon(Icons.topic_outlined),
      selectedIcon: const Icon(Icons.topic),
      label: tr.topics,
      tab: HomeTab.topic,
    ),
    _NavigationItem(
      icon: const Icon(Icons.notifications_outlined),
      selectedIcon: const Icon(Icons.notifications),
      label: tr.notice,
      tab: HomeTab.notice,
      unreadNoticeBadge: true,
    ),
    _NavigationItem(
      icon: const Icon(Icons.person_outline),
      selectedIcon: const Icon(Icons.person),
      label: tr.me,
      tab: HomeTab.me,
    ),
  ];
}

/// Index in [items] of the destination showing [tab]: the selected one.
int _selectedIndexOf(List<_NavigationItem> items, HomeTab tab) => items.indexWhere((e) => e.tab == tab);

/// Icon of [item], with the unread notification count when it carries one.
Widget _destinationIcon(_NavigationItem item, {bool selected = false}) {
  final icon = selected ? item.selectedIcon : item.icon;
  return item.unreadNoticeBadge ? _UnreadNoticeIcon(icon) : icon;
}

/// [icon] with the unread notification count, by the rules of `NoticeIcon`: only with an account, only when the unread
/// hint setting is on and only when something is unread. The count is the one of [NotificationStateCubit], which the
/// notification sync keeps (blocked and muted senders already left out); nothing is shown without that cubit.
class _UnreadNoticeIcon extends StatelessWidget {
  const _UnreadNoticeIcon(this.icon);

  final Icon icon;

  @override
  Widget build(BuildContext context) {
    final cubit = context.readOrNull<NotificationStateCubit>();
    if (cubit == null) {
      return icon;
    }
    return BlocBuilder<NotificationStateCubit, NotificationStateInfo>(
      bloc: cubit,
      builder: (context, state) {
        final loggedIn = context.readOrNull<AuthenticationRepository>()?.currentUser != null;
        final showUnreadHint =
            getIt.isRegistered<SettingsRepository>() &&
            getIt.get<SettingsRepository>().currentSettings.showUnreadInfoHint;
        if (!loggedIn || !showUnreadHint || state.total <= 0) {
          return icon;
        }
        final colorScheme = Theme.of(context).colorScheme;
        return Badge(
          // Three digits crowd the label under the icon of the bottom bar.
          label: Text(state.total > 99 ? '99+' : '${state.total}'),
          backgroundColor: colorScheme.error,
          textColor: colorScheme.onError,
          child: icon,
        );
      },
    );
  }
}
