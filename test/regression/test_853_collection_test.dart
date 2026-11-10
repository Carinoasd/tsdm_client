/// The forum's collections (淘帖, 淘专辑): the lists, a collection's page and its comments, and the changes (subscribe,
/// create, edit, delete, put a thread in, take threads out, comment).
///
/// The fixtures under `test/data/collection` are the test forum's answers (Discuz! X5 with plugin tsdmapp 3.7.0, the
/// collections switched on), scrubbed (host `forum.test`, form hash `f1f2f3f4`, time 1700000000):
///
/// * `list_*.html`, `view_*.html`, `comments*.html`: the web pages (`div#ct`, the account in `discuz_uid`, the logout
///   link with the form hash), which the plugin answers as they are: it has no answer of its own for them. Account 35
///   owns collections 3 and 4 and subscribed to collection 1; account 31 commented on collection 3 twice, once with 4
///   stars; collection 4 holds 21 threads, two pages;
/// * `*.json`: the plugin's write results (`tsdmapp=json`, `inajax=1`), `*.xml` the forum's AJAX fragments of the same
///   without the plugin; `dialog.*` the forum's "淘帖" window; `stale_formhash.html` the forum's System Error page.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/features/collection/utils/parse_collection.dart';
import 'package:tsdm_client/features/collection/view/collection_detail_page.dart';
import 'package:tsdm_client/features/collection/widgets/collect_thread_sheet.dart';
import 'package:tsdm_client/features/collection/widgets/collection_pager.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/collection';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Object? _answer(String name) => name.endsWith('.json') ? jsonDecode(_raw(name)) : _raw(name);

/// A request the repository sent.
typedef _Sent = ({String url, bool write, Map<String, String>? body});

/// A forum answering each url by the first of [routes] it contains, recording every request.
final class _Forum {
  _Forum(this.routes);

  final Map<String, String> routes;
  final sent = <_Sent>[];

  Object? _answerFor(String url) {
    for (final e in routes.entries) {
      if (url.contains(e.key)) {
        return _answer(e.value);
      }
    }
    throw StateError('no answer for $url');
  }

