import 'package:flutter/foundation.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';

/// Where a link the app has no page for is opened.
enum LinkTarget {
  /// The in-app browser, signed in with the account in use on the forum.
  inAppBrowser,

  /// The "Open in app" page, which launches the browser only when asked to (#105).
  openInAppPage,

  /// The external browser.
  external,
}

/// Whether the in-app browser runs on this platform: the web view has no Linux (nor web) implementation, there links
/// keep opening as before.
bool get inAppBrowserSupported =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS || TargetPlatform.windows => true,
      _ => false,
    };

/// Whether [uri] is a web page (`http` or `https`), or a relative forum link; anything else (`mailto:`, `intent:`,
/// app schemes) belongs to another app.
bool isWebLink(Uri uri) => !uri.hasScheme || uri.scheme == 'http' || uri.scheme == 'https';

/// Where [uri], a link the app has no page for, is opened.
///
/// * [forumPages]: forum pages go to the in-app browser (the `inAppBrowserForForum` setting).
/// * [allLinks]: every web link goes to the in-app browser (the `inAppBrowserForAll` setting).
/// * [supported]: the platform has the in-app browser ([inAppBrowserSupported]); without it nothing changes.
/// * [explicitBrowser]: the user asked for the browser (an "open in browser" action), not the app: a forum link
///   kept out of the in-app browser goes to the external browser instead of the "Open in app" page.
LinkTarget linkTargetOf(
  Uri uri, {
  required bool forumPages,
  required bool allLinks,
  required bool supported,
  bool explicitBrowser = false,
}) {
  if (!isWebLink(uri)) {
    return LinkTarget.external;
  }
  if (uri.isForumOrRelative) {
    if (supported && (forumPages || allLinks)) {
      return LinkTarget.inAppBrowser;
    }
    return explicitBrowser ? LinkTarget.external : LinkTarget.openInAppPage;
  }
  return supported && allLinks ? LinkTarget.inAppBrowser : LinkTarget.external;
}

/// [linkTargetOf] with the settings in use; both switches count as off when the settings are not loaded.
LinkTarget currentLinkTargetOf(Uri uri, {bool explicitBrowser = false}) {
  final settings = getIt.isRegistered<SettingsRepository>() ? getIt.get<SettingsRepository>().currentSettings : null;
  return linkTargetOf(
    uri,
    forumPages: settings?.inAppBrowserForForum ?? false,
    allLinks: settings?.inAppBrowserForAll ?? false,
    supported: inAppBrowserSupported,
    explicitBrowser: explicitBrowser,
  );
}

/// [uri] made absolute: a relative link is resolved on the forum host, keeping query and fragment.
Uri absoluteForumUri(Uri uri) => uri.hasScheme ? uri : Uri.parse('$baseUrl/').resolveUri(uri);

/// What the in-app browser does with a navigation.
sealed class BrowserNavigation {
  const BrowserNavigation();
}

/// Load the page in the web view.
final class BrowserNavigationAllow extends BrowserNavigation {
  /// Constructor.
  const BrowserNavigationAllow();
}

/// Stay on the current page and open [route] in the app instead.
final class BrowserNavigationOpenInApp extends BrowserNavigation {
  /// Constructor.
  const BrowserNavigationOpenInApp(this.route);

  /// The page of the app.
  final RecognizedRoute route;
}

/// Stay on the current page and hand the link to the platform (`mailto:`, `intent:`, app schemes).
final class BrowserNavigationExternal extends BrowserNavigation {
  /// Constructor.
  const BrowserNavigationExternal();
}

/// Schemes the web view loads itself.
const _webViewSchemes = {'http', 'https', 'about', 'data', 'blob', 'javascript'};

/// What the in-app browser does with a navigation to [uri].
///
/// A forum page the app has a page for, followed in the main frame, opens in the app. [initial] is a navigation before
/// the page the browser was opened with has loaded (that page and its redirects): it always loads, the app sent it here
/// ("open in browser" of a thread).
BrowserNavigation browserNavigationOf(Uri uri, {required bool mainFrame, bool initial = false}) {
  if (!_webViewSchemes.contains(uri.scheme.toLowerCase())) {
    return const BrowserNavigationExternal();
  }
  if (!mainFrame || initial) {
    return const BrowserNavigationAllow();
  }
  final route = '$uri'.parseUrlToRoute();
  if (route != null) {
    return BrowserNavigationOpenInApp(route);
  }
  return const BrowserNavigationAllow();
}
