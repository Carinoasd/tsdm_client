import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// tsdm39 offers six site styles; "默认毛坯" has no `div#um` header block at all, so the topics tab treated every
/// page of such a user as "not the current user's" (issue #1 follow-up). Every Discuz! page carries `discuz_uid` in
/// its head script regardless of the style.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const head =
      '<script type="text/javascript">var STYLEID = \'31\', discuz_uid = \'1000\', cookiepre = \'x_\';</script>';

  group('parseLoggedUidFromDocument', () {
    test('reads the header user node when present', () {
      final doc = parseHtmlDocument(
        '<html><head>$head</head><body><div id="hd"><div class="wp"><div class="hdc cl"><div id="um"><p> '
        '<strong class="vwmy"><a href="home.php?mod=space&uid=1000">Alice</a></strong></p></div></div></div></div> '
        '</body></html>',
      );
      expect(parseLoggedUserFromDocument(doc)?.username, 'Alice');
      expect(parseLoggedUidFromDocument(doc), 1000);
    });

    test('reads the avatar block name link of the bare style', () {
      final doc = parseHtmlDocument(
        '<html><head>$head</head><body><div class="block_name"><a href="home.php?mod=space&amp;uid=1000">Alice</a>'
        ' <a href="home.php?mod=spacecp&amp;ac=usergroup">group</a></div></body></html>',
      );
      final user = parseLoggedUserFromDocument(doc);
      expect(user?.uid, 1000);
      expect(user?.username, 'Alice');
    });

    test('falls back to the discuz_uid script variable', () {
      final doc = parseHtmlDocument('<html><head>$head</head><body><div id="ct">no header</div></body></html>');
      expect(parseLoggedUserFromDocument(doc), isNull);
      expect(parseLoggedUidFromDocument(doc), 1000);
    });

    test('a guest page (discuz_uid 0) has no uid', () {
      final doc = parseHtmlDocument(
        "<html><head><script>var discuz_uid = '0';</script></head><body></body></html>",
      );
      expect(parseLoggedUidFromDocument(doc), isNull);
    });
  });
}
