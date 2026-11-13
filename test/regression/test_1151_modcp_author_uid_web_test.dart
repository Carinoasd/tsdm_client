/// The author uid of the moderator panel's lists read from the web page, the same as the app API's (plugin 4.0.0).
///
/// * The moderation queue of replies (42): the stock panel prints a waiting reply's author as plain text
///   (`<span class="xi2">name</span>`; `moderate.php` wraps the author of a waiting thread only), so the web page has
///   no uid to give there. Where a template links it, either link form (`home.php?mod=space&uid=N`, the rewritten
///   `space-uid-N.html`) gives the same model as the API, the uid included.
/// * The recycle bins (45) read the uid of a rewritten link too (only `?uid=` was read).
///
/// Fixtures: the queue and the bins of the test forum recorded for PR #420 (cleaned).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_v4.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:universal_html/parsing.dart';

const _admin = 32;

String _read(String name) => File('test/data/tsdmapp/v4/g2_modcp_$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_read('$name.json')) as Map<String, dynamic>;

String _row(ModerateQueueItem e) => '${e.id}|${e.subject}|${e.author}|${e.authorUid}|${e.time}|${e.message}';

String _binRow(RecycleBinItem e) =>
    '${e.id}|${e.title}|${e.author}|${e.authorUid}|${e.time}|${e.tid}|${e.reason}|${e.replies}|${e.views}';

/// The queue of replies of forum 25 with every author printed as [author] does it with the name.
ModerateQueueList _replies(String Function(String name) author) {
  final html = _read('q_replies_25.html').replaceAll('<span class="xi2">ag_low2</span>', author('ag_low2'));
  return parseModerateQueue(parseHtmlDocument(html), ModerateQueueKind.replies, fid: 25, uid: _admin)!;
}

void main() {
  group('the queue of replies', () {
    final api = moderateQueueFromApi(_json('q_replies_25'), ModerateQueueKind.replies, fid: 25, uid: _admin)!;

    test('an author linked either way: the same rows as the app API, uid included', () {
      for (final link in [
        'home.php?mod=space&amp;uid=35',
        'home.php?mod=space&amp;uid=35&amp;do=profile',
        'https://forum.test/home.php?mod=space&amp;uid=35',
        'space-uid-35.html',
        'https://forum.test/space-uid-35.html',
      ]) {
        final web = _replies((name) => '<span class="xi2"><a href="$link" target="_blank">$name</a></span>');
        expect(web.items, hasLength(4), reason: link);
        expect(web.items.map(_row), api.items.map(_row), reason: link);
        expect(web.items.map((e) => e.authorUid), everyElement(35), reason: link);
      }
    });

    test('the stock panel prints no link for a reply: no uid, the rest the same', () {
      final web = _replies((name) => '<span class="xi2">$name</span>');
      expect(web.items.map((e) => e.authorUid), everyElement(isNull));
      String withoutUid(ModerateQueueItem e) => '${e.id}|${e.subject}|${e.author}|${e.time}|${e.message}';
      expect(web.items.map(withoutUid), api.items.map(withoutUid));
    });

    test('a link to something else gives no uid', () {
      final web = _replies(
        (name) => '<span class="xi2"><a href="forum.php?mod=viewthread&amp;tid=35">$name</a></span>',
      );
      expect(web.items.map((e) => e.authorUid), everyElement(isNull));
    });
  });

  group('the recycle bins', () {
    for (final (name, kind) in [('rb_2', RecycleBinKind.threads), ('rbp_2', RecycleBinKind.posts)]) {
      test('${kind.name}: rewritten author links give the same rows as the app API', () {
        final html = _read(
          '$name.html',
        ).replaceAllMapped(RegExp(r'home\.php\?mod=space&amp;uid=(\d+)'), (m) => 'space-uid-${m[1]}.html');
        final web = parseRecycleBin(parseHtmlDocument(html), kind, fid: 2, uid: _admin)!;
        final api = recycleBinFromApi(_json(name), kind, fid: 2, uid: _admin)!;
        expect(web.items, isNotEmpty);
        expect(web.items.map(_binRow), api.items.map(_binRow));
        expect(web.items.map((e) => e.authorUid), everyElement(isNotNull));
      });
    }
  });
}
