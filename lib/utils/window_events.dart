import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Window size diagnostics for the "layout keeps the old window size" reports on Android (GitHub #28).
///
/// The Android side reports the sizes the system hands to the activity (configuration, multi-window mode, the
/// `FlutterView` layout and its render surface); the Dart side logs the metrics the framework works with. Reading
/// both in one exported log tells which layer stopped following a resize: the system, the view, the engine, or
/// the framework.
const _windowChannel = MethodChannel('kzs.th000.tsdm_client/windowChannel');

/// Log every window event the Android activity reports. No-op on other platforms.
void listenAndroidWindowEvents() {
  if (!isAndroid) {
    return;
  }
  _windowChannel.setMethodCallHandler((call) async => talker.debug(formatWindowEvent(call.method, call.arguments)));
}

/// One log line for the window event [name] with the [arguments] sent by the Android side.
String formatWindowEvent(String name, Object? arguments) {
  final args = arguments is Map ? Map<String, Object?>.from(arguments) : <String, Object?>{};
  String size(String width, String height) => args[width] == null ? '?' : '${args[width]}x${args[height]}';
  final parts = <String>[
    switch (name) {
      'flutterViewLayout' => 'flutter view ${size('width', 'height')} visibility=${args['visibility']}',
      'surfaceChanged' => 'surface ${size('width', 'height')}',
      'configurationChanged' || 'multiWindowModeChanged' || 'pictureInPictureModeChanged' =>
        'screen ${size('screenWidthDp', 'screenHeightDp')}dp orientation=${args['orientation']} '
            'density=${args['densityDpi']}',
      _ => '',
    },
    if (args['multiWindow'] != null) 'multiWindow=${args['multiWindow']}',
    if (args['pictureInPicture'] != null) 'pip=${args['pictureInPicture']}',
    'window ${size('decorWidth', 'decorHeight')} display ${size('displayWidth', 'displayHeight')}',
  ];
  return 'window event: $name ${parts.where((e) => e.isNotEmpty).join(' ')}';
}

/// One log line with the metrics the framework lays out with: the physical size and pixel ratio of [view], the
/// logical size that follows, the keyboard inset and the system paddings.
String describeViewMetrics(FlutterView view) {
  final size = view.physicalSize;
  final dpr = view.devicePixelRatio;
  String logical(double v) => (v / dpr).toStringAsFixed(1);
  return 'view metrics: physical ${size.width.round()}x${size.height.round()} dpr=$dpr '
      'logical ${logical(size.width)}x${logical(size.height)} '
      'keyboard=${logical(view.viewInsets.bottom)} padding(t/b)=${logical(view.padding.top)}/${logical(view.padding.bottom)}';
}

/// Decides which metrics changes are worth a log line: every size, pixel ratio or padding change, and the keyboard
/// appearing or disappearing, but not every step of the keyboard animation.
final class ViewMetricsLogGate {
  Size? _size;
  double? _dpr;
  ViewPadding? _padding;
  bool? _keyboardShown;

  /// Whether the current metrics of [view] differ from the last accepted ones; remembers them when they do.
  bool accept(FlutterView view) {
    final keyboardShown = view.viewInsets.bottom > 0;
    final changed =
        view.physicalSize != _size ||
        view.devicePixelRatio != _dpr ||
        !_samePadding(view.padding, _padding) ||
        keyboardShown != _keyboardShown;
    if (changed) {
      _size = view.physicalSize;
      _dpr = view.devicePixelRatio;
      _padding = view.padding;
      _keyboardShown = keyboardShown;
    }
    return changed;
  }

  static bool _samePadding(ViewPadding a, ViewPadding? b) =>
      b != null && a.top == b.top && a.bottom == b.bottom && a.left == b.left && a.right == b.right;
}
