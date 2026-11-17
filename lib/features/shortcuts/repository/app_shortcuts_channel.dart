import 'package:flutter/services.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What came of asking the launcher to pin a shortcut ([AppShortcutsChannel.requestPin]).
enum PinShortcutResult {
  /// The launcher was asked: it asks the user (or pins on its own).
  requested,

  /// The shortcut was pinned already: its label was updated, nothing new was pinned.
  updated,

  /// Not asked: the launcher does not pin shortcuts, or the system refused.
  failed,
}

/// The channel the native `ShortcutsHandler` (Android) hands the shortcut ids over, or `HomeWidgetBridge` (iOS) the
/// links of the widget's taps and of the icon's quick actions.
///
/// A cold start asks for the shortcut the activity was started with ([initial]); a shortcut tapped while the app runs
/// is pushed to [listen]'s callback. On Android it also pins a forum or a thread to the home screen ([requestPin]).
final class AppShortcutsChannel with LoggerMixin {
  /// Constructor, [channel] replaces the app's channel in tests.
  const AppShortcutsChannel([this.channel = const MethodChannel(name)]);

  /// The channel name, same as `ShortcutsHandler.CHANNEL`.
  static const name = 'kzs.th000.tsdm_client/shortcuts';

  /// The method asking for the shortcut of a cold start, same as `ShortcutsHandler.GET_INITIAL_SHORTCUT`.
  static const getInitialShortcut = 'getInitialShortcut';

  /// The method telling a shortcut tapped while the app runs, same as `ShortcutsHandler.ON_SHORTCUT`.
  static const onShortcut = 'onShortcut';

  /// The method asking whether the launcher pins shortcuts, same as `PinnedShortcuts.IS_SUPPORTED`.
  static const isPinShortcutSupported = 'isPinShortcutSupported';

  /// The method asking the launcher to pin a shortcut, same as `PinnedShortcuts.REQUEST`.
  static const requestPinShortcut = 'requestPinShortcut';

  /// The method channel.
  final MethodChannel channel;

  /// The shortcut of the app icon the app was started with, null when it was started otherwise (or the platform has no
  /// shortcuts).
  ///
  /// Asked once: the native side forgets it when told.
  Future<AppShortcut?> initial() async => switch ((await initialRequest())?.shortcut) {
    final AppShortcut shortcut => shortcut,
    _ => null,
  };

  /// The shortcut the app was started with, of the app icon or pinned, with where it came from
  /// ([ShortcutTarget.requestOf]).
  Future<AppShortcutRequest?> initialRequest() async {
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

  /// Hand every shortcut of the app icon tapped while the app runs to [onTapped].
  void listen(void Function(AppShortcut shortcut) onTapped) => listenRequests((e) {
    if (e.shortcut case final AppShortcut shortcut) {
      onTapped(shortcut);
    }
  });

  /// Hand every shortcut tapped while the app runs, of the app icon or pinned, to [onTapped] with where it came from
  /// ([ShortcutTarget.requestOf]).
  void listenRequests(void Function(AppShortcutRequest request) onTapped) {
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

  /// Whether the launcher pins shortcuts (Android 8 or later): false when it does not, and where the native side does
  /// not answer.
  Future<bool> pinSupported() async {
    try {
      return await channel.invokeMethod<bool>(isPinShortcutSupported) ?? false;
    } on PlatformException catch (e, st) {
      error('failed to ask whether shortcuts can be pinned: $e', e, st);
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Ask the launcher to pin [shortcut] to the home screen, labelled [shortLabel] under its icon and [longLabel] where
  /// there is room.
  Future<PinShortcutResult> requestPin(
    PinnedShortcut shortcut, {
    required String shortLabel,
    required String longLabel,
  }) async {
    final String? answer;
    try {
      answer = await channel.invokeMethod<String>(requestPinShortcut, {
        'id': shortcut.id,
        'shortLabel': shortLabel,
        'longLabel': longLabel,
      });
    } on PlatformException catch (e, st) {
      error('failed to pin shortcut ${shortcut.id}: $e', e, st);
      return PinShortcutResult.failed;
    } on MissingPluginException {
      return PinShortcutResult.failed;
    }
    final result = PinShortcutResult.values.firstWhere((e) => e.name == answer, orElse: () => PinShortcutResult.failed);
    info('pin shortcut ${shortcut.id}: ${result.name}');
    return result;
  }

  AppShortcutRequest? _parse(String? id) {
    if (id == null) {
      return null;
    }
    final shortcut = ShortcutTarget.requestOf(id);
    if (shortcut == null) {
      warning('unknown app shortcut "$id"');
    }
    return shortcut;
  }
}
