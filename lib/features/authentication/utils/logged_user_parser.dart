import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// The user a forum page (`forum.php`, `home.php`...) was served to, read from the user node in its header.
///
/// Null when the page was served to a guest or the node is not there. Shared by the authentication repository
/// (login by document) and the topics tab, which must only trust the "我收藏的版块" panel of a page that belongs to
/// the current user: the shared `forum.php` cache may still hold the previous account's page after a switch.
UserLoginInfo? parseLoggedUserFromDocument(uh.Document document) {
  final userNode =
      // Style 1: With avatar.
      document.querySelector('div#hd div.wp div.hdc.cl div#um p strong.vwmy a') ??
      // Style 2: Without avatar.
      document.querySelector('div#inner_stat > strong > a') ??
      // Style 3 ("默认毛坯" on tsdm39): the name link sits in the avatar block, no div#um at all.
      document.querySelector('div.block_name > a[href*="mod=space"][href*="uid="]');
  if (userNode == null) {
    talker.debug('logged user: user node not found');
    return null;
  }
  final username = userNode.firstEndDeepText();
  if (username == null) {
    talker.debug('logged user: user name not found');
    return null;
  }
  final uid = userNode.firstHref()?.split('uid=').lastOrNull?.parseToInt();
  if (uid == null) {
    talker.debug('logged user: user id not found');
    return null;
  }
  return UserLoginInfo(uid: uid, username: username);
}

final _discuzUidRe = RegExp(r"discuz_uid\s*=\s*'(\d+)'");

/// The uid a page was served to: the header user node when present, otherwise the `discuz_uid` variable every
/// Discuz! page declares in its head script regardless of the site style. Null for a guest page (uid 0) or when
/// neither is there.
int? parseLoggedUidFromDocument(uh.Document document) {
  final fromHeader = parseLoggedUserFromDocument(document)?.uid;
  if (fromHeader != null) {
    return fromHeader;
  }
  for (final script in document.querySelectorAll('script')) {
    final match = _discuzUidRe.firstMatch(script.text ?? '');
    if (match != null) {
      final uid = int.tryParse(match.group(1)!);
      return uid == null || uid <= 0 ? null : uid;
    }
  }
  return null;
}
