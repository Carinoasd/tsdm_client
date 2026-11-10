import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/in_app_browser/utils/link_routing.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';

/// Open the forum page [url] in a browser: the in-app browser where it runs (signed in with the account in use, or
/// signed out with [guest]), the external browser elsewhere.
///
/// Returns false when no browser could be started (the caller tells the user).
Future<bool> openForumPageInBrowser(GoRouter router, String url, {bool guest = false}) async {
  if (await inAppBrowserAvailable()) {
    unawaited(router.pushNamed(ScreenPaths.inAppBrowser, queryParameters: {'url': url, if (guest) 'guest': '1'}));
    return true;
  }
  try {
    return await openInExternalBrowser(Uri.parse(url));
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to open a forum page externally');
    return false;
  }
}
