/// A few checks of a forum page took any path ending with the script's name for the script: `/xhome.php?mod=follow`,
/// `/plugin/misc.php?mod=stat`, `https://www.tsdm39.com/a/forum.php?mod=viewthread…` (the link of a shared thread, the
/// guarded thread pages of the anti-theft check). Now the path is the script at the root of the forum
/// ([UriOriginExt.isForumScript]), as `isAttachmentDownloadUrl` already had it.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/open_in_app/utils/share_text.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/antitheft_interceptor.dart';

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  test('the script at the root, relative or on a host', () {
    for (final url in [
      'forum.php',
      '/forum.php',
      'https://www.tsdm39.com/forum.php',
      'HTTPS://WWW.TSDM39.COM/Forum.php',
    ]) {
      expect(Uri.parse(url).isForumScript('forum.php'), isTrue, reason: url);
    }
    for (final url in [
      'xforum.php',
      '/xforum.php',
      '/a/forum.php',
      'a/forum.php',
      'https://www.tsdm39.com/xforum.php',
      'https://www.tsdm39.com/plugin.php/forum.php',
      'https://www.tsdm39.com/',
      'https://www.tsdm39.com',
    ]) {
      expect(Uri.parse(url).isForumScript('forum.php'), isFalse, reason: url);
    }
  });

  test('the follow pages and the statistics: of home.php and misc.php only', () {
    expect('home.php?mod=follow&do=following'.parseUrlToRoute()?.screenPath, ScreenPaths.followMembers);
    expect('https://www.tsdm39.com/home.php?mod=follow'.parseUrlToRoute()?.screenPath, ScreenPaths.followFeed);
    expect('misc.php?mod=stat'.parseUrlToRoute()?.screenPath, ScreenPaths.siteStats);
    for (final url in [
      'https://www.tsdm39.com/xhome.php?mod=follow&do=following',
      'https://www.tsdm39.com/plugin/home.php?mod=follow',
    ]) {
      expect(
        url.parseUrlToRoute()?.screenPath,
        isNot(anyOf(ScreenPaths.followMembers, ScreenPaths.followFeed)),
        reason: url,
      );
    }
    for (final url in ['https://www.tsdm39.com/xmisc.php?mod=stat', 'https://www.tsdm39.com/a/misc.php?mod=stat']) {
      expect(url.parseUrlToRoute()?.screenPath, isNot(ScreenPaths.siteStats), reason: url);
    }
  });

  test('the link of a shared thread is cut down on forum.php only', () {
    expect(
      shortThreadUrl('https://www.tsdm39.com/forum.php?mod=viewthread&tid=12&extra=page%3D1&page=3'),
      'https://www.tsdm39.com/forum.php?mod=viewthread&tid=12',
    );
    const other = 'https://www.tsdm39.com/xforum.php?mod=viewthread&tid=12&page=3';
    expect(shortThreadUrl(other), other);
  });

  test('the guarded thread pages of the anti-theft check: forum.php only', () {
    // The answer of the challenge: no posts.
    const answer = {'ok': 0, 'error': 'unknown', 'document': '<div id="wp"></div>'};
    bool hides(String url) => AntitheftInterceptor.hidesChallenge(RequestOptions(path: url), answer);
    const query = 'mod=viewthread&tid=1&tsdmapp=json';
    expect(hides('https://www.tsdm39.com/forum.php?$query'), isTrue);
    expect(hides('https://www.tsdm39.com/a/forum.php?$query'), isFalse);
    expect(hides('https://www.tsdm39.com/xforum.php?$query'), isFalse);
  });
}
