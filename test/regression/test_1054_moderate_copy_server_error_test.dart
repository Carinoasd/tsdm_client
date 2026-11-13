// The forum's own copy of a thread answered some threads with 503 (Database Error) after it had made the new thread:
// an empty thread was left in the forum, and the app said only that the request failed, inviting another try.
//
// Copy, merge and split write before the forum answers. A server error or a connection lost after the request left
// leaves their result unknown: the app says so ("check the forum"), reads the thread again and offers nothing to
// send twice; never sent again by itself. Any other operation, or a forum that could not be reached at all, is a
// failure as before.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/split_thread_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Translations get t => LocaleSettings.instance.currentTranslations;

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _fid = 13;
const _uid = 31;

Object? _data(String name) {
  final text = File('$_dir/$name').readAsStringSync();
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

Future<Either<AppException, ModerateResponse>> _databaseError() async =>
    right((statusCode: 503, data: '<h1>Discuz! Database Error</h1>'));

Future<Either<AppException, ModerateResponse>> _connectionLost() async =>
    left(HttpHandshakeFailedException('reset', connectionLost: true));

Future<Either<AppException, ModerateResponse>> _offline() async =>
    left(HttpHandshakeFailedException('offline', connectionFailed: true));

/// A thread of three floors, for the split.
ThreadPageInfo _threadPage() => threadPageFromApi({
  'ok': 1,
  'api': 1,
  'uid': _uid,
  'formhash': 'f1f2f3f4',
  'type': 'thread',
  'schema': 13,
  'thread': {'tid': int.parse(_tid), 'fid': _fid, 'subject': '测试主题', 'replies': 2},
  'forum': {'fid': _fid, 'name': '测试版块'},
  'page': 1,
  'pages': 1,
  'ppp': 10,
  'posts': [
    for (final (floor, pid, author) in [(1, 101, '甲'), (2, 102, '乙'), (3, 103, '丙')])
      {
        'pid': pid,
        'position': floor,
        'first': floor <= 1 ? 1 : 0,
        'authorid': 40 + floor,
        'author': author,
        'dateline': 1700000000 + floor,
        'message': '第$floor楼',
        'body_html': '<div class="t_fsz">第$floor楼</div>',
      },
  ],
}, 1);

/// [answer]: what the forum answers a post, a 503 page or no answer at all.
ModerateRepository _repo(
  Object? window,
  List<String> posts,
  Future<Either<AppException, ModerateResponse>> Function() answer,
) => ModerateRepository(
  get: (url) async => right((statusCode: 200, data: window)),
  post: (url, body) async {
    posts.add(url);
    return answer();
  },
  threadPage: (tid, page) async => right(_threadPage()),
  currentUid: () => _uid,
);

Widget _app(void Function(BuildContext context) open) => TranslationProvider(
  child: MaterialApp(
    scaffoldMessengerKey: snackbarKey,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(onPressed: () => open(context), child: const Text('open')),
      ),
    ),
  ),
);

