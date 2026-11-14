import 'package:tsdm_client/instance.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

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

/// The link handed to another app for [uri], the parsed form of [original] (the link as written, when known).
///
/// A [Uri] lower-cases its host and percent-encodes what a host may not hold: `thunder://QUFodHRw…` (base64, its case
/// matters) became `thunder://qufodhrw…` and `ed2k://|file|Name.mkv|…|/` became `ed2k://%7Cfile%7Cname.mkv…`, which the
/// download apps cannot open. A link of another scheme than the web's is therefore handed over as written: [original]
/// trimmed, when it has the scheme of [uri] and no control character. A web page (`http`, `https`) is handed over as
/// [uri] says, as before.
String externalLaunchTarget(Uri uri, String? original) {
  final scheme = uri.scheme.toLowerCase();
  final s = original?.trim();
  if (s == null || scheme == 'http' || scheme == 'https' || s.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
    return '$uri';
  }
  final colon = s.indexOf(':');
  return colon > 0 && s.substring(0, colon).toLowerCase() == scheme ? s : '$uri';
}

/// Hand [uri] to the app that opens it ([LaunchMode.externalApplication]) when [mayLaunchExternally]; otherwise do
/// nothing (logged) and return false. [original] is the link as written, handed over instead of [uri] where the parsing
/// changed it ([externalLaunchTarget]).
Future<bool> launchExternalUrl(Uri uri, {bool appSchemes = false, String? original}) async {
  if (!mayLaunchExternally(uri, appSchemes: appSchemes)) {
    talker.warning('not launching a link of scheme "${uri.scheme}"');
    return false;
  }
  final target = externalLaunchTarget(uri, original);
  if (target == '$uri') {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  try {
    if (await launchUrlString(target, mode: LaunchMode.externalApplication)) {
      return true;
    }
    // A platform that cannot take the link as written (iOS and macOS parse it with `URL(string:)`, which refuses the
    // `|` of an `ed2k://` link): the parsed form, which opens even if changed.
  } on Object catch (e) {
    talker.warning('launching a link as written failed (scheme=${uri.scheme}): $e');
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
