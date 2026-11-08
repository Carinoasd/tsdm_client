import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_intents.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether the keyboard shortcuts are in use: on Windows, macOS and Linux only, overridable in tests.
bool get keyboardShortcutsEnabled => KeyboardShortcutsHost.enabledOverride ?? isDesktop;

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

/// Keys of the whole app on Windows, macOS and Linux: the ones that open a page, and the table binding every key to
/// the intents the pages answer (`KeyboardPageActions`).
///
/// Sitting between the app's own shortcuts and the navigator, the table is seen by the focus first; a key whose
/// intent no page around the focus answers goes on untouched.
///
/// On other platforms this widget only builds [child].
class KeyboardShortcutsHost extends StatelessWidget {
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
  };

  @override
  Widget build(BuildContext context) {
    if (!keyboardShortcutsEnabled) {
      return child;
    }
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {
          if (onQuickOpen != null)
            OpenQuickOpenIntent: KeyboardAction<OpenQuickOpenIntent>(onQuickOpen!, pageRouteOnly: true),
          OpenSearchIntent: KeyboardAction<OpenSearchIntent>(onSearch, pageRouteOnly: true),
          OpenSettingsIntent: KeyboardAction<OpenSettingsIntent>(onSettings, pageRouteOnly: true),
        },
        child: child,
      ),
    );
  }
}
