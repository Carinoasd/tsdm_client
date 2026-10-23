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
    // The four tabs, the same destinations as the side navigation of wider windows.
    final barItems = _buildNavigationItems(context);
    final colorScheme = Theme.of(context).colorScheme;

    // Same look as the side navigation: low container color, rounded indicator, hairline towards the content.
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _navigationHairline(colorScheme))),
      ),
      child: NavigationBar(
        backgroundColor: colorScheme.surfaceContainerLow,
        elevation: 0,
        indicatorShape: _navigationIndicatorShape,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        // The notifications carry their unread count, as on the side navigation.
        destinations: barItems
            .map(
              (e) => NavigationDestination(
                icon: _destinationIcon(e),
                selectedIcon: _destinationIcon(e, selected: true),
                label: e.label,
              ),
            )
            .toList(),
        selectedIndex: _selectedIndexOf(barItems, context.watch<HomeCubit>().state.tab),
        onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
      ),
    );
  }
}
