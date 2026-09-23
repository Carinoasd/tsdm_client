import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';

/// Query keys of the "批准申请" link of a friend request notice, each exactly once and nothing else.
const _approveLinkKeys = {'mod', 'ac', 'op', 'uid', 'from'};

final _positiveUidRe = RegExp(r'^[1-9]\d{0,9}$');

/// Uid of the member whose friend request the link [url] approves, null for any other url.
///
/// Only the forum's own "批准申请" link of a friend request notice is recognized:
/// `home.php?mod=spacecp&ac=friend&op=add&uid=N&from=notice`, relative or on the forum's own hosts over http(s) on
/// the default port, without user info, exactly `/home.php`, with a positive uid and no other query parameter. The
/// add-friend link of a profile (no `from=notice`), foreign hosts, other ports and anything else are not.
int? friendApprovalUidOfUrl(String url) {
  final uri = Uri.tryParse(url.replaceAll('&amp;', '&'));
  if (uri == null || !isForumScript(uri, 'home.php')) {
    return null;
  }
  if (uri.hasAbsolutePath && uri.path != '/home.php') {
    return null;
  }
  final Map<String, List<String>> all;
  try {
    all = uri.queryParametersAll;
  } on FormatException {
    return null;
  }
  if (all.length != _approveLinkKeys.length || !all.keys.every(_approveLinkKeys.contains)) {
    return null;
  }
  if (all.values.any((e) => e.length != 1)) {
    return null;
  }
  String q(String key) => all[key]!.single;
  if (q('mod') != 'spacecp' || q('ac') != 'friend' || q('op') != 'add' || q('from') != 'notice') {
    return null;
  }
  final uid = q('uid');
  if (!_positiveUidRe.hasMatch(uid)) {
    return null;
  }
  return int.parse(uid);
}

/// Url of the approval form of the friend request of [uid], the same operation as the notice link, loaded as ajax.
String approveFriendFormUrl(int uid) => '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=$uid&from=notice&inajax=1';

/// Where the approval of the friend request of [uid] is posted.
String approveFriendSubmitUrl(int uid) => '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=$uid&inajax=1';
