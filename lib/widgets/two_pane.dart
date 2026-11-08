import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Windows at least this wide (Material's "expanded" class) show a list page and the thread opened from it side by
/// side, see [TwoPaneLayout].
const twoPaneMinWidth = 840.0;

/// The list pane takes this share of the window...
const twoPaneListFraction = 0.4;

/// ...kept at least this wide...
const twoPaneListMinWidth = 360.0;

/// ...and at most this wide, until the divider between the panes is dragged ([twoPaneListWidthFor]).
const twoPaneListMaxWidth = 480.0;

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
  PaneThread._(this.id, this.query);

  /// Tells the threads opened apart, so the same thread opened again starts over.
  final int id;

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
class TwoPaneController extends ChangeNotifier {
  final _threads = <PaneThread>[];
  var _nextId = 0;

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
      ..add(PaneThread._(_nextId++, query));
    notifyListeners();
  }

  /// Show [query] above what the pane holds.
  void push(Map<String, String> query) {
    _threads.add(PaneThread._(_nextId++, query));
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

  /// Empty the pane without telling the listeners: for the pane being taken out of the tree in the same build.
  void _reset() => _threads.clear();
}

/// Which pane a widget is built in.
enum TwoPaneSide {
  /// The list on the left.
  list,

  /// The thread on the right.
  detail,
}

/// Tells the widgets of a pane which pane they are in and gives them the [TwoPaneController]; they rebuild when the
/// threads of the pane change.
class TwoPaneScope extends InheritedNotifier<TwoPaneController> {
  /// Constructor.
  const TwoPaneScope({required TwoPaneController controller, required this.side, required super.child, super.key})
    : super(notifier: controller);

  /// The pane [child] is in.
  final TwoPaneSide side;

  /// The controller of the panes.
  TwoPaneController get controller => notifier!;

  /// The scope of the pane [context] is in, null outside a two-pane layout (a page on its own, a narrow window).
  ///
  /// For a build: the caller is built again when the threads of the pane change. Event handlers use [readOf].
  static TwoPaneScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TwoPaneScope>();

  /// [maybeOf] without depending on the scope, for event handlers (a tap, a link opened).
  static TwoPaneScope? readOf(BuildContext context) => context.getInheritedWidgetOfExactType<TwoPaneScope>();

  /// The controller of the panes when [context] is in the detail pane, null elsewhere.
  static TwoPaneController? detailOf(BuildContext context) {
    final scope = maybeOf(context);
    return scope?.side == TwoPaneSide.detail ? scope!.controller : null;
  }
}

/// Open the thread of [queryParameters] (the query of [ScreenPaths.threadV1]) in the detail pane of the layout
/// [context] is in: from the list it replaces what the pane shows, from the detail pane it goes on top. False when
/// [context] is not in a two-pane layout, the caller then opens the thread as a page of its own.
bool openThreadInPane(BuildContext context, Map<String, String?> queryParameters) {
  final scope = TwoPaneScope.readOf(context);
  if (scope == null) {
    return false;
  }
  final query = {
    for (final MapEntry(:key, :value) in queryParameters.entries) key: ?value,
  };
  switch (scope.side) {
    case TwoPaneSide.list:
      scope.controller.open(query);
    case TwoPaneSide.detail:
      scope.controller.push(query);
  }
  return true;
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
  final _controller = TwoPaneController();

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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<bool> _onBackPressed() async {
    // Only while this page is the one on top: the listener is not told about the pages above it.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    return _controller.pop();
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
    final top = _controller.top;
    // Built again when this page comes on top again (the page above it closed): the layout held meanwhile changes then.
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (!twoPaneEnabled(context) && (top == null || current)) {
      if (top != null) {
        // Narrow now, with a thread on the right: it goes on as a page of its own. Opened once this build is over,
        // the pane leaves the tree in this one.
        _controller._reset();
        // Where the thread is read now, asked before the pane goes.
        final query = top.currentQuery;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(context.pushNamed(ScreenPaths.threadV1, queryParameters: query));
          }
        });
      }
      return list;
    }
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
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: width,
          maxWidth: width,
          child: _panes(context, colorScheme, listWidth, list),
        ),
      ),
    );
  }

  Widget _panes(BuildContext context, ColorScheme colorScheme, double listWidth, Widget list) => Stack(
    children: [
      Positioned.fill(child: _row(colorScheme, listWidth, list)),
      Positioned(
        // Below the app bars: their buttons at the edges of the panes (the back button of a thread opened above
        // another) are not covered.
        top: MediaQuery.paddingOf(context).top + kToolbarHeight,
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
      ),
    ],
  );

  Widget _row(ColorScheme colorScheme, double listWidth, Widget list) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: listWidth,
        child: TwoPaneScope(
          controller: _controller,
          side: TwoPaneSide.list,
          child: ScaffoldMessenger(child: _pane(list, left: true)),
        ),
      ),
      VerticalDivider(width: 1, thickness: 1, color: colorScheme.outlineVariant),
      Expanded(
        child: TwoPaneScope(
          controller: _controller,
          side: TwoPaneSide.detail,
          child: _pane(
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final top = _controller.top;
                if (top == null) {
                  return const TwoPaneEmptyDetail();
                }
                return KeyedSubtree(key: ValueKey(top.id), child: ThreadPage.fromQuery(top.query));
              },
            ),
            left: false,
          ),
        ),
      ),
    ],
  );
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
