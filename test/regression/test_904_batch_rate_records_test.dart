/// Rating in batches, the batches (schema 35) and a batch's detail (schema 34): the list a page at a time opening each
/// detail, the floors rated and skipped with the plugin's words, a floor's rate taken back once after a confirmation,
/// the whole batch taken back a part at a time until the plugin says it is finished, a batch still running run on, a
/// tampered form never used, and the plugin's refusal shown as it said it.
///
/// The batches are the test forum's (scrubbed); the results of taking back are shaped as the spec gives them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_batch_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_list_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_run_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

const _list = '$baseUrl/plugin.php?id=batchrate:list';

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: home),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  expect(find.byType(AlertDialog), findsOneWidget);
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('answers', () {
    test('the batches: newest first, what each may do', () {
      final list = BatchRateBatches.fromJson(_fixture('batchrate_list'))!;
      expect((list.uid, list.page, list.pages, list.count), (31, 1, 2, 51));
      expect(list.batches.map((b) => (b.batchId, b.status, b.canContinue, b.canUndo)), [
        (51, 1, false, true),
        (50, 1, false, true),
        (49, 1, false, true),
        (11, 0, true, false),
        (10, 3, false, true),
      ]);
      final first = list.batches.first;
      expect((first.username, first.modeText, first.floors, first.reason), ('ag_admin', '樓層範圍 2～9', '2~', '活動獎勵'));
      expect(first.conds, ['精灵 ≥ 5']);
      expect(first.scores.single, (id: 1, title: '威望', score: 1));
      expect((first.total, first.applied, first.skipped, first.pending), (8, 2, 6, 0));
      expect(list.detailOf(51), '$_list&bract=detail&batchid=51');
      expect(list.undoBatch!.url, '$_list&bract=undo_batch');
    });

    test('a detail: the floors with the plugin words, which may be taken back', () {
      final page = BatchRateBatchPage.fromJson(_fixture('batchrate_detail'))!;
      expect((page.run, page.batch.batchId, page.batch.statusText), (false, 10, '部分撤回'));
      expect(page.items!.map((i) => (i.position, i.status, i.statusText, i.canUndo)), [
        (33, 'undone', '已撤回', false),
        (34, 'applied', '已評分', true),
        (37, 'applied', '已評分', true),
        (38, 'applied', '已評分', true),
        (40, 'applied', '已評分', true),
      ]);
      expect(page.links.undoItem!.url, '$_list&bract=undo_item');
      final json = _fixture('batchrate_detail');
      final forms = json['forms'] as Map<String, dynamic>;
      final tampered = BatchRateBatchPage.fromJson({
        ...json,
        'forms': {
          ...forms,
          'undo_item': {...forms['undo_item'] as Map<String, dynamic>, 'url': 'https://evil.test/x.php'},
        },
      })!;
      expect(tampered.links.undoItem, isNull);
    });
  });

  group('pages', () {
    testWidgets('the list opens a detail; a floor taken back once after the confirmation', (tester) async {
      final gets = <String>[];
      final posted = <(String, Map<String, String>)>[];
      final repo = BatchRateRepository(
        ask: (_) async => null,
        get: (url) async {
          gets.add(url);
          return url.contains('bract=detail') ? _fixture('batchrate_detail') : _fixture('batchrate_list');
        },
        post: (url, data) async {
          posted.add((url, data));
          return _fixture('batchrate_undo_item_ok');
        },
        currentUid: () => 31,
      );
      await _pump(tester, BatchRateListPage(listUrl: _list, repository: repo));
      expect(gets, [_list]);
      expect(find.byKey(const ValueKey('batch-rate-batch-51')), findsOneWidget);
      expect(find.text('#11 · 测试版块 · 樓層範圍 2～10'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('batch-rate-batch-10')));
      await tester.pumpAndSettle();
      expect(gets.last, '$_list&bract=detail&batchid=10');
      expect(find.byKey(const ValueKey('batch-rate-undo-batch')), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-rate-continue')), findsNothing);
      expect(find.byKey(const ValueKey('batch-rate-undo-667')), findsNothing, reason: 'taken back already');

      final undo = find.byKey(const ValueKey('batch-rate-undo-668'));
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(posted, isEmpty);
      await _confirm(tester);
      expect(posted.single.$1, '$_list&bract=undo_item');
      expect(posted.single.$2, {'formhash': 'f1f2f3f4', 'itemid': '668'});
      expect(find.text('Taken back'), findsOneWidget);
      expect(gets.last, '$_list&bract=detail&batchid=10');
    });

    testWidgets("a floor not taken back: the plugin's sentence", (tester) async {
      await _pump(
        tester,
        BatchRateBatchView(
          url: '$_list&bract=detail&batchid=10',
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => _fixture('batchrate_detail'),
            post: (_, _) async => _fixture('batchrate_undo_item_refused'),
            currentUid: () => 31,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('batch-rate-undo-668')));
      await tester.pumpAndSettle();
      await _confirm(tester);
      expect(find.text('本項目已撤回或未評分，無法再次撤回。'), findsOneWidget);
    });

    testWidgets('the whole batch taken back a part at a time', (tester) async {
      final answers = <Object?>[_fixture('batchrate_undo_batch_step'), _fixture('batchrate_undo_batch_done')];
      final posted = <(String, Map<String, String>)>[];
      var gets = 0;
      await _pump(
        tester,
        BatchRateBatchView(
          url: '$_list&bract=detail&batchid=10',
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async {
              gets++;
              return _fixture('batchrate_detail');
            },
            post: (url, data) async {
              posted.add((url, data));
              return answers.removeAt(0);
            },
            currentUid: () => 31,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('batch-rate-undo-batch')));
      await tester.pumpAndSettle();
      expect(find.text('Take back batch #10'), findsOneWidget);
      await _confirm(tester);
      expect(posted, hasLength(2));
      for (final (url, data) in posted) {
        expect(url, '$_list&bract=undo_batch');
        expect(data, {'formhash': 'f1f2f3f4', 'batchid': '10'});
      }
      expect(find.text('Taken back'), findsOneWidget);
      expect(gets, 2);
    });

    testWidgets('taken back as a whole from the result: its detail read, no more taking back', (tester) async {
      final answers = <Object?>[_fixture('batchrate_undo_batch_step'), _fixture('batchrate_undo_batch_done')];
      final gets = <String>[];
      final undone = _fixture('batchrate_detail_undone');
      await _pump(
        tester,
        BatchRateBatchView(
          url: '$baseUrl/plugin.php?id=batchrate:rate&brmode=result&batchid=10',
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (url) async {
              gets.add(url);
              if (url.contains('brmode=result')) {
                // A batch with nothing rated any more: the plugin's sentence, not the batch.
                return gets.length == 1 ? _fixture('batchrate_detail') : _fixture('batchrate_message_result_none');
              }
              return {
                ...undone,
                'batch': {...undone['batch'] as Map<String, dynamic>, 'batchid': 10},
              };
            },
            post: (_, _) async => answers.removeAt(0),
            currentUid: () => 31,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('batch-rate-undo-668')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('batch-rate-undo-batch')));
      await tester.pumpAndSettle();
      await _confirm(tester);
      expect(gets.last, '$_list&bract=detail&batchid=10');
      expect(find.text('本批沒有任何項目被評分（可能都已評過或被跳過），仍保留批次紀錄以供追查。'), findsNothing);
      expect(find.text('#10 · 已整批撤回'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-rate-undo-batch')), findsNothing);
      expect(find.textContaining('Take back'), findsNothing);
      expect(find.text('Taken back'), findsOneWidget);
    });

    testWidgets('a batch still running is run on from its detail', (tester) async {
      var runs = 0;
      await _pump(
        tester,
        BatchRateBatchView(
          url: '$_list&bract=detail&batchid=11',
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (url) async => url.contains('brmode=result')
                ? _fixture('batchrate_result_done')
                : _fixture('batchrate_detail_running'),
            post: (url, data) async {
              runs++;
              expect(url, '$baseUrl/plugin.php?id=batchrate:run');
              expect(data, {'formhash': 'f1f2f3f4', 'batchid': '11'});
              return {
                ..._fixture('batchrate_run_done'),
                'values': {'done': '1', 'total': '1', 'remaining': '0', 'finished': '1'},
              };
            },
            currentUid: () => 31,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('batch-rate-undo-batch')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('batch-rate-continue')));
      await tester.pumpAndSettle();
      expect(find.byType(BatchRateRunPage), findsNothing, reason: 'run to the end, then the result');
      expect(runs, 1);
      // Back on the detail, read again; not a second page of the result.
      expect(find.text('Batch rating #11'), findsOneWidget);
      expect(find.byType(BatchRateBatchView), findsOneWidget);
    });

    testWidgets("the plugin's refusal of the list shown as it said it", (tester) async {
      await _pump(
        tester,
        BatchRateListPage(
          listUrl: _list,
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => _fixture('batchrate_message_nolist'),
            post: (_, _) async => null,
            currentUid: () => 31,
          ),
        ),
      );
      expect(find.text('您沒有檢視批次紀錄的權限。'), findsOneWidget);
    });
  });
}