/// The forum to copy to: one without categories.
Future<void> _pickForum(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('GLTEST 子版塊（型別 sub）').last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('a write that may have landed', () {
    test('a server error, a redirect, or no answer after the request left', () {
      for (final (e, expected) in [
        (HttpRequestFailedException(503), true),
        (HttpRequestFailedException(500), true),
        (HttpRequestFailedException(302), true),
        (HttpRequestFailedException(null), true),
        (HttpHandshakeFailedException('reset', connectionLost: true), true),
        (HttpHandshakeFailedException('timeout', timedOut: true), true),
        (HttpHandshakeFailedException('offline', connectionFailed: true), false),
        (HttpRequestFailedException(200), false),
        (HttpRequestFailedException(404), false),
        (HttpRequestFailedException(403), false),
        (IdentityChangedException(), false),
      ]) {
        expect(writeMayHaveLanded(e), expected, reason: '$e');
      }
    });

    test('the rule of a direct reply is the same, but the reply window', () {
      for (final e in [
        HttpRequestFailedException(503),
        HttpRequestFailedException(404),
        HttpHandshakeFailedException('reset', connectionLost: true),
        HttpHandshakeFailedException('offline', connectionFailed: true),
      ]) {
        expect(directReplyMayHaveSent(e), writeMayHaveLanded(e), reason: '$e');
      }
      expect(directReplyMayHaveSent(ReplyWindowFetchFailedException(noNetwork: false, statusCode: 503)), isFalse);
    });

    test('copy, merge and split only', () {
      final e = HttpRequestFailedException(503);
      expect(
        [
          for (final op in ModerateOperation.values)
            if (op.resultUnknownOn(e)) op,
        ],
        [ModerateOperation.copy, ModerateOperation.merge, ModerateOperation.split],
      );
      expect(ModerateOperation.copy.resultUnknownOn(HttpHandshakeFailedException('x', connectionFailed: true)), false);
      expect(ModerateOperation.copy.resultUnknownOn(HttpRequestFailedException(404)), false);
    });
  });

  group('copy', () {
    for (final (label, answer) in [('503', _databaseError), ('connection lost', _connectionLost)]) {
      testWidgets('$label: unknown, said so, the dialog closed as done, sent once', (tester) async {
        final posts = <String>[];
        bool? done;
        await tester.pumpWidget(
          _app((context) async {
            done = await showDialog<bool>(
              context: context,
              builder: (_) => ModerateDialog(
                operation: ModerateOperation.copy,
                tid: _tid,
                fid: _fid,
                repository: _repo(_data('window_copy.json'), posts, answer),
              ),
            );
          }),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await _pickForum(tester);
        await tester.tap(find.widgetWithText(TextButton, t.general.ok));
        await tester.pumpAndSettle();

        expect(posts, hasLength(1));
        expect(posts.single, contains('action=copy'));
        expect(find.byType(ModerateDialog), findsNothing);
        expect(done, isTrue);
        expect(find.text(t.moderate.unconfirmed), findsOneWidget);
        expect(find.text(t.moderate.failed), findsNothing);
      });
    }

    testWidgets('a forum not reached: failed, the dialog stays to send again', (tester) async {
      final posts = <String>[];
      await tester.pumpWidget(
        _app(
          (context) => showDialog<bool>(
            context: context,
            builder: (_) => ModerateDialog(
              operation: ModerateOperation.copy,
              tid: _tid,
              fid: _fid,
              repository: _repo(_data('window_copy.json'), posts, _offline),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await _pickForum(tester);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(find.byType(ModerateDialog), findsOneWidget);
      expect(find.text(t.moderate.failed), findsOneWidget);
      expect(find.text(t.moderate.unconfirmed), findsNothing);
    });
  });

  testWidgets('another operation answered 503: failed as before, the dialog stays', (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(
      _app(
        (context) => showDialog<bool>(
          context: context,
          builder: (_) => ModerateDialog(
            operation: ModerateOperation.repair,
            tid: _tid,
            fid: _fid,
            repository: _repo(null, posts, _databaseError),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, t.general.ok));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(find.byType(ModerateDialog), findsOneWidget);
    expect(find.text(t.moderate.failed), findsOneWidget);
  });

  group('split', () {
    Future<void> pick(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(CheckboxListTile, '丙'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t.moderate.splitSubject), '新主题');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, t.general.ok)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('503: the page closed as unknown, sent once', (tester) async {
      final posts = <String>[];
      ModerateSplitDone? done;
      await tester.pumpWidget(
        _app((context) async {
          done = await openSplitThreadPage(
            context,
            tid: _tid,
            fid: _fid,
            repository: _repo(_data('window_split.json'), posts, _databaseError),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await pick(tester);
      expect(posts, hasLength(1));
      expect(find.byType(SplitThreadPage), findsNothing);
      expect(done?.unconfirmed, isTrue);
    });

    testWidgets('from the thread menu: said unknown, the thread read again, no new thread offered', (tester) async {
      final posts = <String>[];
      ModerateDone? done;
      await tester.pumpWidget(
        _app((context) async {
          done = await showThreadModerateSheet(
            context,
            tid: _tid,
            fid: _fid,
            closed: false,
            repository: _repo(_data('window_split.json'), posts, _connectionLost),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(t.moderate.split), 100, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text(t.moderate.split));
      await tester.pumpAndSettle();
      await pick(tester);
      expect(posts, hasLength(1));
      expect(done, ModerateDone.changed);
      expect(find.text(t.moderate.unconfirmed), findsOneWidget);
      expect(find.text(t.moderate.openNewThread), findsNothing);
    });

    testWidgets('a forum not reached: failed, the title kept to send again', (tester) async {
      final posts = <String>[];
      await tester.pumpWidget(
        _app(
          (context) => openSplitThreadPage(
            context,
            tid: _tid,
            fid: _fid,
            repository: _repo(_data('window_split.json'), posts, _offline),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await pick(tester);
      expect(posts, hasLength(1));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(t.moderate.failed), findsOneWidget);
    });
  });
}
