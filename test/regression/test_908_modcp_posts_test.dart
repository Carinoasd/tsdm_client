/// The panel's post management (tsdmapp 3.9.0 `modcp_post`, `schema` 37): the search sent as the answer describes it,
/// the panel's reasons for not searching (`error_key`) worded by the app, the limits (an end time the account may not
/// choose is not offered), the results each opening its floor, and the posts picked deleted once confirmed: done only
/// on `modcp_thread_delete_succeed` (worded by the app: X5's language pack lacks it) with none of them listed again,
/// refused when the account may not delete posts.
///
/// The GET answers are the test forum's (scrubbed); the answers to a deletion (the same page with `message_key`) are
/// shaped as the spec gives them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/modcp_posts_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name, {int uid = 33}) => {
  ...jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>,
  'uid': uid,
};

ModcpPostPage _read(Map<String, dynamic> json) => modcpPostFromApi(json)!;

/// The results after deleting: [left] of the search's posts still listed, with [key].
Map<String, dynamic> _deleted({List<int> left = const [], String key = 'modcp_thread_delete_succeed', int error = 0}) {
  final json = _fixture('modcp_post_search');
  final posts = (json['posts'] as List).cast<Map<String, dynamic>>();
  return {
    ...json,
    'posts': [
      for (final p in posts)
        if (left.contains(p['pid'])) p,
    ],
    'count': left.length,
    'error': error,
    'error_key': error == 4 ? 'noperm' : '',
    'message_key': key,
  };
}

