import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_intents.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Windows at least this wide (Material's "expanded" class) show a list page and the thread opened from it side by
/// side, see [TwoPaneLayout].
const twoPaneMinWidth = 840.0;

/// The list pane takes this share of the window...
const twoPaneListFraction = 0.4;

/// ...kept at least this wide...
const twoPaneListMinWidth = 360.0;

/// ...and at most this wide, until the divider between the panes is dragged ([twoPaneListWidthFor]).
const twoPaneListMaxWidth = 480.0;

/// The detail pane holds at most this many tabs ([TwoPaneTabs]).
const twoPaneMaxTabs = 20;

/// The detail pane, the divider included, is kept at least this wide when the divider is dragged.
const twoPaneDetailMinWidth = 480.0;

/// The list pane of a two-pane layout [width] wide: [dragged] wide when the divider was dragged there (above 0),
/// else its share of the window ([twoPaneListFraction], within [twoPaneListMinWidth]–[twoPaneListMaxWidth]); always
/// at least [twoPaneListMinWidth], with [twoPaneDetailMinWidth] left on the right. A layout too narrow to hold both
/// gives each pane its share of the two least widths: a guard only while the two least widths add up to
/// [twoPaneMinWidth], the layout is never laid out narrower.
double twoPaneListWidthFor(double width, double dragged) {
  const least = twoPaneListMinWidth + twoPaneDetailMinWidth;
  if (width < least) {
    return width * twoPaneListMinWidth / least;
  }
  final wanted = dragged > 0 ? dragged : (width * twoPaneListFraction).clamp(twoPaneListMinWidth, twoPaneListMaxWidth);
  return wanted.clamp(twoPaneListMinWidth, width - twoPaneDetailMinWidth);
}

/// Whether the window of [context] shows two panes: wide enough, and the `twoPaneLayout` setting on (on when no
/// settings are provided, as in widget tests of a page alone).
///
/// Rebuilds the caller when the setting changes.
bool twoPaneEnabled(BuildContext context) {
  if (MediaQuery.sizeOf(context).width < twoPaneMinWidth) {
    return false;
  }
  if (context.readOrNull<SettingsBloc>() == null) {
    return true;
  }
  return context.select<SettingsBloc, bool>((bloc) => bloc.state.settingsMap.twoPaneLayout);
}

/// A thread shown in the detail pane: the query of its route ([ScreenPaths.threadV1]), as the route builder reads it.
final class PaneThread {
  PaneThread._(this.query, {ValueNotifier<String?>? title})
    : id = _nextId++,
      title = title ?? ValueNotifier(query['appBarTitle']);

  /// Ids are never given twice, whatever the tab: the pages of two tabs shown one after the other do not share a
  /// state.
  static var _nextId = 0;

  /// Tells the threads opened apart, so the same thread opened again starts over.
  final int id;

  /// The title of the thread, for its tab: the one it was opened with, then the one its page loaded
  /// ([reportTitle]).
  final ValueNotifier<String?> title;

  /// The page showing this thread tells its title, from its build: set once the frame is over.
  void reportTitle(String? value) {
    if (value == null || value.isEmpty || value == title.value) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => title.value = value);
  }

  /// The query parameters the thread was opened with.
  final Map<String, String> query;

  /// Tells how to open the thread again where it is read now, set by the thread page showing it ([resolver]).
  PaneQueryResolver? _resolver;

  /// The query to open the thread again as a page of its own: where it is read now when its page says so
  /// ([resolver]), else as it was opened.
  Map<String, String> get currentQuery => _resolver?.call(query) ?? query;

  /// The page showing this thread tells, through it, how to open the thread again where it is read now (the page in
  /// view, the author filter), from the query it was opened with. Undone with [detach].
  set resolver(PaneQueryResolver resolve) => _resolver = resolve;

  /// The resolver set, null while no page tells.
  PaneQueryResolver? get resolver => _resolver;

  /// Forget [resolve], when it is the [resolver] set.
  void detach(PaneQueryResolver resolve) {
    if (identical(_resolver, resolve)) {
      _resolver = null;
    }
  }
}

