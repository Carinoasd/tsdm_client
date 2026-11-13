/// GitHub #156: notices missed after a long time away from the app.
///
/// `notify` lists the newest 50 unread notices, and `seen` marks EVERY unread notice read: the 51st and later were
/// marked read without the app ever reading them. Plugin 4.0.0 reads them page by page (`limit`, `before`, told by
/// `status` with `notify_paging: 1`); the fetch reads every page and only then posts `seen`, with the clock of the
/// first page.
///
/// * Paging on: the first `notify` carries `limit=200`; the pages are read with `before=<next>` until `has_more` is 0;
///   every notice of every page is kept; `seen` is posted with the first page's `time`.
/// * A page that fails (no answer, `error: before`, another account), a cursor that does not move, too many pages:
///   what was read is kept, `seen` is not posted (the next fetch reads again).
/// * A page refused as too soon is waited for (the plugin's interval), not given up.
/// * The flags not known yet (the background service starts with nothing): a `notify` of 4.0.0 that counts more
///   unread notices than it lists makes the fetch ask `status`, then the first page again with `limit`; one that lists
///   them all, or an older plugin's, is read as before.
/// * A poll with nothing new marks the unread notices read only after reading every page as well.
///
/// Synthetic answers in the shape of the plugin's (and the two recorded pages of the test forum, cleaned).
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 34;
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The bound a poll stored a day ago: every notice below is newer.
final int _since = _now - 86400;

/// [count] unread notices, newest first, one minute apart, the newest a minute ago.
List<Map<String, Object?>> _unread(int count, {int from = 100000}) => [
  for (var i = 0; i < count; i++)
    {
      'id': from - i,
      'new': 1,
      'type': 'post',
      'category': 1,
      'authorid': 3001,
      'author': 'Peer',
      'note': 'notice ${from - i}',
      'text': 'notice ${from - i}',
      'dateline': _now - 60 * (i + 1),
      'from_id': 5,
      'from_idtype': 'post',
      'from_num': 0,
    },
];

/// The plugin's `notify` over the unread notices `all` (newest first): the 50 newest without `limit`, else the page
/// after the cursor `before`; `version` the plugin's, `time` the clock of the first page.
final class _Notify {
  _Notify(this.all, {this.version = '4.0.0', this.time});

  final List<Map<String, Object?>> all;
  final String version;
  final int? time;

  /// A page answered instead, by its number (1 first), when given.
  final override = <int, V4Reply>{};

  /// Refuse the next request of page N as too soon once.
  final busyOnce = <int>{};

  /// The `time` of each page asked, by page.
  final times = <int, int>{};

  V4Reply answer(Map<String, String> q) {
    final limit = int.tryParse(q['limit'] ?? '');
    final before = q['before'];
    if (limit == null) {
      return V4Reply({..._first(), 'notices': all.take(50).toList()});
    }
    var start = 0;
    if (before != null) {
      final at = all.indexWhere((n) => '${n['dateline']}_${n['id']}' == before);
      if (at < 0) {
        return const V4Reply({'ok': 0, 'error': 'before'});
      }
      start = at + 1;
    }
    final page = start ~/ limit + 1;
    if (busyOnce.remove(page)) {
      return const V4Reply.busy();
    }
    if (override[page] case final reply?) {
      return reply;
    }
    final slice = all.skip(start).take(limit).toList();
    final hasMore = start + limit < all.length;
    final next = hasMore ? '${slice.last['dateline']}_${slice.last['id']}' : '';
    final pageTime = (time ?? _now) + page - 1;
    times[page] = pageTime;
    final common = {
      'ok': 1,
      'api': 1,
      'version': version,
      'time': pageTime,
      'uid': _uid,
      'formhash': 'f1f2f3f4',
      'timeoffset': 8,
      'notices': slice,
      'limit': limit,
      'has_more': hasMore ? 1 : 0,
      'next': next,
    };
    return V4Reply(before == null ? {..._first(), ...common} : common);
  }

