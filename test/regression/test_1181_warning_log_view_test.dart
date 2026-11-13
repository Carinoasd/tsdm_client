/// The warnings of a floor's author, from the floor's warned mark: the mark opens the warning window of the author in
/// the thread (the forum's ajax window, one GET), a guest too (the forum lets anyone who may read the forum look);
/// an answer that comes after the account changed is dropped; the forum's refusal is told in its words, a failure
/// with a retry. The mark of an anonymous floor (no author) or of a floor outside a thread opens nothing.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/warning_log.dart';
import 'package:tsdm_client/features/moderate/repository/warning_log_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/warning_log_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

String _raw(String name) => File('test/data/warning_log/$name.xml').readAsStringSync();

const _url = '$baseUrl/forum.php?mod=misc&action=viewwarning&tid=9199072&uid=31&inajax=1';

WarningLogRepository _repo(
  List<Object?> answers, {
  List<String>? asked,
  int Function()? uid,
  int status = 200,
}) {
  var i = 0;
  return WarningLogRepository(
    get: (url) async {
      asked?.add(url);
      final answer = answers[i < answers.length ? i++ : answers.length - 1];
      if (answer is AppException) {
        return left(answer);
      }
      return right((statusCode: status, data: answer));
    },
    currentUid: uid ?? () => 35,
  );
}

Widget _app(Widget child) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('repository', () {
    test('one GET of the window of the author in the thread', () async {
      final asked = <String>[];
      final answer = await _repo([_raw('staff')], asked: asked).fetch(tid: 9199072, uid: 31);
      expect(asked, [_url]);
      expect(answer.getRight().toNullable(), isA<WarningLogShown>());
    });

    test('a guest may look as the forum lets it', () async {
      final answer = await _repo([_raw('staff')], uid: () => 0).fetch(tid: 9199072, uid: 31);
      expect(answer.getRight().toNullable(), isA<WarningLogShown>());
    });

    test('an answer after the account changed is dropped', () async {
      var uid = 35;
      final repo = WarningLogRepository(
        get: (url) async {
          uid = 31;
          return right((statusCode: 200, data: _raw('staff')));
        },
        currentUid: () => uid,
      );
      final answer = await repo.fetch(tid: 9199072, uid: 31);
      expect(answer.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test('no thread or member: nothing asked; not the window or not 200: a failure', () async {
      final asked = <String>[];
      expect((await _repo([_raw('staff')], asked: asked).fetch(tid: 0, uid: 31)).isLeft(), isTrue);
      expect((await _repo([_raw('staff')], asked: asked).fetch(tid: 9199072, uid: 0)).isLeft(), isTrue);
      expect(asked, isEmpty);
      expect((await _repo(['<html></html>']).fetch(tid: 9199072, uid: 31)).isLeft(), isTrue);
      expect((await _repo([null]).fetch(tid: 9199072, uid: 31)).isLeft(), isTrue);
      expect((await _repo([_raw('staff')], status: 503).fetch(tid: 9199072, uid: 31)).isLeft(), isTrue);
    });
  });

  group('mark', () {
    testWidgets('a tap shows the warnings: the reason, who and when, the line under them', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(
        _app(WarnedFloorMark(tid: 9199072, authorUid: 31, repository: _repo([_raw('staff')], asked: asked))),
      );
      expect(asked, isEmpty);
      await tester.tap(find.byKey(const ValueKey('floor-warned-mark')));
      await tester.pumpAndSettle();
      expect(asked, [_url]);
      expect(find.text('Warning log'), findsOneWidget);
      expect(find.text('BU區警告46626'), findsOneWidget);
      expect(find.text('管理团队 · 2026-9-12 04:42'), findsOneWidget);
      expect(find.text('notify 警告理由（warn_1789171425534）'), findsOneWidget);
      expect(find.textContaining('已被累计警告 2 次'), findsOneWidget);
      // The staff are not linked: nothing to open.
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('warning-record-0'))).onTap, isNull);
    });

    testWidgets("the forum's refusal in its words", (tester) async {
      await tester.pumpWidget(
        _app(WarnedFloorMark(tid: 9199072, authorUid: 35, repository: _repo([_raw('no_warning')]))),
      );
      await tester.tap(find.byKey(const ValueKey('floor-warned-mark')));
      await tester.pumpAndSettle();
      expect(find.text('抱歉，指定帖子没有警告记录'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a failure offers a retry, which asks again', (tester) async {
      final asked = <String>[];
      final repo = _repo([HttpRequestFailedException(500), _raw('moderators')], asked: asked);
      await tester.pumpWidget(_app(WarnedFloorMark(tid: 9199072, authorUid: 31, repository: repo)));
      await tester.tap(find.byKey(const ValueKey('floor-warned-mark')));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(asked, hasLength(2));
      expect(find.text('ag_mid · 2026-9-12 04:42'), findsOneWidget);
      // A moderator linked opens the profile.
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('warning-record-0'))).onTap, isNotNull);
    });

    testWidgets('an anonymous floor or a floor outside a thread: the mark alone', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              WarnedFloorMark(tid: 9199072, authorUid: null, repository: _repo([_raw('staff')], asked: asked)),
              WarnedFloorMark(tid: null, authorUid: 31, repository: _repo([_raw('staff')], asked: asked)),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('floor-warned-mark')), findsNothing);
      expect(find.byIcon(Icons.report_outlined), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.report_outlined).first);
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
    });
  });
}
