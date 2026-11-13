/// The broadcast messages (公共消息) read from the forum's app API (plugin 4.0.0, `announce: 1` in `status`).
///
/// * The list of the first fetch and of a refresh (the read ones too) comes from `pmlist&filter=announce` instead of
///   the broadcast message page: asked after the conversation list (both are `pmlist`, one interval), the page read
///   when it does not answer, and as before when `status` did not say `announce: 1`. A poll keeps reading the unread
///   ones from `notify`.
/// * The list gives the whole text and the read state; private messages switched off (`closed: 1`) list none, as
///   the page shows none.
/// * The detail is `subop=viewg` asked with `tsdmv=4` (`announcepm`, schema 40): the forum's html shown by the post
///   renderer, the time as the page prints it; the forum's message (`pm_status_off`) or a message not in the
///   account's inbox (`announce: null`) fails as the page that has none; the page as before otherwise. Asked only
///   when opened (it marks the message read).
///
/// Fixtures: the list and the detail of the test forum with private messages off (cleaned); the rest synthetic in the
/// plugin's shape.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> _row(int id, int dateline, {bool unread = false, String text = 'text'}) => {
  'id': id,
  'new': unread ? 1 : 0,
  'authorid': 32,
  'author': 'ag_admin',
  'system': 0,
  'dateline': dateline,
  'text': text,
};

Map<String, Object?> _list(List<Map<String, Object?>> rows, {int uid = _uid, int closed = 0}) => {
  'ok': 1,
  'api': 1,
  'time': _now,
  'uid': uid,
  'timeoffset': 8,
  'filter': 'announce',
  'closed': closed,
  'page': 1,
  'perpage': 20,
  'count': rows.length,
  'unread': rows.where((e) => e['new'] == 1).length,
  'announces': rows,
};

Map<String, Object?> _notify() => {
  'ok': 1,
  'api': 1,
  'version': '4.0.0',
  'time': _now,
  'uid': _uid,
  'formhash': 'f1f2f3f4',
  'timeoffset': 8,
  'counts': {'notice': 0, 'pm': 0, 'announce': 0},
  'pm_last': 0,
  'notices': <Object>[],
  'pms': <Object>[],
  'announces': <Object>[],
  'limit': 200,
  'has_more': 0,
  'next': '',
};

const Map<String, Object> _pmlist = {'ok': 1, 'api': 1, 'uid': _uid, 'closed': 0, 'timeoffset': 8, 'pms': <Object>[]};

/// The broadcast message page with one unread message.
String _page(int pmid) => [
  '<html><body><div id="um"></div><div class="pml">',
  '<dl id="gpmlist_$pmid" class="bbda cur1 cl newpm"><dd class="m avt"></dd><dd class="ptm pm_c">',
  '<span id="p_gpmid_$pmid">Broadcast $pmid</span> &nbsp;',
  '<span class="xg1"><span title="2026-11-1 10:00">9&nbsp;小时前</span></span>&nbsp;',
  '<a href="home.php?mod=space&amp;do=pm&amp;subop=viewg&amp;pmid=$pmid" id="gpmlist_${pmid}_a">查看</a>',
  '</dd></dl></div></body></html>',
].join();

