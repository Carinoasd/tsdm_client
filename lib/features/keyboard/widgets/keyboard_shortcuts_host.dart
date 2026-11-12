import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_intents.dart';
import 'package:tsdm_client/features/keyboard/utils/hardware_keyboard_presence.dart';

/// Whether the keyboard shortcuts are in use: on Windows, macOS and Linux, and on iOS once a hardware keyboard is seen
/// ([HardwareKeyboardPresence]); overridable in tests.
bool get keyboardShortcutsEnabled =>
    KeyboardShortcutsHost.enabledOverride ??
    (HardwareKeyboardPresence.desktopPlatform ||
        (HardwareKeyboardPresence.touchPlatform && HardwareKeyboardPresence.seen.value));

/// Whether the widgets answering the keys are built: wherever the shortcuts are or may come in use.
///
/// Fixed for the platform, so the widget tree does not change when a hardware keyboard turns up: the pages below keep
/// their state, the focused text field its focus. Until then the actions are off ([keyboardShortcutsEnabled]) and the
/// keys go on as without them (and an iPhone without a keyboard has no key events at all).
bool get keyboardShortcutsBuilt =>
    KeyboardShortcutsHost.enabledOverride ??
    (HardwareKeyboardPresence.desktopPlatform || HardwareKeyboardPresence.touchPlatform);

