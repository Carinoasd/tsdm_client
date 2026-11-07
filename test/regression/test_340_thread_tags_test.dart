import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show Either;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/tag/models/forum_tag.dart';
import 'package:tsdm_client/features/tag/repository/tag_repository.dart';
import 'package:tsdm_client/features/tag/view/tag_cloud_page.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:universal_html/parsing.dart';

/// Tag pages of the forum: the threads of a tag open in the latest thread page, the tag cloud has a page of its own.

String _data(String name) => File('test/data/tag/$name').readAsStringSync();

final class _FakeLatestRepository extends LatestThreadRepository {
  final requested = <String>[];

  @override
  AsyncEither<TsdmAppPageAnswer> fetchPage(String url) {
    requested.add(url);
    final file = url.contains('page=2') ? 'tag_threads_page2_x5.html' : 'tag_threads_page1_x5.html';
    return AsyncEither.right(TsdmAppWebPage(parseHtmlDocument(_data(file))));
  }
}

final class _FakeTagRepository extends TagRepository {
  _FakeTagRepository(this.answers);

  final List<Either<AppException, List<ForumTag>>> answers;
  int calls = 0;

  @override
  AsyncEither<List<ForumTag>> fetchCloud() => AsyncEither.fromEither(answers[calls++ % answers.length]);
}

void main() {
  group('tag cloud', () {
    test('parses the tags of the captured page in order, with their counts', () {
      final tags = parseTagCloud(parseHtmlDocument(_data('tag_cloud_x5.html')));
      expect(tags, hasLength(14));
      expect(tags.first.id, '14');
      expect(tags.first.name, '2026新番');
      expect(tags.first.count, 1);
      expect(tags.last.id, '1');
      expect(tags.where((e) => e.name == '无损').single.count, 3);
      expect(tags.first.url, endsWith('/misc.php?mod=tag&id=14'));
    });

    test('a page without tags is empty, a tag without a count keeps 0', () {
      expect(parseTagCloud(parseHtmlDocument('<html><body>nothing</body></html>')), isEmpty);
      final tags = parseTagCloud(
        parseHtmlDocument(
          '<div class="taglist"><a href="misc.php?mod=tag&amp;id=5">A</a><a href="misc.php?mod=tag&amp;id=5">dup</a> '
          '<a href="misc.php?mod=tag">no id</a></div>',
        ),
      );
      expect(tags.map((e) => (e.id, e.name, e.count)), [('5', 'A', 0)]);
    });

    testWidgets('shows the tags, retries a failed load', (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final repository = _FakeTagRepository([
        Either.left(HttpRequestFailedException(500)),
        Either.right(parseTagCloud(parseHtmlDocument(_data('tag_cloud_x5.html')))),
      ]);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: TagCloudPage(repository: repository)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ActionChip), findsNothing);
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();
      expect(repository.calls, 2);
      expect(find.byType(ActionChip), findsNWidgets(14));
      expect(find.text('无损 3'), findsOneWidget);
      expect(find.text(t.tagPage.cloudTitle), findsOneWidget);
    });
  });

  group('tag page', () {
    test('the threads of a tag are read from the paged list, then the next page', () async {
      final repository = _FakeLatestRepository();
      final bloc = LatestThreadBloc(latestThreadRepository: repository);
      addTearDown(bloc.close);
      const url = 'https://forum.test/misc.php?mod=tag&id=15&type=thread';
      bloc.add(const LatestThreadRefreshRequested(url));
      await bloc.stream.firstWhere((s) => s.status == LatestThreadStatus.success);

      var state = bloc.state;
      expect(state.tagName, '分页测试');
      expect(state.threadList, hasLength(20));
      final first = state.threadList.first;
      expect(first.title, isNotEmpty);
      expect(first.threadID, isNotNull);
      expect(first.forumName, isNotEmpty);
      expect(first.threadAuthor?.name, isNotEmpty);
      expect(first.replyCount, isNotNull);
      expect(state.nextPageUrl, contains('page=2'));

      bloc.add(LatestThreadLoadMoreRequested());
      await bloc.stream.firstWhere((s) => s.pageNumber == 2 && !s.loadingMore);
      state = bloc.state;
      expect(repository.requested.last, contains('page=2'));
      expect(state.threadList, hasLength(25));
      expect(state.nextPageUrl, isNull);
      expect(state.threadList.map((e) => e.threadID).toSet(), hasLength(25));
    });

    test('the preview page of a tag lists its threads too', () async {
      final repository = _FakeLatestRepository();
      final bloc = LatestThreadBloc(latestThreadRepository: repository);
      addTearDown(bloc.close);
      bloc.add(const LatestThreadRefreshRequested('https://forum.test/misc.php?mod=tag&id=2'));
      await bloc.stream.firstWhere((s) => s.status == LatestThreadStatus.success);
      expect(bloc.state.threadList, isNotEmpty);
    });
  });

  group('tag links', () {
    test('a tag link opens the full paged list in the latest thread page', () {
      final route = 'misc.php?mod=tag&id=2'.parseUrlToRoute();
      expect(route?.screenPath, ScreenPaths.latestThread);
      final url = Uri.parse(route!.queryParameters['url']!);
      expect(url.path, '/misc.php');
      expect(url.queryParameters, {'mod': 'tag', 'id': '2', 'type': 'thread'});
    });

    test('keeps the page, takes a tag by name, ignores the other kinds', () {
      final paged = 'https://www.tsdm39.com/misc.php?mod=tag&id=7&type=thread&page=3'.parseUrlToRoute();
      expect(Uri.parse(paged!.queryParameters['url']!).queryParameters['page'], '3');
      final named = 'misc.php?mod=tag&name=OST'.parseUrlToRoute();
      expect(Uri.parse(named!.queryParameters['url']!).queryParameters, {
        'mod': 'tag',
        'name': 'OST',
        'type': 'thread',
      });
      expect('misc.php?mod=tag&id=7&type=blog'.parseUrlToRoute(), isNull);
      expect('misc.php?mod=tag&op=manage&id=7'.parseUrlToRoute(), isNull);
      expect('https://example.com/misc.php?mod=tag&id=7'.parseUrlToRoute(), isNull);
    });

    test('the tag list without an id is the cloud', () {
      expect('misc.php?mod=tag'.parseUrlToRoute()?.screenPath, ScreenPaths.tagCloud);
      expect('misc.php?mod=tag&id=0'.parseUrlToRoute()?.screenPath, ScreenPaths.tagCloud);
    });
  });
}
