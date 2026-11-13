/// The four lists of the thread page read from the forum's app API (plugin 4.0.0, `tsdmv=4`): the rate log
/// (`ratings`, schema 48), the voters of a poll (`poll_voters`, 49), the moderation log (`thread_mod`, 50) and the sales
/// history of a paid thread (`payments`, 51).
///
/// * Asked as a page (`tsdmapp=json&tsdmv=4&nodoc=1`, without the window's `inajax`) only once `status` listed it in
///   `thread_lists`; otherwise the floating window (the AJAX xml) is read as before, every request the same.
/// * The same data read either way gives the same rows (the recorded window and answer of the same thread, the
///   times compared to the minute the window prints).
/// * The forum's message: "none" is an empty list as the window shows it, any other its refusal; the plugin's
///   `error: polloption` (an option not of this poll) is refused like the window that is not one; another account's
///   answer is refused.
///
/// Fixtures: the four answers and windows of the test forum (cleaned); the rest synthetic.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/poll/models/poll_voters.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/purchase/utils/sales_history.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// A fake forum answering the API page [api] to a request with `tsdmv=4` and the window [window] to the others.
V4Forum _forum({Object? api, String? window}) => V4Forum((o) {
  final q = o.uri.queryParameters;
  if (q['tsdmv'] == '4') {
    return api == null ? null : V4Reply(api);
  }
  return window == null || q['inajax'] != '1' ? null : V4Reply(window);
});

DateTime _minute(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute);

bool _asksV4(V4Forum forum) => forum.requests.every((r) {
  final q = r.uri.queryParameters;
  return q['tsdmv'] == '4' && q['tsdmapp'] == 'json' && q['nodoc'] == '1' && !q.containsKey('inajax');
});

