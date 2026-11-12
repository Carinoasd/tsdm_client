/// Rating in batches, the run (schema 34 and the write results of `run`): a batch made or run on is run a part at a
/// time until the plugin says it is finished, then its result is read; a part refused or not answered stops the run
/// with the reason and a button to run on (never retried by itself); a run that takes nothing off stops; an answer for
/// another account stops it. Running on a batch already done answers its result (`run 0`).
///
/// The batches are the test forum's (scrubbed); the run results are shaped as the spec gives them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_run_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _step(Map<String, String> values, {int uid = 31}) => {
  ..._fixture('batchrate_run_step'),
  'uid': uid,
  'values': values,
};

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(TranslationProvider(child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('answers', () {
    test('a batch made, to run; running on one running; running on one done', () {
      final made = BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!;
      expect(
        (made.run, made.items, made.batch.batchId, made.batch.status, made.batch.pending),
        (true, null, 52, 0, null),
      );
      expect(made.links.run!.url, '$baseUrl/plugin.php?id=batchrate:run');
      expect(made.links.run!.fields, {'formhash': 'f1f2f3f4'});
      expect(made.links.resultUrl, '$baseUrl/plugin.php?id=batchrate:rate&brmode=result&batchid=52');
      final running = BatchRateBatchPage.fromJson(_fixture('batchrate_continue'))!;
      expect((running.run, running.batch.batchId, running.batch.canContinue), (true, 11, true));
      final done = BatchRateBatchPage.fromJson(_fixture('batchrate_result_done'))!;
      expect((done.run, done.batch.status, done.batch.statusText, done.items!.length), (false, 1, '完成', 8));
    });

    test('the run results: a part, the end, a refusal; the plugin own JSON too', () async {
      final answers = <Object?>[
        _fixture('batchrate_run_step'),
        _fixture('batchrate_run_done'),
        _fixture('batchrate_run_refused'),
        '{"ok":true,"done":3,"total":3,"remaining":0,"finished":true}',
        _step({'done': '1'}, uid: 99),
      ];
      final posted = <(String, Map<String, String>)>[];
      final repo = BatchRateRepository(
        ask: (_) async => null,
        get: (_) async => null,
        post: (url, data) async {
          posted.add((url, data));
          return answers.removeAt(0);
        },
        currentUid: () => 31,
      );
      final form = BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!.links.run!;
      final a = (await repo.run(form, 52) as BatchRateAnswered<BatchRateStep>).value;
      expect(a, (ok: true, done: 2, total: 4, remaining: 2, finished: false, message: ''));
      final b = (await repo.run(form, 52) as BatchRateAnswered<BatchRateStep>).value;
      expect((b.finished, b.done), (true, 4));
      final c = (await repo.run(form, 52) as BatchRateAnswered<BatchRateStep>).value;
      expect((c.ok, c.finished, c.message), (false, false, '您不是本版塊的版主或管理員，無法撤回。'));
      final d = (await repo.run(form, 52) as BatchRateAnswered<BatchRateStep>).value;
      expect((d.ok, d.finished, d.done), (true, true, 3));
      await expectLater(repo.run(form, 52), throwsA(isA<Exception>()));
      expect(posted, hasLength(5));
      expect(posted.map((e) => e.$2), everyElement(equals({'formhash': 'f1f2f3f4', 'batchid': '52'})));
    });
  });

  group('page', () {
    testWidgets('run to the end, then the result', (tester) async {
      final answers = <Object?>[
        _step({'done': '2', 'total': '4', 'remaining': '2', 'finished': '0'}),
        _fixture('batchrate_run_done'),
      ];
      final gets = <String>[];
      await _pump(
        tester,
        BatchRateRunPage(
          start: BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!,
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (url) async {
              gets.add(url);
              return _fixture('batchrate_result_done');
            },
            post: (_, _) async => answers.removeAt(0),
            currentUid: () => 31,
          ),
        ),
      );
      expect(answers, isEmpty);
      expect(gets, ['$baseUrl/plugin.php?id=batchrate:rate&brmode=result&batchid=52']);
      expect(find.byType(BatchRateRunPage), findsNothing);
      expect(find.text('Batch rate #51'), findsOneWidget);
    });

    testWidgets('a refusal stops the run with its reason; run on by hand', (tester) async {
      final answers = <Object?>[
        _step({'done': '2', 'total': '4', 'remaining': '2', 'finished': '0'}),
        _fixture('batchrate_run_refused'),
        null,
        _fixture('batchrate_run_done'),
      ];
      var posts = 0;
      await _pump(
        tester,
        BatchRateRunPage(
          start: BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!,
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => _fixture('batchrate_result_done'),
            post: (_, _) async {
              posts++;
              return answers.removeAt(0);
            },
            currentUid: () => 31,
          ),
        ),
      );
      expect(posts, 2);
      expect(find.text('您不是本版塊的版主或管理員，無法撤回。'), findsOneWidget);
      expect(find.text('Running 2／4'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('batch-rate-resume')));
      await tester.pumpAndSettle();
      // Not answered: stopped again, not sent again by itself.
      expect(posts, 3);
      expect(find.text('Stopped'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('batch-rate-resume')));
      await tester.pumpAndSettle();
      expect(posts, 4);
      expect(find.text('Batch rate #51'), findsOneWidget);
    });

    testWidgets('a part without `remaining` that rates more is progress', (tester) async {
      final answers = <Object?>[
        for (var i = 1; i <= 5; i++) _step({'done': '$i', 'total': '6', 'finished': '0'}),
        _fixture('batchrate_run_done'),
      ];
      await _pump(
        tester,
        BatchRateRunPage(
          start: BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!,
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => _fixture('batchrate_result_done'),
            post: (_, _) async => answers.removeAt(0),
            currentUid: () => 31,
          ),
        ),
      );
      expect(answers, isEmpty);
      expect(find.text('Batch rate #51'), findsOneWidget);
    });

    testWidgets('a run that takes nothing off stops; an answer for another account stops', (tester) async {
      var posts = 0;
      await _pump(
        tester,
        BatchRateRunPage(
          start: BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!,
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => null,
            post: (_, _) async {
              posts++;
              return _step({'done': '2', 'total': '4', 'remaining': '2', 'finished': '0'});
            },
            currentUid: () => 31,
          ),
        ),
      );
      expect(posts, 4);
      expect(find.text('Stopped'), findsOneWidget);

      await _pump(
        tester,
        BatchRateRunPage(
          key: UniqueKey(),
          start: BatchRateBatchPage.fromJson(_fixture('batchrate_batch_made'))!,
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => null,
            post: (_, _) async => _step({'done': '2'}, uid: 99),
            currentUid: () => 31,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('batch-rate-resume')), findsOneWidget);
      expect(find.text(t.general.accountChangedRetry), findsOneWidget);
    });
  });
}
