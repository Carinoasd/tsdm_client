import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';

const _channel = MethodChannel('kzs.th000.tsdm_client/interactiveHtmlChannel');

/// Maximum authored HTML payload accepted by the native viewer, measured in UTF-8 bytes.
const int interactivePostMaxBytes = 256 * 1024;

/// Whether this platform has the isolated native interactive viewer.
bool get supportsInteractivePostViewer => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Where the explicit open action ended.
enum InteractivePostOpenResult {
  /// Opened the native interactive viewer.
  viewer,

  /// Opened the original post in an external browser.
  browser,

  /// Neither viewer nor browser could open the post.
  failed,
}

/// Canonical original-post URL without author attribution, session data, or arbitrary HTML-supplied links.
Uri? interactivePostSourceUrl(String postId) {
  if (!RegExp(r'^[1-9]\d{0,19}$').hasMatch(postId)) {
    return null;
  }
  return Uri.parse('$baseUrl/forum.php').replace(
    queryParameters: {'mod': 'redirect', 'goto': 'findpost', 'pid': postId},
  );
}

/// Texts of the native viewer in the language chosen in the app, keyed as the viewer reads them.
Map<String, String> interactivePostViewerLabels() {
  final tr = LocaleSettings.instance.currentTranslations.postCard.interactiveHtml.viewer;
  return {
    'title': tr.title,
    'back': tr.back,
    'original': tr.original,
    'originalDescription': tr.originalDescription,
    'loading': tr.loading,
    'loadFailed': tr.loadFailed,
    'openFailed': tr.openFailed,
    'linkFailed': tr.linkFailed,
    'browserFailed': tr.browserFailed,
    'downloadInOriginal': tr.downloadInOriginal,
    'pageMessage': tr.pageMessage,
  };
}

/// Time away after which the app lock locks, in milliseconds; null while the lock is off.
///
/// The native viewer is an activity of its own above the Flutter pages, out of reach of the lock screen: it closes
/// itself where the app would lock, so the lock screen shows instead.
int? interactivePostAppLockDelayMs() {
  if (!getIt.isRegistered<AppLockCubit>()) {
    return null;
  }
  final config = getIt.get<AppLockCubit>().state.config;
  return config.enabled ? config.timing.delay.inMilliseconds : null;
}

/// Open already-fetched authored HTML only after the reader asks to interact with it.
///
/// [currentUid] identifies the currently logged-in reader for isolated local storage. It must never be the author
/// UID. No cookies, credentials, headers or authenticated client are passed to the viewer. Unsupported platforms,
/// oversized payloads and native failures use the existing browser-only original-post path.
Future<InteractivePostOpenResult> openInteractivePost({
  required String html,
  required String postId,
  required int? currentUid,
}) async {
  final source = interactivePostSourceUrl(postId);
  if (source == null) {
    return InteractivePostOpenResult.failed;
  }
  if (supportsInteractivePostViewer && html.isNotEmpty && utf8.encode(html).length <= interactivePostMaxBytes) {
    final appLockDelayMs = interactivePostAppLockDelayMs();
    try {
      final opened = await _channel.invokeMethod<bool>('openHtml', {
        'html': html,
        'sourceUrl': source.toString(),
        'accountScope': currentUid != null && currentUid > 0 ? '$currentUid' : 'guest',
        'postId': postId,
        // The viewer's own texts follow the language chosen in the app, not the system one (#165).
        'locale': LocaleSettings.currentLocale.languageTag,
        // Translated here so the native viewer does not keep its own copy of these texts.
        'labels': interactivePostViewerLabels(),
        'appLockDelayMs': ?appLockDelayMs,
      });
      if (opened ?? false) {
        return InteractivePostOpenResult.viewer;
      }
    } on PlatformException {
      // The browser fallback below does not pass the post payload or account scope.
    } on MissingPluginException {
      // Older native hosts can still open the original forum post.
    }
  }
  try {
    return await openInExternalBrowser(source) ? InteractivePostOpenResult.browser : InteractivePostOpenResult.failed;
  } on PlatformException {
    return InteractivePostOpenResult.failed;
  } on MissingPluginException {
    return InteractivePostOpenResult.failed;
  }
}
