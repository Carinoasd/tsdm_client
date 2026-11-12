/// The panel's thread management (tsdmapp 3.9.0 `modcp_thread`, `schema` 36): the forums to choose from, a forum's
/// threads with what the account may do with them (`perms`, as on the forum page), the search sent as the answer
/// describes it (at least one condition: the panel lists the whole forum again without one, never taken for results),
/// the results' pages, and the threads picked handed to the forum page's management sheet.
///
/// The answers are the test forum's (scrubbed).
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
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/modcp_threads_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name, {int uid = 33}) => {
  ...jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>,
  'uid': uid,
};

ModcpThreadPage _read(Map<String, dynamic> json) => modcpThreadFromApi(json)!;

ModcpPagesRepository _repo({Object? Function(String url)? answer, List<String>? asked}) {
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async {
    asked?.add(url);
    return right((statusCode: 200, data: answer?.call(url) ?? _fixture('modcp_thread_fid2')));
  }

  // The panel's login: it sends the account on to the panel.
  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async =>
      right((statusCode: 302, data: null));

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
    test('without a forum: the forums to choose from, nothing listed nor managed', () {
      final page = _read(_fixture('modcp_thread_need', uid: 34));
      expect(page.needForum, isTrue);
      expect(page.fid, 0);
      expect(page.forums.map((f) => f.fid), [2, 6, 12, 25]);
      expect(page.threads, isEmpty);
      expect(page.perms, isNull);
      expect(page.canModerate, isFalse);
      expect(page.listUrl, isNull);
    });

    test("a forum's threads, the account's permissions, its management", () {
      final page = _read(_fixture('modcp_thread_fid2'));
      expect(
        (page.fid, page.forum, page.isModerator, page.needForum, page.isSearch),
        (
          2,
          '公告与新手报到',
          true,
          false,
          false,
        ),
      );
      expect((page.page, page.pages), (1, 4));
      expect(page.threads.length, 20);
      final first = page.threads.first;
      expect(
        (first.tid, first.subject, first.author, first.authorId),
        (9203132, 'other thread for 100', 'member_a', 104),
      );
      expect(first.dateline, greaterThan(0));
      expect(page.threadOptions.map((o) => o.value), ['0', '1', '2', '3', '4', '5', '999', '888']);
      final perms = page.perms!;
      expect(perms.threadOperations(ModerateOperation.values), [
        ModerateOperation.stick,
        ModerateOperation.digest,
        ModerateOperation.highlight,
        ModerateOperation.close,
        ModerateOperation.open,
        ModerateOperation.move,
        ModerateOperation.type,
        ModerateOperation.delete,
        ModerateOperation.bump,
        ModerateOperation.down,
      ]);
      expect((perms.stickMax, perms.digestMax), (2, 3));
      expect(page.canModerate, isTrue);
      expect(page.listUrl, '$baseUrl/forum.php?mod=modcp&action=thread&op=thread&do=list&fid=2');
      expect(
        page.resultsUrl(3),
        '$baseUrl/forum.php?mod=modcp&action=thread&op=thread&do=list&fid=2&page=3&tsdmapp=json&nodoc=1',
      );
    });

    test('the results of a search', () {
      final page = _read(_fixture('modcp_thread_search'));
      expect(page.isSearch, isTrue);
      expect(page.filters['users'], 'member_a');
      expect(page.count, 5);
      expect(page.threads.map((t) => t.tid), [9203132, 9203130, 9203128, 9203135, 9203134]);
    });

    test('a management form of another forum or page, a search sent elsewhere: not used', () {
      final json = _fixture('modcp_thread_fid2');
      final moderate = json['moderate'] as Map<String, dynamic>;
      for (final bad in [
        'forum.php?mod=topicadmin&action=moderate&fid=6',
        'forum.php?mod=topicadmin&action=delete&fid=2',
        'https://evil.test/forum.php?mod=topicadmin&action=moderate&fid=2',
      ]) {
        expect(
          _read({
            ...json,
            'moderate': {...moderate, 'url': bad},
          }).canModerate,
          isFalse,
          reason: bad,
        );
      }
      final search = json['search'] as Map<String, dynamic>;
      expect(ModcpSearchForm.parse(search, op: 'thread', conditions: ModcpThreadQuery.all), isNotNull);
      expect(ModcpSearchForm.parse(search, op: 'post', conditions: ModcpThreadQuery.all), isNull);
      expect(
        ModcpSearchForm.parse(
          {...search, 'url': 'forum.php?mod=modcp&action=thread&op=thread&id=x'},
          op: 'thread',
          conditions: {},
        ),
        isNull,
      );
      expect(ModcpSearchForm.parse({...search, 'fid_field': 'fid[]'}, op: 'thread', conditions: {}), isNull);
      expect(_read({...json, 'list_url': 'forum.php?mod=modcp&action=report&do=list'}).listUrl, isNull);
      // The fixed fields never choose the page: the panel reads them over the URL's.
      for (final fields in [
        {'do': 'search', 'submit': 'true', 'mod': 'post'},
        {'do': 'search', 'submit': 'true', 'action': 'report'},
        {'do': 'delete', 'submit': 'true'},
        {'submit': 'true'},
        {'do': 'search', 'op': 'post'},
      ]) {
        expect(
          ModcpSearchForm.parse({...search, 'fields': fields}, op: 'thread', conditions: ModcpThreadQuery.all),
          isNull,
          reason: '$fields',
        );
      }
      expect(
        _read({
          ...json,
          'moderate': {...moderate, 'url': '${moderate['url']}&action2=x'},
        }).canModerate,
        isFalse,
      );
    });

    test('a search needs a condition: the type "all" is none', () {
      expect(ModcpThreadQuery.hasCondition({'threadoption': '0'}), isFalse);
      expect(ModcpThreadQuery.hasCondition({'threadoption': '0', 'users': ' '}), isFalse);
      expect(ModcpThreadQuery.hasCondition({'threadoption': '999'}), isTrue);
      expect(ModcpThreadQuery.hasCondition({'threadoption': '0', 'noreplydays': '30'}), isTrue);
    });
  });

  group('repository', () {
    test('the forum, a page of it, a search, its results', () async {
      final asked = <String>[];
      final repo = _repo(asked: asked);
      final page = ((await repo.fetchThreads(fid: 2, page: 2).run()) as Right).value as ModcpReady<ModcpThreadPage>;
      expect(asked.last, '$baseUrl/forum.php?mod=modcp&action=thread&op=thread&fid=2&page=2&tsdmapp=json&nodoc=1');
      await repo.searchThreads(page.value, {'threadoption': '0', 'users': ' member_a ', 'keywords': ''}).run();
      expect(
        asked.last,
        '$baseUrl/forum.php?mod=modcp&action=thread&op=thread&do=search&submit=true&fid=2&threadoption=0&users=member_a'
        '&tsdmapp=json&nodoc=1',
      );
      await repo.fetchThreadResults(page.value, 2).run();
      expect(
        asked.last,
        '$baseUrl/forum.php?mod=modcp&action=thread&op=thread&do=list&fid=2&page=2&tsdmapp=json&nodoc=1',
      );
    });

    test('a search without a condition, or of no forum, is never sent', () async {
      final asked = <String>[];
      final repo = _repo(asked: asked);
      final page = _read(_fixture('modcp_thread_fid2'));
      expect(await repo.searchThreads(page, {'threadoption': '0'}).run(), isA<Left<AppException, Object?>>());
      final need = _read(_fixture('modcp_thread_need'));
      expect(await repo.searchThreads(need, {'users': 'a'}).run(), isA<Left<AppException, Object?>>());
      expect(asked, isEmpty);
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
            home: ModcpThreadsPage(repository: repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a forum chosen, its threads; a search, its results; back to the forum', (tester) async {
      final asked = <String>[];
      await pump(
        tester,
        _repo(
          asked: asked,
          answer: (url) => switch (Uri.parse(url).queryParameters) {
            {'do': 'search'} => _fixture('modcp_thread_search'),
            {'fid': '2'} => _fixture('modcp_thread_fid2'),
            _ => _fixture('modcp_thread_need'),
          },
        ),
      );
      expect(find.byKey(const ValueKey('modcp-forum-2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modcp-forum-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-thread-9203135')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-threads-clear-search')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('modcp-threads-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-threads-users')), 'member_a');
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search-submit')));
      await tester.pumpAndSettle();
      expect(Uri.parse(asked.last).queryParameters, containsPair('users', 'member_a'));
      expect(find.byKey(const ValueKey('modcp-thread-9203132')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-thread-9202952')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-threads-clear-search')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('modcp-threads-clear-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-thread-9202952')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-threads-clear-search')), findsNothing);
    });

    testWidgets('a search without a condition is not sent; one answered with the whole forum is not its results', (
      tester,
    ) async {
      final asked = <String>[];
      await pump(tester, _repo(asked: asked));
      final before = asked.length;
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search-submit')));
      await tester.pumpAndSettle();
      expect(asked.length, before);
      expect(find.text('Fill in at least one condition'), findsOneWidget);

      // The panel lists the forum again (`do` empty): the forum stays shown, no search to clear.
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-threads-keywords')), 'x');
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search-submit')));
      await tester.pumpAndSettle();
      expect(asked.length, before + 1);
      expect(find.byKey(const ValueKey('modcp-threads-clear-search')), findsNothing);
    });

    testWidgets('the threads picked go to the management sheet, its operations those the answer allows', (
      tester,
    ) async {
      await pump(tester, _repo());
      expect(find.byKey(const ValueKey('modcp-threads-moderate')), findsOneWidget);
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('modcp-thread-9203135')), matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-threads-moderate')));
      await tester.pumpAndSettle();
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Recommend'), findsNothing);
    });

    testWidgets("the panel's password asked during a search: the search is run again once logged in", (tester) async {
      final asked = <String>[];
      var login = true;
      await pump(
        tester,
        _repo(
          asked: asked,
          answer: (url) {
            if (!url.contains('do=search')) {
              return _fixture('modcp_thread_fid2');
            }
            if (login) {
              login = false;
              return {
                ..._fixture('modcp_report_login'),
                'uid': 33,
                'head': "<script>var discuz_uid = '33';</script>",
              };
            }
            return _fixture('modcp_thread_search');
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-threads-users')), 'member_a');
      await tester.tap(find.byKey(const ValueKey('modcp-threads-search-submit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'pw');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      final searches = asked.where((u) => u.contains('do=search')).toList();
      expect(searches.length, 2);
      expect(Uri.parse(searches.last).queryParameters, containsPair('users', 'member_a'));
      expect(find.byKey(const ValueKey('modcp-thread-9202952')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-thread-9203132')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-threads-clear-search')), findsOneWidget);
    });

    testWidgets('no management form: the threads only open', (tester) async {
      await pump(tester, _repo(answer: (_) => {..._fixture('modcp_thread_fid2'), 'moderate': null}));
      expect(find.byKey(const ValueKey('modcp-threads-moderate')), findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('modcp-thread-9203135')), matching: find.byType(Checkbox)),
        findsNothing,
      );
    });
  });
}
