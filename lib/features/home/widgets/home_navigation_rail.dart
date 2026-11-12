part of 'widgets.dart';

/// Size of the app icon heading [HomeNavigationRail].
const homeNavigationRailLogoSize = 36.0;

/// Where the destinations of [HomeNavigationRail] sit in the room below the app icon: the middle.
const homeNavigationRailGroupAlignment = 0.0;

/// [NavigationRail] used in home page.
///
/// Use in medium window size.
class HomeNavigationRail extends StatefulWidget {
  /// Constructor.
  const HomeNavigationRail({super.key});

  @override
  State<HomeNavigationRail> createState() => _HomeNavigationRailState();
}

class _HomeNavigationRailState extends State<HomeNavigationRail> {
  final _doubleTap = HomeTabDoubleTapDetector();

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);
    final colorScheme = Theme.of(context).colorScheme;

    // Same look as the bottom bar and the drawer: low container color, rounded indicator, labels always shown. The app
    // icon heads the rail (GitHub #236), the destinations sit in the middle of the room below it.
    final rail = NavigationRail(
      groupAlignment: homeNavigationRailGroupAlignment,
      leading: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SvgPicture.asset(
            assetsLogoSvgPath,
            key: const ValueKey('home-navigation-rail-logo'),
            width: homeNavigationRailLogoSize,
            height: homeNavigationRailLogoSize,
          ),
        ),
      ),
      backgroundColor: colorScheme.surfaceContainerLow,
      indicatorShape: _navigationIndicatorShape,
      labelType: NavigationRailLabelType.all,
      destinations: [
        for (final e in barItems)
          NavigationRailDestination(
            icon: _destinationIcon(e),
            selectedIcon: _destinationIcon(e, selected: true),
            label: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      selectedIndex: _selectedIndexOf(barItems, context.watch<HomeCubit>().state.tab),
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
    );

    // NavigationRail does not scroll: its destinations can overflow a short window (landscape phone with large text).
    // It gets the window height, or the height its destinations really need when that is more, inside a scroll view. The height is measured (intrinsic height of the rail), not estimated: a generous estimate left empty room
    // at the end, and the last destination stopped half clipped at the top of the scroll area (feedback 110).
    //
    // The top and bottom insets (status bar, gesture bar) stay outside of the scroll view as bands of the rail color:
    // inside, the rail padded them in its own content and scrolling to the end moved the destinations under the status
    // bar (feedback 110). The scroll view clips to the area between the bands; the start inset (cutout in landscape)
    // is still handled by the rail itself.
    final padding = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.only(top: padding.top, bottom: padding.bottom),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              key: const ValueKey('home-navigation-rail-scroll'),
              primary: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0),
                child: IntrinsicHeight(child: rail),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