/// Builds the query to open a pane's thread again where it is read now, from the query it was opened with.
typedef PaneQueryResolver = Map<String, String> Function(Map<String, String> opened);

/// The threads of the detail pane, the one on top shown: taps on the list replace them all ([open]), a thread link
/// inside the pane goes on top of them ([push]), back takes the top one away ([pop]).
///
/// Each tab of the detail pane is one ([TwoPaneTabs]).
class TwoPaneController extends ChangeNotifier {
  final _threads = <PaneThread>[];

  /// The threads opened, bottom first.
  List<PaneThread> get threads => UnmodifiableListView(_threads);

  /// Nothing shown on the right.
  bool get isEmpty => _threads.isEmpty;

  /// The thread shown, null when the pane is empty.
  PaneThread? get top => _threads.lastOrNull;

  /// Show [query] alone: what the pane held before goes away.
  void open(Map<String, String> query) {
    _threads
      ..clear()
      ..add(PaneThread._(query));
    notifyListeners();
  }

  /// Show [query] above what the pane holds.
  void push(Map<String, String> query) {
    _threads.add(PaneThread._(query));
    notifyListeners();
  }

  /// Take the thread shown away; false when the pane was empty.
  bool pop() {
    if (_threads.isEmpty) {
      return false;
    }
    _threads.removeLast();
    notifyListeners();
    return true;
  }

  /// The thread on top, about to leave the screen (its tab no longer the one shown): kept as where it is read now,
  /// its page goes and can not tell any more. Nobody is told, nothing shown changes.
  void _freeze() {
    final top = _threads.lastOrNull;
    if (top == null || top.resolver == null) {
      return;
    }
    _threads.last = PaneThread._(top.currentQuery, title: top.title);
  }
}

/// The tabs of the detail pane, each a [TwoPaneController], one of them shown ([active]).
///
/// With no tab the pane is empty. A tab whose last thread is taken away ([TwoPaneController.pop]) closes; a tab not
/// shown is not built, its thread opens again where it was read when it is shown again.
class TwoPaneTabs extends ChangeNotifier {
  final _tabs = <TwoPaneController>[];
  var _active = 0;

  /// The tabs, in the order of the tab strip.
  List<TwoPaneController> get tabs => UnmodifiableListView(_tabs);

  /// How many tabs.
  int get length => _tabs.length;

  /// No tab: the pane is empty.
  bool get isEmpty => _tabs.isEmpty;

  /// Where the tab shown is, 0 when there is none.
  int get activeIndex => _active;

  /// The tab shown, null when there is none.
  TwoPaneController? get active => _tabs.isEmpty ? null : _tabs[_active];

  TwoPaneController _newTab() {
    final tab = TwoPaneController();
    tab.addListener(() => _onTabChanged(tab));
    return tab;
  }

  void _onTabChanged(TwoPaneController tab) {
    final index = _tabs.indexOf(tab);
    if (index < 0) {
      return;
    }
    if (tab.isEmpty) {
      close(index);
      return;
    }
    notifyListeners();
  }

  /// Show [query] alone in the tab shown, a first tab when there is none.
  void open(Map<String, String> query) {
    if (_tabs.isEmpty) {
      _tabs.add(_newTab()..open(query));
      _active = 0;
      notifyListeners();
      return;
    }
    active!.open(query);
  }

  /// Show [query] in a new tab at the end, behind the tab shown (the first tab is shown). With [twoPaneMaxTabs] tabs
  /// already, nothing opens and nothing shown changes; false then.
  bool openInNewTab(Map<String, String> query) {
    if (_tabs.length >= twoPaneMaxTabs) {
      return false;
    }
    _tabs.add(_newTab()..open(query));
    notifyListeners();
    return true;
  }

  /// Show the tab at [index].
  void select(int index) {
    if (index < 0 || index >= _tabs.length || index == _active) {
      return;
    }
    _tabs[_active]._freeze();
    _active = index;
    notifyListeners();
  }

  /// Show the tab after the one shown, the first after the last.
  void selectNext() {
    if (_tabs.length > 1) {
      select((_active + 1) % _tabs.length);
    }
  }

  /// Show the tab before the one shown, the last before the first.
  void selectPrevious() {
    if (_tabs.length > 1) {
      select((_active - 1 + _tabs.length) % _tabs.length);
    }
  }

