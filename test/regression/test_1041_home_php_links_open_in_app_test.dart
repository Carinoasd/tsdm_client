// GitHub #29: the links of home.php (the members' pages) open in the app as the forum.php ones do. Android hands the
// link to the "open page" screen (`OpenInAppPage`, autoOpen), which routes what `parseUrlToRoute` recognizes and keeps
// anything else on screen with its button to the browser.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';

/// The VIEW filters of the main activity, as (scheme, host, path prefix) combinations: the data elements of a filter
/// combine with each other.
Set<(String, String, String)> _viewLinks(XmlDocument manifest) {
  final activity = manifest
      .findAllElements('activity')
      .singleWhere((e) => e.getAttribute('name', namespace: _android) == '.MainActivityImpl');
  final links = <(String, String, String)>{};
  for (final filter in activity.findElements('intent-filter')) {
    final actions = filter.findElements('action').map((e) => e.getAttribute('name', namespace: _android));
    if (!actions.contains('android.intent.action.VIEW')) continue;
    final data = filter.findElements('data').toList();
    String? attr(XmlElement e, String name) => e.getAttribute(name, namespace: _android);
    final schemes = data.map((e) => attr(e, 'scheme')).nonNulls.toSet();
    final hosts = data.map((e) => attr(e, 'host')).nonNulls.toSet();
    final paths = data.map((e) => attr(e, 'pathPrefix')).nonNulls.toSet();
    for (final s in schemes) {
      for (final h in hosts) {
        for (final p in paths) {
          links.add((s, h, p));
        }
      }
    }
  }
  return links;
}

void main() {
  group('manifest', () {
    final manifest = XmlDocument.parse(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());

    test('both hosts take forum.php and home.php', () {
      expect(_viewLinks(manifest), {
        ('https', 'www.tsdm39.com', '/forum.php'),
        ('https', 'tsdm39.com', '/forum.php'),
        ('https', 'www.tsdm39.com', '/home.php'),
        ('https', 'tsdm39.com', '/home.php'),
      });
    });

    test('no App Links verification: the forum hosts no assetlinks file for the app', () {
      final verified = manifest
          .findAllElements('intent-filter')
          .where((e) => e.getAttribute('autoVerify', namespace: _android) != null);
      expect(verified, isEmpty);
    });
  });

  group('routes of home.php links', () {
    for (final host in ['https://www.tsdm39.com', 'https://tsdm39.com']) {
      test('a profile by uid ($host)', () {
        final route = '$host/home.php?mod=space&uid=12345'.parseUrlToRoute();
        expect(route?.screenPath, ScreenPaths.profile);
        expect(route?.queryParameters, {'uid': '12345'});
      });

      test('a profile by username, percent-encoded ($host)', () {
        final route = '$host/home.php?mod=space&username=%E6%B5%8B%E8%AF%95'.parseUrlToRoute();
        expect(route?.screenPath, ScreenPaths.profile);
        expect(route?.queryParameters, {'username': '测试'});
      });
    }

    test('a profile link with the "profile" page of it', () {
      final route = 'https://www.tsdm39.com/home.php?mod=space&uid=7&do=profile'.parseUrlToRoute();
      expect(route?.screenPath, ScreenPaths.profile);
      expect(route?.queryParameters, {'uid': '7'});
    });

    test('a page of home.php the app does not show is not routed: the open page screen keeps it', () {
      expect('https://www.tsdm39.com/home.php?mod=task'.parseUrlToRoute(), isNull);
      expect('https://www.tsdm39.com/home.php'.parseUrlToRoute(), isNull);
    });

    test('forum.php links route as before', () {
      expect(
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1'.parseUrlToRoute()?.screenPath,
        ScreenPaths.threadV1,
      );
    });
  });
}
