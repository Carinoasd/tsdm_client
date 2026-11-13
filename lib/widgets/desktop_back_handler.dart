import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/keyboard/utils/hardware_keyboard_presence.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';

/// Lets desktop users go back with the keyboard and the mouse (GitHub #138).
///
/// On Windows, macOS and Linux, `Esc` and the mouse "back" side button pop the page the focus is in, exactly like
/// the back button in its app bar. Nothing happens when that page is the first of its navigator (the homepage
/// tabs), so the app is never closed by accident.
///
/// Sitting between the app's shortcuts and the navigator, this widget sees `Esc` before the app does, so it steps
/// aside whenever somebody closer to the focus owns the key:
///
/// * A dialog, popup menu or modal bottom sheet is not a page route: the key goes on to the route's own dismiss
///   action, which closes it when its barrier is dismissible.
/// * A focused text input keeps the key: the text editing shortcuts of the app stop it, and editors implementing
///   [TextInputClient] (the BBCode editor) are skipped here too, so typing in the search box or the editor never
///   leaves the page.
///
/// A persistent bottom sheet (the expanded reply editor) is a local history entry of its page, so the pop closes
/// the sheet first and the page only on the next press. Pages refusing to pop (an unsaved draft asking first) keep
/// deciding through their `PopScope`.
///
/// On iOS `Esc` does the same once a hardware keyboard is seen (`keyboardShortcutsEnabled`), the mouse button from the
/// start; on Android `Esc` while a hardware keyboard is in use, the mouse button being the system's back already. The
/// widget is there from the start so the tree below does not change when the keyboard turns up.
///
/// On other platforms this widget only builds [child].
class DesktopBackHandler extends StatelessWidget {
  /// Constructor.
  const DesktopBackHandler({required this.child, super.key});

  /// The app content, usually the navigator.
  final Widget child;

  /// Whether the handler is active, overridable in tests.
  @visibleForTesting
  static bool? enabledOverride;

  static bool get _built =>
      enabledOverride ?? (HardwareKeyboardPresence.desktopPlatform || HardwareKeyboardPresence.touchPlatform);

  static bool get _keysEnabled => enabledOverride ?? keyboardShortcutsEnabled;

  /// Pops the page holding the primary focus, when it is a page route that can be popped.
  ///
  /// Returns whether a pop was attempted.
  @visibleForTesting
  static bool goBack() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null || !focusContext.mounted) {
      return false;
    }
    if (isInTextInput(focusContext)) {
      return false;
    }
    final route = ModalRoute.of(focusContext);
    if (route is! PageRoute || !route.isCurrent) {
      return false;
    }
    if (route.isFirst && !route.willHandlePopInternally) {
      // The root of a navigator: a pop attempt here would trigger the exit-app `PopScope` of the shell pages.
      return false;
    }
    final navigator = route.navigator;
    if (navigator == null) {
      return false;
    }
    // `maybePop` respects `PopScope` of the page and pops local history entries (a persistent bottom sheet) first.
    unawaited(navigator.maybePop());
    return true;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse && event.buttons & kBackMouseButton != 0) {
      goBack();
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_keysEnabled || event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    return goBack() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!_built) {
      return child;
    }
    final keys = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: child,
    );
    // Android turns the mouse's back button into its own back key, which pops the page already: a second pop here
    // would leave two pages.
    if (HardwareKeyboardPresence.toldBySystem) {
      return keys;
    }
    return Listener(onPointerDown: _onPointerDown, child: keys);
  }
}
