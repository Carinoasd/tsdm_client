import 'package:flutter/widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The text a thread is shared with: the site's name, the thread's [title] and its [url] (the link "copy link"
/// copies), a link token the other side can paste in the app (`findForumLinkInText` finds the link in it).
String threadShareText(BuildContext context, {required String title, required String url}) =>
    context.t.linkToken.shareText(site: context.t.shareFloorImage.siteName, title: title.trim(), url: url);
