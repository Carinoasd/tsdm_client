import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Set up the sound player before the app starts: the media notification and playing in the background on Android,
/// iOS and macOS. Windows and Linux have nothing to set up here ([ensureDesktopAudioPlayer]).
///
/// Optional, like the tray: a failure is logged and the app starts; the player then says it cannot play.
///
/// Kept before `runApp` on the mobile platforms and macOS, not put off to the first play:
///
/// * `just_audio_background` asks for `init` once, in `main()`, before the app runs; it swaps the platform
///   implementation of `just_audio` and starts `audio_service`'s handler.
/// * Android starts the engine with no activity when the media button or the system asks the audio service again
///   (`waitForAndroidActivity` in `main()`): nothing is played then, so a first play never comes to make the handler,
///   and the service would be left without one.
///
/// Its cost at the start is one channel call, with a time limit.
Future<void> initAudioPlayer() async {
  try {
    if (isAndroid || isIOS || isMacOS) {
      // Before the first frame: never left to hold the app's start up.
      await JustAudioBackground.init(
        androidNotificationChannelId: 'kzs.th000.tsdm_client.audio',
        androidNotificationChannelName: LocaleSettings.currentLocale.translations.audioPlayer.notificationChannel,
        // Monochrome, as the app's other notifications.
        androidNotificationIcon: 'drawable/ic_launcher_foreground',
      ).timeout(const Duration(seconds: 5));
    }
  } on Object catch (e, st) {
    talker.handle(e, st, 'audio player init failed');
  }
}

bool _desktopReady = false;

/// Windows and Linux: make libmpv the player of `just_audio`, the first time something is to be played. Loading the
/// library is not paid at every start of the app; `just_audio` takes its platform implementation when a player is
/// made, so this only has to come before the first one. Nothing on the other platforms.
///
/// A failure is logged and tried again at the next play; the player then says it cannot play.
void ensureDesktopAudioPlayer() {
  if (_desktopReady || !(isWindows || isLinux)) {
    return;
  }
  try {
    JustAudioMediaKit.ensureInitialized();
    _desktopReady = true;
  } on Object catch (e, st) {
    talker.handle(e, st, 'audio player init failed');
  }
}