  /// Close the tab at [index]; when it was shown, the one after it is shown, or the one before when it was the last.
  void close(int index) {
    if (index < 0 || index >= _tabs.length) {
      return;
    }
    _remove(index);
    notifyListeners();
  }

  /// Move the tab at [from] to [to] (where it is once moved), the tab shown staying shown.
  void move(int from, int to) {
    if (from < 0 || from >= _tabs.length || from == to) {
      return;
    }
    final target = to.clamp(0, _tabs.length - 1);
    final shown = _tabs[_active];
    _tabs.insert(target, _tabs.removeAt(from));
    _active = _tabs.indexOf(shown);
    notifyListeners();
  }

  /// Take the tab shown out without telling the listeners: for the pane being taken out of the tree in the same build.
  TwoPaneController? _takeActive() {
    if (_tabs.isEmpty) {
      return null;
    }
    final tab = _tabs[_active];
    _remove(_active);
    return tab;
  }

  /// Close every tab without telling the listeners: for the pane being out of the tree.
  void _clear() {
    while (_tabs.isNotEmpty) {
      _remove(_tabs.length - 1);
    }
    _active = 0;
  }

  void _remove(int index) {
    final tab = _tabs.removeAt(index);
    if (index < _active || (index == _active && _active == _tabs.length && _active > 0)) {
      _active--;
    }
    // Maybe telling its listeners right now (its last thread taken away).
    scheduleMicrotask(tab.dispose);
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}

/// Which pane a widget is built in.
enum TwoPaneSide {
  /// The list on the left.
  list,

  /// The thread on the right.
  detail,
}

/// Tells the widgets of a pane which pane they are in and gives them the [TwoPaneTabs]; they rebuild when the tabs or
/// the threads of the pane change.
class TwoPaneScope extends InheritedNotifier<TwoPaneTabs> {
  /// Constructor.
  const TwoPaneScope({required TwoPaneTabs tabs, required this.side, required super.child, this.tab, super.key})
    : super(notifier: tabs);

  /// The pane [child] is in.
  final TwoPaneSide side;

  /// In the detail pane: the tab shown, null when the pane is empty.
  final TwoPaneController? tab;

  /// The tabs of the detail pane.
  TwoPaneTabs get tabs => notifier!;

  /// The scope of the pane [context] is in, null outside a two-pane layout (a page on its own, a narrow window).
  ///
  /// For a build: the caller is built again when the threads of the pane change. Event handlers use [readOf].
  static TwoPaneScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TwoPaneScope>();

  /// [maybeOf] without depending on the scope, for event handlers (a tap, a link opened).
  static TwoPaneScope? readOf(BuildContext context) => context.getInheritedWidgetOfExactType<TwoPaneScope>();

