/// The thread's "支持" and "踩" (Discuz! 主题评价) under the first floor.
///
/// The fixtures under `test/data/recommend` are the test forum's answers (Discuz! X5 with plugin tsdmapp 3.7.0, the
/// evaluation on with the texts "支持" and "踩踩", as the live forum has them), scrubbed (thread 9199345, account 31,
/// form hash `f1f2f3f4`, time 1700000000):
///
/// * `p_btn_member.html` / `p_btn_guest.html`: the first floor's `div#p_btn` of the web page served to a member and to
///   a guest, the thread with 1 support and 2 treads;
/// * `result_*.json`: the write results of the plugin (`tsdmapp=json`, `inajax=1`) for a support counted
///   (`recommend_succeed`), a tread counted with the day limit on (`recommend_daycount_succeed`), and the refusals:
///   evaluated already, the account's own thread, no evaluation left today, a stale form hash, a guest;
/// * `web_*.xml`: the forum's AJAX fragments of the same without the plugin.
///
/// The plugin's thread answer has no field of the evaluation (3.7.0): the first page is asked with its `document`
/// and the two links are cut from it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/thread_recommend/repository/thread_recommend_repository.dart';
import 'package:tsdm_client/features/thread_recommend/utils/thread_recommend_answer.dart';
import 'package:tsdm_client/features/thread_recommend/widgets/thread_recommend_buttons.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/recommend';

Translations get t => LocaleSettings.instance.currentTranslations;

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Object? _result(String name) => name.endsWith('.json') ? jsonDecode(_raw(name)) : _raw(name);

/// The structured thread answer of the plugin (page 1, account 35), a fresh copy.
Map<String, dynamic> _thread() =>
    jsonDecode(File('test/data/tsdmapp/thread_v3_plain.json').readAsStringSync()) as Map<String, dynamic>;

/// [_thread] served to account 31 with the page's `document` and `head`, the first floor's `div#p_btn` being [pBtn].
Map<String, dynamic> _threadWithDocument(String pBtn) => _thread()
  ..['uid'] = 31
  ..['head'] = '<link href="forum.php?mod=viewthread&amp;tid=9199345" />'
  ..['document'] = [
    '<div id="postlist"><div id="post_1"><table><tr><td class="plc">',
    '<a href="forum.php?mod=misc&amp;action=rate&amp;tid=9199345">评分</a></td></tr>',
    '<tr><td class="plc plm">$pBtn</td></tr></table></div></div>',
  ].join();

ThreadRecommend? _parse(String html, {int? viewerUid = 31}) =>
    ThreadRecommend.fromNode(parseHtmlDocument(html).body, viewerUid: viewerUid);

