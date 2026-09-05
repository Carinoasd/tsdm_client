import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Urls from page contents only become in-app routes when they point at the forum.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('forum urls keep working', () {
    test('relative, https and http links on both hosts route in-app', () {
      for (final url in [
        'forum.php?mod=viewthread&tid=1264928',
        '$baseUrl/forum.php?mod=viewthread&tid=1264928&extra=page%3D1',
        'https://tsdm39.com/forum.php?mod=viewthread&tid=1264928',
        'http://www.tsdm39.com/forum.php?mod=viewthread&tid=1264928',
        'HTTPS://WWW.TSDM39.COM/forum.php?mod=viewthread&tid=1264928',
      ]) {
        final route = url.parseUrlToRoute();
        expect(route?.screenPath, ScreenPaths.threadV1, reason: url);
        expect(route?.queryParameters['tid'], '1264928', reason: url);
      }
      expect('$baseUrl/forum.php?mod=forumdisplay&fid=4'.parseUrlToRoute()?.screenPath, ScreenPaths.forum);
      expect('home.php?mod=space&uid=1000'.parseUrlToRoute()?.screenPath, ScreenPaths.profile);
      expect('home.php?mod=space&uid=1000&do=friend'.parseUrlToRoute()?.screenPath, ScreenPaths.friend);
      expect('home.php?mod=space&do=favorite&type=thread'.parseUrlToRoute()?.screenPath, ScreenPaths.favorite);
    });

    test('routes that fetch the url themselves get the canonical https host', () {
      final guide = 'http://tsdm39.com/forum.php?mod=guide&view=new'.parseUrlToRoute();
      expect(guide?.screenPath, ScreenPaths.latestThread);
      expect(guide?.queryParameters['url'], '$baseUrl/forum.php?mod=guide&view=new');
      final relative = 'forum.php?mod=forum&srchfrom=86400&orderby=lastpost'.parseUrlToRoute();
      expect(relative?.queryParameters['url'], '$baseUrl/forum.php?mod=forum&srchfrom=86400&orderby=lastpost');
    });
  });

  group('foreign urls are not routed', () {
    test('another host with forum-looking parameters', () {
      for (final url in [
        'https://evil.example/forum.php?mod=viewthread&tid=1264928',
        'https://www.tsdm39.com.evil.example/forum.php?mod=viewthread&tid=1264928',
        'https://evil.example/home.php?mod=space&uid=1000',
        'https://evil.example/forum.php?mod=guide&view=new',
        'https://www.tsdm39.com@evil.example/forum.php?mod=viewthread&tid=1264928',
        'https://evil.example/?mod=viewthread&tid=1&host=www.tsdm39.com',
        'ftp://www.tsdm39.com/forum.php?mod=viewthread&tid=1264928',
      ]) {
        expect(url.parseUrlToRoute(), isNull, reason: url);
      }
    });

    test('non http schemes', () {
      for (final url in ['javascript:alert(1)', 'data:text/html,forum.php?mod=viewthread&tid=1', 'mailto:a@b.c']) {
        expect(url.parseUrlToRoute(), isNull, reason: url);
      }
    });
  });

  group('uri helpers', () {
    test('isForumHost and isForumOrRelative', () {
      expect(Uri.parse('$baseUrl/forum.php').isForumHost, isTrue);
      expect(Uri.parse('http://tsdm39.com/forum.php').isForumHost, isTrue);
      expect(Uri.parse('https://evil.example/forum.php').isForumHost, isFalse);
      expect(Uri.parse('forum.php?mod=viewthread').isForumOrRelative, isTrue);
      expect(Uri.parse('//evil.example/forum.php').isForumOrRelative, isFalse, reason: 'protocol relative is foreign');
      expect(Uri.parse('javascript:alert(1)').isForumOrRelative, isFalse);
    });

    test('canonicalForumUrl', () {
      expect('forum.php?mod=viewthread&tid=1'.canonicalForumUrl(), '$baseUrl/forum.php?mod=viewthread&tid=1');
      expect('http://tsdm39.com/forum.php?mod=viewthread&tid=1'.canonicalForumUrl(), '$baseUrl/forum.php?mod=viewthread&tid=1');
      expect('https://evil.example/x'.canonicalForumUrl(), 'https://evil.example/x', reason: 'foreign urls unchanged');
    });
  });
}
