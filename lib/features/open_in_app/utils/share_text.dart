import 'package:flutter/widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The text a thread is shared with: the site's name, the thread's [title] and its [url] (the link "copy link"
/// copies), a link token the other side can paste in the app (`findForumLinkInText` finds the link in it).
String threadShareText(BuildContext context, {required String title, required String url}) =>
    context.t.linkToken.shareText(site: context.t.shareFloorImage.siteName, title: title.trim(), url: url);

/// [url] of a thread page cut down to the thread: `forum.php?mod=viewthread&tid=…` without what the page it was
/// copied from carries (`extra`, `ordertype`, `page`, `authorid`…), which mean nothing to who it is shared with.
/// Anything else (a `findpost` redirect, another page) is returned as it is.
String shortThreadUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority || !uri.path.endsWith('/forum.php')) {
    return url;
  }
  final query = uri.queryParameters;
  final tid = int.tryParse(query['tid'] ?? '');
  if (query['mod'] != 'viewthread' || tid == null || tid <= 0) {
    return url;
  }
  return '${uri.scheme}://${uri.authority}${uri.path}?mod=viewthread&tid=$tid';
}