  /// The tab shown when [context] is in the detail pane, null elsewhere.
  static TwoPaneController? detailOf(BuildContext context) {
    final scope = maybeOf(context);
    return scope?.side == TwoPaneSide.detail ? scope!.tab : null;
  }
}

/// Whether a click now asks for a new tab: Ctrl (Cmd) held.
///
/// Cmd on macOS (and iPadOS, following it), where Ctrl with a click is the right click; Ctrl elsewhere.
bool _newTabRequested() =>
    isMacOS || isIOS ? HardwareKeyboard.instance.isMetaPressed : HardwareKeyboard.instance.isControlPressed;

/// Open the thread of [queryParameters] (the query of [ScreenPaths.threadV1]) in the detail pane of the layout
/// [context] is in: from the list it replaces what the tab shown holds, from the detail pane it goes on top. With
/// [newTab] (by default: Ctrl or Cmd held) it opens in a new tab instead ([TwoPaneTabs.openInNewTab]). False when
/// [context] is not in a two-pane layout, the caller then opens the thread as a page of its own.
bool openThreadInPane(BuildContext context, Map<String, String?> queryParameters, {bool? newTab}) {
  final scope = TwoPaneScope.readOf(context);
  if (scope == null) {
    return false;
  }
  final query = {
    for (final MapEntry(:key, :value) in queryParameters.entries) key: ?value,
  };
  final tabs = scope.tabs;
  if (newTab ?? _newTabRequested()) {
    if (!tabs.openInNewTab(query)) {
      showSnackBar(
        context: context,
        message: context.t.twoPane.tabsFull(count: twoPaneMaxTabs),
        clearPrevious: true,
      );
    }
    return true;
  }
  switch (scope.side) {
    case TwoPaneSide.list:
      tabs.open(query);
    case TwoPaneSide.detail:
      if (scope.tab case final tab?) {
        tab.push(query);
      } else {
        tabs.open(query);
      }
  }
  return true;
}

/// The [TwoPaneLayout]s mounted, the one mounted last at the end.
final _mountedLayouts = <_TwoPaneLayoutState>[];

/// A context in the list page of the [TwoPaneLayout] in view: the one of the page on top of the app (no other page, no
/// dialog or sheet above it) in the branch shown. Null when the page on top is no such list page.
///
/// A link opened from it ([DispatchUrl.dispatchAsUrl]) goes where a link tapped in that list goes: a thread to the
/// detail pane while the panes show, a page of its own otherwise. For what is opened from outside the pages (a snack
/// bar of the root messenger).
BuildContext? twoPaneListContextInView() {
  for (final layout in _mountedLayouts.reversed) {
    if (!layout.mounted) {
      continue;
    }
    final context = layout.context;
    // An offstage branch of the home shell, another page or a dialog above it: not in view.
    if (!TickerMode.getValuesNotifier(context).value.enabled || !(ModalRoute.of(context)?.isCurrent ?? false)) {
      continue;
    }
    if (layout._listKey.currentContext case final list?) {
      return list;
    }
  }
  return null;
}

/// A list page ([list]) on the left and the thread opened from it on the right, while the window is at least
/// [twoPaneMinWidth] wide and the `twoPaneLayout` setting is on ([twoPaneEnabled]); [list] alone otherwise, as on
/// phones.
///
/// Tapping a thread in [list] shows it on the right ([openThreadInPane]); another tap replaces it. Inside the thread,
/// a link to a thread opens above it on the right, everything else (a member, a forum, the editor) opens as a page of
/// its own. The system back takes the thread on the right away first, then leaves the page. A window turning narrow
/// (rotated, resized) with a thread on the right goes on reading it as a page of its own, at the page in view
/// ([PaneThread.resolver]); while another page, a dialog or a sheet is above this one, the panes stay as they are (laid
/// out at least [twoPaneMinWidth] wide, clipped) until it is on top again, so the thread is not pushed above that page
/// and the sheet keeps its floor. A window turning wide changes the layout only, nothing moves into the pane.
///
/// The detail pane holds tabs ([TwoPaneTabs]), with a strip above the thread once there are two: Ctrl (Cmd) with a
/// click on a thread or a link, a middle click on a card, or the card's menu opens a new one behind the tab shown;
/// Ctrl+W closes the tab shown, Ctrl+Tab and Ctrl+Shift+Tab go through them, Ctrl+1 to Ctrl+9 show one. A window
/// turning narrow takes the tab shown out as a page of its own (see above), the others stay for the window turning
/// wide again.
///
/// Each pane sees a [MediaQuery] of its own width, with the side insets of its own edge only. The list pane has a
/// [ScaffoldMessenger] of its own: the app's snack bars (shown through its root messenger) appear on the detail pane
/// only, not on both.
class TwoPaneLayout extends StatefulWidget {
  /// Constructor.
  const TwoPaneLayout({required this.list, super.key});

  /// The list page.
  final Widget list;

  @override
  State<TwoPaneLayout> createState() => _TwoPaneLayoutState();
}

class _TwoPaneLayoutState extends State<TwoPaneLayout> {
  final _tabs = TwoPaneTabs();

  /// The width the divider is dragged to (0: back to the share of the window), while it is dragged and until the
  /// setting holds it; null otherwise, the setting decides.
  double? _draggedWidth;

  /// The divider is being dragged.
  bool _dragging = false;

  /// The width of the list pane when the drag started, and how far the pointer went since: the divider follows the
  /// pointer, also back from beyond a limit.
  double _dragStartWidth = 0;
  double _dragDistance = 0;

