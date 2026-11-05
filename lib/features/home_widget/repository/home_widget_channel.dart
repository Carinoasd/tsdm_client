import 'package:flutter/services.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';

/// The channel the Android home screen widget's state goes over to the native `HomeWidgetChannel`.
///
/// Android only: on every other platform [update] does nothing. A native side that does not answer (an old activity,
/// a test without one) is logged and never thrown.
final class HomeWidgetChannel with LoggerMixin {
  /// Constructor.
  ///
  /// [channel] replaces the app's channel in tests; [enabled] overrides the platform check (Android only by default).
  const HomeWidgetChannel({this.channel = const MethodChannel(name), bool? enabled}) : _enabled = enabled;

  /// The channel name, same as `HomeWidgetChannel.CHANNEL`.
  static const name = 'kzs.th000.tsdm_client/homeWidget';

  /// The method carrying the state, same as `HomeWidgetChannel.UPDATE`.
  static const updateMethod = 'update';

  /// The method channel.
  final MethodChannel channel;

  final bool? _enabled;

  /// Whether this platform has the widget.
  bool get enabled => _enabled ?? isAndroid;

  /// Tell the widget the state of the account in use: [uid] (null when no account is in use, the widget then shows no
  /// counts), the unread [notice] and [personalMessage] counts and the day it checked in ([checkedInDay], ISO date,
  /// null when not today).
  ///
  /// A null count leaves the one the widget shows as it is, when the widget shows the same account: the app has not
  /// counted yet in this run, the background service may have. For another account the widget shows a dash until
  /// counted. The widget compares [checkedInDay] with the day it draws on, so the check-in is over at midnight by
  /// itself.
  Future<void> update({
    required int? uid,
    required int? notice,
    required int? personalMessage,
    required String? checkedInDay,
  }) async {
    if (!enabled) {
      return;
    }
    try {
      await channel.invokeMethod<bool>(updateMethod, {
        'uid': uid,
        'notice': notice,
        'personalMessage': personalMessage,
        'checkedInDay': checkedInDay,
      });
    } on MissingPluginException {
      // No native side on this engine.
    } on PlatformException catch (e, st) {
      error('failed to update the home screen widget: $e', e, st);
    }
  }

  /// No account in use: no counts, not checked in.
  Future<void> clear() => update(uid: null, notice: 0, personalMessage: 0, checkedInDay: null);
}
