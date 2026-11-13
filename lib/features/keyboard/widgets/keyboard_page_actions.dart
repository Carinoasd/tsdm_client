import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_intents.dart';
import 'package:tsdm_client/features/keyboard/utils/hardware_keyboard_presence.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';

/// Lets a page answer the keys of [KeyboardShortcutsHost]: every callback given is the page's own reaction to the
/// matching key; the keys with no callback are left alone.
///
/// The plain keys (J, K, N, P, R, Enter, Home, End) do nothing while a text input has the focus. The page takes the
/// focus when it is built, so the keys work before anything was clicked.
///
/// Only the page in view answers: a page behind another keeps the focus out of its subtree. Where the page is a tab
/// kept alive off screen, [active] tells whether the tab is the one shown.
///
/// On iOS and Android the page neither takes the focus nor answers a key until a hardware keyboard is in use
/// ([HardwareKeyboardPresence]): a tap on a phone's page never moves the focus away from its text field. When the
/// keyboard turns up the page keeps its state (its child is kept by a global key) and takes the focus; when it goes
/// (Android tells it) the page is as before, its state kept too.
class KeyboardPageActions extends StatefulWidget {
  /// Constructor.
  const KeyboardPageActions({
    required this.child,
    this.active = true,
    this.onRefresh,
    this.onNextItem,
    this.onPreviousItem,
    this.onOpenItem,
    this.canOpenItem,
    this.onNextPage,
    this.onPreviousPage,
    this.onReply,
    this.onScrollToStart,
    this.onScrollToEnd,
    this.onCopyLink,
    super.key,
  });

  /// The page.
  final Widget child;

  /// Whether the page is the one in view.
  final bool active;

  /// Reload (F5, Ctrl+R).
  final VoidCallback? onRefresh;

  /// J.
  final VoidCallback? onNextItem;

  /// K.
  final VoidCallback? onPreviousItem;

  /// Enter.
  final VoidCallback? onOpenItem;

  /// Whether Enter has an item to open: else it is left to the focused button.
  final bool Function()? canOpenItem;

  /// N.
  final VoidCallback? onNextPage;

  /// P.
  final VoidCallback? onPreviousPage;

  /// R.
  final VoidCallback? onReply;

  /// Home.
  final VoidCallback? onScrollToStart;

  /// End.
  final VoidCallback? onScrollToEnd;

  /// Ctrl+Shift+C.
  final VoidCallback? onCopyLink;

  @override
  State<KeyboardPageActions> createState() => _KeyboardPageActionsState();
}

class _KeyboardPageActionsState extends State<KeyboardPageActions> {
  /// The scope of the page, so a text input giving the focus up (a click outside it) leaves it on the page, below its
  /// actions, rather than on the route above them.
  final _scopeNode = FocusScopeNode(debugLabel: 'KeyboardPageActions');

  /// Keeps the state of the page when the actions are put around it.
  final GlobalKey _childKey = GlobalKey(debugLabel: 'KeyboardPageActions.child');

  @override
  void initState() {
    super.initState();
    HardwareKeyboardPresence.seen.addListener(_onKeyboardSeen);
    _takeFocusWhenFree();
  }

  /// The keyboard came (the actions go around the page, which takes the focus) or went (Android: they go away again,
  /// the page keeps its state either way).
  void _onKeyboardSeen() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (HardwareKeyboardPresence.seen.value) {
      _takeFocusWhenFree();
    }
  }

  @override
  void didUpdateWidget(KeyboardPageActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // The tab came to the front: the focus of the tab that was in front is not to keep the keys.
      _takeFocusWhenFree(force: true);
    }
  }

  @override
  void dispose() {
    HardwareKeyboardPresence.seen.removeListener(_onKeyboardSeen);
    _scopeNode.dispose();
    super.dispose();
  }

  /// Whether nothing in the route holds the focus, or the route has it for itself (two pages side by side then both
  /// ask for it, the one built last gets it).
  bool _focusIsFree() {
    final scope = FocusScope.of(context);
    return scope.focusedChild == null || FocusManager.instance.primaryFocus == scope;
  }

  /// Takes the focus once the page is built, unless something inside the route has it (a text field focusing itself
  /// at once, the search box) or the page is not the one in view; [force] takes it from whatever has it.
  void _takeFocusWhenFree({bool force = false}) {
    if (!widget.active || !keyboardShortcutsEnabled) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // After the other post frame callbacks of the frame: a text field gives itself the focus in one.
      scheduleMicrotask(() {
        if (!mounted || !widget.active || (!force && !_focusIsFree())) {
          return;
        }
        _scopeNode.requestFocus();
      });
    });
  }

  /// Enter opens the item moved to only while the focus is on the page itself: a focused button keeps its Enter.
  bool _canOpenItem() => FocusManager.instance.primaryFocus == _scopeNode && (widget.canOpenItem?.call() ?? true);

  /// A click on the page puts the keys on it, when they are not on it already: two pages side by side (a list and the
  /// thread beside it) follow the mouse.
  void _onPointerDown(PointerDownEvent event) {
    // After the text input beside gave its focus up: its tap region runs after this listener, and would hand the focus
    // back to the page it is in.
    scheduleMicrotask(() {
      if (mounted && !_scopeNode.hasFocus) {
        _scopeNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (!keyboardShortcutsEnabled) {
      return child;
    }
    final onRefresh = widget.onRefresh;
    final onCopyLink = widget.onCopyLink;
    final onNextItem = widget.onNextItem;
    final onPreviousItem = widget.onPreviousItem;
    final onOpenItem = widget.onOpenItem;
    final onNextPage = widget.onNextPage;
    final onPreviousPage = widget.onPreviousPage;
    final onReply = widget.onReply;
    final onScrollToStart = widget.onScrollToStart;
    final onScrollToEnd = widget.onScrollToEnd;
    return Actions(
      actions: {
        if (onRefresh != null) RefreshPageIntent: KeyboardAction<RefreshPageIntent>(onRefresh),
        if (onCopyLink != null) CopyPageLinkIntent: KeyboardAction<CopyPageLinkIntent>(onCopyLink),
        if (onNextItem != null) NextItemIntent: KeyboardAction<NextItemIntent>(onNextItem, singleKey: true),
        if (onPreviousItem != null)
          PreviousItemIntent: KeyboardAction<PreviousItemIntent>(onPreviousItem, singleKey: true),
        if (onOpenItem != null)
          OpenItemIntent: KeyboardAction<OpenItemIntent>(
            onOpenItem,
            singleKey: true,
            enabledWhen: _canOpenItem,
          ),
        if (onNextPage != null) NextPageIntent: KeyboardAction<NextPageIntent>(onNextPage, singleKey: true),
        if (onPreviousPage != null)
          PreviousPageIntent: KeyboardAction<PreviousPageIntent>(onPreviousPage, singleKey: true),
        if (onReply != null) StartReplyIntent: KeyboardAction<StartReplyIntent>(onReply, singleKey: true),
        if (onScrollToStart != null)
          ScrollToStartIntent: KeyboardAction<ScrollToStartIntent>(onScrollToStart, singleKey: true),
        if (onScrollToEnd != null) ScrollToEndIntent: KeyboardAction<ScrollToEndIntent>(onScrollToEnd, singleKey: true),
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        child: FocusScope(node: _scopeNode, child: child),
      ),
    );
  }
}