  /// The width of the list pane dragged to, saved: 0 while never dragged, or with no settings provided.
  double _savedWidth(BuildContext context) {
    if (context.readOrNull<SettingsBloc>() == null) {
      return 0;
    }
    return context.select<SettingsBloc, double>((bloc) => bloc.state.settingsMap.twoPaneListWidth);
  }

  /// Keep [width] as the width of the list pane (0: its share of the window again).
  void _save(double width) {
    setState(() => _draggedWidth = width);
    context.readOrNull<SettingsBloc>()?.add(SettingsValueChanged(SettingsKeys.twoPaneListWidth, width));
  }

  /// Keeps the state of [TwoPaneLayout.list] (its scroll positions, its tabs) when the layout changes shape.
  final GlobalKey _listKey = GlobalKey();

  /// The last build showed the list alone (the window narrow, or the setting off): the thread shown then went on as a
  /// page of its own, the other tabs wait for the window to be wide again. Set and cleared by [build] only.
  var _collapsed = false;

  @override
  void initState() {
    super.initState();
    _mountedLayouts.add(this);
  }

  @override
  void dispose() {
    _mountedLayouts.remove(this);
    _tabs.dispose();
    super.dispose();
  }

  Future<bool> _onBackPressed() async {
    // Only while this page is the one on top: the listener is not told about the pages above it.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    return _tabs.active?.pop() ?? false;
  }

