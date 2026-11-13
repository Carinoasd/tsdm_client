// The moderation queue read two ways (PR #420): the panel's web page and the forum's app API (plugin 4.0.0, schema
// 42). The web page printed the time with the panel's "发表于 " in front and gave no author uid for a reply; the API
// gives neither. The two models of the same queue must be the same.
//
// Fixtures: the queue of threads and of replies of one forum of the test forum, read once each way by the same
// moderator (the page cut to the panel, cleaned).
//
// The panel links the author of a waiting thread (`home.php?mod=space&uid=N`), never the one of a waiting reply
// (`<span class="xi2">name</span>`): read from the web page, a reply has no author uid. That one field is the only
// difference left.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/moderate/models/modcp_v4.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:universal_html/parsing.dart';

const _admin = 32;
const _fid = 25;

String _read(String name) => File('test/data/tsdmapp/v4/g2_modcp_$name').readAsStringSync();

ModerateQueueList _web(ModerateQueueKind kind) =>
    parseModerateQueue(parseHtmlDocument(_read('q_${kind.name}_$_fid.html')), kind, fid: _fid, uid: _admin)!;

ModerateQueueList _api(ModerateQueueKind kind) => moderateQueueFromApi(
  jsonDecode(_read('q_${kind.name}_$_fid.json')) as Map<String, dynamic>,
  kind,
  fid: _fid,
  uid: _admin,
)!;

/// The fields sent back, but those printed empty: the list of threads prints `posttableid` empty (the forum reads it
/// for replies only), the app API leaves it out.
Map<String, String> _sent(ModerateQueueList list) => {
  for (final MapEntry(:key, :value) in list.fields.entries)
    if (value.isNotEmpty) key: value,
};

String _row(ModerateQueueItem e, {bool uid = true}) =>
    '${e.id}|${e.subject}|${e.author}|${uid ? e.authorUid : '-'}|${e.time}|${e.message}';

void main() {
  test('threads: the same list either way', () {
    final web = _web(ModerateQueueKind.threads);
    final api = _api(ModerateQueueKind.threads);
    expect(web.items, isNotEmpty);
    expect(web.items.map(_row), api.items.map(_row));
    expect(web.items.first.authorUid, 35);
    expect(_sent(web), _sent(api));
    expect(web.hasNext, api.hasNext);
  });

  test('replies: the same list either way, but the uid the panel does not print', () {
    final web = _web(ModerateQueueKind.replies);
    final api = _api(ModerateQueueKind.replies);
    expect(web.items, hasLength(4));
    expect(web.items.map((e) => _row(e, uid: false)), api.items.map((e) => _row(e, uid: false)));
    expect(api.items.map((e) => e.authorUid), everyElement(35));
    expect(web.items.map((e) => e.authorUid), everyElement(isNull));
    expect(_sent(web), _sent(api));
    expect(web.hasNext, api.hasNext);
  });

  test('the time as the forum prints it, without the panel\'s prefix', () {
    for (final kind in [ModerateQueueKind.threads, ModerateQueueKind.replies]) {
      for (final item in _web(kind).items) {
        expect(item.time, matches(RegExp(r'^\d{4}-\d{1,2}-\d{1,2} \d{2}:\d{2}$')), reason: '${kind.name} ${item.id}');
      }
    }
    expect(_web(ModerateQueueKind.replies).items.map((e) => e.time), [
      '2026-11-13 03:47',
      '2026-9-12 08:40',
      '2026-9-12 08:40',
      '2026-9-12 05:53',
    ]);
  });

  test('the prefix of the traditional page, and a time without one, are read alike', () {
    String timeOf(String line) {
      final html = _read('q_replies_$_fid.html').replaceFirst('<span class="xg1">发表于 2026-11-13 03:47</span>', line);
      return parseModerateQueue(
        parseHtmlDocument(html),
        ModerateQueueKind.replies,
        fid: _fid,
        uid: _admin,
      )!.items.first.time;
    }

    expect(timeOf('<span class="xg1">發表於 2026-11-13 03:47</span>'), '2026-11-13 03:47');
    expect(timeOf('<span class="xg1">2026-11-13 03:47</span>'), '2026-11-13 03:47');
    expect(timeOf('<span class="xg1">发表于  2026-11-13 03:47 </span>'), '2026-11-13 03:47');
  });

  test('the uid of a rewritten author link', () {
    final html = _read(
      'q_threads_$_fid.html',
    ).replaceFirst('href="home.php?mod=space&uid=35"', 'href="space-uid-35.html"');
    final web = parseModerateQueue(parseHtmlDocument(html), ModerateQueueKind.threads, fid: _fid, uid: _admin)!;
    expect(web.items.single.authorUid, 35);
  });
}
