import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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

/// Whether the web view can be created here: [inAppBrowserSupported] and, on Windows, the WebView2 runtime installed.
///
/// Checked once; false when the check fails.
Future<bool> inAppBrowserAvailable() async {
  if (!inAppBrowserSupported) {
    return false;
  }
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return true;
  }
  return _webView2Available ??= await () async {
    try {
      return await WebViewEnvironment.getAvailableVersion() != null;
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to check the WebView2 runtime');
      return false;
    }
  }();
}

bool? _webView2Available;

/// Whether [url] can be opened in the in-app browser: absolute `http` or `https`.
bool isInAppBrowserUrl(Uri? url) => url != null && url.hasAuthority && (url.scheme == 'http' || url.scheme == 'https');

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

/// [currentLinkTargetOf], checking the in-app browser can run ([inAppBrowserAvailable]); where it cannot, links go
/// where they went before it.
Future<LinkTarget> resolveLinkTarget(Uri uri, {bool explicitBrowser = false}) async {
  final target = currentLinkTargetOf(uri, explicitBrowser: explicitBrowser);
  if (target != LinkTarget.inAppBrowser || await inAppBrowserAvailable()) {
    return target;
  }
  return linkTargetOf(uri, forumPages: false, allLinks: false, supported: false, explicitBrowser: explicitBrowser);
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

/// What the in-app browser does with a link of another app ([BrowserNavigationExternal]).
sealed class ExternalLaunch {
  const ExternalLaunch();
}

/// Hand [uri] to the app that handles its scheme (`mailto:`, `tel:`, app schemes).
final class ExternalLaunchApp extends ExternalLaunch {
  /// Constructor.
  const ExternalLaunchApp(this.uri);

  /// The link.
  final Uri uri;
}

/// Load [uri], the web page an Android `intent:` link falls back to, in the web view.
final class ExternalLaunchFallback extends ExternalLaunch {
  /// Constructor.
  const ExternalLaunchFallback(this.uri);

  /// The web page.
  final Uri uri;
}

/// Do nothing: an `intent:` link without a web fallback, local files.
final class ExternalLaunchNone extends ExternalLaunch {
  /// Constructor.
  const ExternalLaunchNone();
}

/// Schemes never handed to another app from a web page.
const _blockedSchemes = {'file', 'content', 'intent'};

/// What the in-app browser does with [uri], a link of another app followed by the user.
///
/// An `intent:` link is not started (the platform launch can not parse it): its `S.browser_fallback_url` web page, if
/// any, loads in the web view instead.
ExternalLaunch externalLaunchOf(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'intent') {
    final raw = uri.fragment
        .split(';')
        .where((e) => e.startsWith('S.browser_fallback_url='))
        .map((e) => e.substring('S.browser_fallback_url='.length))
        .firstOrNull;
    final fallback = raw == null ? null : Uri.tryParse(Uri.decodeComponent(raw));
    return isInAppBrowserUrl(fallback) ? ExternalLaunchFallback(fallback!) : const ExternalLaunchNone();
  }
  if (_blockedSchemes.contains(scheme)) {
    return const ExternalLaunchNone();
  }
  return ExternalLaunchApp(uri);
}

/// Whether a navigation was started by the user: [hasGesture] where the platform tells it (Android), else whether a
/// link was activated ([linkActivated], iOS and macOS). Neither known: not the user, a page must not start other apps
/// on its own.
bool userStartedNavigation({required bool? hasGesture, required bool linkActivated}) => hasGesture ?? linkActivated;