  CollectionRepository repository({int uid = 35}) => CollectionRepository(
    get: (url, {write = false}) async {
      sent.add((url: url, write: write, body: null));
      return right(_answerFor(url));
    },
    post: (url, body) async {
      sent.add((url: url, write: true, body: body));
      return right(_answerFor(url));
    },
    currentUid: () => uid,
  );
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('lists', () {
    test('recommended: the rows, the counts by their place, the creator and the latest thread', () {
      final page = parseCollectionList(parseHtmlDocument(_raw('list_recommended.html')));
      expect(page.viewerUid, 31);
      expect(page.formHash, 'f1f2f3f4');
      expect(page.canCreate, isTrue);
      expect((page.currentPage, page.totalPages), (1, 1));
      expect(page.items.map((e) => e.ctid), [2, 1]);
      final first = page.items.first;
      expect(first.name, 'BU lists 淘帖 C（855956）');
      expect((first.threadCount, first.followCount, first.commentCount), (3, 1, 0));
      expect((first.creatorUid, first.creatorName), (33, 'ag_mid'));
      expect(first.lastUpdate, '2026-9-12 06:53');
      expect(first.latestThread?.tid, 9199035);
      expect(first.relation, isNull);
    });

    test('all, by subscribers: the big number is the subscribers, the line the threads and comments', () {
      final page = parseCollectionList(
        parseHtmlDocument(_raw('list_all_follownum.html')),
        order: CollectionOrder.follownum,
      );
      final byId = {for (final c in page.items) c.ctid: c};
      expect((byId[1]!.threadCount, byId[1]!.followCount, byId[1]!.commentCount), (3, 1, 0));
      expect((byId[3]!.threadCount, byId[3]!.followCount, byId[3]!.commentCount), (1, 0, 2));
      expect(byId[3]!.keywords, ['動畫', '測試']);
      // The description the forum stored escaped reads as the web page shows it.
      expect(byId[3]!.description, startsWith('CL測試 用的簡介'));
    });

    test('mine and subscribed are the two parts of the one page of the account', () async {
      final forum = _Forum({'op=my': 'list_my.html'});
      final repository = forum.repository();
      final mine = (await repository.fetchList(CollectionListTab.mine).run()).toNullable()!;
      final subscribed = (await repository.fetchList(CollectionListTab.subscribed).run()).toNullable()!;
      expect(mine.items.map((e) => (e.ctid, e.relation)), [
        (4, CollectionRelation.created),
        (3, CollectionRelation.created),
      ]);
      expect(subscribed.items.map((e) => (e.ctid, e.relation)), [(1, CollectionRelation.subscribed)]);
      // Changed since its owner opened it: the forum prints its name red.
      expect(mine.items.first.updated, isTrue);
      expect(mine.items.last.updated, isFalse);
      expect(forum.sent.map((e) => (e.url, e.write)), [
        ('$baseUrl/forum.php?mod=collection&op=my', false),
        ('$baseUrl/forum.php?mod=collection&op=my', false),
      ]);
    });

    test("a guest's page of its collections is empty, the collections of a thread are read as a list", () {
      expect(parseCollectionList(parseHtmlDocument(_raw('list_my_guest.html'))).items, isEmpty);
      final related = parseCollectionList(parseHtmlDocument(_raw('list_related.html')));
      expect(related.items.map((e) => e.ctid), [2, 1, 3]);
    });

    test('the list urls', () {
      expect(
        CollectionRepository.listUrl(CollectionListTab.recommended, page: 2),
        '$baseUrl/forum.php?mod=collection&page=2',
      );
      expect(CollectionRepository.listUrl(CollectionListTab.all), '$baseUrl/forum.php?mod=collection&op=all');
      expect(
        CollectionRepository.listUrl(CollectionListTab.all, order: CollectionOrder.commentnum, page: 3),
        '$baseUrl/forum.php?mod=collection&op=all&order=commentnum&page=3',
      );
      expect(CollectionRepository.relatedUrl(9), '$baseUrl/forum.php?mod=collection&tid=9');
    });
  });

  group('a collection', () {
    test("its owner's page: managed, no subscription, threads with their reason", () {
      final detail = parseCollectionDetail(parseHtmlDocument(_raw('view_owner.html')));
      expect(detail.ctid, 3);
      expect(detail.name, 'CL測試 甲專輯');
      expect(detail.description, 'CL測試 用的簡介<b>x</b>');
      expect(detail.keywords, ['動畫', '測試']);
      expect(detail.creator, (uid: 35, name: 'ag_low2'));
      expect(detail.teamworkers, isEmpty);
      expect(detail.canManage, isTrue);
      expect(detail.followState, CollectionFollowState.none);
      expect((detail.threadCount, detail.commentCount, detail.followCount), (1, 2, 0));
      expect(detail.formHash, 'f1f2f3f4');
      expect(detail.viewerUid, 35);
      final thread = detail.threads.single;
      expect(thread.tid, 9199035);
      expect(thread.subject, 'BU 驗收 B 的一般主題（1789153112776）');
      expect(thread.reason, 'CL測試 收錄理由');
      expect((thread.authorUid, thread.authorName, thread.date), (35, 'ag_low2', '2026-9-12'));
      expect((thread.replies, thread.views), (0, 6));
    });

    test("another member's page: the subscription offered, the rating, nothing to manage", () {
      final detail = parseCollectionDetail(parseHtmlDocument(_raw('view_other.html')));
      expect(detail.canManage, isFalse);
      expect(detail.followState, CollectionFollowState.canFollow);
      expect(detail.averageRate, 4.0);
      expect(detail.rateCount, 1);
      expect(detail.viewerUid, 31);
      expect(detail.formHash, 'f1f2f3f4');
    });

    test('its threads on two pages', () {
      final first = parseCollectionDetail(parseHtmlDocument(_raw('view_paged_1.html')));
      final second = parseCollectionDetail(parseHtmlDocument(_raw('view_paged_2.html')));
      expect((first.currentPage, first.totalPages, first.threads.length), (1, 2, 20));
      expect((second.currentPage, second.totalPages, second.threads.length), (2, 2, 1));
      expect(first.threadCount, 21);
      expect(first.threads.first.reason, 'CL測試 分頁');
    });

    test("the forum's message instead of the page is the failure, in its words", () async {
      final forum = _Forum({'ctid=5': 'view_missing.html'});
      final result = await forum.repository().fetchDetail(5).run();
      expect(result.getLeft().toNullable(), isA<ServerRespondedErrorException>());
      expect(result.getLeft().toNullable()?.message, '抱歉，该淘专辑不存在或没有相应的权限');
    });

    test('its comments: the stars given with one, the rating already given, the form', () {
      final page = parseCollectionComments(parseHtmlDocument(_raw('comments.html')));
      expect((page.ctid, page.name), (3, 'CL測試 甲專輯'));
      expect(page.comments.map((e) => (e.uid, e.username, e.message, e.rate)), [
        (31, 'ag_low', 'CL測試 評論二', null),
        (31, 'ag_low', 'CL測試 評論一', 4),
      ]);
      expect(page.comments.first.time, '刚刚');
      expect(page.canComment, isTrue);
      expect(page.myRate, 4);
      expect(page.formHash, 'f1f2f3f4');
      // A collection without comments: the form, the stars offered.
      final empty = parseCollectionComments(parseHtmlDocument(_raw('comments_empty.html')));
      expect(empty.comments, isEmpty);
      expect((empty.ctid, empty.canComment, empty.myRate), (4, true, null));
      // Its owner has not rated it: the stars are offered.
      final owner = parseCollectionComments(parseHtmlDocument(_raw('comments_owner.html')));
      expect(owner.myRate, isNull);
      expect(owner.canComment, isTrue);
    });
  });

