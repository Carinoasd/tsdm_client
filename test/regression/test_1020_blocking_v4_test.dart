/// The blocking settings read from the forum's app API (plugin 4.0.0, `tsdmv=4`): the notice filter of the privacy
/// page (`privacy_filter`, schema 55), the notice ignore window (small form `ignore`) and the website blacklist of the
/// `blockuser` plugin (`blockuser`, schema 56).
///
/// * Asked as structured answers only once `status` listed them (`block_pages`, `forms`); otherwise, and for any
///   answer that is not the page, the web page is read as before.
/// * The same data read either way gives the same form, rules, list and lookup (the recorded page and answer of the
///   same account).
/// * A write goes back once with the result parameters (`tsdmapp=json&tsdmv=4`) and is decided by `message_key`
///   (`do_success`) or, for the blacklist, by the plugin's redirect and the `error` of the page drawn again; the list
///   is read again from the answer either way, and only that confirms it.
/// * The login prompt and another account's answer are refused; a refusal without a message reads the web page.
///
/// Fixtures: the answers and pages of the test forum (cleaned); the rules, the list and the write results synthetic,
/// shaped as the spec of 4.0.0 (5.8–5.10) gives them.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

const _repo = NoticeIgnoreRepository();
const _blocklist = WebsiteBlocklistRepository();

/// A write result (`schema` 13) of account [uid].
Map<String, dynamic> _result({
  String kind = 'handle',
  int ok = 1,
  String messageKey = '',
  String message = '',
  String url = '',
  String alert = '',
  int uid = _uid,
  int login = 0,
}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': uid,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': kind,
  'message': message,
  'message_key': messageKey,
  'url': url,
  'handlekey': '',
  'values': <String, Object?>{},
  'login': login,
  'alert': alert,
};

/// The recorded privacy page answer with the rules [notices] (`type|uid`, uid 0 for every friend), the feed rule
/// `doing|35` and friend groups 2 and 3 checked.
Map<String, dynamic> _privacy({List<String> notices = const ['post|35', 'friend|0']}) {
  final json = v4Json('g3_privacy_filter_v55.json');
  for (final g in json['groups'] as List) {
    (g as Map)['checked'] = g['gid'] == 2 || g['gid'] == 3 ? 1 : 0;
  }
  Map<String, Object?> row(String key, String field) {
    final uid = int.parse(key.split('|')[1]);
    return {
      'key': key,
      'type': key.split('|')[0],
      'name': key.startsWith('post') ? '话题回复' : key.split('|')[0],
      'uid': uid,
      'username': uid == 0 ? '' : 'ag_low2',
      'target': uid == 0 ? '全部好友' : 'ag_low2',
      'field': 'privacy[$field][$key]',
      'value': '1',
    };
  }

  json['feeds'] = [row('doing|35', 'filter_icon')];
  json['notices'] = [for (final k in notices) row(k, 'filter_note')];
  return json;
}

Map<String, String> _form(String body) => Uri.splitQueryString(body);

bool _isPrivacy(Uri u) => u.path == '/home.php' && u.queryParameters['ac'] == 'privacy';

bool _isIgnore(Uri u) => u.path == '/home.php' && u.queryParameters['op'] == 'ignore';

bool _isBlocklist(Uri u) => u.queryParameters['id'] == 'blockuser:spacecp';

bool _v4(Uri u) => u.queryParameters['tsdmv'] == '4' && u.queryParameters['tsdmapp'] == 'json';

