part of 'widgets.dart';

/// [NavigationDrawer] used in home page.
///
/// Use in large or extra-large window.
class HomeNavigationDrawer extends StatefulWidget {
  /// Constructor.
  const HomeNavigationDrawer({super.key});

  @override
  State<HomeNavigationDrawer> createState() => _HomeNavigationDrawerState();
}

class _HomeNavigationDrawerState extends State<HomeNavigationDrawer> {
  final _doubleTap = HomeTabDoubleTapDetector();

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);
    return NavigationDrawer(
      selectedIndex: context.watch<HomeCubit>().state.tab.index,
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
      children: barItems
          .map((e) => NavigationDrawerDestination(icon: e.icon, selectedIcon: e.selectedIcon, label: Text(e.label)))
          .toList(),
    );
  }
}