  group('answers', () {
    test("the plugin's results and the forum's fragments read alike", () {
      void done(String name, {String message = '', Map<String, String> values = const {}}) {
        final outcome = collectionOutcomeOf(_answer(name));
        expect(outcome, isA<CollectionDone>(), reason: name);
        outcome as CollectionDone;
        expect(outcome.message, message, reason: name);
        for (final e in values.entries) {
          expect(outcome.values[e.key], e.value, reason: name);
        }
      }

      void refused(String name, String message) {
        final outcome = collectionOutcomeOf(_answer(name));
        expect(outcome, isA<CollectionRefused>(), reason: name);
        expect((outcome as CollectionRefused).message, message, reason: name);
      }

      done('follow_done.json', message: '成功订阅淘专辑', values: {'status': '1'});
      done('follow_done.xml', message: '成功订阅淘专辑', values: {'status': '1'});
      done('unfollow_done.json', message: '成功取消订阅淘专辑', values: {'status': '2'});
      done('unfollow_done.xml', message: '成功取消订阅淘专辑', values: {'status': '2'});
      done('create_done.json', message: '新建淘专辑成功，即将进入淘专辑页面', values: {'ctid': '3'});
      done('create_done.xml', message: '新建淘专辑成功，即将进入淘专辑页面', values: {'ctid': '4'});
      done('collect_done.json', message: '淘帖成功，主题已经被加入到相应淘专辑中');
      done('comment_done.json', message: '发表评论成功');
      done('edit_done.json', message: '淘专辑编辑成功，即将进入淘专辑页面');
      done('remove_threads_done.json', message: '删除淘专辑内主题成功，即将返回淘专辑页面');
      done('delete_done.json', message: '删除淘专辑成功，即将进入我的专辑');
      refused('create_empty.json', '请将内容填写完整');
      refused('collect_none.json', '您还没有选择可以添加的淘专辑');
      refused('collect_none.xml', '您还没有选择可以添加的淘专辑');
      refused('comment_too_fast.json', '抱歉，两次发布操作太快，请等待 15 秒再试');
      refused('comment_too_fast.xml', '抱歉，两次发布操作太快，请等待 15 秒再试');
      refused('edit_refused.json', '抱歉，该淘专辑不存在或没有相应的权限');
      refused('stale_formhash.html', '您当前的访问请求当中含有非法字符，已经被系统拒绝');
      expect(createdCtid(collectionOutcomeOf(_answer('create_done.json'))), 3);
      expect(createdCtid(collectionOutcomeOf(_answer('create_done.xml'))), 4);
      // A subscription the account has already: an empty page, which tells nothing.
      expect(collectionOutcomeOf(_answer('follow_again.json')), isA<CollectionUnknown>());
      expect(collectionOutcomeOf(_answer('dialog_guest.json')), isA<CollectionNeedLogin>());
      expect(collectionOutcomeOf(''), isA<CollectionUnknown>());
    });

    test("the forum's window: the account's collections without the thread, how many more it may create", () {
      for (final name in ['dialog.json', 'dialog.xml']) {
        final form = parseCollectThreadForm(collectionDialogHtml(_answer(name)), tid: 9199035, viewerUid: 35);
        expect(form, isNotNull, reason: name);
        expect(form!.choices, [(ctid: 4, name: 'CL測試 乙專輯（改）')], reason: name);
        expect(form.remainingCreate, 3, reason: name);
        expect(form.formHash, 'f1f2f3f4', reason: name);
      }
      expect(parseCollectThreadForm(collectionDialogHtml(_answer('dialog_guest.json')), tid: 1, viewerUid: 0), isNull);
    });
  });