List<(String, String, bool, PrivacyFilterCategory, String, String?)> _boxes(ParsedForumForm form) => [
  for (final c in form.checkboxes) (c.name, c.value, c.checked, c.category, c.key, c.label),
];

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('privacy filter (privacy_filter, schema 55)', () {
    test('the answer and the page of the same account give the same form', () {
      final api = privacyFilterFormFromApi(v4Json('g3_privacy_filter_v55.json'));
      final web = parsePrivacyFilterPage(v4Raw('g3_privacy_filter_web.html'), expectedUid: _uid);
      expect(api.fromApi, isTrue);
      expect(web.fromApi, isFalse);
      expect(api.action, web.action);
      expect(api.fields.toSet(), web.fields.toSet());
      expect(_boxes(api), _boxes(web));
      expect(api.checkboxes, hasLength(8));
    });

    test('the rules carry the type, the member and the text the page prints', () {
      final form = privacyFilterFormFromApi(_privacy());
      expect(form.noteRules.map((e) => (e.key, e.label)), [
        ('post|35', '话题回复 (ag_low2)'),
        ('friend|0', 'friend (全部好友)'),
      ]);
      expect(
        form.checkboxes.where((c) => c.checked).map((c) => (c.category, c.key)),
        containsAll([
          (PrivacyFilterCategory.gid, '2'),
          (PrivacyFilterCategory.gid, '3'),
          (PrivacyFilterCategory.icon, 'doing|35'),
        ]),
      );
    });

    test('a form posting elsewhere, without formhash or with a foreign field is refused', () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (j) => (j['submit'] as Map)['url'] = 'https://evil.test/home.php?mod=spacecp&ac=privacy&op=filter',
        (j) => ((j['submit'] as Map)['fields'] as Map).remove('formhash'),
        (j) => ((j['submit'] as Map)['fields'] as Map).remove('privacy2submit'),
        (j) => ((j['notices'] as List).first as Map)['field'] = 'privacy[other][post|35]',
        (j) => ((j['notices'] as List).first as Map)['field'] = 'privacy[filter_icon][post|35]',
      ]) {
        final json = _privacy()..also(change);
        expect(() => privacyFilterFormFromApi(json), throwsA(anything));
        // The repository turns it into a failure, nothing sent.
      }
    });

    Future<NoticeIgnoreResult> fetch(V4Forum forum) => _repo.fetchRules(v4Client(forum), uid: _uid);

    test('listed: one request of the answer, the rules from it', () async {
      knowV4Status();
      final forum = V4Forum((o) => _isPrivacy(o.uri) && _v4(o.uri) ? V4Reply(_privacy()) : null);
      final result = await fetch(forum);
      expect(result.isSuccess, isTrue);
      expect(result.rules!.map((e) => e.key), ['post|35', 'friend|0']);
      expect(forum.requests, hasLength(1));
      expect(forum.requests.single.uri.queryParameters, allOf(containsPair('nodoc', '1'), isNot(contains('inajax'))));
    });

    test('not listed, or no status: the page as before', () async {
      for (final status in [
        v4Status({'block_pages': <String>[]}),
        v4Status({'v4': null}),
        null,
      ]) {
        TsdmAppApi.reset();
        if (status != null) {
          knowV4Status(status);
        }
        // Without a status the one asked is not answered (a connection error): nothing of 4.0.0 is asked.
        final forum = V4Forum(
          (o) => _isPrivacy(o.uri) && !_v4(o.uri) ? V4Reply(v4Raw('g3_privacy_filter_web.html')) : null,
        );
        expect((await fetch(forum)).isSuccess, isTrue);
        expect(forum.requests.where((r) => _isPrivacy(r.uri)), hasLength(1));
        expect(forum.requests.where((r) => _v4(r.uri)), isEmpty);
      }
    });

    test('the login prompt and another account', () async {
      knowV4Status();
      final guest = V4Forum((o) => V4Reply(v4Json('g3_privacy_filter_guest.json')));
      expect((await fetch(guest)).failure, NoticeIgnoreFailure.notLoggedIn);
      final other = V4Forum((o) => V4Reply({..._privacy(), 'uid': 35}));
      expect((await fetch(other)).failure, NoticeIgnoreFailure.accountMismatch);
    });

    test('an answer that is not the page reads the page', () async {
      knowV4Status();
      final forum = V4Forum((o) {
        if (_v4(o.uri)) {
          return const V4Reply({'ok': 0, 'error': 'internal'});
        }
        return V4Reply(v4Raw('g3_privacy_filter_web.html'));
      });
      expect((await fetch(forum)).isSuccess, isTrue);
      expect(forum.requests, hasLength(2));
    });

    test('removing a rule: one post of the rest, do_success, confirmed by the answer read again', () async {
      knowV4Status();
      var saved = false;
      final forum = V4Forum((o) {
        if (o.method == 'POST') {
          saved = true;
          return V4Reply(_result(kind: 'message', messageKey: 'do_success', message: '操作成功', alert: 'right'));
        }
        return V4Reply(_privacy(notices: saved ? ['friend|0'] : ['post|35', 'friend|0']));
      });
      final result = await _repo.removeRule(
        v4Client(forum),
        uid: _uid,
        rule: const NoticeIgnoreRule(type: 'post', authorId: 35),
      );
      expect(result.isSuccess, isTrue);
      expect(result.rules!.map((e) => e.key), ['friend|0']);
      final posts = [
        for (final (i, r) in forum.requests.indexed)
          if (r.method == 'POST') (r, forum.bodies[i]),
      ];
      expect(posts, hasLength(1));
      final (request, body) = posts.single;
      expect(_v4(request.uri), isTrue);
      expect(request.uri.queryParameters, isNot(contains('nodoc')));
      expect(_form(body), {
        'formhash': 'f1f2f3f4',
        'privacy2submit': 'true',
        'privacy[filter_gid][2]': '2',
        'privacy[filter_gid][3]': '3',
        'privacy[filter_icon][doing|35]': '1',
        'privacy[filter_note][friend|0]': '1',
      });
    });

    test('the forum refusing the save is a failure, not a success, and is not sent again', () async {
      knowV4Status();
      final forum = V4Forum((o) {
        if (o.method == 'POST') {
          return V4Reply(
            _result(kind: 'message', ok: 0, messageKey: 'submitcheck_error', message: '您的请求来路不正确', alert: 'error'),
          );
        }
        return V4Reply(_privacy());
      });
      final result = await _repo.removeRule(
        v4Client(forum),
        uid: _uid,
        rule: const NoticeIgnoreRule(type: 'post', authorId: 35),
      );
      expect(result.failure, NoticeIgnoreFailure.forumError);
      expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1));
    });

    test('do_success that the answer read again does not show stays unconfirmed', () async {
      knowV4Status();
      final forum = V4Forum(
        (o) => o.method == 'POST' ? V4Reply(_result(kind: 'message', messageKey: 'do_success')) : V4Reply(_privacy()),
      );
      final result = await _repo.removeRule(
        v4Client(forum),
        uid: _uid,
        rule: const NoticeIgnoreRule(type: 'post', authorId: 35),
      );
      expect(result.failure, NoticeIgnoreFailure.unknownAfterSubmit);
    });
  });

  group('notice ignore window (small form ignore)', () {
    const target = NoticeIgnoreTarget(type: 'post', authorId: 35);

    test('the answer and the window give the same form, plus the button the website sends', () {
      final answer = smallFormAnswerOfIgnore(v4Json('g3_ignore_form_v4.json'));
      final api = noticeIgnoreFormFromApi(answer, target: target);
      final web = parseNoticeIgnoreForm(v4Raw('g3_ignore_form_web.xml'), target: target, expectedUid: _uid);
      expect(api.action, web.action);
      expect(api.fields.toSet(), {...web.fields, ('feedignoresubmit', 'true')});
    });

    test('the window of a system notice: one choice for everybody', () {
      final answer = smallFormAnswerOfIgnore(v4Json('g3_ignore_form_system_v4.json'));
      final form = noticeIgnoreFormFromApi(answer, target: const NoticeIgnoreTarget(type: 'system', authorId: 0));
      expect(form.fields, contains(('authorid', '0')));
    });

    test('a window of another type, other authors or posting elsewhere is refused', () {
      final json = v4Json('g3_ignore_form_v4.json');
      expect(
        () => noticeIgnoreFormFromApi(
          smallFormAnswerOfIgnore(json),
          target: const NoticeIgnoreTarget(type: 'at', authorId: 35),
        ),
        throwsA(anything),
      );
      expect(
        () => noticeIgnoreFormFromApi(
          smallFormAnswerOfIgnore(json),
          target: const NoticeIgnoreTarget(type: 'post', authorId: 36),
        ),
        throwsA(anything),
      );
      final elsewhere = v4Json('g3_ignore_form_v4.json');
      (elsewhere['submit'] as Map)['url'] = 'home.php?mod=spacecp&ac=common&op=ignore&type=at&id=0';
      expect(() => noticeIgnoreFormFromApi(smallFormAnswerOfIgnore(elsewhere), target: target), throwsA(anything));
    });

    test('adding a rule: the answer, the window, one post with inajax and v4, confirmed by the answer', () async {
      knowV4Status();
      var saved = false;
      final forum = V4Forum((o) {
        if (_isIgnore(o.uri)) {
          if (o.method == 'POST') {
            saved = true;
            return V4Reply(_result(messageKey: 'do_success', message: '操作成功', alert: 'right'));
          }
          return V4Reply(v4Json('g3_ignore_form_v4.json'));
        }
        return V4Reply(_privacy(notices: saved ? ['friend|0', 'post|0'] : ['friend|0']));
      });
      final result = await _repo.addRule(v4Client(forum), uid: _uid, target: target, everybody: true);
      expect(result.isSuccess, isTrue, reason: '${result.failure}');
      final window = forum.requests.firstWhere((r) => _isIgnore(r.uri) && r.method == 'GET').uri.queryParameters;
      expect(window, allOf(containsPair('tsdmform', '1'), containsPair('tsdmv', '4'), containsPair('inajax', '1')));
      final i = forum.requests.indexWhere((r) => r.method == 'POST');
      expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1));
      expect(forum.requests[i].uri.queryParameters, allOf(containsPair('inajax', '1'), containsPair('tsdmv', '4')));
      expect(_form(forum.bodies[i]), allOf(containsPair('authorid', '0'), containsPair('ignoresubmit', 'true')));
    });

    test('the window refused by the forum, the guest, another account', () async {
      knowV4Status();
      Future<NoticeIgnoreFailure?> add(Map<String, dynamic> window) async {
        final forum = V4Forum((o) => _isIgnore(o.uri) ? V4Reply(window) : V4Reply(_privacy(notices: [])));
        final result = await _repo.addRule(v4Client(forum), uid: _uid, target: target, everybody: false);
        expect(forum.requests.where((r) => r.method == 'POST'), isEmpty);
        return result.failure;
      }

      expect(await add(v4Json('g3_ignore_form_guest.json')), NoticeIgnoreFailure.notLoggedIn);
      expect(await add({...v4Json('g3_ignore_form_v4.json'), 'uid': 35}), NoticeIgnoreFailure.accountMismatch);
      expect(
        await add({
          'ok': 0,
          'error': 'message',
          'message': '没有权限',
          'message_key': 'no_privilege',
          'login': 0,
          'uid': _uid,
          'form': 'ignore',
        }),
        NoticeIgnoreFailure.forumError,
      );
    });

    test('the answer of 3.9.0 (the window as a page, without tsdmv) reads the web window', () async {
      knowV4Status();
      final forum = V4Forum((o) {
        if (_isIgnore(o.uri)) {
          if (o.method == 'POST') {
            return V4Reply(_result(messageKey: 'do_success'));
          }
          return o.uri.queryParameters.containsKey('tsdmform')
              ? V4Reply(v4Json('g3_ignore_form_nov4.json'))
              : V4Reply(v4Raw('g3_ignore_form_web.xml'));
        }
        return V4Reply(_privacy(notices: []));
      });
      await _repo.addRule(v4Client(forum), uid: _uid, target: target, everybody: false);
      final windows = forum.requests.where((r) => _isIgnore(r.uri) && r.method == 'GET').toList();
      expect(windows, hasLength(2));
      expect(windows.last.uri.queryParameters, isNot(contains('tsdmform')));
      final i = forum.requests.indexWhere((r) => r.method == 'POST');
      expect(_v4(forum.requests[i].uri), isFalse, reason: 'a form of the web window goes back as before');
      expect(_form(forum.bodies[i]), containsPair('authorid', '35'));
    });

    test('ignore not listed in forms: the web window as before', () async {
      knowV4Status(
        v4Status({
          'forms': <String>['rate'],
          'block_pages': <String>[],
        }),
      );
      final forum = V4Forum((o) {
        if (_isIgnore(o.uri)) {
          return o.method == 'GET' ? V4Reply(v4Raw('g3_ignore_form_web.xml')) : const V4Reply('');
        }
        return V4Reply(v4Raw('g3_privacy_filter_web.html'));
      });
      await _repo.addRule(v4Client(forum), uid: _uid, target: target, everybody: false);
      expect(forum.requests.where((r) => _v4(r.uri) || r.uri.queryParameters.containsKey('tsdmform')), isEmpty);
      expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1));
    });
  });

  group('website blacklist (blockuser, schema 56)', () {
    Map<String, dynamic> list({List<int> uids = const [35]}) {
      final json = v4Json('g3_blockuser_v56_empty.json');
      json['count'] = uids.length;
      json['list'] = [
        for (final uid in uids)
          {'uid': uid, 'username': uid == 77 ? '' : 'ag_low2', 'gone': uid == 77 ? 1 : 0, 'dateline': 1700000000},
      ];
      return json;
    }

    test('the answer and the page of the same account give the same list', () {
      final api = websiteBlocklistDocumentFromApi(v4Json('g3_blockuser_v56_empty.json'), expectedUid: _uid);
      final web = parseWebsiteBlocklistDocument(v4Raw('g3_blockuser_web_empty.html'), expectedUid: _uid);
      expect(api.fromApi, isTrue);
      String shape(WebsiteBlocklistDocument d) =>
          '${[for (final r in d.list.rows) r.uid]} ${d.list.complete} ${d.list.quota?.used} ${d.list.quota?.limit}';
      expect(shape(api), shape(web));
      expect(api.list.complete, isTrue);
    });

    test('the lookup of the answer and of the page find the same member and the same add form', () {
      final api = websiteBlocklistDocumentFromApi(
        v4Json('g3_blockuser_v56_lookup.json'),
        expectedUid: _uid,
        lookupUid: 35,
      );
      final web = parseWebsiteBlocklistDocument(
        v4Raw('g3_blockuser_web_lookup.html'),
        expectedUid: _uid,
        lookupUid: 35,
      );
      final a = api.lookup!;
      final w = web.lookup!;
      expect((a.uid, a.username, a.alreadyListed, a.canAdd), (w.uid, w.username, w.alreadyListed, w.canAdd));
      expect(a.canAdd, isTrue);
      expect(api.addPayload(35), web.addPayload(35));
      expect(api.actionOf(add: true, uid: 35), web.actionOf(add: true, uid: 35));
    });

    test('the rows: a member gone is shown by uid, each removable with its own form', () {
      final doc = websiteBlocklistDocumentFromApi(list(uids: [35, 77]), expectedUid: _uid);
      expect(doc.list.rows.map((e) => (e.uid, e.displayName, e.removable)), [
        (35, 'ag_low2', true),
        (77, 'UID 77', true),
      ]);
      expect(doc.removePayload(77), {'formhash': 'f1f2f3f4', 'blockuserdel': 'yes', 'buid': '77'});
      expect(doc.list.complete, isTrue);
      expect(websiteBlocklistDocumentFromApi({...list(), 'pages': 2}, expectedUid: _uid).list.complete, isFalse);
      expect(websiteBlocklistDocumentFromApi({...list(), 'count': 3}, expectedUid: _uid).list.complete, isFalse);
    });

    test('a row of the account itself or twice, a form posting elsewhere', () {
      expect(
        () => websiteBlocklistDocumentFromApi(list(uids: [_uid]), expectedUid: _uid),
        throwsA(isA<WebsiteBlocklistRejected>()),
      );
      expect(
        () => websiteBlocklistDocumentFromApi(list(uids: [35, 35]), expectedUid: _uid),
        throwsA(isA<WebsiteBlocklistRejected>()),
      );
      final elsewhere = list();
      (elsewhere['remove'] as Map)['url'] = 'home.php?mod=spacecp&ac=plugin&id=other:spacecp';
      expect(websiteBlocklistDocumentFromApi(elsewhere, expectedUid: _uid).list.rows.single.removable, isFalse);
      final more = list();
      ((more['remove'] as Map)['fields'] as Map)['handlekey'] = 'bu';
      expect(
        websiteBlocklistDocumentFromApi(more, expectedUid: _uid).removePayload(35),
        {'formhash': 'f1f2f3f4', 'blockuserdel': 'yes', 'handlekey': 'bu', 'buid': '35'},
        reason: 'a field a later plugin adds goes back as served',
      );
    });

    test('the lookup errors: self and not a uid, not found, listed already, full', () {
      WebsiteBlocklistFailure? failureOf(String file, int lookup, [Map<String, Object?> change = const {}]) {
        try {
          final doc = websiteBlocklistDocumentFromApi(
            {...v4Json(file), ...change},
            expectedUid: _uid,
            lookupUid: lookup,
          );
          return doc.lookup == null ? WebsiteBlocklistFailure.notFound : null;
        } on WebsiteBlocklistRejected catch (e) {
          return e.failure;
        }
      }

      expect(failureOf('g3_blockuser_v56_self.json', _uid), WebsiteBlocklistFailure.targetMismatch);
      expect(failureOf('g3_blockuser_v56_bad.json', 1), WebsiteBlocklistFailure.targetMismatch);
      expect(failureOf('g3_blockuser_v56_notfound.json', 999999), WebsiteBlocklistFailure.notFound);
      expect(
        failureOf('g3_blockuser_v56_empty.json', 35, {
          'error': {'code': 'full', 'uid': 35, 'username': 'ag_low2'},
          'can_add': 0,
        }),
        WebsiteBlocklistFailure.forumError,
      );
      final dup = websiteBlocklistDocumentFromApi(
        {
          ...list(),
          'error': {'code': 'dup', 'uid': 35, 'username': 'ag_low2'},
        },
        expectedUid: _uid,
        lookupUid: 35,
      );
      expect((dup.lookup!.alreadyListed, dup.lookup!.canAdd, dup.addPayload(35)), (true, false, null));
      final confirmOther = {
        ...v4Json('g3_blockuser_v56_lookup.json'),
        'confirm': {'uid': 36, 'username': 'x', 'avatar': ''},
      };
      expect(
        () => websiteBlocklistDocumentFromApi(confirmOther, expectedUid: _uid, lookupUid: 35),
        throwsA(isA<WebsiteBlocklistRejected>()),
      );
    });

    test('adding: the lookup answer, one post with v4, the redirect, confirmed by the list read again', () async {
      knowV4Status();
      var added = false;
      final forum = V4Forum((o) {
        if (o.method == 'POST') {
          added = true;
          return V4Reply(
            _result(
              kind: 'redirect',
              url: 'home.php?mod=spacecp&ac=plugin&id=blockuser:spacecp&bu_msg=added&bu_uid=35',
            ),
          );
        }
        if (o.uri.queryParameters.containsKey('bu_q')) {
          return V4Reply(v4Json('g3_blockuser_v56_lookup.json'));
        }
        return V4Reply(added ? list() : v4Json('g3_blockuser_v56_empty.json'));
      });
      final result = await _blocklist.add(v4Client(forum), uid: _uid, target: 35, expectedName: 'ag_low2');
      expect(result.isSuccess, isTrue, reason: '${result.error}');
      expect(result.list!.contains(35), isTrue);
      final i = forum.requests.indexWhere((r) => r.method == 'POST');
      expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1));
      expect(_v4(forum.requests[i].uri), isTrue);
      expect(_form(forum.bodies[i]), {'formhash': 'f1f2f3f4', 'blockuseradd': 'yes', 'buid': '35'});
      expect(forum.requests.every((r) => _isBlocklist(r.uri)), isTrue);
    });

    test('adding refused: the page drawn again with its error, never a success', () async {
      knowV4Status();
      final forum = V4Forum((o) {
        if (o.method == 'POST') {
          return V4Reply({
            ...v4Json('g3_blockuser_v56_empty.json'),
            'message_key': '',
            'error': {'code': 'full', 'uid': 35, 'username': 'ag_low2'},
          });
        }
        if (o.uri.queryParameters.containsKey('bu_q')) {
          return V4Reply(v4Json('g3_blockuser_v56_lookup.json'));
        }
        return V4Reply(v4Json('g3_blockuser_v56_empty.json'));
      });
      final result = await _blocklist.add(v4Client(forum), uid: _uid, target: 35);
      expect(result.error?.failure, WebsiteBlocklistFailure.forumError);
      expect(result.sent, isTrue);
      expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1));
    });

    test('removing: one post with v4, confirmed by the complete list read again', () async {
      knowV4Status();
      var removed = false;
      final forum = V4Forum((o) {
        if (o.method == 'POST') {
          removed = true;
          return V4Reply(
            _result(kind: 'redirect', url: 'home.php?mod=spacecp&ac=plugin&id=blockuser:spacecp&bu_msg=removed'),
          );
        }
        return V4Reply(removed ? v4Json('g3_blockuser_v56_empty.json') : list());
      });
      final result = await _blocklist.remove(v4Client(forum), uid: _uid, target: 35);
      expect(result.isSuccess, isTrue, reason: '${result.error}');
      final i = forum.requests.indexWhere((r) => r.method == 'POST');
      expect(_form(forum.bodies[i]), {'formhash': 'f1f2f3f4', 'blockuserdel': 'yes', 'buid': '35'});
    });

    test('the answer of the write of another account is refused', () {
      expect(
        websiteBlocklistWriteErrorOf(_result(kind: 'redirect', uid: 35), uid: _uid)?.failure,
        WebsiteBlocklistFailure.accountMismatch,
      );
      expect(websiteBlocklistWriteErrorOf(_result(kind: 'redirect'), uid: _uid), isNull);
      expect(
        websiteBlocklistWriteErrorOf(_result(kind: 'message', ok: 0, login: 1, uid: 0), uid: _uid)?.failure,
        WebsiteBlocklistFailure.notLoggedIn,
      );
    });

    test('not listed in block_pages: the page as before; the guest prompt', () async {
      knowV4Status(
        v4Status({
          'block_pages': <String>['privacy_filter'],
        }),
      );
      final web = V4Forum((o) => _v4(o.uri) ? null : V4Reply(v4Raw('g3_blockuser_web_empty.html')));
      expect((await _blocklist.fetchList(v4Client(web), uid: _uid)).isRight(), isTrue);
      expect(web.unexpected, isEmpty);
      TsdmAppApi.reset();
      knowV4Status();
      final guest = V4Forum((o) => V4Reply(v4Json('g3_blockuser_guest.json')));
      final failed = await _blocklist.fetchList(v4Client(guest), uid: _uid);
      expect(failed.getLeft().toNullable()?.failure, WebsiteBlocklistFailure.notLoggedIn);
    });
  });
}

/// The ignore window answer [json] as the small form it is.
SmallFormFields smallFormAnswerOfIgnore(Map<String, dynamic> json) =>
    smallFormAnswerOf(jsonDecode(jsonEncode(json)), SmallFormKind.ignore)! as SmallFormFields;

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
