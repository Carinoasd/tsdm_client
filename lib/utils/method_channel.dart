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
