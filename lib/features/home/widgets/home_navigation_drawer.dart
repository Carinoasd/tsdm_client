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
    final colorScheme = Theme.of(context).colorScheme;
    // Same look as the bottom bar and the rail: low container color (shared with the brand block above it), rounded
    // indicator. The same four destinations as the bottom bar; the drawer is a list and scrolls when the window is
    // short.
    return NavigationDrawer(
      backgroundColor: colorScheme.surfaceContainerLow,
      elevation: 0,
      indicatorShape: _navigationIndicatorShape,
      selectedIndex: _selectedIndexOf(barItems, context.watch<HomeCubit>().state.tab),
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
      children: [
        for (final e in barItems)
          NavigationDrawerDestination(
            icon: _destinationIcon(e),
            selectedIcon: _destinationIcon(e, selected: true),
            // The label sits in a row of unbounded width: bound it so a long label (large text) is cut instead of
            // overflowing the 250px side panel.
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _drawerLabelMaxWidth),
              child: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    );
  }
}

/// Room of a drawer label in the 250px side panel, after the tile padding, the icon and the gaps.
const _drawerLabelMaxWidth = 150.0;
