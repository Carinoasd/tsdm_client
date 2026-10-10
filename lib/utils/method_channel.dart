import 'package:flutter/services.dart';

const _mainChannel = MethodChannel('kzs.th000.tsdm_client/mainChannel');

const _methodExitApp = 'exitApp';

const _methodOpenInBrowser = 'openInBrowser';

/// Exit app on Android platform.
///
/// Currently it only moves to background instead of closing the app.
Future<bool?> androidExitApp() async => _mainChannel.invokeMethod<bool>(_methodExitApp);

/// Open [uri] in a browser on Android, never in this app (#105).
///
/// The app catches forum links itself, so a plain view intent may come back to it. Returns whether a browser was
/// started; platform errors (no handler, for example) are thrown to the caller.
Future<bool> androidOpenInBrowser(Uri uri) async =>
    await _mainChannel.invokeMethod<bool>(_methodOpenInBrowser, {'url': uri.toString()}) ?? false;

const _methodSetHighRefreshRate = 'setHighRefreshRate';

/// Ask Android to run this app at the highest refresh rate the screen offers, or let the system decide again when
/// [enable] is false (GitHub #182).
///
/// Returns the refresh rate of the preferred mode, or 0 when nothing was preferred (disabled, or the device has no
/// display modes to pick from).
Future<double> androidSetHighRefreshRate({required bool enable}) async =>
    await _mainChannel.invokeMethod<double>(_methodSetHighRefreshRate, {'enable': enable}) ?? 0;