  Map<String, Object?> _first() => {
    'ok': 1,
    'api': 1,
    'version': version,
    'time': time ?? _now,
    'uid': _uid,
    'formhash': 'f1f2f3f4',
    'timeoffset': 8,
    'counts': {'notice': all.length, 'pm': 0, 'announce': 0},
    'pm_last': 0,
    'pms': <Object>[],
    'announces': <Object>[],
  };
}

/// A forum with `notify` by [notify], `status` by [status] (none: no answer), `seen` taken.
V4Forum _forum(_Notify notify, {Map<String, dynamic>? status}) => V4Forum((o) {
  final q = o.uri.queryParameters;
  return switch (q['action']) {
    'notify' => notify.answer(q),
    'status' => status == null ? null : V4Reply(status),
    'seen' => V4Reply({'ok': 1, 'api': 1, 'time': _now, 'uid': _uid, 'notice': 1, 'newer': 0, 'pm': 0}),
    _ => null,
  };
});

List<RequestOptions> _asked(V4Forum forum, String action) =>
    forum.requests.where((r) => r.uri.queryParameters['action'] == action).toList();

/// The form posted to `seen`, null when none was.
Future<String?> _seenNotice(V4Forum forum) async {
  final at = forum.requests.indexWhere((r) => r.uri.queryParameters['action'] == 'seen');
  return at < 0 ? null : forum.bodies[at];
}

