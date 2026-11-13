import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/features/diagnostics/abnormal_exit.dart';
import 'package:tsdm_client/features/diagnostics/widgets/error_block.dart';
import 'package:tsdm_client/instance.dart';

/// Where uncaught errors go: the log, and, for a widget that failed to build, [ErrorBlock] in its place.
///
/// * [FlutterError.onError]: errors the framework caught (a build, a layout, a paint, a gesture, an image). They never
///   reach the zone handler of `main`; the error, its stack and the "building `<widget>`" part go to the log, then to
///   the handler that was there before (the console in a debug build).
/// * [PlatformDispatcher.onError]: errors of callbacks running outside the guarded zone of `main` (engine and plugin
///   callbacks registered before it); without it they were printed to the console only.
/// * [ErrorWidget.builder]: in a release or profile build, the failing subtree shows [ErrorBlock] instead of the plain
///   grey box of Flutter; a [debug] build keeps the red error screen of Flutter.
///
/// Errors of the guarded zone itself stay with the zone handler of `main`.
///
/// Each of them also leaves the error mark of the run ([recordAbnormalError]), but a failed image (the forum's images
/// fail to load every day) and an error reported as silent: the next start asks about it.
void installErrorReporting({required bool debug}) {
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    logFlutterError(details);
    if (countsAsAbnormal(details)) {
      recordAbnormalError(details.exception);
    }
    presentError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    talker.handle(error, stack, 'uncaught platform error');
    recordAbnormalError(error);
    return true;
  };
  if (!debug) {
    ErrorWidget.builder = ErrorBlock.fromDetails;
  }
}

/// Write [details] to the log: the error, its stack, and where it happened.
void logFlutterError(FlutterErrorDetails details) {
  // `context` is the "building <widget>" part, the one thing that says where the error block was (GitHub #55).
  final where = details.context?.toDescription();
  talker.handle(
    details.exception,
    details.stack,
    'FlutterError in ${details.library ?? 'widgets'}${where == null ? '' : ': $where'}',
  );
}

/// Whether the framework error [details] counts as an abnormal end of the run ([recordAbnormalError]): not one marked
/// silent, nor an image that failed (a broken or missing image of a post, the network).
bool countsAsAbnormal(FlutterErrorDetails details) => !details.silent && details.library != 'image resource service';
