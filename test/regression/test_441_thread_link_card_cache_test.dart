/// Links in a post's content to a thread are drawn as cards of the thread (the link card, part 2: what a card shows and
/// how threads are asked).
///
/// A card is the first page of its thread, asked as the thread page asks it: the forum's app API answer (`schema`
/// fields: title, forum, replies and views, the first floor's author and time) or the web page without the plugin.
/// A thread the account can not read is no card (the link stays). Each thread is asked once for each account in the
/// run of the app, also while the first request is still going, two at a time; a thread the forum refuses is kept as
/// no card, a failed request or another page that is not the thread (a login prompt) is not, an answer that comes after
/// the account changed is dropped.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/thread_link_card/models/thread_link_card_info.dart';
import 'package:tsdm_client/features/thread_link_card/repository/thread_link_card_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

ThreadPageInfo _apiPage(Map<String, dynamic> json) => threadPageFromApi(threadApiAnswerOf(json)!, 1);

ThreadPageInfo _webPage(String html) => parseThreadDocument(tsdmAppPageDocument(html), 1);

/// A page titled [title], with no floor.
ThreadPageInfo _page(String title) => ThreadPageInfo(
  tid: '1',
  title: title,
  fid: 2,
  forumName: '版块',
  currentPage: 1,
  totalPages: 1,
  havePermission: true,
  permissionDeniedMessage: null,
  needLogin: false,
  threadSoftClosed: false,
  threadClosed: false,
  postList: const [],
  replyParameters: null,
  threadType: null,
  isDraft: false,
  latestModAct: null,
  breadcrumbs: const [],
  postMedals: const [],
  viewCount: 3,
  replyCount: 4,
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('the card of a page', () {
    test('the forum app API answer', () {
      final info = ThreadLinkCardInfo.ofPage(9199345, _apiPage(_json('thread_v3_plain.json')))!;
      expect(info.title, '[Rulebot multi fixture 20260930-101846] FID2 版規問答測試');
      expect(info.forumName, '📢 公告 & 新手報到');
      expect(info.author, 'ag_admin');
      expect(info.replyCount, 8);
      expect(info.viewCount, 100);
      // The forum's time (`dateline` 1790763526 in its `timeoffset` 8), as the thread page shows it, whatever the time
      // zone of the device.
      final time = info.publishTime!;
      expect(
        DateTime(time.year, time.month, time.day, time.hour, time.minute, time.second),
        DateTime(2026, 9, 30, 18, 18, 46),
      );
    });

    test('an anonymous first floor names nobody', () {
      final json = _json('thread_v3_plain.json');
      json['posts'] = [
        for (final p in json['posts'] as List)
          (p as Map)['first'] == 1 ? {...p, 'anonymous': 1, 'authorid': 0, 'author': ''} : p,
      ];
      final info = ThreadLinkCardInfo.ofPage(9199345, _apiPage(json))!;
      expect(info.author, isNull);
      expect(info.title, isNotEmpty);
    });

    test('the web page, without the plugin', () {
      final info = ThreadLinkCardInfo.ofPage(9199345, _webPage(_raw('thread_plain.html')))!;
      expect(info.title, '[Rulebot multi fixture 20260930-101846] FID2 版規問答測試');
      expect(info.forumName, isNotNull);
      expect(info.viewCount, 29);
      expect(info.replyCount, 8);
      // The test forum prints "楼主" for the first floor: the first floor of the page all the same.
      expect(info.author, isNotNull);
    });

    test('a thread the account can not read is no card', () {
      // The login prompt of a guest.
      expect(ThreadLinkCardInfo.ofPage(1, _apiPage(_json('thread_v3_denied_guest.json'))), isNull);
      // A member without permission.
      final message = {'ok': 0, 'error': 'message', 'message': '抱歉，本帖要求阅读权限高于 20 才能浏览', 'login': 0, 'uid': 35};
      expect(ThreadLinkCardInfo.ofPage(1, _apiPage(message)), isNull);
      // The forum's message page.
      expect(
        ThreadLinkCardInfo.ofPage(1, _webPage(File('test/data/thread_readperm_guest_x5.html').readAsStringSync())),
        isNull,
      );
    });
  });

  group('the repository', () {
    late List<int> asked;
    late int? uid;
    late Map<int, FutureOr<Either<AppException, ThreadPageInfo>> Function()> answers;
    late ThreadLinkCardRepository repository;

    setUp(() {
      asked = [];
      uid = 35;
      answers = {};
      repository = ThreadLinkCardRepository(
        fetchPage: (tid) async {
          asked.add(tid);
          return answers[tid]!();
        },
        currentUid: () => uid,
      );
    });

    test('a thread is asked once, also while the first request is going', () async {
      final answer = Completer<Either<AppException, ThreadPageInfo>>();
      answers[1] = () => answer.future;
      final first = repository.load(1);
      final second = repository.load(1);
      expect(repository.isCached(1), isFalse);
      answer.complete(Right(_page('标题')));
      expect((await first)?.title, '标题');
      expect((await second)?.title, '标题');
      expect(repository.isCached(1), isTrue);
      expect(repository.cached(1)?.replyCount, 4);
      expect((await repository.load(1))?.viewCount, 3);
      expect(asked, [1]);
    });

    test('a thread the forum refuses to the account is kept as no card', () async {
      final message = {'ok': 0, 'error': 'message', 'message': '抱歉，本帖要求阅读权限高于 200 才能浏览', 'login': 0, 'uid': 35};
      answers[2] = () => Right(_apiPage(message));
      expect(await repository.load(2), isNull);
      expect(repository.isCached(2), isTrue);
      expect(await repository.load(2), isNull);
      expect(asked, [2]);
      // The plugin's answer for a thread that does not exist, as the test forum answers it.
      answers[3] = () => Right(_apiPage({'ok': 0, 'error': 'message', 'message': '没有找到帖子', 'login': 0, 'uid': 35}));
      expect(await repository.load(3), isNull);
      expect(repository.isCached(3), isTrue);
      expect(asked, [2, 3]);
    });

    test('any other page that is not the thread is asked again', () async {
      // The login prompt (an expired session), a message that is no refusal (too many requests), a page without a title.
      answers[20] = () => Right(_apiPage(_json('thread_v3_denied_guest.json')));
      answers[21] = () =>
          Right(_apiPage({'ok': 0, 'error': 'message', 'message': '抱歉，您的请求来路不正确或表单验证串不符，无法提交', 'login': 0}));
      answers[22] = () => Right(_page(''));
      for (final tid in [20, 21, 22]) {
        expect(await repository.load(tid), isNull);
        expect(repository.isCached(tid), isFalse, reason: '$tid');
        expect(await repository.load(tid), isNull);
      }
      expect(asked, [20, 20, 21, 21, 22, 22]);
    });

    test('at most two requests at a time', () async {
      final answers0 = {for (var tid = 30; tid < 35; tid++) tid: Completer<Either<AppException, ThreadPageInfo>>()};
      for (final MapEntry(:key, :value) in answers0.entries) {
        answers[key] = () => value.future;
      }
      final loads = [for (var tid = 30; tid < 35; tid++) repository.load(tid)];
      await pumpEventQueue();
      expect(asked, [30, 31]);
      expect(repository.running, 2);
      answers0[30]!.complete(Right(_page('30')));
      // A new request coming while the turn is handed over waits too.
      final late = Completer<Either<AppException, ThreadPageInfo>>();
      answers[40] = () => late.future;
      final lateLoad = repository.load(40);
      await pumpEventQueue();
      expect(asked, [30, 31, 32]);
      expect(repository.running, 2);
      for (var tid = 31; tid < 35; tid++) {
        answers0[tid]!.complete(Right(_page('$tid')));
        await pumpEventQueue();
      }
      late.complete(Right(_page('40')));
      expect(
        [
          for (final e in await Future.wait([...loads, lateLoad])) e?.title,
        ],
        ['30', '31', '32', '33', '34', '40'],
      );
      expect(asked, [30, 31, 32, 33, 34, 40]);
      expect(repository.running, 0);
    });

    test('the oldest answers go past the capacity', () async {
      for (var tid = 1; tid <= ThreadLinkCardRepository.capacity + 1; tid++) {
        answers[tid] = () => Right(_page('$tid'));
        await repository.load(tid);
      }
      expect(repository.isCached(1), isFalse);
      expect(repository.isCached(2), isTrue);
      expect(repository.isCached(ThreadLinkCardRepository.capacity + 1), isTrue);
    });

    test('a failed request is not kept', () async {
      var fail = true;
      answers[3] = () => fail ? Left(HttpRequestFailedException(500)) : Right(_page('后来'));
      expect(await repository.load(3), isNull);
      expect(repository.isCached(3), isFalse);
      fail = false;
      expect((await repository.load(3))?.title, '后来');
      // Thrown is failed too.
      answers[4] = () => throw StateError('broken');
      expect(await repository.load(4), isNull);
      expect(repository.isCached(4), isFalse);
      expect(asked, [3, 3, 4]);
    });

    test('each account has its own cards; an answer after the account changed is dropped', () async {
      answers[5] = () => Right(_page('甲'));
      expect((await repository.load(5))?.title, '甲');
      uid = 36;
      expect(repository.isCached(5), isFalse);
      final answer = Completer<Either<AppException, ThreadPageInfo>>();
      answers[5] = () => answer.future;
      final pending = repository.load(5);
      // Logged out (a guest) before the answer came.
      uid = null;
      answer.complete(Right(_page('乙')));
      expect(await pending, isNull);
      uid = 36;
      expect(repository.isCached(5), isFalse);
      uid = 35;
      expect(repository.cached(5)?.title, '甲');
      expect(asked, [5, 5]);
    });
  });
}
