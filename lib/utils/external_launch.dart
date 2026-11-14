import 'package:tsdm_client/instance.dart';
import 'package:url_launcher/url_launcher.dart';

/// Schemes a link may be handed to another app with: web pages and mail, and the ones the forum itself takes in
/// `[url]` (the downloads and calls of a resource forum: `magnet:`, `ed2k://`, `thunder://`, `ftp://`…, see
/// `_urlSchemeRe` in `post_bbcode.dart`), opened by whatever the user installed for them.
const externalLaunchSchemes = {
  'http',
  'https',
  'mailto',
  'magnet',
  'ed2k',
  'thunder',
  'ftp',
  'tel',
  'gopher',
  'news',
  'telnet',
  'rtsp',
  'mms',
  'callto',
  'bctp',
  'qqdl',
  'synacast',
};

/// Schemes never handed to another app, even where the links of other apps are ([mayLaunchExternally] with
/// `appSchemes`): local files and shares, the platform's own intents and handlers, scripts and inline documents.
const _neverLaunchedSchemes = {
  'file',
  'content',
  'intent',
  'javascript',
  'vbscript',
  'data',
  'blob',
  'about',
  'smb',
  'jar',
  'shell',
  'search',
  'search-ms',
};

/// Whether [uri] may be handed to another app: an absolute url of a scheme in [externalLaunchSchemes].
///
/// With [appSchemes] (the in-app browser on a phone, where a web page links its app: `weixin://`, `market://`) any
/// other scheme is let through too, except [_neverLaunchedSchemes] and the Windows handlers (`ms-*`).
///
/// A url without a scheme is not: it is the forum's, and opens in the app.
bool mayLaunchExternally(Uri uri, {bool appSchemes = false}) {
  if (!uri.hasScheme) {
    return false;
  }
  final scheme = uri.scheme.toLowerCase();
  if (externalLaunchSchemes.contains(scheme)) {
    return true;
  }
  return appSchemes && !_neverLaunchedSchemes.contains(scheme) && !scheme.startsWith('ms-');
}

/// Hand [uri] to the app that opens it ([LaunchMode.externalApplication]) when [mayLaunchExternally]; otherwise do
/// nothing (logged) and return false.
Future<bool> launchExternalUrl(Uri uri, {bool appSchemes = false}) async {
  if (!mayLaunchExternally(uri, appSchemes: appSchemes)) {
    talker.warning('not launching a link of scheme "${uri.scheme}"');
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
