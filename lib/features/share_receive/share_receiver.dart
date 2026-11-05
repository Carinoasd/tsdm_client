import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/share_receive/models/shared_content.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Receives what other apps share to this one from the Android side (`MainActivity`, `ShareIntents.kt`).
///
/// A share the app was launched with is asked for once ([start]: `getInitialShare`); a share arriving while the app
/// runs is pushed (`onShare`). Each one goes to [onShare], one at a time in the order they arrived.
final class ShareReceiver with LoggerMixin {
  /// Constructor; [channel] replaces the platform channel in tests.
  ShareReceiver({required this.onShare, @visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The channel the Android side serves.
  static const channelName = 'kzs.th000.tsdm_client/shareReceive';

  /// Called with every share received.
  final Future<void> Function(SharedContent content) onShare;

  final MethodChannel _channel;

  /// The share being handled, so the next waits for it (two shares in a row open their pages in order).
  Future<void> _handling = Future<void>.value();

  /// Take the share the app was launched with, if any, and listen for shares arriving while the app runs; one pushed
  /// while the launch share is still being asked for waits for it.
  Future<void> start() async {
    _handling = _initial();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        _take(call.arguments);
      }
      return null;
    });
    await _handling;
  }

  Future<void> _initial() async {
    try {
      final content = SharedContent.fromChannel(await _channel.invokeMethod<Object?>('getInitialShare'));
      if (content != null) {
        await _share(content);
      }
    } on MissingPluginException {
      // Not served here (a build without the Android side).
    } on PlatformException catch (e, st) {
      handleRaw(e, st);
    }
  }

  void _take(Object? arguments) {
    final content = SharedContent.fromChannel(arguments);
    if (content == null) {
      return;
    }
    _handling = _handling.then((_) => _share(content));
  }

  Future<void> _share(SharedContent content) async {
    info('share received: text ${content.text != null}, images ${content.imagePaths.length}');
    try {
      await onShare(content);
    } on Object catch (e, st) {
      handleRaw(e, st);
    }
  }

  /// Stop listening.
  void dispose() => _channel.setMethodCallHandler(null);
}