  group('changes', () {
    test('subscribe: a GET of the page link, once, with the result parameter', () async {
      final forum = _Forum({'action=follow': 'follow_done.json', 'action=view': 'view_other.html'});
      final detail = parseCollectionDetail(parseHtmlDocument(_raw('view_other.html')));
      final outcome = await forum.repository(uid: 31).setFollow(detail, follow: true);
      expect(outcome, isA<CollectionDone>());
      expect(forum.sent.single.write, isTrue);
      expect(
        forum.sent.single.url,
        '$baseUrl/forum.php?mod=collection&action=follow&op=follow&ctid=3&formhash=f1f2f3f4&inajax=1',
      );
      await forum.repository(uid: 31).setFollow(detail, follow: false);
      expect(forum.sent.last.url, contains('op=unfo'));
    });

    test('nothing is sent once another account is in use than the page was served to', () async {
      final forum = _Forum({'mod=collection': 'follow_done.json'});
      final repository = forum.repository(uid: 31);
      final owner = parseCollectionDetail(parseHtmlDocument(_raw('view_owner.html')));
      expect(await repository.setFollow(owner, follow: true), isA<CollectionAccountChanged>());
      expect(await repository.delete(owner), isA<CollectionAccountChanged>());
      expect(await repository.removeThreads(owner, [1]), isA<CollectionAccountChanged>());
      expect(
        await repository.edit(owner, title: 'x', description: '', keywords: ''),
        isA<CollectionAccountChanged>(),
      );
      expect(forum.sent, isEmpty);
    });

    test('put a thread in several collections: the arrays as indexed fields', () async {
      final forum = _Forum({'op=addthread&tid=': 'dialog.json', 'op=addthread&inajax': 'collect_done.json'});
      final repository = forum.repository();
      final form = (await repository.fetchCollectForm(9199035)).toNullable()!;
      expect(forum.sent.single.write, isTrue);
      expect(forum.sent.single.url, '$baseUrl/forum.php?mod=collection&action=edit&op=addthread&tid=9199035&inajax=1');
      final outcome = await repository.collect(form, [4, 7], 'why');
      expect(outcome, isA<CollectionDone>());
      expect(forum.sent.last.body, {
        'formhash': 'f1f2f3f4',
        'addthread': '1',
        'handlekey': 'k_collect',
        'reason': 'why',
        'ctid[0]': '4',
        'ctid[1]': '7',
        'tids[0]': '9199035',
      });
    });

    test("a guest gets no window; the forum's refusal of the window is told", () async {
      final forum = _Forum({'op=addthread': 'dialog_guest.json'});
      expect((await forum.repository(uid: 0).fetchCollectForm(1)).getLeft().toNullable(), isA<CollectionNeedLogin>());
      expect(forum.sent, isEmpty);
      final refused = _Forum({'op=addthread': 'collect_none.json'});
      final outcome = (await refused.repository().fetchCollectForm(1)).getLeft().toNullable();
      expect((outcome! as CollectionRefused).message, '您还没有选择可以添加的淘专辑');
    });

    test('create, edit, take out, delete, comment: the forms the web pages post', () async {
      final forum = _Forum({
        'op=add&': 'create_done.json',
        'op=edit&': 'edit_done.json',
        'op=delthread': 'remove_threads_done.json',
        'op=remove': 'delete_done.json',
        'action=comment': 'comment_done.json',
      });
      final repository = forum.repository();
      final created = await repository.create(viewerUid: 35, formHash: 'f1f2f3f4', title: 'CL', keywords: 'a，b  c');
      expect(createdCtid(created), 3);
      expect(forum.sent.last.body, {
        'formhash': 'f1f2f3f4',
        'collectionsubmit': '1',
        'submitcollection': '1',
        'title': 'CL',
        'desc': '',
        'keyword': 'a b c',
      });
      final owner = parseCollectionDetail(parseHtmlDocument(_raw('view_owner.html')));
      await repository.edit(owner, title: 'N', description: 'D', keywords: 'K');
      expect(forum.sent.last.url, '$baseUrl/forum.php?mod=collection&action=edit&op=edit&ctid=3&inajax=1');
      expect(forum.sent.last.body?['title'], 'N');
      await repository.removeThreads(owner, [9199035, 1]);
      expect(forum.sent.last.body, {
        'formhash': 'f1f2f3f4',
        'ctid': '3',
        'delthread[0]': '9199035',
        'delthread[1]': '1',
      });
      expect(await repository.delete(owner), isA<CollectionDone>());
      expect(forum.sent.last.write, isTrue);
      expect(forum.sent.last.body, isNull);
      expect(forum.sent.last.url, contains('op=remove&ctid=3&formhash=f1f2f3f4'));
      // The rating is sent only while the account has not rated: the forum keeps the first.
      final ownerComments = parseCollectionComments(parseHtmlDocument(_raw('comments_owner.html')));
      await repository.comment(ownerComments, message: 'm', rate: 5);
      expect(forum.sent.last.body?['ratescore'], '5');
      final rated = parseCollectionComments(parseHtmlDocument(_raw('comments.html')));
      await forum.repository(uid: 31).comment(rated, message: 'm', rate: 5);
      expect(forum.sent.last.body?['ratescore'], '');
      expect(forum.sent.last.body?['message'], 'm');
    });
  });

