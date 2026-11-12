import 'package:flutter/services.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The channel the native `ShortcutsHandler` (Android) hands the shortcut ids over, or `HomeWidgetBridge` (iOS) the
/// links of the widget's taps and of the icon's quick actions.
///
/// A cold start asks for the shortcut the activity was started with ([initial]); a shortcut tapped while the app runs
/// is pushed to [listen]'s callback.
final class AppShortcutsChannel with LoggerMixin {
  /// Constructor, [channel] replaces the app's channel in tests.
  const AppShortcutsChannel([this.channel = const MethodChannel(name)]);

  /// The channel name, same as `ShortcutsHandler.CHANNEL`.
  static const name = 'kzs.th000.tsdm_client/shortcuts';

  /// The method asking for the shortcut of a cold start, same as `ShortcutsHandler.GET_INITIAL_SHORTCUT`.
  static const getInitialShortcut = 'getInitialShortcut';

  /// The method telling a shortcut tapped while the app runs, same as `ShortcutsHandler.ON_SHORTCUT`.
  static const onShortcut = 'onShortcut';

  /// The method channel.
  final MethodChannel channel;

  /// The shortcut the app was started with, null when it was started otherwise (or the platform has no shortcuts).
  ///
  /// Asked once: the native side forgets it when told.
  Future<AppShortcut?> initial() async {
    final String? id;
    try {
      id = await channel.invokeMethod<String>(getInitialShortcut);
    } on PlatformException catch (e, st) {
      error('failed to ask for the initial app shortcut: $e', e, st);
      return null;
    } on MissingPluginException {
      return null;
    }
    return _parse(id);
  }

  /// Hand every shortcut tapped while the app runs to [onTapped].
  void listen(void Function(AppShortcut shortcut) onTapped) {
    channel.setMethodCallHandler((call) async {
      if (call.method != onShortcut) {
        throw MissingPluginException('${call.method} is not a method of $name');
      }
      final shortcut = _parse(call.arguments as String?);
      if (shortcut != null) {
        onTapped(shortcut);
      }
    });
  }

  /// Stop listening.
  void dispose() => channel.setMethodCallHandler(null);

  AppShortcut? _parse(String? id) {
    if (id == null) {
      return null;
    }
    final shortcut = AppShortcut.fromIdOrLink(id);
    if (shortcut == null) {
      warning('unknown app shortcut "$id"');
    }
    return shortcut;
  }
}
