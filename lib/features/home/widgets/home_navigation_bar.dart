part of 'widgets.dart';

/// [NavigationBar] used in home page.
///
/// Use in compact window.
class HomeNavigationBar extends StatefulWidget {
  /// Constructor.
  const HomeNavigationBar({super.key});

  @override
  State<HomeNavigationBar> createState() => _HomeNavigationBarState();
}

class _HomeNavigationBarState extends State<HomeNavigationBar> {
  final _doubleTap = HomeTabDoubleTapDetector();

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);

    return NavigationBar(
      destinations: barItems
          .map((e) => NavigationDestination(icon: e.icon, selectedIcon: e.selectedIcon, label: e.label))
          .toList(),
      selectedIndex: context.watch<HomeCubit>().state.tab.index,
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
    );
  }
}
