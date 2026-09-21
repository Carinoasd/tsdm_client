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
  DateTime? _lastTapTime;
  int? _lastTapIndex;

  void _onDestinationSelected(int index, List<_NavigationItem> barItems) {
    final now = DateTime.now();

    // 双击检测 (500ms 内点击同一个 index)
    if (_lastTapIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 500)) {
      
      // 拦截第二次路由跳转，直接发送返回顶部事件
      scrollToTopStream.add(ScrollToTopEvent(index));

      // 重置状态，防止三击再次触发
      _lastTapTime = null;
      _lastTapIndex = null;
    } else {
      // 第一次点击，正常切换 Tab
      context.read<HomeCubit>().setTab(barItems[index].tab);
      context.goNamed(barItems[index].targetPath);

      _lastTapTime = now;
      _lastTapIndex = index;
    }
  }

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);

    return NavigationBar(
      destinations: barItems
          .map((e) => NavigationDestination(icon: e.icon, selectedIcon: e.selectedIcon, label: e.label))
          .toList(),
      selectedIndex: context.watch<HomeCubit>().state.tab.index,
      onDestinationSelected: (index) => _onDestinationSelected(index, barItems),
    );
  }
}
