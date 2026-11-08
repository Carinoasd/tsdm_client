import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Set up the sound player before the app starts: libmpv for Windows and Linux, the media notification and playing
/// in the background on Android, iOS and macOS.
///
/// Optional, like the tray: a failure is logged and the app starts; the player then says it cannot play.
Future<void> initAudioPlayer() async {
  try {
    if (isWindows || isLinux) {
      JustAudioMediaKit.ensureInitialized();
    } else if (isAndroid || isIOS || isMacOS) {
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
