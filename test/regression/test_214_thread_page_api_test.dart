/// The forum's app API, plugin 2.1.0: the thread page answered as structured fields (`schema: 3`).
///
/// The page (`forum.php?mod=viewthread&tid=…&page=…`, with `ordertype`, `authorid`, or the `findpost` redirect) is
/// asked in the JSON mode as before, but an answer of plugin 2.1.0 carries every field the app reads: the thread, the
/// forum and the breadcrumbs, the pagination, the reply form, the medal menus and the floors, each with its author,
/// group, last edit, actions and urls, rate table and poll, while the floor's content (`body_html`) and author column
/// (`author_html`) stay the html of the page. The app builds [ThreadPageInfo] from them ([threadPageFromApi],
/// [Post.fromApi]) and never parses the `document` of such an answer. An older plugin's answer (no `schema`), the
/// antitheft challenge and the thread cache a guest is served (`error: unknown` with a `document`) and the web page
/// are parsed as before ([parseThreadDocument]).
///
/// The fixtures `thread_v3_*.json` are answers of the test forum (Discuz X5.0.2 with plugin 2.1.0, 2026-10-20) with
/// their `document` and `head` removed: the schema 3 path must not need them. `thread_v3_plain.json` keeps a
/// `document` on purpose, a garbage one, to prove that path never reads it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The page built from the structured answer [name], asked for page [pageNumber].
ThreadPageInfo _page(String name, {int pageNumber = 1}) => threadPageFromApi(_json(name), pageNumber);

