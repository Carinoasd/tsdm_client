/// The ids of a link (`tid`, `fid`, `uid`, `pid`…) went into the routes as written, and from there into the urls a
/// page requests: `forum.php?mod=forumdisplay&fid=1%26action%3Dx` opened a forum page asking for `fid=1&action=x`.
/// Now a link whose ids are not all integers is no route ([routeIdsValid]): it opens as an unsupported link of the forum
/// (the "Open in app" page), like any other the app has no page for. The same parsing serves a link in a post, a link
/// handed over by another app (Android's forum links), a shared text and the clipboard.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/route_ids.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// A value adding a parameter of its own once decoded, and a few other values that are no id.
const _bad = ['1%26action%3Dx', '1&action=x', '--1', '1-', '1.5', 'abc', '1 ', '0x10', '１２'];

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  /// Links with an id, the id written as `{}`.
  const links = [
    'forum.php?mod=forumdisplay&fid={}',
    'forum.php?mod=forumdisplay&fid=2&filter=typeid&typeid={}',
    'forum.php?mod=viewthread&tid={}',
    'forum.php?mod=viewthread&tid=1&page={}',
    'forum.php?mod=viewthread&tid=1&authorid={}',
    'forum.php?mod=viewthread&tid=1#pid{}',
    'forum.php?mod=redirect&tid={}&goto=lastpost',
    'forum.php?mod=redirect&goto=findpost&pid={}',
    'forum.php?mod=redirect&goto=findpost&pid=1&authorid={}',
    'home.php?mod=space&uid={}',
    'home.php?mod=space&do=friend&uid={}',
    'home.php?mod=space&do=pm&subop=view&touid={}',
    'home.php?mod=space&do=pm&subop=viewg&pmid={}',
    'forum.php?mod=post&action=edit&fid={}&tid=1&pid=2',
    'forum.php?mod=post&action=edit&fid=1&tid={}&pid=2',
    'forum.php?mod=post&action=edit&fid=1&tid=2&pid={}',
    'forum.php?gid={}',
  ];

  test('every id of a route is an integer', () {
    for (final link in links) {
      for (final bad in _bad) {
        final url = link.replaceAll('{}', bad);
        final route = 'https://www.tsdm39.com/$url'.parseUrlToRoute();
        if (route == null) {
          continue;
        }
        expect(routeIdsValid(route.pathParameters), isTrue, reason: '$url -> ${route.pathParameters}');
        expect(routeIdsValid(route.queryParameters), isTrue, reason: '$url -> ${route.queryParameters}');
      }
    }
  });

  test('an id that is no number: no route, the link opens as unsupported', () {
    for (final url in [
      'forum.php?mod=forumdisplay&fid=1%26action%3Dx',
      'forum.php?mod=viewthread&tid=1%26mod%3Dpost',
      'forum.php?mod=viewthread&tid=1&authorid=2%26x%3D1',
      'forum.php?mod=redirect&goto=findpost&pid=abc',
      'home.php?mod=space&uid=1%26do%3Dprofile',
      'home.php?mod=space&do=pm&subop=view&touid=x',
      'forum.php?gid=1%26mod%3Dx',
    ]) {
      expect('https://www.tsdm39.com/$url'.parseUrlToRoute(), isNull, reason: url);
      expect(url.parseUrlToRoute(), isNull, reason: 'relative: $url');
    }
  });

  test('the links of the forum route as before', () {
    final thread = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123&page=2&authorid=31#pid456'
        .parseUrlToRoute()!;
    expect(thread.screenPath, ScreenPaths.threadV1);
    expect(thread.queryParameters['tid'], '123');
    expect(thread.queryParameters['pageNumber'], '2');
    expect(thread.queryParameters['onlyVisibleUid'], '31');
    expect(thread.queryParameters['pid'], '456');
    final forum = 'forum.php?mod=forumdisplay&fid=8&filter=typeid&typeid=3'.parseUrlToRoute()!;
    expect(forum.screenPath, ScreenPaths.forum);
    expect(forum.pathParameters['fid'], '8');
    expect(forum.queryParameters['threadTypeID'], '3');
    expect('home.php?mod=space&uid=31'.parseUrlToRoute()?.queryParameters['uid'], '31');
    expect('home.php?mod=space&username=abc'.parseUrlToRoute()?.queryParameters['username'], 'abc');
    expect('forum.php?gid=1'.parseUrlToRoute()?.pathParameters['gid'], '1');
    // An empty value names nothing else either: as before.
    expect('forum.php?mod=viewthread&tid=1&page='.parseUrlToRoute()?.queryParameters['tid'], '1');
  });

  test('the check itself', () {
    expect(isRouteIdValue('123'), isTrue);
    expect(isRouteIdValue('-1'), isTrue);
    expect(isRouteIdValue(''), isTrue);
    for (final bad in _bad) {
      expect(isRouteIdValue(bad), isFalse, reason: bad);
    }
    expect(routeIdsValid({'tid': '1', 'username': 'a&b', 'url': 'https://x/?a=b'}), isTrue);
    expect(routeIdsValid({'tid': '1', 'fid': '2&x=1'}), isFalse);
  });
}