/// A forum answering every request with [answer] (JSON), recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final Object answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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

  group('the buttons the page prints', () {
    test("a member's: the forum's texts, counts, thread and form hash", () {
      final r = _parse(_raw('p_btn_member.html'))!;
      expect(r.tid, 9199345);
      expect(r.hash, 'f1f2f3f4');
      expect(r.guest, isFalse);
      expect(r.viewerUid, 31);
      expect(r.add, const ThreadRecommendButton(label: '支持', count: 1));
      expect(r.subtract, const ThreadRecommendButton(label: '踩踩', count: 2));
      expect(
        r.url(ThreadRecommendSide.add),
        '$baseUrl/forum.php?mod=misc&action=recommend&do=add&tid=9199345&hash=f1f2f3f4&inajax=1',
      );
      expect(Uri.parse(r.url(ThreadRecommendSide.subtract)).queryParameters['do'], 'subtract');
    });

    test("a guest's open the login, whatever account is named", () {
      for (final uid in [null, 0, 31]) {
        final r = _parse(_raw('p_btn_guest.html'), viewerUid: uid)!;
        expect(r.guest, isTrue, reason: '$uid');
        expect(r.viewerUid, isNull, reason: '$uid');
        expect(r.add?.count, 1);
      }
    });

    test("a member's page that does not tell its account: none", () {
      expect(_parse(_raw('p_btn_member.html'), viewerUid: null), isNull);
    });

    test('a count of 0 (hidden by the page), one button only, none, or not the forum evaluation', () {
      final member = _raw('p_btn_member.html');
      final zero = member.replaceFirst(
        '<span id="recommendv_add">1</span>',
        '<span id="recommendv_add" style="display:none">0</span>',
      );
      expect(_parse(zero)!.add, const ThreadRecommendButton(label: '支持', count: 0));

      final addOnly = member.replaceFirst(RegExp(r'<a id="recommend_subtract"[\s\S]*?</a>'), '');
      final r = _parse(addOnly)!;
      expect(r.add?.label, '支持');
      expect(r.subtract, isNull);

      final none = addOnly.replaceFirst(RegExp(r'<a id="recommend_add"[\s\S]*?</a>'), '');
      expect(_parse(none), isNull);
      expect(_parse(''), isNull);

      final elsewhere = member.replaceAll('action=recommend', 'action=rate');
      expect(_parse(elsewhere), isNull);
    });

    test('the web page: on the first floor only', () {
      String floor(int pid, String pBtn) => [
        '<div id="post_$pid"><table><tbody><tr><td class="pls"></td><td class="plc">',
        '<div class="pi"><div class="pti"><div class="authi">',
        '<a href="home.php?mod=space&amp;uid=35" class="xi2">ag</a> <em id="authorposton$pid">发表于 2026-11-10 12:00</em>',
        '</div></div></div><div class="pct"><div class="pcb"><div class="t_fsz"><table><tr>',
        '<td class="t_f" id="postmessage_$pid">x</td></tr></table></div></div></div></td></tr>',
        '<tr><td class="plc plm">$pBtn</td></tr></tbody></table></div>',
      ].join();
      final first = parseHtmlDocument(floor(1, _raw('p_btn_member.html'))).querySelector('div#post_1')!;
      final reply = parseHtmlDocument(floor(2, '')).querySelector('div#post_2')!;
      expect(Post.fromPostNode(first, 1, viewerUid: 31)?.recommend?.subtract?.count, 2);
      expect(Post.fromPostNode(reply, 1, viewerUid: 31)?.recommend, isNull);
    });
  });

  group("the plugin's answer: the links cut from its document", () {
    test('the two links only', () {
      final links = threadRecommendLinksIn(_threadWithDocument(_raw('p_btn_member.html'))['document'] as String);
      expect(RegExp('<a ').allMatches(links), hasLength(2));
      expect(links, startsWith('<a id="recommend_add"'));
      expect(links, endsWith('</a>'));
      expect(threadRecommendLinksIn('<div id="p_btn"><a class="followp" href="x">转播</a></div>'), isEmpty);
    });

    test('the answer kept without document and head, the evaluation on the first floor only', () {
      final cut = threadAnswerWithRecommend(_threadWithDocument(_raw('p_btn_member.html')))! as Map<String, dynamic>;
      expect(cut, isNot(contains('document')));
      expect(cut, isNot(contains('head')));
      expect(cut[threadRecommendHtmlKey], contains('recommend_subtract'));

      final offline = threadAnswerWithoutRecommend(cut)! as Map<String, dynamic>;
      expect(offline, isNot(contains(threadRecommendHtmlKey)), reason: 'no form hash in the offline copy');
      expect(offline.keys.toSet(), cut.keys.toSet()..remove(threadRecommendHtmlKey));
      final lean = _thread();
      expect(identical(threadAnswerWithoutRecommend(lean), lean), isTrue);

      final page = threadPageFromApi(threadApiAnswerOf(cut)!, 1);
      final first = page.postList.firstWhere((p) => p.postFloor == 1);
      expect(first.recommend?.viewerUid, 31);
      expect(first.recommend?.add?.count, 1);
      expect(page.postList.where((p) => p.recommend != null), hasLength(1));
    });

    test('a guest answer: buttons to the login', () {
      final answer = _threadWithDocument(_raw('p_btn_guest.html'))..['uid'] = 0;
      final page = threadPageFromApi(threadApiAnswerOf(threadAnswerWithRecommend(answer))!, 1);
      expect(page.postList.firstWhere((p) => p.postFloor == 1).recommend?.guest, isTrue);
    });

    test('no links: the document is dropped all the same; a lean or a web answer is left as it came', () {
      final cut = threadAnswerWithRecommend(_threadWithDocument('')) as Map<String, dynamic>?;
      expect(cut, isNot(contains('document')));
      expect(cut, isNot(contains(threadRecommendHtmlKey)));
      expect(threadPageFromApi(cut!, 1).postList.where((p) => p.recommend != null), isEmpty);

      final lean = _thread()..remove('document');
      expect(identical(threadAnswerWithRecommend(lean), lean), isTrue);
      final cache = {'ok': 0, 'error': 'unknown', 'document': _raw('p_btn_member.html')};
      expect(identical(threadAnswerWithRecommend(cache), cache), isTrue);
      const web = '<html><body></body></html>';
      expect(threadAnswerWithRecommend(web), web);
    });

    test('withTsdmAppJson without nodoc', () {
      const url = '$baseUrl/forum.php?mod=viewthread&tid=9199345&page=1';
      expect(withTsdmAppJson(url, nodoc: false), '$url&tsdmapp=json');
      expect(withTsdmAppJson('$url#x', nodoc: false), '$url&tsdmapp=json#x');
      expect(withTsdmAppJson(url), '$url&tsdmapp=json&nodoc=1');
    });

    test('fetchThreadPage: page 1 by thread id asks its document, any other page stays lean', () async {
      final forum = _Forum(_threadWithDocument(_raw('p_btn_member.html')));
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
      try {
        final page = (await ThreadRepository().fetchThreadPage(tid: '9199345').run()).fold((e) => throw e, (v) => v);
        expect(page.postList.firstWhere((p) => p.postFloor == 1).recommend?.subtract?.count, 2);
        expect(forum.requests.single.uri.queryParameters, containsPair('tsdmapp', 'json'));
        expect(forum.requests.single.uri.queryParameters, isNot(contains('nodoc')));

        await ThreadRepository().fetchThreadPage(tid: '9199345', pageNumber: 2).run();
        expect(forum.requests.last.uri.queryParameters, containsPair('nodoc', '1'));
      } finally {
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group("the forum's answer to an evaluation", () {
    test('the results of the plugin: counted by key, refused with the forum words, the login told apart', () {
      expect(threadRecommendOutcomeOf(_result('result_add_succeed.json')), isA<ThreadRecommendDone>());
      expect(threadRecommendOutcomeOf(_result('result_daycount_succeed.json')), isA<ThreadRecommendDone>());
      String refusal(String name) => (threadRecommendOutcomeOf(_result(name)) as ThreadRecommendRefused).message;
      expect(refusal('result_duplicate.json'), '评价指数 1\n您已评价过本主题');
      expect(refusal('result_self_disallow.json'), '评价指数 1\n您不能评价自己的帖子');
      expect(refusal('result_outoftimes.json'), '评价指数 0\n今日评价机会已用完');
      // The line break goes after the index the forum prints after a space, not after a digit of its label.
      final relabeled = _result('result_duplicate.json')! as Map<String, dynamic>;
      relabeled['message'] = '第1评价指数 1您已评价过本主题';
      expect((threadRecommendOutcomeOf(relabeled) as ThreadRecommendRefused).message, '第1评价指数 1\n您已评价过本主题');
      expect(refusal('result_submit_invalid.json'), '抱歉，您的请求来路不正确或表单验证串不符，无法提交');
      expect(threadRecommendOutcomeOf(_result('result_to_login.json')), isA<ThreadRecommendNeedLogin>());
    });

    test("the forum's AJAX fragments without the plugin", () {
      expect(threadRecommendOutcomeOf(_result('web_subtract_succeed.xml')), isA<ThreadRecommendDone>());
      String refusal(String name) => (threadRecommendOutcomeOf(_result(name)) as ThreadRecommendRefused).message;
      expect(refusal('web_duplicate.xml'), '评价指数 1\n您已评价过本主题');
      expect(refusal('web_self_disallow.xml'), '评价指数 1\n您不能评价自己的帖子');
      expect(refusal('web_to_login.xml'), '您需要先登录才能继续本操作');
      expect(threadRecommendOutcomeOf('<html></html>'), isA<ThreadRecommendUnknown>());
      expect(threadRecommendOutcomeOf(null), isA<ThreadRecommendUnknown>());
    });

    test('sent once, with the result parameter; a guest sends nothing; failures', () async {
      final member = _parse(_raw('p_btn_member.html'))!;
      final sent = <String>[];
      final ok = ThreadRecommendRepository(
        send: (url) async {
          sent.add(url);
          return _result('result_add_succeed.json');
        },
      );
      expect(await ok.submit(member, ThreadRecommendSide.add), isA<ThreadRecommendDone>());
      expect(sent, [member.url(ThreadRecommendSide.add)]);

      final guest = _parse(_raw('p_btn_guest.html'), viewerUid: null)!;
      expect(await ok.submit(guest, ThreadRecommendSide.add), isA<ThreadRecommendNeedLogin>());
      expect(sent, hasLength(1));

      final changed = ThreadRecommendRepository(send: (_) async => throw IdentityChangedException());
      expect(await changed.submit(member, ThreadRecommendSide.add), isA<ThreadRecommendAccountChanged>());
      final failed = ThreadRecommendRepository(send: (_) async => throw HttpRequestFailedException(502));
      expect(await failed.submit(member, ThreadRecommendSide.subtract), isA<ThreadRecommendUnknown>());
    });

    test('the network transport adds the result parameter, not nodoc, and sends once', () async {
      final forum = _Forum(_result('result_add_succeed.json')!);
      final client = NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
      );
      final member = _parse(_raw('p_btn_member.html'))!;
      final outcome = await ThreadRecommendRepository.network(client).submit(member, ThreadRecommendSide.add);
      expect(outcome, isA<ThreadRecommendDone>());
      final query = forum.requests.single.uri.queryParameters;
      expect(query, containsPair('tsdmapp', 'json'));
      expect(query, containsPair('inajax', '1'));
      expect(query, containsPair('do', 'add'));
      expect(query, isNot(contains('nodoc')));
    });
  });

  group('the buttons', () {
    setUp(ThreadRecommendMemory.clear);

    Future<List<String>> pump(WidgetTester tester, ThreadRecommend recommend, String result) async {
      final sent = <String>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: Scaffold(
              body: RepositoryProvider(
                create: (_) => ThreadRecommendRepository(
                  send: (url) async {
                    sent.add(url);
                    return _result(result);
                  },
                ),
                child: ThreadRecommendButtons(recommend),
              ),
            ),
          ),
        ),
      );
      return sent;
    }

    testWidgets("the forum's texts with their counts; counted once, then both off", (tester) async {
      final recommend = _parse(_raw('p_btn_member.html'))!;
      final sent = await pump(tester, recommend, 'result_add_succeed.json');
      expect(find.text('支持 1'), findsOneWidget);
      expect(find.text('踩踩 2'), findsOneWidget);

      await tester.tap(find.text('支持 1'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(find.text('支持 2'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);

      await tester.tap(find.text('踩踩 2'));
      await tester.tap(find.text('支持 2'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1), reason: 'one evaluation per member and thread');

      // The floor built again (scrolled out of view and back): still counted, still off.
      await tester.pumpWidget(const SizedBox());
      final again = await pump(tester, recommend, 'result_add_succeed.json');
      expect(find.text('支持 2'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      await tester.tap(find.text('踩踩 2'));
      await tester.pumpAndSettle();
      expect(again, isEmpty);

      // The page read again has the support in its count: not added twice.
      final reloaded = _parse(
        _raw(
          'p_btn_member.html',
        ).replaceFirst('<span id="recommendv_add">1</span>', '<span id="recommendv_add">2</span>'),
      )!;
      await pump(tester, reloaded, 'result_add_succeed.json');
      expect(find.text('支持 2'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    });

    testWidgets('no verdict: said so, both off', (tester) async {
      final sent = await pump(tester, _parse(_raw('p_btn_member.html'))!, 'p_btn_guest.html');
      await tester.tap(find.text('支持 1'));
      await tester.pumpAndSettle();
      expect(find.text(t.threadRecommend.unknown), findsOneWidget);
      await tester.tap(find.text('踩踩 2'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(find.text('支持 1'), findsOneWidget);
    });

    testWidgets("refused: the forum's words, the counts as they were", (tester) async {
      final recommend = _parse(
        _raw('p_btn_member.html').replaceFirst(
          '<span id="recommendv_add">1</span>',
          '<span id="recommendv_add" style="display:none">0</span>',
        ),
      )!;
      final sent = await pump(tester, recommend, 'result_duplicate.json');
      expect(find.text('支持'), findsOneWidget, reason: 'no count when there is none');

      await tester.tap(find.text('踩踩 2'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(find.text('评价指数 1\n您已评价过本主题'), findsOneWidget);
      expect(find.text('踩踩 2'), findsOneWidget);
    });
  });
}
