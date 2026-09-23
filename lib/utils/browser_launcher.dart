import 'package:flutter/foundation.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:url_launcher/url_launcher.dart';

/// Open [uri] in an external web browser (#105).
///
/// On Android the app itself handles forum links, so a generic external launch may open the link in this app again:
/// the main channel starts a browser only, and there is no fallback to the generic launch. Other platforms use
/// url_launcher with [LaunchMode.externalApplication].
///
/// Returns whether a browser was started; platform errors are thrown to the caller.
Future<bool> openInExternalBrowser(Uri uri) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return androidOpenInBrowser(uri);
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