  /// [child] laid out as one pane: as wide as the pane, with the side inset of its own edge only.
  Widget _pane(Widget child, {required bool left}) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      EdgeInsets inner(EdgeInsets insets) => left ? insets.copyWith(right: 0) : insets.copyWith(left: 0);
      return MediaQuery(
        data: media.copyWith(
          size: Size(constraints.maxWidth, media.size.height),
          padding: inner(media.padding),
          viewPadding: inner(media.viewPadding),
          viewInsets: inner(media.viewInsets),
        ),
        child: child,
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final list = KeyedSubtree(key: _listKey, child: widget.list);
    // Built again when this page comes on top again (the page above it closed): the layout held meanwhile changes then.
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (!twoPaneEnabled(context) && (_collapsed || _tabs.isEmpty || current)) {
      if (!_collapsed) {
        _collapsed = true;
        // Narrow now, with a thread on the right: it goes on as a page of its own, its tab closes; the other tabs stay
        // for the window turning wide again. Opened once this build is over, the pane leaves the tree in this one.
        if (_tabs._takeActive()?.top case final top?) {
          // Where the thread is read now, asked before the pane goes.
          final query = top.currentQuery;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              unawaited(context.pushNamed(ScreenPaths.threadV1, queryParameters: query));
            }
          });
        }
      }
      if (MediaQuery.sizeOf(context).width >= twoPaneMinWidth) {
        // Wide, the setting off: the panes are not to come back on their own, the tabs left go.
        _tabs._clear();
      }
      return list;
    }
    // The last build laid out the panes: the next narrow one takes the tab shown out again.
    _collapsed = false;
    final colorScheme = Theme.of(context).colorScheme;
    // Held under another page while narrow: laid out as a wide window would be, not squeezed.
    final width = math.max(MediaQuery.sizeOf(context).width, twoPaneMinWidth);
    final saved = _savedWidth(context);
    if (!_dragging && _draggedWidth == saved) {
      // The setting holds it now.
      _draggedWidth = null;
    }
    final listWidth = twoPaneListWidthFor(width, _draggedWidth ?? saved);
    return BackButtonListener(
      onBackButtonPressed: _onBackPressed,
      child: Actions(
        actions: {
          ClosePaneTabIntent: KeyboardAction<ClosePaneTabIntent>(
            () => _tabs.close(_tabs.activeIndex),
            pageRouteOnly: true,
            enabledWhen: () => !_tabs.isEmpty,
          ),
          NextPaneTabIntent: KeyboardAction<NextPaneTabIntent>(
            _tabs.selectNext,
            pageRouteOnly: true,
            enabledWhen: () => _tabs.length > 1,
          ),
          PreviousPaneTabIntent: KeyboardAction<PreviousPaneTabIntent>(
            _tabs.selectPrevious,
            pageRouteOnly: true,
            enabledWhen: () => _tabs.length > 1,
          ),
          SelectPaneTabIntent: _SelectPaneTabAction(_tabs),
        },
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: width,
            maxWidth: width,
            child: _panes(context, colorScheme, listWidth, list),
          ),
        ),
      ),
    );
  }

  Widget _panes(BuildContext context, ColorScheme colorScheme, double listWidth, Widget list) => Stack(
    children: [
      Positioned.fill(child: _row(colorScheme, listWidth, list)),
      // Below the tab strip too while it shows.
      ListenableBuilder(listenable: _tabs, builder: (context, _) => _divider(context, listWidth)),
    ],
  );

  Widget _divider(BuildContext context, double listWidth) => Positioned(
    // Below the app bars (and the tab strip of the detail pane): their buttons at the edges of the panes (the back
    // button of a thread opened above another) are not covered.
    top: MediaQuery.paddingOf(context).top + kToolbarHeight + (_tabs.length > 1 ? _TwoPaneTabStrip._height : 0),
    bottom: 0,
    left: listWidth - _TwoPaneDivider.reachIntoList,
    width: _TwoPaneDivider.reach,
    child: _TwoPaneDivider(
      onDragStart: () => setState(() {
        _dragging = true;
        _draggedWidth = listWidth;
        _dragStartWidth = listWidth;
        _dragDistance = 0;
      }),
      onDragUpdate: (dx) => setState(() {
        final width = math.max(MediaQuery.sizeOf(context).width, twoPaneMinWidth);
        _dragDistance += dx;
        _draggedWidth = twoPaneListWidthFor(width, _dragStartWidth + _dragDistance);
      }),
      onDragEnd: () {
        // A tap ends a drag that never started (cancelled): nothing moved, nothing to keep.
        if (!_dragging) {
          return;
        }
        _dragging = false;
        _save(_draggedWidth ?? listWidth);
      },
      onReset: () => _save(0),
    ),
  );

  Widget _row(ColorScheme colorScheme, double listWidth, Widget list) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: listWidth,
        child: TwoPaneScope(
          tabs: _tabs,
          side: TwoPaneSide.list,
          child: ScaffoldMessenger(child: _pane(list, left: true)),
        ),
      ),
      VerticalDivider(width: 1, thickness: 1, color: colorScheme.outlineVariant),
      Expanded(
        child: _pane(
          ListenableBuilder(
            listenable: _tabs,
            builder: (context, _) {
              final tab = _tabs.active;
              final top = tab?.top;
              // The strip only with two tabs or more: one tab is the pane as it always was.
              final strip = _tabs.length > 1;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (strip) _TwoPaneTabStrip(tabs: _tabs),
                  Expanded(
                    key: const ValueKey('detail'),
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: strip,
                      child: TwoPaneScope(
                        tabs: _tabs,
                        side: TwoPaneSide.detail,
                        tab: tab,
                        child: top == null
                            ? const TwoPaneEmptyDetail()
                            : KeyedSubtree(key: ValueKey(top.id), child: ThreadPage.fromQuery(top.query)),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          left: false,
        ),
      ),
    ],
  );
}

/// Ctrl+1 to Ctrl+9: the tab of that number.
class _SelectPaneTabAction extends KeyboardAction<SelectPaneTabIntent> {
  _SelectPaneTabAction(this.tabs) : super(_noop, pageRouteOnly: true);

  final TwoPaneTabs tabs;

  static void _noop() {}

  @override
  bool isEnabled(SelectPaneTabIntent intent) => intent.index < tabs.length && super.isEnabled(intent);

  @override
  Object? invoke(SelectPaneTabIntent intent) {
    tabs.select(intent.index);
    return null;
  }
}

/// The tabs of the detail pane, above the thread shown: a click shows one, the cross or a middle click closes it, a
/// drag moves it.
class _TwoPaneTabStrip extends StatelessWidget {
  const _TwoPaneTabStrip({required this.tabs});

  final TwoPaneTabs tabs;

  static const _height = 40.0;
  static const _tabWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainer,
      child: SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: SizedBox(
          height: _height,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            itemCount: tabs.length,
            onReorder: (from, to) => tabs.move(from, to > from ? to - 1 : to),
            itemBuilder: (context, index) {
              final tab = tabs.tabs[index];
              final item = _TwoPaneTab(
                tab: tab,
                selected: index == tabs.activeIndex,
                width: _tabWidth,
                onSelect: () => tabs.select(index),
                onClose: () => tabs.close(index),
              );
              return KeyedSubtree(
                key: ObjectKey(tab),
                child: isMobile
                    ? ReorderableDelayedDragStartListener(index: index, child: item)
                    : ReorderableDragStartListener(index: index, child: item),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TwoPaneTab extends StatefulWidget {
  const _TwoPaneTab({
    required this.tab,
    required this.selected,
    required this.width,
    required this.onSelect,
    required this.onClose,
  });

  final TwoPaneController tab;
  final bool selected;
  final double width;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_TwoPaneTab> createState() => _TwoPaneTabState();
}

class _TwoPaneTabState extends State<_TwoPaneTab> {
  /// For a tab with no thread: none is left open, the tab is closing.
  static final _noTitle = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _showWhenSelected();
  }

  @override
  void didUpdateWidget(_TwoPaneTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected) {
      _showWhenSelected();
    }
  }

  /// The tab shown scrolls into view of the strip.
  void _showWhenSelected() {
    if (!widget.selected) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.selected) {
        unawaited(Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 150)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final top = widget.tab.top;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kMiddleMouseButton) {
          widget.onClose();
        }
      },
      child: Material(
        color: widget.selected ? colorScheme.surface : Colors.transparent,
        child: InkWell(
          onTap: widget.onSelect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: widget.selected ? colorScheme.primary : Colors.transparent, width: 2),
                right: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            child: SizedBox(
              width: widget.width,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: ValueListenableBuilder<String?>(
                      valueListenable: top?.title ?? _noTitle,
                      builder: (context, title, _) => Tooltip(
                        message: title ?? '',
                        waitDuration: const Duration(milliseconds: 600),
                        child: Text(
                          title ?? '…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: widget.selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    onPressed: widget.onClose,
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the divider between the panes is grabbed: a strip over the 1px line below the app bars, reaching a little
/// into the list (its scroll bar is at its right edge) and further into the detail pane (the side room of the floors).
/// Dragged sideways it moves the line, tapped twice it puts the line back at the list's share of the window. The
/// pointer goes on to the panes below too: a scroll (the wheel, a vertical drag) or a tap started on the strip reaches
/// them.
class _TwoPaneDivider extends StatelessWidget {
  const _TwoPaneDivider({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onReset,
  });

  /// How far the strip reaches into the list pane.
  static const reachIntoList = 3.0;

  /// How wide the strip is.
  static const reach = 16.0;

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    opaque: false,
    child: GestureDetector(
      key: const ValueKey('two-pane-divider'),
      behavior: HitTestBehavior.translucent,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (_) => onDragStart(),
      onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
      onHorizontalDragEnd: (_) => onDragEnd(),
      onHorizontalDragCancel: onDragEnd,
      onDoubleTap: onReset,
    ),
  );
}

/// The detail pane with nothing opened: a faint icon on the page's background. A [Scaffold], so the app's snack bars
/// have somewhere to show while nothing is opened.
class TwoPaneEmptyDetail extends StatelessWidget {
  /// Constructor.
  const TwoPaneEmptyDetail({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ExcludeSemantics(
          child: Icon(Icons.article_outlined, size: 72, color: colorScheme.outlineVariant),
        ),
      ),
    );
  }
}

/// A middle click on [child] opens the thread of [query] (as [openThreadInPane] has it) in a new tab of the detail
/// pane; outside a two-pane layout, or with [query] null, it does nothing.
class TwoPaneMiddleClickOpener extends StatelessWidget {
  /// Constructor.
  const TwoPaneMiddleClickOpener({required this.query, required this.child, super.key});

  /// The thread to open, null when [child] has none to open now.
  final Map<String, String?>? query;

  /// The card.
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.buttons == kMiddleMouseButton && query != null) {
        openThreadInPane(context, query!, newTab: true);
      }
    },
    child: child,
  );
}