  group('pager', () {
    /// A pager whose loads are answered by hand: page N of a load is its items `'<tag>:N'`, two pages.
    (CollectionPager<List<String>, String>, List<(int, Completer<List<String>>)>) pager() {
      final asked = <(int, Completer<List<String>>)>[];
      final p = CollectionPager<List<String>, String>(
        fetch: (page) => AsyncEither(() async {
          final c = Completer<List<String>>();
          asked.add((page, c));
          return right(await c.future);
        }),
        itemsOf: (page) => page,
        pagesOf: (_) => 2,
      );
      return (p, asked);
    }

    test('a refresh overtaken by another: the older answer is dropped', () async {
      final (p, asked) = pager();
      final first = p.refresh();
      final second = p.refresh();
      asked[1].$2.complete(['new:1']);
      await second;
      asked[0].$2.complete(['old:1']);
      await first;
      expect(p.items, ['new:1']);
      expect(p.loading, isFalse);
    });

    test('a next page asked before a refresh is not added to the list the refresh loaded', () async {
      final (p, asked) = pager();
      final load = p.refresh();
      asked[0].$2.complete(['a:1']);
      await load;
      final more = p.loadMore();
      final again = p.refresh();
      asked[2].$2.complete(['b:1']);
      await again;
      asked[1].$2.complete(['a:2']);
      await more;
      expect(p.items, ['b:1']);
      expect((p.loadedPages, p.loadingMore, p.hasMore), (1, false, true));
    });
  });