/// A forum: `notify`, `pmlist` (conversations), `pmlist&filter=announce` by [announce], the broadcast message page.
V4Forum _forum({V4Reply? announce}) => V4Forum((o) {
  final q = o.uri.queryParameters;
  return switch (q['action']) {
    'notify' => V4Reply(_notify()),
    'pmlist' when q['filter'] == 'announce' => announce,
    'pmlist' => const V4Reply(_pmlist),
    'seen' => const V4Reply({'ok': 1}),
    _ when q['filter'] == 'announcepm' => V4Reply(_page(9)),
    _ => null,
  };
});

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('the list (pmlist&filter=announce)', () {
    test('every message, the whole text, the read state, the times as the page path reads them', () {
      final list = BroadcastMessage.listFromApi(
        _list([_row(3, _now - 60, unread: true, text: 'a long text\nsecond line'), _row(2, _now - 3600)]),
        uid: _uid,
      )!;
      expect(list.map((e) => (e.pmid, e.alreadyRead, e.data)), [
        (3, false, 'a long text\nsecond line'),
        (2, true, 'text'),
      ]);
      expect(list.first.timestamp, apiTimeOf(_now - 60, 8));
    });

    test('private messages switched off: none, as the page shows none', () {
      expect(BroadcastMessage.listFromApi(v4Json('announce_list_closed.json'), uid: _uid), isEmpty);
    });

    test('not the list: another account, a pmlist without the filter, a refusal, nothing', () {
      expect(BroadcastMessage.listFromApi(_list([_row(1, _now)], uid: 35), uid: _uid), isNull);
      expect(BroadcastMessage.listFromApi({..._list([]), 'filter': null}, uid: _uid), isNull);
      expect(BroadcastMessage.listFromApi(const {'ok': 0, 'error': 'login'}, uid: _uid), isNull);
      expect(BroadcastMessage.listFromApi(null, uid: _uid), isNull);
    });

    test('a refresh reads it after the conversations, not the broadcast message page', () async {
      knowV4Status();
      final forum = _forum(announce: V4Reply(_list([_row(5, _now - 60, unread: true), _row(4, _now - 999999)])));
      final fetched = (await NotificationRepository().fetchNotificationWith(v4Client(forum)).run()).getOrElse(
        (e) => fail('$e'),
      );
      expect(forum.unexpected, isEmpty);
      final names = forum.requests.map((r) => '${r.uri.queryParameters['action']}${r.uri.queryParameters['filter']}');
      expect(names.where((e) => e.startsWith('pmlist')), ['pmlistnull', 'pmlistannounce']);
      expect(forum.requests.any((r) => r.uri.queryParameters['filter'] == 'announcepm'), isFalse);
      expect(fetched.info.broadcastMessageList.map((e) => e.pmid), [5], reason: 'the read old one outside the window');
    });

    test('a refresh: the page when the list does not answer, or without the flag', () async {
      knowV4Status();
      final failing = _forum(announce: const V4Reply({'ok': 0, 'error': 'busy'}, status: 503));
      final fetched = (await NotificationRepository().fetchNotificationWith(v4Client(failing)).run()).getOrElse(
        (e) => fail('$e'),
      );
      expect(failing.requests.any((r) => r.uri.queryParameters['filter'] == 'announcepm'), isTrue);
      expect(fetched.info.broadcastMessageList, isNotEmpty);

      TsdmAppApi.reset();
      knowV4Status(v4Status({'announce': 0}));
      final off = _forum();
      await NotificationRepository().fetchNotificationWith(v4Client(off)).run();
      expect(off.unexpected, isEmpty);
      expect(off.requests.any((r) => r.uri.queryParameters['filter'] == 'announce'), isFalse);
      expect(off.requests.any((r) => r.uri.queryParameters['filter'] == 'announcepm'), isTrue);
    });

    test('a poll keeps the unread ones of notify: neither the list nor the page', () async {
      knowV4Status();
      final forum = _forum();
      await NotificationRepository().fetchNotificationWith(v4Client(forum), timestamp: _now - 600).run();
      expect(forum.unexpected, isEmpty);
      expect(forum.requests.any((r) => r.uri.queryParameters.containsKey('filter')), isFalse);
    });
  });

  group('the detail (announcepm, schema 40)', () {
    Map<String, dynamic> detail(Object? announce, {int uid = _uid}) => {
      'ok': 1,
      'api': 1,
      'time': _now,
      'uid': uid,
      'formhash': 'f1f2f3f4',
      'timeoffset': 8,
      'type': 'announcepm',
      'schema': 40,
      'pmid': 3,
      'announce': announce,
    };

    final announce = {
      'id': 3,
      'authorid': 32,
      'author': 'ag_admin',
      'system': 0,
      'dateline': 1789177714,
      'text': 'Bold\n  line',
      'message_html': '<b>Bold</b><br /> &nbsp; line <a href="forum.php?mod=viewthread&tid=5">t</a>',
    };

    test("the forum's html in a node for the renderer, the time as the page prints it", () {
      final answer = tsdmAppV4AnswerOf(detail(announce), type: 'announcepm', schema: 40)!;
      final read = AnnounceDetailAnswer.of(answer) as AnnounceDetail;
      expect(read.messageNode.querySelector('b')?.text, 'Bold');
      expect(read.messageNode.querySelector('a')?.attributes['href'], 'forum.php?mod=viewthread&tid=5');
      expect(read.dateTime, tsdmAppWallClockTime(1789177714, 8));
      final plain = AnnounceDetailAnswer.of(
        tsdmAppV4AnswerOf(detail({...announce, 'message_html': ''}), type: 'announcepm', schema: 40)!,
      );
      expect((plain as AnnounceDetail).messageNode.innerHtml, contains('Bold<br>'));
    });

    test('no such message for the account, the forum refusing: refused', () {
      expect(
        AnnounceDetailAnswer.of(tsdmAppV4AnswerOf(detail(null), type: 'announcepm', schema: 40)!),
        isA<AnnounceDetailRefused>(),
      );
      final off = AnnounceDetailAnswer.of(
        tsdmAppV4AnswerOf(v4Json('announce_detail_pm_off.json'), type: 'announcepm', schema: 40)!,
      );
      expect((off as AnnounceDetailRefused).reason, isNotEmpty);
    });

    test('asked with tsdmv=4 only with the flag; the account checked', () async {
      final forum = V4Forum((o) => V4Reply(detail(announce)));
      useV4Forum(forum);
      expect(
        (await NotificationRepository().fetchAnnounceDetail('3', uid: _uid).run()).getOrElse((e) => throw e),
        isNull,
      );
      expect(forum.requests, isEmpty);

      knowV4Status();
      final got = await NotificationRepository().fetchAnnounceDetail('3', uid: _uid).run();
      expect(got.getOrElse((e) => throw e), isA<AnnounceDetail>());
      final q = forum.requests.single.uri;
      expect(q.toString(), startsWith('$baseUrl/home.php?'));
      expect(q.queryParameters, containsPair('subop', 'viewg'));
      expect(q.queryParameters, containsPair('pmid', '3'));
      expect(q.queryParameters, containsPair('tsdmv', '4'));

      final other = await NotificationRepository().fetchAnnounceDetail('3', uid: 35).run();
      expect(other.isLeft(), isTrue);
    });

    test('an older plugin answering the page: null, the page is read as before', () async {
      knowV4Status();
      useV4Forum(V4Forum((o) => const V4Reply('<html><body><div id="pm_ul"></div></body></html>')));
      expect(
        (await NotificationRepository().fetchAnnounceDetail('3', uid: _uid).run()).getOrElse((e) => throw e),
        isNull,
      );
    });
  });
}
