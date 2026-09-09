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
      document.querySelector('div#inner_stat > strong > a');
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