  test('the links of the collections open in the app', () {
    final detail = '$baseUrl/forum.php?mod=collection&action=view&ctid=3&fromop=my'.parseUrlToRoute();
    expect(detail?.screenPath, ScreenPaths.collectionDetail);
    expect(detail?.pathParameters, {'ctid': '3'});
    final comments = '$baseUrl/forum.php?mod=collection&action=view&op=comment&ctid=3'.parseUrlToRoute();
    expect(comments?.screenPath, ScreenPaths.collectionComments);
    expect('$baseUrl/forum.php?mod=collection'.parseUrlToRoute()?.screenPath, ScreenPaths.collections);
    expect('$baseUrl/forum.php?mod=collection&op=my'.parseUrlToRoute()?.queryParameters, {'tab': 'mine'});
    expect('$baseUrl/forum.php?mod=collection&op=all'.parseUrlToRoute()?.queryParameters, {'tab': 'all'});
    // The pages the app does not show stay with the web page.
    expect('$baseUrl/forum.php?mod=collection&action=edit&op=invite&ctid=3'.parseUrlToRoute(), isNull);
    expect('$baseUrl/forum.php?mod=collection&action=view&op=followers&ctid=3'.parseUrlToRoute(), isNull);
  });

  group('pages', () {
    Future<void> pump(WidgetTester tester, Widget home) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => home),
          for (final path in [ScreenPaths.threadV1, ScreenPaths.collectionComments, ScreenPaths.collectionDetail])
            GoRoute(
              path: path,
              name: path,
              builder: (_, state) => Scaffold(body: Text('at ${state.uri}')),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();
    }

    testWidgets("a collection's page subscribes, then shows the forum's page again", (tester) async {
      var followed = false;
      final forum = _Forum({});
      final repository = CollectionRepository(
        get: (url, {write = false}) async {
          forum.sent.add((url: url, write: write, body: null));
          if (url.contains('action=follow')) {
            followed = true;
            return right(_answer('follow_done.json'));
          }
          final html = _raw('view_other.html');
          return right(
            followed
                ? html
                      .replaceFirst('<i>订阅</i>', '<i class="u">取消订阅</i>')
                      .replaceFirst('id="follownum_display">0', 'id="follownum_display">1')
                : html,
          );
        },
        post: (url, body) async => throw StateError('nothing is posted'),
        currentUid: () => 31,
      );
      await pump(tester, CollectionDetailPage(ctid: 3, repository: repository));
      expect(find.text('CL測試 甲專輯'), findsWidgets);
      expect(find.byKey(const ValueKey('collection-thread-9199035')), findsOneWidget);
      // Nothing to manage on another member's collection.
      expect(find.byKey(const ValueKey('collection-menu')), findsNothing);
      expect(find.byKey(const ValueKey('collection-thread-menu-9199035')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('collection-follow')));
      await tester.pumpAndSettle();
      expect(forum.sent.where((e) => e.write).map((e) => e.url), [
        '$baseUrl/forum.php?mod=collection&action=follow&op=follow&ctid=3&formhash=f1f2f3f4&inajax=1',
      ]);
      expect(find.text(t.collection.unfollow), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('collection-thread-9199035')));
      await tester.pumpAndSettle();
      expect(find.text('at ${ScreenPaths.threadV1}?tid=9199035'), findsOneWidget);
    });

    testWidgets('the 淘帖 window: the collections holding the thread, a choice, the reason, sent once', (tester) async {
      final forum = _Forum({
        'op=addthread&tid=': 'dialog.json',
        'op=addthread&inajax': 'collect_done.json',
        'mod=collection&tid=': 'list_related.html',
      });
      await pump(tester, Scaffold(body: CollectThreadSheet(tid: 9199035, repository: forum.repository())));
      expect(find.byKey(const ValueKey('collect-related-3')), findsOneWidget);
      final submit = find.byKey(const ValueKey('collect-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('collect-choice-4')));
      await tester.enterText(find.byKey(const ValueKey('collect-reason')), 'good');
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final posts = forum.sent.where((e) => e.body != null).toList();
      expect(posts, hasLength(1));
      expect(posts.single.body?['ctid[0]'], '4');
      expect(posts.single.body?['reason'], 'good');
    });
  });
}

Translations get t => LocaleSettings.instance.currentTranslations;