ModcpPagesRepository _repo({
  Object? Function(String url)? answer,
  Object? reply,
  List<String>? asked,
  List<(String, Map<String, String>)>? posted,
}) {
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async {
    asked?.add(url);
    return right((statusCode: 200, data: answer?.call(url) ?? _fixture('modcp_post_fid2')));
  }

  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async {
    posted?.add((url, body));
    if (url.contains('action=login')) {
      // The panel's login: it sends the account on to the panel.
      return right((statusCode: 302, data: null));
    }
    return right((statusCode: 200, data: reply ?? _deleted()));
  }

  return ModcpPagesRepository(
    panel: ModcpRepository(get: get, post: post, currentUid: () => 33),
    get: get,
    post: post,
    currentUid: () => 33,
  );
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('answer', () {
    test('before a search: the conditions shown, the limits, the forms', () {
      final page = _read(_fixture('modcp_post_fid2'));
      expect((page.fid, page.forum, page.isSearch, page.error), (2, '公告与新手报到', false, ModcpPostError.none));
      expect(page.filters['starttime'], isNotEmpty);
      expect(page.threadOptions.map((o) => o.value), ['0', '1', '2']);
      expect(page.limits, (days: 14, endTimeFixed: true, keywordMinBytes: 4));
      expect(page.posts, isEmpty);
      expect((page.allowDelete, page.canDelete), (true, true));
      expect(page.deleteForm!.ids.form.url, '$baseUrl/forum.php?mod=modcp&action=thread&op=post');
      expect(page.deleteForm!.ids.form.fields, {
        'formhash': 'f1f2f3f4',
        'fid': '2',
        'do': 'delete',
        'posttableid': '0',
        'deletesubmit': 'true',
      });
    });

    test('a moderator without bulk deletion, all its forums', () {
      final page = _read(_fixture('modcp_post_area', uid: 34));
      expect((page.fid, page.allowDelete, page.canDelete), (0, false, false));
      expect(page.limits.days, 7);
    });

    test('the results: each floor, its thread, first posts and those waiting', () {
      final page = _read(_fixture('modcp_post_search'));
      expect(page.isSearch, isTrue);
      expect(page.count, 8);
      final first = page.posts.first;
      expect(
        (first.pid, first.tid, first.fid, first.first, first.subject, first.author, first.authorId),
        (
          16018,
          9203135,
          2,
          true,
          'paid thread',
          'member_a',
          104,
        ),
      );
      expect(page.posts.where((p) => !p.first), isNotEmpty);
      expect(page.posts.every((p) => !p.pending), isTrue);
      expect(
        _read({
          ..._fixture('modcp_post_search'),
          'posts': [
            {...(_fixture('modcp_post_search')['posts'] as List).first as Map<String, dynamic>, 'invisible': -2},
          ],
        }).posts.single.pending,
        isTrue,
      );
    });

    test("the panel's reasons", () {
      expect(_read(_fixture('modcp_post_condition')).error, ModcpPostError.condition);
      for (final (key, error) in [
        ('range', ModcpPostError.range),
        ('keyword', ModcpPostError.keyword),
        ('noperm', ModcpPostError.noperm),
        ('later', ModcpPostError.unknown),
      ]) {
        expect(_read({..._fixture('modcp_post_fid2'), 'error': 9, 'error_key': key}).error, error);
      }
    });

    test('a deletion form sent elsewhere, or of another shape, is never used', () {
      final delete = _fixture('modcp_post_fid2')['delete'] as Map<String, dynamic>;
      expect(ModcpPostDeleteForm.parse(delete, fid: 2), isNotNull);
      expect(ModcpPostDeleteForm.parse(delete, fid: 6), isNull);
      for (final bad in [
        {'url': 'forum.php?mod=modcp&action=thread&op=thread'},
        {'url': 'forum.php?mod=modcp&action=recyclebin&op=post'},
        {'url': 'https://evil.test/forum.php?mod=modcp&action=thread&op=post'},
        {'ids_field': 'delete'},
        {'nocredit_field': 'no credit'},
        {'nocredit_field': 'do'},
        {'nocredit_field': 'fid'},
        {'ids_field': 'action[]'},
        {
          'fields': {'formhash': 'f', 'fid': '2', 'do': 'delete', 'deletesubmit': 'true', 'mod': 'post'},
        },
        {
          'fields': {'formhash': 'f', 'fid': '2', 'do': 'search', 'deletesubmit': 'true'},
        },
        {
          'fields': {'formhash': 'f', 'fid': '2', 'do': 'delete', 'action': 'report'},
        },
      ]) {
        expect(ModcpPostDeleteForm.parse({...delete, ...bad}, fid: 2), isNull, reason: '$bad');
      }
    });

    test('the body: the pids indexed, the credits kept only when asked', () {
      final form = _read(_fixture('modcp_post_fid2')).deleteForm!;
      expect(form.body([16018, 16013]), {
        'formhash': 'f1f2f3f4',
        'fid': '2',
        'do': 'delete',
        'posttableid': '0',
        'deletesubmit': 'true',
        'delete[0]': '16018',
        'delete[1]': '16013',
      });
      expect(form.body([1], keepCredits: true)['nocredit'], '1');
    });

    test('a search needs an author, a word or an IP', () {
      expect(ModcpPostQuery.hasCondition({'threadoption': '1', 'starttime': '2026-11-01'}), isFalse);
      expect(ModcpPostQuery.hasCondition({'useip': '203.0.113.*'}), isTrue);
    });
  });

  group('repository', () {
    test('the search and its pages, as the answer describes them', () async {
      final asked = <String>[];
      final repo = _repo(asked: asked);
      final shown = _read(_fixture('modcp_post_fid2'));
      await repo.fetchPosts().run();
      expect(asked.last, '$baseUrl/forum.php?mod=modcp&action=thread&op=post&tsdmapp=json&nodoc=1');
      await repo.searchPosts(shown, 0, {
        'threadoption': '0',
        'users': 'member_a',
        'keywords': '',
        'starttime': '2026-11-01',
      }).run();
      expect(
        asked.last,
        '$baseUrl/forum.php?mod=modcp&action=thread&op=post&do=search&searchsubmit=true&posttableid=0&fid=0'
        '&threadoption=0&users=member_a&starttime=2026-11-01&tsdmapp=json&nodoc=1',
      );
      await repo.fetchPostResults(_read(_fixture('modcp_post_search')), 2).run();
      expect(
        asked.last,
        '$baseUrl/forum.php?mod=modcp&action=thread&op=post&do=list&fid=2&posttableid=0&page=2&tsdmapp=json&nodoc=1',
      );
    });

    test('deleted: done only when the panel says so and lists none of them', () async {
      final shown = _read(_fixture('modcp_post_search'));
      final posted = <(String, Map<String, String>)>[];
      final done = await _repo(
        posted: posted,
        reply: _deleted(left: [16013]),
      ).deletePosts(shown, [16018, 16017]).run();
      expect(posted.single.$1, '$baseUrl/forum.php?mod=modcp&action=thread&op=post&tsdmapp=json');
      expect(((done as Right).value as ModcpPosted<ModcpPostPage>).outcome, isA<ModcpWriteDone>());
      expect(((done as Right).value as ModcpPosted<ModcpPostPage>).page!.posts.single.pid, 16013);

      final skipped = await _repo(reply: _deleted(left: [16017])).deletePosts(shown, [16018, 16017]).run();
      final notDone = ((skipped as Right).value as ModcpPosted<ModcpPostPage>).outcome as ModcpWriteNotDone;
      expect(notDone.remaining, ['16017']);

      final silent = await _repo(reply: _deleted(key: '')).deletePosts(shown, [16018]).run();
      expect(((silent as Right).value as ModcpPosted<ModcpPostPage>).outcome, isA<ModcpWriteUnknown>());

      final noperm = await _repo(reply: _deleted(key: '', error: 4)).deletePosts(shown, [16018]).run();
      final refused = (noperm as Right).value as ModcpPosted<ModcpPostPage>;
      expect(refused.outcome, isA<ModcpWriteRefused>());
      expect(refused.page!.error, ModcpPostError.noperm);
    });

    test('nothing sent without the permission, the form or a post', () async {
      final posted = <(String, Map<String, String>)>[];
      final repo = _repo(posted: posted);
      await repo.deletePosts(_read({..._fixture('modcp_post_search'), 'allow_delete': 0}), [16018]).run();
      await repo.deletePosts(_read({..._fixture('modcp_post_search'), 'delete': null}), [16018]).run();
      await repo.deletePosts(_read(_fixture('modcp_post_search')), []).run();
      expect(posted, isEmpty);
    });
  });

  group('page', () {
    Future<void> pump(WidgetTester tester, ModcpPagesRepository repo) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: ModcpPostsPage(repository: repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('no end time for an account whose end is now; a search without an author, word or IP not sent', (
      tester,
    ) async {
      final asked = <String>[];
      await pump(tester, _repo(asked: asked));
      expect(find.byKey(const ValueKey('modcp-posts-starttime')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-posts-endtime')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('modcp-posts-search')));
      await tester.pumpAndSettle();
      expect(asked.length, 1);
      expect(find.text('Fill in an author, a keyword or an IP'), findsOneWidget);
    });

    testWidgets("the panel's reason worded by the app", (tester) async {
      await pump(tester, _repo(answer: (_) => {..._fixture('modcp_post_fid2'), 'error': 3, 'error_key': 'keyword'}));
      expect(find.text('Keywords need at least 4 bytes'), findsOneWidget);
    });

    testWidgets('posts picked deleted once confirmed, the credits kept when asked; the app words it', (tester) async {
      final posted = <(String, Map<String, String>)>[];
      final asked = <String>[];
      await pump(
        tester,
        _repo(
          asked: asked,
          posted: posted,
          answer: (url) => url.contains('do=search') ? _fixture('modcp_post_search') : _fixture('modcp_post_fid2'),
          reply: _deleted(left: [16017]),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('modcp-posts-users')), 'member_a');
      await tester.tap(find.byKey(const ValueKey('modcp-posts-search')));
      await tester.pumpAndSettle();
      expect(Uri.parse(asked.last).queryParameters, containsPair('users', 'member_a'));
      expect(Uri.parse(asked.last).queryParameters.containsKey('endtime'), isFalse);
      expect(find.byKey(const ValueKey('modcp-post-16018')), findsOneWidget);

      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('modcp-post-16018')), matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-posts-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-posts-keep-credits')));
      await tester.pumpAndSettle();
      expect(posted, isEmpty);
      await tester.tap(find.byKey(const ValueKey('modcp-posts-delete-confirm')));
      await tester.pumpAndSettle();
      expect(posted.single.$2, containsPair('delete[0]', '16018'));
      expect(posted.single.$2, containsPair('nocredit', '1'));
      expect(find.text('Deleted 1 posts'), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-post-16018')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-post-16017')), findsOneWidget);
    });

    testWidgets("the panel's password asked during a search: the same search run again once logged in", (tester) async {
      final asked = <String>[];
      var login = true;
      await pump(
        tester,
        _repo(
          asked: asked,
          answer: (url) {
            if (!url.contains('do=search')) {
              return _fixture('modcp_post_fid2');
            }
            if (login) {
              login = false;
              return {
                ..._fixture('modcp_report_login'),
                'uid': 33,
                'head': "<script>var discuz_uid = '33';</script>",
              };
            }
            return _fixture('modcp_post_search');
          },
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('modcp-posts-users')), 'member_a');
      await tester.tap(find.byKey(const ValueKey('modcp-posts-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'pw');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      final searches = asked.where((u) => u.contains('do=search')).toList();
      expect(searches.length, 2);
      expect(searches.last, searches.first);
      expect(find.byKey(const ValueKey('modcp-post-16018')), findsOneWidget);
    });

    testWidgets('no deletion offered without the permission', (tester) async {
      await pump(
        tester,
        _repo(
          answer: (url) => {
            ..._fixture(url.contains('do=search') ? 'modcp_post_search' : 'modcp_post_fid2'),
            'allow_delete': 0,
          },
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('modcp-posts-users')), 'member_a');
      await tester.tap(find.byKey(const ValueKey('modcp-posts-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-post-16018')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-posts-delete')), findsNothing);
    });
  });
}