/// Whether [context] is inside a text input: an [EditableText] (text fields) or any other editor that talks to the
/// platform text input (the BBCode editor).
bool isInTextInput(BuildContext context) {
  var found = false;
  context.visitAncestorElements((element) {
    if (element is StatefulElement && element.state is TextInputClient) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Action run by a shortcut key.
///
/// It is disabled, so the key goes on to whoever is next in line, when:
///
/// * The shortcuts are off ([keyboardShortcutsEnabled]).
/// * [singleKey] is set and a text input has the focus: typing "j" in the search box is typing.
/// * [enabledWhen] says no (Enter with nothing selected stays the Enter of the focused button).
/// * [pageRouteOnly] is set and the focus is not in the page on top (a dialog or a sheet is above it).
class KeyboardAction<T extends Intent> extends Action<T> {
  /// Constructor.
  KeyboardAction(this.callback, {this.singleKey = false, this.pageRouteOnly = false, this.enabledWhen});

  /// What the key does.
  final VoidCallback callback;

  /// The key is a plain key (no modifier): it is left to the text input that has the focus.
  final bool singleKey;

  /// The key works only while a page is on top.
  final bool pageRouteOnly;

  /// Extra condition for the key to be taken, null when it always is.
  final bool Function()? enabledWhen;

  @override
  bool isEnabled(T intent) {
    if (!keyboardShortcutsEnabled || (enabledWhen != null && !enabledWhen!())) {
      return false;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null || !focusContext.mounted) {
      return false;
    }
    if (singleKey && isInTextInput(focusContext)) {
      return false;
    }
    if (pageRouteOnly) {
      final route = ModalRoute.of(focusContext);
      if (route is! PageRoute || !route.isCurrent) {
        return false;
      }
    }
    return true;
  }

  @override
  Object? invoke(T intent) {
    callback();
    return null;
  }
}

/// Keys of the whole app on Windows, macOS and Linux, and on iOS with a hardware keyboard: the ones that open a page, and the table binding every key to
/// the intents the pages answer (`KeyboardPageActions`).
///
/// Sitting between the app's own shortcuts and the navigator, the table is seen by the focus first; a key whose
/// intent no page around the focus answers goes on untouched.
///
/// On iOS it starts watching for a hardware keyboard ([HardwareKeyboardPresence.watch]). The primary modifier is Ctrl
/// or Cmd on every platform, as on macOS; none of the keys is one iPadOS keeps for itself (Cmd+H, Cmd+Space, Cmd+Tab,
/// Cmd+Shift+3/4/5).
///
/// On other platforms this widget only builds [child].
class KeyboardShortcutsHost extends StatefulWidget {
  /// Constructor.
  const KeyboardShortcutsHost({
    required this.child,
    required this.onSearch,
    required this.onSettings,
    this.onQuickOpen,
    super.key,
  });

  /// The app content, usually the navigator.
  final Widget child;

  /// Opens the search page.
  final VoidCallback onSearch;

  /// Opens the settings page.
  final VoidCallback onSettings;

  /// Opens the quick open box, null for no such key.
  final VoidCallback? onQuickOpen;

  /// Whether the shortcuts are active, overridable in tests.
  @visibleForTesting
  static bool? enabledOverride;

  /// Both Ctrl and Cmd do the job of the primary modifier whatever the platform.
  static Map<ShortcutActivator, Intent> _withPrimary(LogicalKeyboardKey key, Intent intent, {bool shift = false}) => {
    SingleActivator(key, control: true, shift: shift): intent,
    SingleActivator(key, meta: true, shift: shift): intent,
  };

  /// The keys and the intents they send.
  static final Map<ShortcutActivator, Intent> shortcuts = {
    ..._withPrimary(LogicalKeyboardKey.keyF, const OpenSearchIntent()),
    ..._withPrimary(LogicalKeyboardKey.keyK, const OpenQuickOpenIntent()),
    ..._withPrimary(LogicalKeyboardKey.comma, const OpenSettingsIntent()),
    const SingleActivator(LogicalKeyboardKey.f5): const RefreshPageIntent(),
    ..._withPrimary(LogicalKeyboardKey.keyR, const RefreshPageIntent()),
    ..._withPrimary(LogicalKeyboardKey.keyC, const CopyPageLinkIntent(), shift: true),
    const SingleActivator(LogicalKeyboardKey.keyJ): const NextItemIntent(),
    const SingleActivator(LogicalKeyboardKey.keyK): const PreviousItemIntent(),
    const SingleActivator(LogicalKeyboardKey.keyN): const NextPageIntent(),
    const SingleActivator(LogicalKeyboardKey.keyP): const PreviousPageIntent(),
    const SingleActivator(LogicalKeyboardKey.keyR): const StartReplyIntent(),
    const SingleActivator(LogicalKeyboardKey.enter): const OpenItemIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter): const OpenItemIntent(),
    const SingleActivator(LogicalKeyboardKey.home): const ScrollToStartIntent(),
    const SingleActivator(LogicalKeyboardKey.end): const ScrollToEndIntent(),
    ..._withPrimary(LogicalKeyboardKey.keyW, const ClosePaneTabIntent()),
    // Control on every platform: Cmd+Tab switches the apps of macOS.
    const SingleActivator(LogicalKeyboardKey.tab, control: true): const NextPaneTabIntent(),
    const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): const PreviousPaneTabIntent(),
    for (final (index, key) in _digits.indexed) ..._withPrimary(key, SelectPaneTabIntent(index)),
  };

  @override
  State<KeyboardShortcutsHost> createState() => _KeyboardShortcutsHostState();

  /// The keys 1 to 9, for the tabs of the detail pane.
  static const List<LogicalKeyboardKey> _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
}

class _KeyboardShortcutsHostState extends State<KeyboardShortcutsHost> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboardPresence.watch();
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    if (!keyboardShortcutsBuilt) {
      return widget.child;
    }
    final onQuickOpen = widget.onQuickOpen;
    return Shortcuts(
      shortcuts: KeyboardShortcutsHost.shortcuts,
      child: Actions(
        actions: {
          if (onQuickOpen != null)
            OpenQuickOpenIntent: KeyboardAction<OpenQuickOpenIntent>(onQuickOpen, pageRouteOnly: true),
          OpenSearchIntent: KeyboardAction<OpenSearchIntent>(widget.onSearch, pageRouteOnly: true),
          OpenSettingsIntent: KeyboardAction<OpenSettingsIntent>(widget.onSettings, pageRouteOnly: true),
        },
        child: widget.child,
      ),
    );
  }
}