/// The floor [pid] of the answer [name], as the answer gives it.
Map<String, dynamic> _floor(String name, int pid) =>
    (_json(name)['posts'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['pid'] == pid);

/// The floor [pid] of the page built from [name].
Post _post(String name, int pid) => _page(name).postList.firstWhere((e) => e.postID == '$pid');

/// The thread cache a guest is served, and the antitheft challenge: `unknown` answers with a document.
Map<String, Object?> _unknown(String document) => {
  'ok': 0,
  'error': 'unknown',
  'formhash': 'abcd1234',
  'head': '<link href="forum.php?mod=viewthread&amp;tid=9199345" rel="canonical" />',
  'document': document,
};

/// A forum answering every request with [body] served as [contentType].
final class _Forum implements HttpClientAdapter {
  _Forum(this.body, {this.contentType = 'application/json; charset=utf-8'});

  final String body;
  final String contentType;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The repository of a forum answering [body].
ThreadRepository _repository(String body, {String contentType = 'application/json; charset=utf-8'}) {
  final forum = _Forum(body, contentType: contentType);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return ThreadRepository();
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('threadApiAnswerOf tells the structured answers apart', () {
    test('schema 3 and later: the structured page, and the message of the plugin (login tells it)', () {
      for (final name in [
        'plain',
        'plain_guest',
        'long_p1',
        'long_p2',
        'long_reverse',
        'long_author',
        'rated',
        'edited',
        'paid',
        'hide',
        'denied',
        'findpost',
        'poll',
        'typed',
        'closed',
        'moderated',
        'rush_deleted',
        'overpage',
      ]) {
        expect(threadApiAnswerOf(_raw('thread_v3_$name.json')), isNotNull, reason: name);
        // The fixtures are the answers of plugin 2.8.0 (schema 15; the file names keep the v3 of 2.1.0).
        expect(_json('thread_v3_$name.json')['schema'], 15, reason: name);
      }
      expect(threadApiAnswerOf(_json('thread_v3_plain.json')), isNotNull, reason: 'decoded by dio already');
      // Plugin 2.1.0 answered schema 3: still a structured page.
      expect(threadApiAnswerOf(jsonEncode({..._json('thread_v3_plain.json'), 'schema': 3})), isNotNull);
      expect(threadApiAnswerOf(_raw('thread_v3_denied_guest.json')), isNotNull);
      expect(threadApiAnswerOf('{"ok":0,"error":"message","message":"x","schema":3}'), isNotNull);
    });

    test('everything else is read from its document as before', () {
      // An older plugin: no schema, its message without login.
      expect(threadApiAnswerOf(_raw('thread_plain.json')), isNull);
      expect(threadApiAnswerOf(_raw('thread_denied.json')), isNull);
      expect(threadApiAnswerOf('{"ok":1,"type":"thread","schema":2,"document":""}'), isNull);
      expect(threadApiAnswerOf('{"ok":0,"error":"internal"}'), isNull);
      // The antitheft challenge and the thread cache of a guest: `unknown`, whatever the plugin's version.
      expect(threadApiAnswerOf(jsonEncode(_unknown(''))), isNull);
      expect(threadApiAnswerOf(jsonEncode({..._unknown('<div id="postlist"></div>'), 'schema': 3})), isNull);
      expect(threadApiAnswerOf('<html><body>page</body></html>'), isNull);
      expect(threadApiAnswerOf(''), isNull);
      expect(threadApiAnswerOf(null), isNull);
    });
  });

  group('threadPageFromApi builds the page from the fields', () {
    test('a thread page: every field', () {
      final page = _page('thread_v3_plain.json');
      expect(page.tid, '9199345');
      expect(page.title, '[Rulebot multi fixture 20260930-101846] FID2 版規問答測試');
      expect(page.fid, 2);
      expect(page.forumName, '📢 公告 & 新手報到');
      expect(page.currentPage, 1);
      expect(page.totalPages, 1);
      expect(page.havePermission, isTrue);
      expect(page.permissionDeniedMessage, isNull);
      expect(page.needLogin, isFalse);
      expect(page.threadSoftClosed, isFalse);
      expect(page.threadClosed, isFalse, reason: 'reply.allowed 1');
      expect(page.threadType, isNull, reason: 'typeid 0');
      expect(page.isDraft, isFalse);
      expect(page.latestModAct, isNull, reason: 'modact empty');
      expect(page.viewCount, 100);
      expect(page.replyCount, 8);

      // The breadcrumbs from the group down to the forum, the thread not among them, linked as the page links them.
      expect(page.breadcrumbs.map((e) => e.description), ['🏠 論壇大廳', '📢 公告 & 新手報到']);
      expect(page.breadcrumbs.map((e) => '${e.link}'), [
        '$baseUrl/forum.php?gid=1',
        '$baseUrl/forum.php?mod=forumdisplay&fid=2',
      ]);

      // The fast reply form: the hidden fields and the answer's form hash.
      final reply = page.replyParameters!;
      expect(reply.fid, '2');
      expect(reply.tid, '9199345');
      expect(reply.postTime, '1700000000');
      expect(reply.formHash, 'f1f2f3f4');
      expect(reply.subject, '');

      // The medal menus of the page, one per menu.
      expect(page.postMedals, hasLength((_json('thread_v3_plain.json')['menus_html'] as List).length));
      expect(page.postMedals.map((e) => e.id).toSet(), hasLength(page.postMedals.length));

      // The floors in the forum's order: the sticky reply (position 8) right after the first floor.
      expect(page.postList.map((e) => e.postID), [
        '3938',
        '3954',
        '3940',
        '3942',
        '3950',
        '3951',
        '3952',
        '3953',
        '3955',
      ]);
      expect(page.postList.map((e) => e.postFloor), [1, 8, 2, 3, 4, 5, 6, 7, 9]);
      expect(page.postList.every((e) => e.page == 1), isTrue);
    });

    test('the garbage document of the fixture is never parsed', () {
      final json = _json('thread_v3_plain.json');
      expect(json['document'], contains('GARBAGE'));
      final page = _page('thread_v3_plain.json');
      expect(page.postList.map((e) => e.postID), isNot(contains('1')));
      expect(page.postList.every((e) => !e.data.contains('GARBAGE')), isTrue);
    });

    test('a typed thread: the type beside the title', () {
      final page = _page('thread_v3_typed.json');
      expect(page.threadType?.name, '版主公告');
      expect(page.threadType?.typeID, '4');
    });

    test('a closed thread: the lock, no reply, the moderation sentence', () {
      final page = _page('thread_v3_closed.json');
      expect(page.threadSoftClosed, isTrue);
      expect(page.threadClosed, isTrue, reason: 'a member, reply.allowed 0');
      // The sentence is live data (the last moderation of the thread, its time relative to the fetch): the field as
      // the page prints it.
      final modAct = (_json('thread_v3_closed.json')['thread'] as Map<String, dynamic>)['modact'] as String;
      expect(modAct, startsWith('本主题由 '));
      expect(page.latestModAct, modAct);
      expect(page.replyParameters, isNotNull, reason: 'the forum still prints the form (fastpost 1)');
      expect(page.postList.every((e) => e.replyAction == null), isTrue, reason: 'can.reply 0 on every floor');
      expect(page.postList.every((e) => e.rateAction == null), isTrue);
    });

    test('a thread the answer does not name keeps the thread asked for', () {
      final json = _json('thread_v3_plain.json');
      final thread = json['thread'] as Map<String, dynamic>;
      for (final bad in [
        {...thread}..remove('tid'),
        {...thread, 'tid': 0},
        {...thread, 'tid': 'x'},
      ]) {
        final page = threadPageFromApi({...json, 'thread': bad}, 1);
        expect(page.tid, isNull, reason: '$bad');
        expect(page.replyParameters, isNull, reason: 'no thread to reply to');
        expect(page.postList, hasLength(9));
      }
      final noForum = threadPageFromApi({
        ...json,
        'thread': {...thread, 'fid': 0},
      }, 1);
      expect(noForum.fid, isNull);
      expect(noForum.replyParameters, isNull);
      expect(noForum.postList.every((e) => e.reportTarget == null), isTrue, reason: 'no forum for the report');
    });

    test('closed for a member when the forum prints no fast reply form, or one without its textarea', () {
      final json = _json('thread_v3_plain.json');
      final reply = json['reply'] as Map<String, dynamic>;
      expect(reply, containsPair('fastpost_allowed', 1));
      ThreadPageInfo withReply(Map<String, dynamic> r) => threadPageFromApi({
        ...json,
        'reply': {...reply, ...r},
      }, 1);
      expect(withReply({}).threadClosed, isFalse);
      expect(withReply({'allowed': 0}).threadClosed, isTrue);
      expect(withReply({'fastpost': 0}).threadClosed, isTrue);
      expect(withReply({'fastpost': 0}).replyParameters, isNull);
      final noTextarea = withReply({'fastpost_allowed': 0});
      expect(noTextarea.threadClosed, isTrue, reason: 'a newbie: the form without its textarea');
      expect(noTextarea.replyParameters, isNotNull, reason: 'the hidden fields are there, as the page parser reads');
      // A guest is told to log in instead.
      expect(
        threadPageFromApi({
          ...json,
          'uid': 0,
          'reply': {...reply, 'fastpost_allowed': 0},
        }, 1).threadClosed,
        isFalse,
      );
    });

    test('a moderated thread: the moderation sentence', () {
      final page = _page('thread_v3_moderated.json');
      // The forum prints the moderation time relative to now ("N 小时前"), so the fixture carries whatever it was when refreshed.
      expect(page.latestModAct, matches(RegExp(r'^本主题由 管理团队 于 .+ 打开$')));
      expect(page.threadClosed, isFalse);
    });

    test('a guest: never closed, no report, the poll of nobody', () {
      final page = _page('thread_v3_plain_guest.json');
      expect(_json('thread_v3_plain_guest.json')['uid'], 0);
      expect(page.threadClosed, isFalse, reason: 'reply.allowed 0, but a guest is told to log in instead');
      expect(page.replyParameters, isNotNull);
      expect(page.postList.map((e) => e.postID), _page('thread_v3_plain.json').postList.map((e) => e.postID));
      expect(page.postList.every((e) => e.reportTarget == null), isTrue);
      expect(page.postList.every((e) => e.editUrl == null), isTrue);
    });

    test('the second page, the reversed order, the author only', () {
      final p2 = _page('thread_v3_long_p2.json');
      expect(p2.currentPage, 2);
      expect(p2.totalPages, 31);
      expect(p2.postList.map((e) => e.postFloor), [11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
      expect(p2.postList.every((e) => e.page == 2), isTrue);
      expect(p2.postList.every((e) => e.shareLink!.contains('goto=findpost&ptid=1120&pid=${e.postID}')), isTrue);

      final reversed = _page('thread_v3_long_reverse.json');
      expect(_json('thread_v3_long_reverse.json')['ordertype'], 1);
      expect(reversed.currentPage, 1);
      expect(reversed.totalPages, 31);
      expect(reversed.postList.first.postFloor, 1, reason: 'the first floor stays first');
      expect(reversed.postList.map((e) => e.postFloor).skip(1), [302, 301, 300, 299, 298, 297, 296, 295, 294]);

      final author = _page('thread_v3_long_author.json');
      expect(_json('thread_v3_long_author.json')['authorid'], 31);
      expect(author.totalPages, 1);
      expect(author.postList.map((e) => e.postID), ['4043']);
      expect(author.postList.single.postFloor, 1, reason: 'the position the forum numbers the filtered list with');
      expect(author.postList.single.author.uid, '31');
    });

    test('a page past the last one: the forum answers the last page', () {
      final page = _page('thread_v3_overpage.json', pageNumber: 99);
      expect(page.currentPage, 31);
      expect(page.totalPages, 31);
      expect(page.postList.map((e) => e.postFloor), [301, 302]);
      expect(page.postList.every((e) => e.page == 31), isTrue);
    });

    test('a rush thread: the placeholder of a deleted floor is left out, as the page parser leaves it out', () {
      final json = _json('thread_v3_rush_deleted.json');
      final deleted = (json['posts'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['deleted'] == 1);
      expect(deleted['pid'], 3208);
      expect(deleted['urls'], isNull);
      expect(deleted['group'], isNull);
      final page = _page('thread_v3_rush_deleted.json');
      expect(page.postList.map((e) => e.postID), ['3206', '3207', '3209']);
      expect(page.postList.map((e) => e.postFloor), [1, 2, 4]);
      expect(page.replyCount, 3);

      // Built on its own, the placeholder is an empty floor, nothing thrown on the null fields.
      final post = Post.fromApi(deleted, tid: '9199091', fid: 6, viewerUid: 35, page: 1);
      expect(post.postID, '3208');
      expect(post.postFloor, 3);
      expect(post.author.uid, isNull);
      expect(post.author.avatarUrl, isNull);
      expect(post.publishTime, isNull);
      expect(post.data, '');
      expect(post.shareLink, isNull);
      expect(post.replyAction, isNull);
      expect(post.rateAction, isNull);
      expect(post.editUrl, isNull);
      expect(post.reportTarget, isNull);
      expect(post.rate, isNull);
      expect(post.poll, isNull);
      expect(post.locked, isEmpty);
      expect(post.signature, isNull);
    });

    test('the findpost redirect: the page the floor is on', () {
      final page = _page('thread_v3_findpost.json');
      expect(page.tid, '1125');
      expect(page.currentPage, 1);
      expect(page.totalPages, 2);
      expect(page.postList.map((e) => e.postID), contains('200010'));
    });

    test('the login prompt of a guest, and the message of a member without permission', () {
      final login = _page('thread_v3_denied_guest.json', pageNumber: 2);
      expect(login.needLogin, isTrue);
      expect(login.havePermission, isTrue);
      expect(login.permissionDeniedMessage, isNull);
      expect(login.postList, isEmpty);
      expect(login.tid, isNull);
      expect(login.replyParameters, isNull);
      expect(login.currentPage, 2);
      expect(login.totalPages, 2);
      expect(login.threadClosed, isTrue, reason: 'no reply form, as on the web page');

      final denied = threadPageFromApi({
        'ok': 0,
        'error': 'message',
        'message': '抱歉，本帖要求阅读权限高于 <b>20</b> 才能浏览',
        'login': 0,
        'schema': 3,
      }, 1);
      expect(denied.needLogin, isFalse);
      expect(denied.havePermission, isFalse);
      expect(denied.permissionDeniedMessage?.innerText, '抱歉，本帖要求阅读权限高于 <b>20</b> 才能浏览');
      expect(denied.permissionDeniedMessage?.querySelector('b'), isNull, reason: 'text, not html');
      expect(denied.postList, isEmpty);
    });
  });

  group('Post.fromApi builds the floor from the fields', () {
    test('the first floor: every field', () {
      final post = _post('thread_v3_plain.json', 3938);
      final floor = _floor('thread_v3_plain.json', 3938);
      expect(post.postID, '3938');
      expect(post.postFloor, 1);
      expect(post.author.name, 'ag_admin');
      expect(post.author.uid, '32');
      expect(post.author.url, '$baseUrl/home.php?mod=space&uid=32');
      expect(post.author.avatarUrl, '$baseUrl/data/avatar/noavatar.svg');
      // The forum's wall clock (+8, the answer's `timeoffset`), as the page prints it, whatever the device's zone.
      expect(post.publishTime, tsdmAppWallClockTime(1790763526, 8));
      // As it is but the comments, shown on their own (test 831).
      expect(post.data, splitPostComments(floor['body_html'] as String, post.postID).data, reason: 'the content html');
      expect(post.data, contains('id="postmessage_3938"'));
      expect(post.shareLink, '$baseUrl/forum.php?mod=viewthread&tid=9199345');
      expect(post.page, 1);
      expect(post.isDraft, isFalse);
      expect(post.locked, isEmpty);
      expect(post.poll, isNull);
      expect(post.lastEditUsername, isNull);
      expect(post.lastEditTime, isNull);
      expect(post.packetUrl, isNull);
      expect(post.packetAllTaken, isFalse);

      // The actions the forum allows: reply (can.reply 1), report (can.report 1); not rate, not edit.
      expect(
        post.replyAction,
        '$baseUrl/forum.php?mod=post&action=reply&fid=2&tid=9199345&reppost=3938&extra=page%3D1&page=1',
      );
      expect(post.rateAction, isNull, reason: 'can.rate 0');
      expect(post.editUrl, isNull, reason: 'can.edit 0');
      final report = post.reportTarget!;
      expect(report.pid, 3938);
      expect(report.tid, 9199345);
      expect(report.fid, 2);
      expect(report.viewerUid, 35);

      // The rate table.
      final rate = post.rate!;
      expect(rate.userCount, 1);
      expect(rate.detailUrl, '$baseUrl/forum.php?mod=misc&action=viewratings&tid=9199345&pid=3938');
      expect(rate.attrList, ['威望', '理由']);
      expect(rate.rateStatus, '威望 +2');
      expect(rate.records, hasLength(1));
      expect(rate.records.single.user.name, 'ag_low');
      expect(rate.records.single.user.uid, '31');
      expect(rate.records.single.user.url, '$baseUrl/home.php?mod=space&uid=31');
      expect(rate.records.single.user.avatarUrl, startsWith('https://'), reason: 'an external avatar, as it is');
      expect(rate.records.single.attrValueList, ['+ 2', '']);

      // The author column: what the test forum's default template puts there (no TSDM stat bar: no profile).
      expect(post.checkin, isNotNull, reason: 'div.qdsmile');
      expect(post.userBriefProfile, isNull);
      expect(post.badge, isNull);
      expect(post.signature, isNull);
    });

    test('a reply of the viewer: editable, not reportable; the sticky reply; a reply hidden from the viewer', () {
      final own = _post('thread_v3_plain.json', 3942);
      expect(own.author.uid, '35');
      expect(own.editUrl, '$baseUrl/forum.php?mod=post&action=edit&fid=2&tid=9199345&pid=3942&page=1');
      expect(own.reportTarget, isNull, reason: 'can.report 0: own post');
      expect(own.postFloor, 3);
      expect(own.rate?.records.single.attrValueList, ['+ 5', '帖內倍數']);

      final sticky = _page('thread_v3_plain.json').postList[1];
      expect(sticky.postID, '3954');
      expect(sticky.postFloor, 8);
      expect(sticky.shareLink, '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199345&pid=3954');
      expect(sticky.replyAction, isNotNull, reason: 'can.reply 1');
      expect(sticky.reportTarget?.pid, 3954);
      expect(sticky.data, contains('https://www.tsdm39.com/home.php?mod=space&amp;uid=35'));

      // "回帖仅作者可见": a reply hidden from the viewer has no content, no rate and no reply, as the page shows it.
      final hidden = _post('thread_v3_plain.json', 3940);
      expect(hidden.data, isNot(contains('id="postmessage_3940"')));
      expect(hidden.rate, isNull);
      expect(hidden.replyAction, isNull, reason: 'can.reply 0');
      expect(hidden.reportTarget?.pid, 3940);
    });

    test('the rate table with a reason, and the totals', () {
      final post = _post('thread_v3_rated.json', 200001);
      final rate = post.rate!;
      expect(rate.userCount, 1);
      expect(rate.attrList, ['威望', '理由']);
      expect(rate.rateStatus, '威望 +1');
      expect(rate.records.single.user.name, 'ag_admin');
      expect(rate.records.single.user.uid, '32');
      expect(rate.records.single.attrValueList, ['+ 1', 'ratenotify 驗收：預設通知']);
      expect(_post('thread_v3_rated.json', 200007).rate, isNull);
      expect(_post('thread_v3_rated.json', 200010).rate?.rateStatus, '威望 +20');
      expect(_post('thread_v3_rated.json', 200010).rate?.records.single.attrValueList, ['+ 20', 'creditlist 驗收']);

      // Several columns, a negative value: printed as the page prints them.
      final two = Post.fromApi(
        {
          ..._floor('thread_v3_rated.json', 200001),
          'rate': {
            'count': 2,
            'columns': ['威望', '天使币'],
            'totals': [80, -3],
            'records': [
              {
                'uid': 1107,
                'username': 'Mallory',
                'avatar': '',
                'values': [80, 0],
                'reason': 'well',
              },
              {
                'uid': 1108,
                'username': 'Trent',
                'avatar': './data/avatar/x.jpg',
                'values': [0, -3],
                'reason': '',
              },
            ],
          },
        },
        tid: '1125',
        fid: 6,
        viewerUid: 35,
        page: 1,
      ).rate!;
      expect(two.userCount, 2);
      expect(two.attrList, ['威望', '天使币', '理由']);
      expect(two.rateStatus, '威望 +80 天使币 -3');
      expect(two.records.map((e) => e.attrValueList), [
        ['+ 80', '0', 'well'],
        ['0', '-3', ''],
      ]);
      expect(two.records.first.user.avatarUrl, isNull);
      expect(two.records.last.user.avatarUrl, '$baseUrl/data/avatar/x.jpg');
    });

    test('the last edit', () {
      final post = _post('thread_v3_edited.json', 4436);
      expect(post.lastEditUsername, 'ag_mid');
      expect(post.lastEditTime, '2026-10-16 02:02');
      expect(post.data, contains('pstatus'), reason: "the content keeps the page's edit line");

      // The time as the forum printed it, whatever its shape; none when the plugin read neither name nor time.
      Post withEdit(Map<String, dynamic> lastedit) => Post.fromApi(
        {..._floor('thread_v3_edited.json', 4436), 'lastedit': lastedit},
        tid: '9199773',
        fid: 11,
        viewerUid: 35,
        page: 1,
      );
      final relative = withEdit({'username': 'ag_mid', 'time': '昨天 12:00', 'text': 'x'});
      expect(relative.lastEditUsername, 'ag_mid');
      expect(relative.lastEditTime, '昨天 12:00');
      final seconds = withEdit({'username': 'a b', 'time': '2026-10-16 02:02:33'});
      expect(seconds.lastEditUsername, 'a b');
      expect(seconds.lastEditTime, '2026-10-16 02:02:33');
      for (final unread in [
        {'username': '', 'time': '', 'text': '本帖最后由 x 编辑'},
        {'username': 'ag_mid', 'time': ''},
        {'username': '', 'time': '2026-10-16 02:02'},
      ]) {
        final post = withEdit(unread);
        expect(post.lastEditUsername, isNull, reason: '$unread');
        expect(post.lastEditTime, isNull, reason: '$unread');
      }
    });

    test('a paid thread not bought: the purchase lock of the first floor', () {
      final page = _page('thread_v3_paid.json');
      final post = page.postList.single;
      expect(post.locked, hasLength(1));
      final lock = post.locked.single;
      expect(lock.lockedWithPurchase, isTrue);
      expect(lock.price, 5);
      expect(lock.purchasedCount, isNull, reason: 'payers 0: the page prints no count');
      expect(lock.tid, '9199057');
      expect(lock.pid, '3055');
      expect(lock.isValid(), isTrue);
      expect(post.data, contains('action=pay'), reason: 'the content keeps the lock block too, as on the web page');

      // Bought already: no lock; a reply of a paid thread: no lock.
      final bought = Post.fromApi(
        _floor('thread_v3_paid.json', 3055),
        tid: '9199057',
        fid: 25,
        viewerUid: 35,
        page: 1,
        pay: const {'price': 5, 'need_pay': 0, 'payers': 3},
      );
      expect(bought.locked, isEmpty);
      final boughtNoCount = Post.fromApi(
        _floor('thread_v3_paid.json', 3055),
        tid: '9199057',
        fid: 25,
        viewerUid: 35,
        page: 1,
        pay: const {'price': 5, 'need_pay': 0, 'payers': null},
      );
      expect(boughtNoCount.locked, isEmpty, reason: 'payers null once bought');
      final reply = Post.fromApi(
        {..._floor('thread_v3_paid.json', 3055), 'first': 0, 'position': 2},
        tid: '9199057',
        fid: 25,
        viewerUid: 35,
        page: 1,
        pay: const {'price': 5, 'need_pay': 1, 'payers': 3},
      );
      expect(reply.locked, isEmpty);
      final counted = Post.fromApi(
        _floor('thread_v3_paid.json', 3055),
        tid: '9199057',
        fid: 25,
        viewerUid: 35,
        page: 1,
        pay: const {'price': 5, 'need_pay': 1, 'payers': 3},
      );
      expect(counted.locked.single.purchasedCount, 3);
    });

    test('hidden content: stays in the content for the renderer, hidden as on the web page', () {
      final post = _page('thread_v3_hide.json').postList.single;
      expect(post.locked, isEmpty);
      expect(post.data, contains('如果您要查看本帖隐藏内容请'));
      expect(_raw('thread_v3_hide.json'), isNot(contains('HIDDEN_SENTINEL_A')));
      expect(post.signature, contains('簽名裡的舊網域連結'), reason: 'signature_html');
    });

    test('a poll thread: the poll form of the first floor, for the account the page was served to', () {
      final post = _page('thread_v3_poll.json').postList.single;
      expect(post.poll, isNotNull);
      expect(post.poll!.form, startsWith('<form id="poll"'));
      expect(post.poll!.form, _floor('thread_v3_poll.json', 3217)['poll_html']);
      expect(post.poll!.viewerUid, 35);
      expect(post.rate?.rateStatus, '威望 +3', reason: 'the first floor rated');

      final guest = Post.fromApi(_floor('thread_v3_poll.json', 3217), tid: '9199099', fid: 2, viewerUid: 0, page: 1);
      expect(guest.poll!.viewerUid, isNull);
      expect(guest.reportTarget, isNull, reason: 'a guest reports nothing');
    });

    test('an anonymous floor, a hot reply, the actions the forum refuses', () {
      final base = _floor('thread_v3_plain.json', 3940);
      final anonymous = Post.fromApi(
        {...base, 'anonymous': 1, 'avatar': '', 'group': null},
        tid: '9199345',
        fid: 2,
        viewerUid: 35,
        page: 1,
      );
      expect(anonymous.author.name, '匿名');
      expect(anonymous.author.uid, isNull);
      expect(anonymous.author.url, '');
      expect(anonymous.author.avatarUrl, isNull);
      expect(anonymous.reportTarget, isNull);
      expect(anonymous.postFloor, 2);
      // A moderator is given the real authorid of an anonymous floor: still anonymous, no uid to navigate to.
      final moderated = Post.fromApi(
        {...base, 'anonymous': 1, 'author': '', 'avatar': '', 'authorid': 31},
        tid: '9199345',
        fid: 2,
        viewerUid: 32,
        page: 1,
      );
      expect(moderated.author.name, '匿名');
      expect(moderated.author.uid, isNull);
      expect(moderated.author.url, '');
      expect(moderated.author.avatarUrl, isNull);
      expect(moderated.reportTarget, isNull);

      final hot = Post.fromApi({...base, 'position': -1}, tid: '9199345', fid: 2, viewerUid: 35, page: 1);
      expect(hot.postFloor, isNull);

      final refused = Post.fromApi(
        {
          ...base,
          'can': {'reply': 0, 'edit': 0, 'rate': 0, 'report': 0},
        },
        tid: '9199345',
        fid: 2,
        viewerUid: 35,
        page: 1,
      );
      expect(refused.replyAction, isNull);
      expect(refused.rateAction, isNull);
      expect(refused.editUrl, isNull);
      expect(refused.reportTarget, isNull);

      final allowed = Post.fromApi(
        {
          ...base,
          'can': {'reply': 1, 'edit': 1, 'rate': 1, 'report': 1},
        },
        tid: '9199345',
        fid: 2,
        viewerUid: 35,
        page: 3,
      );
      final urls = base['urls'] as Map<String, dynamic>;
      expect(allowed.replyAction, '$baseUrl/${urls['reply']}');
      expect(allowed.rateAction, '$baseUrl/${urls['rate']}');
      expect(allowed.editUrl, '$baseUrl/${urls['edit']}');
      expect(allowed.reportTarget?.pid, 3940);
      expect(allowed.reportTarget?.reportUrl.toString(), '$baseUrl/${urls['report']}');
      expect(allowed.page, 3);

      // A draft thread: its first floor is the draft when it can be edited.
      final first = _floor('thread_v3_plain.json', 3938);
      final draft = Post.fromApi(
        {
          ...first,
          'can': {'reply': 1, 'edit': 1, 'rate': 0, 'report': 0},
        },
        tid: '9199345',
        fid: 2,
        viewerUid: 32,
        page: 1,
        draft: true,
      );
      expect(draft.isDraft, isTrue);
      expect(
        Post.fromApi(first, tid: '9199345', fid: 2, viewerUid: 35, page: 1, draft: true).isDraft,
        isFalse,
        reason: 'not editable',
      );
    });

    test('the red packet of a floor, from packet_html', () {
      final base = _floor('thread_v3_plain.json', 3938);
      expect(base['packet_html'], '', reason: 'no packet on the test forum');
      expect(_post('thread_v3_plain.json', 3938).packetUrl, isNull);
      expect(_post('thread_v3_plain.json', 3938).packetAllTaken, isFalse);

      Post withPacket(String image) => Post.fromApi(
        {
          ...base,
          'packet_html':
              '<div id="ts_packet"><a href="plugin.php?id=tsdm_packet:packet&amp;pid=3938" onclick="showWindow(\'packet\', this.href)"> '
              '<img src="$image" /></a></div>',
        },
        tid: '9199345',
        fid: 2,
        viewerUid: 35,
        page: 1,
      );
      final open = withPacket('static/image/post/rp-1.svg');
      expect(open.packetUrl, '$baseUrl/plugin.php?id=tsdm_packet:packet&pid=3938');
      expect(open.packetAllTaken, isFalse);
      final taken = withPacket('static/image/post/rp-2.svg');
      expect(taken.packetUrl, '$baseUrl/plugin.php?id=tsdm_packet:packet&pid=3938');
      expect(taken.packetAllTaken, isTrue);
      // The block is never looked for in the content.
      final inBody = Post.fromApi(
        {...base, 'body_html': '<div id="ts_packet"><a href="x"><img src="static/image/post/rp-2.svg" /></a></div>'},
        tid: '9199345',
        fid: 2,
        viewerUid: 35,
        page: 1,
      );
      expect(inBody.packetUrl, isNull);
      expect(inBody.packetAllTaken, isFalse);
    });

    test('the author column is read with the selectors of the web page', () {
      // The same thread, read from the web page of the old fixture: the author column tells the same.
      final web = parseThreadDocument(parseHtmlDocument(_raw('thread_plain.html')), 1);
      final api = _page('thread_v3_plain.json');
      for (final post in api.postList) {
        final webPost = web.postList.firstWhere((e) => e.postID == post.postID);
        expect(post.author.name, webPost.author.name, reason: post.postID);
        expect(post.author.uid, webPost.author.uid, reason: post.postID);
        expect(post.checkin != null, webPost.checkin != null, reason: post.postID);
        expect(post.pokemon != null, webPost.pokemon != null, reason: post.postID);
        expect(post.postMedals?.length, webPost.postMedals?.length, reason: post.postID);
        expect(post.badge, webPost.badge, reason: post.postID);
        expect(post.secondBadge, webPost.secondBadge, reason: post.postID);
        expect(post.userBriefProfile?.userGroup, webPost.userBriefProfile?.userGroup, reason: post.postID);
      }
    });
  });

  group('ThreadRepository.fetchThreadPage switches on the answer', () {
    test('a structured answer: built from the fields, its document never read', () async {
      final page = _right(await _repository(_raw('thread_v3_plain.json')).fetchThreadPage(tid: '9199345').run());
      expect(page.tid, '9199345');
      expect(page.postList.map((e) => e.postID), contains('3954'));
      expect(page.postList.map((e) => e.postID), isNot(contains('1')), reason: 'the garbage document');
      expect(page.replyParameters?.formHash, 'f1f2f3f4');
    });

    test('the message of the plugin: the login prompt', () async {
      final page = _right(await _repository(_raw('thread_v3_denied_guest.json')).fetchThreadPage(tid: '9199132').run());
      expect(page.needLogin, isTrue);
      expect(page.postList, isEmpty);
    });

    test('an older plugin: parsed from the document as before', () async {
      final page = _right(await _repository(_raw('thread_plain.json')).fetchThreadPage(tid: '9199345').run());
      expect(page.tid, '9199345');
      expect(page.postList.map((e) => e.postID), contains('3954'));
    });

    test(
      'the old path: a page without a pager is page 1 of 1 whatever page was asked (the author-only view)',
      () async {
        final html = _raw('thread_plain.html');
        expect(parseHtmlDocument(html).querySelector('div.pg'), isNull);
        final page = _right(
          await _repository(
            html,
            contentType: 'text/html; charset=utf-8',
          ).fetchThreadPage(tid: '9199345', pageNumber: 5, pageFallback: 1, onlyVisibleUid: '31').run(),
        );
        expect(page.currentPage, 1);
        expect(page.totalPages, 1);
        // Without the fallback the page asked for stands, as the page jumps read it.
        final jumped = _right(
          await _repository(
            html,
            contentType: 'text/html; charset=utf-8',
          ).fetchThreadPage(tid: '9199345', pageNumber: 5).run(),
        );
        expect(jumped.currentPage, 5);
        // The structured answer always tells its page.
        final api = _right(
          await _repository(
            _raw('thread_v3_long_author.json'),
          ).fetchThreadPage(tid: '1120', pageNumber: 5, pageFallback: 1).run(),
        );
        expect(api.currentPage, 1);
        expect(api.totalPages, 1);
      },
    );

    test('the web page: parsed as before', () async {
      final page = _right(
        await _repository(
          _raw('thread_plain.html'),
          contentType: 'text/html; charset=utf-8',
        ).fetchThreadPage(tid: '9199345').run(),
      );
      expect(page.tid, '9199345');
      expect(page.postList.map((e) => e.postID), contains('3954'));
    });

    test('the thread cache of a guest (unknown with the posts): parsed from the document, the page kept', () async {
      final html = _raw('thread_plain.html');
      final document = parseHtmlDocument(html).querySelector('div#postlist')!.outerHtml!;
      final cached = _unknown('<div id="ct">$document</div>');
      expect(tsdmAppAnswerWithoutContent(cached), isFalse);
      expect(tsdmAppAnswerWithoutContent(jsonEncode(cached)), isFalse);
      final page = _right(await _repository(jsonEncode(cached)).fetchThreadPage(tid: '9199345').run());
      expect(page.tid, '9199345');
      expect(page.postList.map((e) => e.postID), contains('3954'));
    });

    test('the antitheft challenge (unknown without the posts) is still an answer without content', () {
      final challenge = _unknown('<form id="x"><input name="formhash" value="abcd1234" /></form>');
      expect(tsdmAppAnswerWithoutContent(challenge), isTrue);
      expect(tsdmAppAnswerWithoutContent(jsonEncode(challenge)), isTrue);
      expect(tsdmAppAnswerWithoutPage(challenge), isFalse);
      expect(tsdmAppAnswerWithoutContent(_raw('thread_v3_plain.json')), isFalse);
    });

    test('an answer without a page is a failed request', () async {
      for (final body in ['{"ok":0,"error":"internal"}', '']) {
        final result = await _repository(body).fetchThreadPage(tid: '9199345').run();
        expect(result.isLeft(), isTrue, reason: body);
        expect(result.getLeft().toNullable(), isA<HttpRequestFailedException>(), reason: body);
      }
    });

    test('fetchThread still gives the document of any answer', () async {
      final document = _right(await _repository(_raw('thread_v3_plain.json')).fetchThread(tid: '9199345').run());
      expect(document, isA<uh.Document>());
      expect(document.querySelector('div#post_1'), isNotNull, reason: 'the document of the answer, whatever it holds');
      final old = _right(await _repository(_raw('thread_plain.json')).fetchThread(tid: '9199345').run());
      expect(old.querySelector('div#post_3954'), isNotNull);
    });
  });

  test('the fixtures carry nothing of the test forum', () {
    final names = Directory(_dir).listSync().map((e) => e.path).where((e) => e.contains('thread_v3_')).toList();
    expect(names, hasLength(19));
    for (final name in names) {
      final raw = File(name).readAsStringSync();
      for (final needle in ['127.0.0.1', 'AgTest', '"password"', '"email"', '"regip"', '"lastip"']) {
        expect(raw, isNot(contains(needle)), reason: '$name $needle');
      }
      expect(raw, isNot(matches(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'))), reason: '$name: an IPv4 address');
      // Plain http only in the test content itself: the empty homepage link Discuz prints (`href="http://"`) and
      // the example hosts of the test posts; never a real host. A url ends at a bracket too (the bbcode of a floor's
      // `message`, `[url=http://…]…[/url]`).
      for (final m in RegExp(r'http://[^"\x27&<\s\\\[\]]*').allMatches(raw)) {
        expect(m.group(0), matches(RegExp(r'^http://([a-z0-9.-]*\.example(\.com)?(/.*)?)?$')), reason: name);
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json.containsKey('head'), isFalse, reason: name);
      expect(json.containsKey('document'), name.endsWith('thread_v3_plain.json'), reason: name);
    }
  });
}