bool _asksWindow(V4Forum forum) => forum.requests.every((r) {
  final q = r.uri.queryParameters;
  return q['inajax'] == '1' && !q.containsKey('tsdmv');
});

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('rate log (ratings, schema 48)', () {
    Future<List<RateLogItem>> fetch(V4Forum forum, {int uid = _uid}) async {
      useV4Forum(forum);
      return (await RateRepository(
        currentUid: () => uid,
      ).fetchRateLog(tid: '9199193', pid: '3400').run()).getOrElse((e) => throw e);
    }

    List<(String, int, String, String, DateTime, String)> rows(List<RateLogItem> items) => [
      for (final e in items) (e.attrName, e.attrValue, e.username, e.uid, _minute(e.time), e.reason),
    ];

    test('the answer and the window of the same floor give the same rows', () async {
      knowV4Status();
      final api = _forum(api: v4Json('ratings_v48.json'));
      final fromApi = await fetch(api);
      expect(_asksV4(api), isTrue);
      expect(api.requests.single.uri.queryParameters, containsPair('pid', '3400'));
      TsdmAppApi.reset();
      final web = _forum(window: v4Raw('ratings_v48_window.xml'));
      final fromWindow = await fetch(web);
      expect(_asksWindow(web), isTrue, reason: 'no status: the window as before');
      expect(fromApi, hasLength(5));
      expect(rows(fromApi), rows(fromWindow));
      expect(fromApi.first.time.second, isNot(0), reason: 'the answer gives the second');
    });

    test('not listed in thread_lists: the window, even with v4', () async {
      knowV4Status(v4Status({'thread_lists': <String>[]}));
      final web = _forum(window: v4Raw('ratings_v48_window.xml'));
      expect(await fetch(web), hasLength(5));
      expect(_asksWindow(web), isTrue);
    });

    test('a digest note without a credit is left out, as the window leaves it out', () {
      final json = v4Json('ratings_v48.json');
      final logs = (json['logs'] as List).cast<Map<String, dynamic>>();
      json['logs'] = [
        {...logs.first, 'credit': null, 'score': 0, 'digest': 1},
        ...logs,
      ];
      expect(RateLogItem.listFromApi(json), hasLength(5));
    });

    test('"no rate": an empty list; another message: the refusal in its words; another account: refused', () async {
      knowV4Status();
      expect(await fetch(_forum(api: v4Json('ratings_v48_none.json'))), isEmpty);
      useV4Forum(
        _forum(
          api: const {
            'ok': 0,
            'error': 'message',
            'message': 'no permission',
            'message_key': 'thread_nopermission',
            'login': 0,
            'uid': _uid,
          },
        ),
      );
      final refused = await RateRepository(currentUid: () => _uid).fetchRateLog(tid: '1', pid: '2').run();
      expect(refused.getLeft().toNullable(), isA<ServerRespondedErrorException>());
      expect(refused.getLeft().toNullable()!.message, 'no permission');
      useV4Forum(_forum(api: v4Json('ratings_v48.json')));
      final other = await RateRepository(currentUid: () => 35).fetchRateLog(tid: '9199193', pid: '3400').run();
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test('a refusal of the plugin, a message without words: the window says what it says', () async {
      knowV4Status();
      for (final answer in [
        const {'ok': 0, 'error': 'privacy', 'uid': _uid},
        const {'ok': 0, 'error': 'message', 'message': '', 'message_key': '', 'login': 0, 'uid': _uid},
      ]) {
        final forum = _forum(api: answer, window: v4Raw('ratings_v48_window.xml'));
        expect(await fetch(forum), hasLength(5), reason: '$answer');
        expect(forum.requests, hasLength(2));
      }
    });

    test('an answer that is not the page: the window', () async {
      knowV4Status();
      final forum = V4Forum((o) {
        if (o.uri.queryParameters['tsdmv'] == '4') {
          return const V4Reply({'ok': 0, 'error': 'unknown'});
        }
        return V4Reply(v4Raw('ratings_v48_window.xml'));
      });
      expect(await fetch(forum), hasLength(5));
      expect(forum.requests, hasLength(2));
    });
  });

  group('voters (poll_voters, schema 49)', () {
    const votersUrl = '$baseUrl/forum.php?mod=misc&action=viewvote&tid=1019';

    PollRepository repo(V4Forum forum, {int uid = _uid}) =>
        PollRepository.network(v4Client(forum), currentUid: () => uid);

    test('the answer and the window of the same option give the same voters', () async {
      knowV4Status();
      final api = _forum(api: v4Json('voters_v49.json'));
      final fromApi = await repo(api).fetchVoters(votersUrl, '3');
      expect(_asksV4(api), isTrue);
      expect(api.requests.single.uri.queryParameters, containsPair('polloptionid', '3'));
      TsdmAppApi.reset();
      final web = _forum(window: v4Raw('voters_v49_window.xml'));
      final fromWindow = await repo(web).fetchVoters(votersUrl, '3');
      expect(_asksWindow(web), isTrue);
      expect(fromApi.voters.map((e) => (e.uid, e.name)), fromWindow.voters.map((e) => (e.uid, e.name)));
      expect(fromApi.voters, hasLength(4));
      expect(fromApi.hasNext, fromWindow.hasNext);
    });

    test('pages: a next page while page is below pages, asked with page', () async {
      knowV4Status();
      final json = {...v4Json('voters_v49.json'), 'page': 1, 'pages': 3};
      final forum = _forum(api: json);
      expect((await repo(forum).fetchVoters(votersUrl, '3')).hasNext, isTrue);
      expect(pollVotersPageFromApi({...json, 'page': 3}, optionId: '3')!.hasNext, isFalse);
      await repo(forum).fetchVoters(votersUrl, '3', page: 2);
      expect(forum.requests.last.uri.queryParameters, containsPair('page', '2'));
    });

    test('an option not of this poll, the forum refusing, another option answered: thrown', () async {
      knowV4Status();
      final notThis = _forum(
        api: const {'ok': 0, 'error': 'polloption', 'message': '', 'message_key': '', 'login': 0, 'uid': _uid},
      );
      await expectLater(repo(notThis).fetchVoters(votersUrl, '776'), throwsFormatException);
      final private = _forum(api: v4Json('voters_v49_private.json'));
      await expectLater(repo(private).fetchVoters(votersUrl, '3'), throwsFormatException);
      final another = _forum(api: v4Json('voters_v49.json'));
      await expectLater(repo(another).fetchVoters(votersUrl, '4'), throwsFormatException);
      final otherAccount = _forum(api: v4Json('voters_v49.json'));
      await expectLater(repo(otherAccount, uid: 35).fetchVoters(votersUrl, '3'), throwsA(isA<AppException>()));
    });
  });

  group('moderation log (thread_mod, schema 50)', () {
    Future<List<OperationLogItem>> fetch(V4Forum forum) async {
      useV4Forum(forum);
      return (await ThreadRepository().fetchOperationLog('9199453', uid: _uid).run()).getOrElse((e) => throw e);
    }

    test('the answer and the window of the same thread give the same rows', () async {
      knowV4Status();
      final api = _forum(api: v4Json('thread_mod_v50.json'));
      final fromApi = await fetch(api);
      expect(_asksV4(api), isTrue);
      TsdmAppApi.reset();
      final web = _forum(window: v4Raw('thread_mod_v50_window.xml'));
      final fromWindow = await fetch(web);
      expect(_asksWindow(web), isTrue);
      // The window prints the forum's word for "permanent", the answer says `unlimited: 1` (the app's word).
      String? end(String? duration) =>
          duration?.replaceAll(RegExp(r'\s'), '') == '永久' ? 'permanent' : (duration?.isEmpty ?? true ? null : duration);
      List<(String, String, DateTime, String?)> rows(List<OperationLogItem> items) => [
        for (final e in items) (e.username, e.action, _minute(e.time), end(e.duration)),
      ];
      expect(fromApi, hasLength(63));
      expect(
        rows(fromApi).map((e) => (e.$1, e.$2, e.$3, e.$4 == t.threadPage.operationLog.permanent ? 'permanent' : e.$4)),
        rows(fromWindow),
      );
      expect(fromApi.where((e) => e.duration == t.threadPage.operationLog.permanent), hasLength(20));
    });

    test('the end of an action, the item used, the cron and the team left out as the window parser does', () {
      final json = {
        'ok': 1,
        'uid': _uid,
        'type': 'thread_mod',
        'schema': 50,
        'timeoffset': 8,
        'reasons_public': 1,
        'logs': [
          {
            'operator': {'uid': 32, 'username': 'ag_admin', 'label': 'ag_admin', 'kind': 'user'},
            'dateline': 1792056295,
            'action': 'STK',
            'action_text': 'stick',
            'magic': 'card',
            'expiration': 1792142695,
            'unlimited': 0,
            'active': 1,
            'reason': 'why',
          },
          {
            'operator': {'uid': 32, 'username': 'ag_admin', 'label': 'ag_admin', 'kind': 'user'},
            'dateline': 1792056295,
            'action': 'REB',
            'action_text': 'recommend',
            'magic': '',
            'expiration': 0,
            'unlimited': 0,
            'active': 1,
            'reason': 'somewhere',
          },
          {
            'operator': {'uid': 0, 'username': '', 'label': 'cron', 'kind': 'cron'},
            'dateline': 1792056295,
            'action': 'UST',
            'action_text': 'unstick',
            'magic': '',
            'expiration': 0,
            'unlimited': 0,
            'active': 1,
            'reason': '',
          },
          {
            'operator': {'uid': 0, 'username': '', 'label': 'team', 'kind': 'team'},
            'dateline': 1792056295,
            'action': 'CLS',
            'action_text': 'close',
            'magic': '',
            'expiration': 0,
            'unlimited': 1,
            'active': 1,
            'reason': '',
          },
        ],
      };
      final items = OperationLogItem.listFromApi(json);
      expect(items, hasLength(2));
      expect(items.first.action, 'stick(card)');
      expect(items.first.duration, '2026-10-16 17:24', reason: 'the forum wall clock of the end');
      expect(items.first.time, DateTime(2026, 10, 15, 17, 24, 55));
      expect(items.last.duration, 'somewhere');
    });

    test('"no log": an empty list; another message: the refusal', () async {
      knowV4Status();
      expect(
        await fetch(
          _forum(
            api: const {
              'ok': 0,
              'error': 'message',
              'message': 'none',
              'message_key': 'threadmod_nonexistence',
              'login': 0,
              'uid': _uid,
            },
          ),
        ),
        isEmpty,
      );
      useV4Forum(
        _forum(
          api: const {
            'ok': 0,
            'error': 'message',
            'message': 'no',
            'message_key': 'thread_nopermission',
            'login': 0,
            'uid': _uid,
          },
        ),
      );
      final refused = await ThreadRepository().fetchOperationLog('1', uid: _uid).run();
      expect(refused.getLeft().toNullable()?.message, 'no');
    });
  });

  group('sales history (payments, schema 51)', () {
    test('the answer and the window of the same thread give the same buyers', () async {
      knowV4Status();
      final api = _forum(api: v4Json('payments_v51.json'));
      final fromApi = await fetchSalesHistory('9202665', client: v4Client(api), currentUid: () => _uid);
      expect(_asksV4(api), isTrue);
      TsdmAppApi.reset();
      final web = _forum(window: v4Raw('payments_v51_window.xml'));
      final fromWindow = await fetchSalesHistory('9202665', client: v4Client(web), currentUid: () => _uid);
      expect(_asksWindow(web), isTrue);
      expect(fromApi, hasLength(7));
      expect(
        fromApi.map((e) => SaleLogItem(username: e.username, uid: e.uid, time: _minute(e.time), price: e.price)),
        fromWindow,
      );
    });

    test('the unit of the credit follows the amount', () {
      final json = {
        ...v4Json('payments_v51.json'),
        'credit': {'id': 2, 'title': 'coin', 'unit': 'pcs'},
      };
      expect(saleLogItemsFromApi(json).first.price, '5 pcs');
    });

    test('the forum refusing, or another account: nothing listed, as a window that failed', () async {
      knowV4Status();
      final refused = _forum(
        api: const {
          'ok': 0,
          'error': 'message',
          'message': 'no',
          'message_key': 'thread_nopermission',
          'login': 0,
          'uid': _uid,
        },
      );
      expect(await fetchSalesHistory('1', client: v4Client(refused), currentUid: () => _uid), isEmpty);
      final other = _forum(api: v4Json('payments_v51.json'));
      expect(await fetchSalesHistory('9202665', client: v4Client(other), currentUid: () => 35), isEmpty);
    });
  });
}
