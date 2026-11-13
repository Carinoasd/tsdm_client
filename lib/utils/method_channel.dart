import 'package:flutter/services.dart';
import 'package:tsdm_client/utils/platform.dart';

// Its one Dart handler is `_handleMainChannelCall`: listen to a call from Android through `_listenOnMainChannel`, never
// with another `setMethodCallHandler`, which would drop the listeners there.
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

const _methodIsActiveNetworkMetered = 'isActiveNetworkMetered';

/// Whether Android counts the network in use as metered (mobile data, a hotspot, a Wi-Fi the user marked metered), as
/// `ConnectivityManager.isActiveNetworkMetered` tells it: true without any network, and when the system does not tell.
Future<bool> androidActiveNetworkMetered() async =>
    await _mainChannel.invokeMethod<bool>(_methodIsActiveNetworkMetered) ?? true;

/// Whether the Android activity set the main channel up, which it does when it attaches to the engine
/// (`MainActivityImpl.configureFlutterEngine`): without an activity nothing answers on it. See
/// `waitForAndroidActivity`.
Future<bool> androidActivityAttached() async {
  try {
    await _mainChannel.invokeMethod<bool>(_methodIsActiveNetworkMetered);
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    // An answer, whatever it says.
    return true;
  }
}

const _methodNetworkMeteredChanged = 'networkMeteredChanged';

const _methodHardwareKeyboardChanged = 'hardwareKeyboardChanged';

/// What Android calls on the main channel, by method: the channel has one handler on the Dart side, so every call
/// from Android goes through [_handleMainChannelCall].
final _mainChannelListeners = <String, void Function(Object? arguments)>{};

Future<Object?> _handleMainChannelCall(MethodCall call) async {
  _mainChannelListeners[call.method]?.call(call.arguments);
  return null;
}

void _listenOnMainChannel(String method, void Function(Object? arguments) listener) {
  _mainChannelListeners[method] = listener;
  _mainChannel.setMethodCallHandler(_handleMainChannelCall);
}

/// Let Android tell [onChanged] whether the default network is metered each time it changes (a `NetworkCallback` of
/// the activity).
void androidOnNetworkMeteredChanged(void Function({required bool metered}) onChanged) =>
    _listenOnMainChannel(_methodNetworkMeteredChanged, (arguments) {
      if (arguments is bool) {
        onChanged(metered: arguments);
      }
    });

const _methodHasHardwareKeyboard = 'hasHardwareKeyboard';

/// Whether a hardware keyboard (a full one, attached and not hidden) is in use on this Android device, as the
/// activity's configuration tells it (`Configuration.keyboard`, `hardKeyboardHidden`).
Future<bool> androidHasHardwareKeyboard() async =>
    await _mainChannel.invokeMethod<bool>(_methodHasHardwareKeyboard) ?? false;

/// Let Android tell [onChanged] whether a hardware keyboard is in use, each time the configuration of the activity
/// changes (attached, removed, a cover keyboard folded away) and each time the activity comes to the front.
void androidOnHardwareKeyboardChanged(void Function({required bool present}) onChanged) =>
    _listenOnMainChannel(_methodHardwareKeyboardChanged, (arguments) {
      if (arguments is bool) {
        onChanged(present: arguments);
      }
    });

const _methodSetBackgroundSyncGuard = 'setBackgroundSyncGuard';

/// Tell Android whether the background message service is [wanted] (`BackgroundSyncGuard.kt`): while it is, a job
/// starts it again when the system killed it, or posts a notification titled [title] when the system refuses (P13).
Future<void> androidSetBackgroundSyncGuard({required bool wanted, required String title}) async =>
    _mainChannel.invokeMethod<bool>(_methodSetBackgroundSyncGuard, {'wanted': wanted, 'title': title});

const _methodOpenAttachment = 'openAttachment';

/// Open the downloaded attachment at [path] (in the app's `attachments` folder) in the app that views its type on
/// Android. Returns false when no app views it.
Future<bool> androidOpenFile(String path) async =>
    await _mainChannel.invokeMethod<bool>(_methodOpenAttachment, {'path': path}) ?? false;

const _methodHasSystemBiometricPrompt = 'hasSystemBiometricPrompt';

/// Whether Android draws the biometric prompt itself (Android 9+); before that the app lock offers the PIN only.
Future<bool> androidHasSystemBiometricPrompt() async =>
    await _mainChannel.invokeMethod<bool>(_methodHasSystemBiometricPrompt) ?? false;

const _methodDeviceName = 'deviceName';

/// The maker and the model of this Android device (`Build.MANUFACTURER`, `Build.MODEL`), the model alone when it
/// starts with the maker already; empty when the system does not tell. For the list of the devices an account logged
/// in on.
Future<String> androidDeviceName() async => await _mainChannel.invokeMethod<String>(_methodDeviceName) ?? '';

const _appIconChannel = MethodChannel('kzs.th000.tsdm_client/appIcon');

/// Switch the launcher icon of the app to the icon called [name] (`default`, `dark`, `mono` or `pink`).
///
/// Android enables the matching `activity-alias` (the main channel), iOS sets the alternate icon of the app (its own
/// channel). Returns whether the icon is in use afterwards; platform errors (an unknown name) are thrown.
Future<bool> setPlatformAppIcon(String name) async {
  final channel = isIOS ? _appIconChannel : _mainChannel;
  return await channel.invokeMethod<bool>('setAppIcon', {'name': name}) ?? false;
}