Future<FetchedNotification> _fetch(V4Forum forum, {int? timestamp}) async {
  final result = await NotificationRepository().fetchNotificationWith(v4Client(forum), timestamp: timestamp).run();
  return result.getOrElse((e) => fail('fetch failed: $e'));
}

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('paging on (status said notify_paging: 1)', () {
    setUp(knowV4Status);

    test('every page read, every notice kept, then seen with the first page time', () async {
      final notify = _Notify(_unread(450), time: _now - 5);
      final forum = _forum(notify);
      final fetched = await _fetch(forum, timestamp: _since);
      final asked = _asked(forum, 'notify').map((r) => r.uri.queryParameters).toList();
      expect(asked, hasLength(3));
      expect(asked.first['limit'], '${NotificationRepository.notifyPageLimit}');
      expect(asked.first['since'], '$_since');
      expect(asked.first.containsKey('before'), isFalse);
      expect(asked[1]['before'], '${_now - 60 * 200}_${100000 - 199}');
      expect(asked[2]['before'], '${_now - 60 * 400}_${100000 - 399}');
      expect(fetched.info.noticeList, hasLength(450));
      expect(fetched.info.noticeList.map((e) => e.id).toSet(), hasLength(450));
      expect(await _seenNotice(forum), contains('notice=${notify.times[1]}'));
      expect(notify.times[1], isNot(notify.times[3]), reason: "the first page's clock, not the last one's");
      expect(forum.unexpected, isEmpty);
    });

    test('one page is all there is: no second request, seen as before', () async {
      final forum = _forum(_Notify(_unread(30)));
      final fetched = await _fetch(forum, timestamp: _since);
      expect(_asked(forum, 'notify'), hasLength(1));
      expect(fetched.info.noticeList, hasLength(30));
      expect(await _seenNotice(forum), isNotNull);
    });

    test('a page refused as too soon is waited for', () async {
      final notify = _Notify(_unread(250))..busyOnce.add(2);
      final forum = _forum(notify);
      final fetched = await _fetch(forum, timestamp: _since);
      expect(_asked(forum, 'notify'), hasLength(3), reason: 'page 1, page 2 refused, page 2 again');
      expect(fetched.info.noticeList, hasLength(250));
      expect(await _seenNotice(forum), isNotNull);
    });

    test('a page that fails: what was read is kept, seen is not posted', () async {
      for (final failure in [
        v4Offline,
        const V4Reply({'ok': 0, 'error': 'login'}),
        const V4Reply({'ok': 0, 'error': 'before'}),
        const V4Reply({
          'ok': 1,
          'uid': 99,
          'notices': <Object>[],
          'has_more': 0,
          'next': '',
        }),
      ]) {
        TsdmAppApi.reset();
        knowV4Status();
        final notify = _Notify(_unread(450))..override[2] = failure;
        final forum = _forum(notify);
        final fetched = await _fetch(forum, timestamp: _since);
        expect(fetched.info.noticeList, hasLength(200), reason: '${failure.body}');
        expect(_asked(forum, 'seen'), isEmpty, reason: '${failure.body}');
      }
    });

    test('a cursor that does not move: stopped, seen not posted', () async {
      final notices = _unread(450);
      final notify = _Notify(notices);
      final stuck = '${notices[199]['dateline']}_${notices[199]['id']}';
      notify.override[2] = V4Reply({
        'ok': 1,
        'api': 1,
        'version': '4.0.0',
        'time': _now,
        'uid': _uid,
        'formhash': 'f1f2f3f4',
        'timeoffset': 8,
        'notices': notices.skip(200).take(200).toList(),
        'limit': 200,
        'has_more': 1,
        'next': stuck,
      });
      final forum = _forum(notify);
      final fetched = await _fetch(forum, timestamp: _since);
      expect(_asked(forum, 'notify'), hasLength(2));
      expect(fetched.info.noticeList, hasLength(400));
      expect(_asked(forum, 'seen'), isEmpty);
    });

    test('at most notifyMaxPages pages in one fetch: the rest left unread', () async {
      const pages = NotificationRepository.notifyMaxPages;
      final forum = _forum(_Notify(_unread(NotificationRepository.notifyPageLimit * pages + 5)));
      final fetched = await _fetch(forum, timestamp: _now - 3 * 86400 + 60);
      expect(_asked(forum, 'notify'), hasLength(pages));
      expect(fetched.info.noticeList.length, lessThanOrEqualTo(NotificationRepository.notifyPageLimit * pages));
      expect(_asked(forum, 'seen'), isEmpty);
    });

    test('a page reaching before the window ends the reading: the rest is older, seen as before 4.0.0', () async {
      // 450 unread, a minute apart; the window starts 300 minutes ago: page 2 reaches before it.
      final forum = _forum(_Notify(_unread(450)));
      final fetched = await _fetch(forum, timestamp: _now - 300 * 60);
      expect(_asked(forum, 'notify'), hasLength(2));
      expect(fetched.info.noticeList, hasLength(300));
      expect(await _seenNotice(forum), isNotNull);
    });

    test('a poll with nothing new: the first page reaches before the window, seen at once', () async {
      // Everything unread is older than the window: nothing to show, and seen marks it all as it always did.
      final old = [
        for (final n in _unread(450)) {...n, 'dateline': _since - 600 - (100000 - (n['id']! as int))},
      ];
      final forum = _forum(_Notify(old));
      final fetched = await _fetch(forum, timestamp: _since);
      expect(fetched.info.noticeList, isEmpty);
      expect(_asked(forum, 'notify'), hasLength(1));
      expect(await _seenNotice(forum), isNotNull);
    });

    test('not every page read: the next fetch keeps the window, and the second fetch shows the rest', () async {
      final notify = _Notify(_unread(450))..override[2] = v4Offline;
      final forum = _forum(notify);
      final first = await _fetch(forum, timestamp: _since);
      expect(first.info.noticeList, hasLength(200));
      expect(first.serverTime!.millisecondsSinceEpoch ~/ 1000, lessThanOrEqualTo(_since));
      // The bound the caller stores from it (nextFetchBound: the minute before).
      final bound = first.serverTime!.millisecondsSinceEpoch ~/ 1000 ~/ 60 * 60 - 60;
      notify.override.clear();
      final second = await _fetch(forum, timestamp: bound);
      expect(second.info.noticeList, hasLength(450));
      expect(_asked(forum, 'seen'), hasLength(1));
    });

    test('the two recorded pages of the test forum read as one list', () async {
      // The recorded times moved to now, so the notices stay inside the window whatever day the test runs.
      final recorded = v4Json('notify_paged_p1.json');
      final shift = _now - (recorded['time'] as int);
      Map<String, dynamic> moved(Map<String, dynamic> page) {
        final next = '${page['next']}'.split('_');
        return {
          ...page,
          'time': (page['time'] as int) + shift,
          'notices': [
            for (final n in (page['notices'] as List).cast<Map<String, dynamic>>())
              {...n, 'dateline': (n['dateline'] as int) + shift},
          ],
          'next': next.length == 2 ? '${int.parse(next[0]) + shift}_${next[1]}' : '',
        };
      }

      final p1 = moved(recorded);
      final p2 = moved(v4Json('notify_paged_p2.json'));
      final forum = V4Forum((o) {
        final q = o.uri.queryParameters;
        return switch (q['action']) {
          'notify' when q['before'] == null => V4Reply({...p1, 'has_more': 1}),
          'notify' when q['before'] == p1['next'] => V4Reply({...p2, 'has_more': 0, 'next': ''}),
          'seen' => const V4Reply({'ok': 1, 'notice': 1}),
          _ => null,
        };
      });
      await _fetch(forum, timestamp: _now - 3 * 86400 + 60);
      expect(forum.unexpected, isEmpty);
      expect(_asked(forum, 'notify').map((r) => r.uri.queryParameters['before']), [null, p1['next']]);
      expect(await _seenNotice(forum), contains('notice=${p1['time']}'));
    });
  });

  group('paging off or not known', () {
    test('an older plugin: no limit, no status, seen as before', () async {
      final forum = _forum(_Notify(_unread(30), version: '3.9.0'));
      await _fetch(forum, timestamp: _since);
      expect(_asked(forum, 'notify').single.uri.queryParameters.containsKey('limit'), isFalse);
      expect(_asked(forum, 'status'), isEmpty);
      expect(await _seenNotice(forum), isNotNull);
    });

    test('status said no paging: no limit; more unread than listed is read as before', () async {
      knowV4Status(v4Status({'notify_paging': 0}));
      final forum = _forum(_Notify(_unread(80)));
      final fetched = await _fetch(forum, timestamp: _since);
      expect(_asked(forum, 'notify').single.uri.queryParameters.containsKey('limit'), isFalse);
      expect(fetched.info.noticeList, hasLength(50));
      expect(await _seenNotice(forum), isNotNull);
    });

    test('4.0.0 not known yet, all listed: nothing more asked', () async {
      final forum = _forum(_Notify(_unread(30)), status: v4Status());
      await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify', 'seen']);
    });

    test('4.0.0 not known yet, more unread than listed: status, then the first page again with limit', () async {
      final notify = _Notify(_unread(450));
      final forum = _forum(notify, status: v4Status());
      final fetched = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify', 'status', 'notify', 'notify', 'notify', 'seen']);
      final again = _asked(forum, 'notify')[1].uri.queryParameters;
      expect(again['limit'], '${NotificationRepository.notifyPageLimit}');
      expect(again['since'], '$_since');
      expect(fetched.info.noticeList, hasLength(450));
      expect(TsdmAppV4.notifyPaging, isTrue);
    });

    test('4.0.0 not known yet and status does not answer: the 50 kept, seen not posted', () async {
      final forum = _forum(_Notify(_unread(80)));
      final fetched = await _fetch(forum, timestamp: _since);
      expect(fetched.info.noticeList, hasLength(50));
      expect(_asked(forum, 'status'), hasLength(1));
      expect(_asked(forum, 'seen'), isEmpty, reason: 'the 30 not listed would be marked read unseen');
    });

    test('a notify of 4.0.0 seen before: status asked first, the first notify already paged', () async {
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '4.0.0', api: 1, nodoc: false);
      final forum = _forum(_Notify(_unread(30)), status: v4Status());
      await _fetch(forum, timestamp: _since);
      expect(forum.names.take(2), ['status', 'notify']);
      expect(_asked(forum, 'notify').single.uri.queryParameters['limit'], '${NotificationRepository.notifyPageLimit}');
    });
  });
}
