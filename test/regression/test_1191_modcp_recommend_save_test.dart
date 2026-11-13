/// The panel's 推荐主题 read and posted by the panel's repository, and its page.
///
/// * Read: one GET of the web page (the forum's app API answers no fields for it, no `status` asked); a page served to
///   another account is dropped; the forum's "no permission" and messages are its refusal in its words.
/// * Posted once to `mod=modcp&action=forum` with the list's form; never for a list the forum orders itself, nor once
///   the account changed. Done when the panel prints its line (推荐主题更新成功) on the list it draws again; taking
///   threads off is done when none of them is listed any more; the forum's message (an end not in its format) is a
///   refusal in its words.
/// * The page: the list as cards (the title, its place, author, recommender, end), a tap opens the change of one
///   (place, title, end), the threads picked are taken off after a confirmation; a list the forum orders itself is
///   read only (no box, no bar).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_recommend.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/view/recommend_threads_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _raw(String name) => File('test/data/modcp_recommend/$name.html').readAsStringSync();

RecommendList _list(String name) => parseRecommendList(parseHtmlDocument(_raw(name)), uid: 33)!;

final class _Log {
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];
}

ModcpRepository _repo(_Log log, {List<String> pages = const [], String? posted, int Function()? uid}) {
  var i = 0;
  return ModcpRepository(
    get: (url) async {
      log.gets.add(url);
      final page = pages[i < pages.length ? i++ : pages.length - 1];
      return right((statusCode: 200, data: page));
    },
    post: (url, body) async {
      log.posts.add((url, body));
      return posted == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: posted));
    },
    currentUid: uid ?? () => 33,
    ensureStatus: () async => throw StateError('the status is not asked'),
  );
}

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('read', () {
    test('one GET of the web page', () async {
      final log = _Log();
      final answer = await _repo(log, pages: [_raw('editable')]).fetchRecommends(fid: 6).run();
      expect(log.gets, [RecommendList.url(fid: 6)]);
      expect(answer.getRight().toNullable(), isA<ModcpReady<RecommendList>>());
    });

    test('a page served to another account is dropped', () async {
      final answer = await _repo(_Log(), pages: [_raw('editable')], uid: () => 34).fetchRecommends(fid: 6).run();
      expect(answer.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test("no permission and the forum's message: its refusal in its words", () async {
      final noperm = await _repo(
        _Log(),
        pages: [_raw('noperm').replaceFirst("'33'", "'34'")],
        uid: () => 34,
      ).fetchRecommends(fid: 6).run();
      expect(
        noperm.getRight().toNullable(),
        isA<ModcpRefused<RecommendList>>().having((e) => e.message, 'message', contains('抱歉，您无此权限')),
      );
      final message = await _repo(
        _Log(),
        pages: [_raw('message').replaceFirst("'33'", "'35'")],
        uid: () => 35,
      ).fetchRecommends(fid: 6).run();
      expect(message.getRight().toNullable(), isA<ModcpRefused<RecommendList>>());
    });
  });

  group('post', () {
    test('a change: posted once with the whole list, done on the panel line', () async {
      final log = _Log();
      final list = _list('editable');
      final outcome = await _repo(
        log,
        posted: _raw('saved'),
      ).saveRecommends(list, edits: {9199890: (order: 3, subject: 'x', expiration: '')}).run();
      expect(log.posts, hasLength(1));
      expect(log.posts.single.$1, RecommendList.submitUrl);
      expect(log.posts.single.$2['order[9199890]'], '3');
      expect(log.posts.single.$2['subject[9199891]'], '本周推荐 <新番>');
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteDone>().having((e) => e.message, 'message', '推荐主题更新成功，请继续操作'),
      );
    });

    test('a line beside the button the list was read with does not tell it was saved', () async {
      final list = _list('editable');
      final read = RecommendList(
        uid: list.uid,
        fid: list.fid,
        forums: list.forums,
        threads: list.threads,
        editable: true,
        formHash: list.formHash,
        message: '推荐主题更新成功，请继续操作',
      );
      final outcome = await _repo(
        _Log(),
        posted: _raw('saved'),
      ).saveRecommends(read, edits: {9199890: (order: 3, subject: 'x', expiration: '')}).run();
      expect(outcome.getRight().toNullable(), isA<ModcpWriteUnknown>());
    });

    test('an end the forum does not take: its refusal in its words', () async {
      final outcome = await _repo(
        _Log(),
        posted: _raw('bad_expiration'),
      ).saveRecommends(_list('editable'), edits: {9199890: (order: 0, subject: 'x', expiration: '2027/1/2')}).run();
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteRefused>().having((e) => e.message, 'message', contains('时间期限格式无效')),
      );
    });

    test('taken off: done when not listed any more, not done for those still listed', () async {
      final list = _list('editable');
      // The panel's empty list of the same forum.
      final empty =
          _raw(
                'empty',
              )
              .replaceFirst('value="7" selected="selected">', 'value="7" >')
              .replaceFirst('value="6" >', 'value="6" selected="selected">');
      final gone = await _repo(_Log(), posted: empty).saveRecommends(list, remove: {9199890, 9199891}).run();
      expect(gone.getRight().toNullable(), isA<ModcpWriteDone>());
      final kept = await _repo(_Log(), posted: _raw('saved')).saveRecommends(list, remove: {9199890}).run();
      expect(
        kept.getRight().toNullable(),
        isA<ModcpWriteNotDone>().having((e) => e.remaining, 'remaining', ['9199890']),
      );
    });

    test('never for a list the forum orders itself, nor once the account changed', () async {
      final log = _Log();
      final auto = await _repo(log, posted: _raw('saved')).saveRecommends(_list('auto'), remove: {9199070}).run();
      expect(auto.getRight().toNullable(), isA<ModcpWriteRefused>());
      final changed = await _repo(
        log,
        posted: _raw('saved'),
        uid: () => 34,
      ).saveRecommends(_list('editable'), remove: {9199890}).run();
      expect(changed.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(log.posts, isEmpty);
    });
  });

  group('page', () {
    testWidgets('the list; a tap changes one thread, sent once', (tester) async {
      final log = _Log();
      await _pump(
        tester,
        RecommendThreadsPage(
          repository: _repo(log, pages: [_raw('editable')], posted: _raw('saved')),
        ),
      );
      expect(find.text('推荐主题 · 新番追蹤'), findsOneWidget);
      expect(find.text('本周推荐 <新番>'), findsOneWidget);
      expect(find.text('2027-1-2 03:04'), findsOneWidget);
      await tester.tap(find.text('本周推荐 <新番>'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-recommend-order')), '5');
      await tester.tap(find.byKey(const ValueKey('modcp-recommend-expiration-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-recommend-save')));
      await tester.pumpAndSettle();
      expect(log.posts, hasLength(1));
      expect(log.posts.single.$2['order[9199891]'], '5');
      expect(log.posts.single.$2['expirationrecommend[9199891]'], '');
      expect(log.posts.single.$2.keys.where((k) => k.startsWith('delete')), isEmpty);
      // Read again after it.
      expect(log.gets, hasLength(2));
    });

    testWidgets('no empty title, no place the forum can not keep', (tester) async {
      final log = _Log();
      await _pump(
        tester,
        RecommendThreadsPage(
          repository: _repo(log, pages: [_raw('editable')], posted: _raw('saved')),
        ),
      );
      await tester.tap(find.text('本周推荐 <新番>'));
      await tester.pumpAndSettle();
      bool saveEnabled() =>
          tester.widget<TextButton>(find.byKey(const ValueKey('modcp-recommend-save'))).onPressed != null;
      await tester.enterText(find.byKey(const ValueKey('modcp-recommend-subject')), '  ');
      await tester.pump();
      expect(saveEnabled(), isFalse);
      await tester.enterText(find.byKey(const ValueKey('modcp-recommend-subject')), 'x');
      await tester.enterText(find.byKey(const ValueKey('modcp-recommend-order')), '200');
      await tester.pump();
      expect(saveEnabled(), isFalse);
      await tester.enterText(find.byKey(const ValueKey('modcp-recommend-order')), '-5');
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('modcp-recommend-order'))).controller!.text, '5');
      expect(saveEnabled(), isTrue);
      expect(log.posts, isEmpty);
    });

    testWidgets('a place the web page set out of range may stay as it is', (tester) async {
      final page = _raw('editable').replaceFirst(
        RegExp(r'name="order\[9199891\]" class="px" size="3" value="\d+"'),
        'name="order[9199891]" class="px" size="3" value="-1"',
      );
      final log = _Log();
      await _pump(
        tester,
        RecommendThreadsPage(
          repository: _repo(log, pages: [page], posted: _raw('saved')),
        ),
      );
      await tester.tap(find.text('本周推荐 <新番>'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-recommend-subject')), '改标题');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('modcp-recommend-save')));
      await tester.pumpAndSettle();
      expect(log.posts.single.$2['order[9199891]'], '-1');
      expect(log.posts.single.$2['subject[9199891]'], '改标题');
    });

    testWidgets('the threads picked are taken off after a confirmation', (tester) async {
      final log = _Log();
      await _pump(
        tester,
        RecommendThreadsPage(
          repository: _repo(log, pages: [_raw('editable')], posted: _raw('saved')),
        ),
      );
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-recommend-remove')));
      await tester.pumpAndSettle();
      expect(log.posts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('modcp-recommend-remove-confirm')));
      await tester.pumpAndSettle();
      expect(log.posts, hasLength(1));
      expect(log.posts.single.$2['delete[0]'], '9199890');
    });

    testWidgets('a list the forum orders itself is read only', (tester) async {
      final log = _Log();
      await _pump(tester, RecommendThreadsPage(repository: _repo(log, pages: [_raw('auto')])));
      expect(find.byKey(const ValueKey('modcp-recommend-9199070')), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byKey(const ValueKey('modcp-recommend-remove')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('modcp-recommend-9199070')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-recommend-save')), findsNothing);
    });

    testWidgets("the panel's tile: where the menu offers the page", (tester) async {
      await _pump(
        tester,
        ModeratorPanelPage(
          key: UniqueKey(),
          repository: _repo(_Log(), pages: [_raw('editable')]),
        ),
      );
      expect(find.byKey(const ValueKey('modcp-recommend')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modcp-recommend')));
      await tester.pumpAndSettle();
      expect(find.byType(RecommendThreadsPage), findsOneWidget);

      await _pump(
        tester,
        ModeratorPanelPage(
          key: UniqueKey(),
          repository: _repo(_Log(), pages: [_raw('noperm').replaceFirst("'33'", "'34'")], uid: () => 34),
        ),
      );
      expect(find.byKey(const ValueKey('modcp-recommend')), findsNothing);
    });
  });
}
