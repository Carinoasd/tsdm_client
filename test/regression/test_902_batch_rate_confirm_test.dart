/// Rating in batches, the confirmation (schema 33): read with the forum's defaults (the anti-flood switches, the
/// thread's author left out, the multiples), every request after it carrying the picking and all the settings (a switch
/// left on is sent on), the checks before sending (the plugin's `blocked`, a quota short although the plugin does not
/// block on it, a score times a multiple out of range, no score, a reason required), and the page: a change waits for
/// the plugin to compute it again before it may be sent, then the sending once after a confirmation.
///
/// The confirmations are the test forum's (scrubbed); the batch made is shaped as the spec gives it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_confirm_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_run_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

BatchRateConfirm _confirm(String name) => BatchRateConfirm.fromJson(_fixture(name))!;

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 3200);
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

  group('answer', () {
    test("a thread's floor numbers with the forum's defaults", () {
      final c = _confirm('batchrate_confirm_range');
      expect(
        (c.uid, c.formHash, c.mode, c.fid, c.tid, c.floors),
        (31, 'f1f2f3f4', BatchRateMode.range, 2, 1019, '2~4 7 9~'),
      );
      expect((c.total, c.apply, c.multSum, c.chunks, c.blocked), (5, 2, 2, 1, false));
      expect(c.credits.single.id, 6);
      expect((c.credits.single.min, c.credits.single.max, c.credits.single.score), (-20, 100, 0));
      expect(c.quota, isEmpty);
      expect((c.reason, c.reasonRequired, c.notify, c.notifyForced), ('', false, false, false));
      expect(c.antispam, (locked: false, rated: true, same: true));
      expect(c.exclude, 'gl_dave');
      expect(c.items.map((i) => (i.position, i.author, i.status)), [
        (2, 'gl_bob', 'pending'),
        (3, 'gl_carol', 'skip_author_rated'),
        (4, 'gl_dave', 'skip_excluded'),
        (7, 'ps_v2', 'skip_author_rated'),
        (9, 'ps_v4', 'pending'),
      ]);
      expect(c.items[1].statusText, startsWith('gl_carol 已在第 3 樓拿過分'));
      expect(c.items.where((i) => i.pending).length, c.apply);
      expect(c.submit.url, '$baseUrl/plugin.php?id=batchrate:rate');
      expect(c.submit.fields, {
        'formhash': 'f1f2f3f4',
        'brmode': '3',
        'fid': '2',
        'tid': '1019',
        'tids': '',
        'pids': '',
        'floors': '2~4 7 9~',
      });
      expect(c.fieldNames.score, 'score{id}');
    });

    test('a form posting anywhere else is never used', () {
      final json = _fixture('batchrate_confirm_range');
      expect(
        BatchRateConfirm.fromJson({
          ...json,
          'submit': {
            ...json['submit'] as Map<String, dynamic>,
            'url': 'https://evil.test/plugin.php?id=batchrate:rate',
          },
        }),
        isNull,
      );
    });

    test('computed again: the picking and every setting, a switch left on sent on', () {
      final c = _confirm('batchrate_confirm_range');
      final s = BatchRateSettings.of(c);
      expect((s.rated, s.same, s.exclude, s.floors), (true, true, 'gl_dave', '2~4 7 9~'));
      expect(s.scored, isEmpty);
      s
        ..scores[6] = 5
        ..mults[46] = 3
        ..reason = ' x '
        ..conds[6] = '';
      expect(s.fields(c, submit: false), {
        'formhash': 'f1f2f3f4',
        'brmode': '3',
        'fid': '2',
        'tid': '1019',
        'tids': '',
        'pids': '',
        'floors': '2~4 7 9~',
        'recalc': '1',
        'score6': '5',
        'reason': 'x',
        'exclude': 'gl_dave',
        'as_rated': '1',
        'as_same': '1',
        'mult[46]': '3',
      });
      s
        ..rated = false
        ..notify = true
        ..conds[6] = '5'
        ..floors = '2~9';
      final sent = s.fields(c, submit: true);
      expect(sent['ratesubmit'], '1');
      expect(sent.containsKey('recalc'), isFalse);
      expect(sent.containsKey('as_rated'), isFalse);
      expect((sent['sendreasonpm'], sent['cond[6]'], sent['floors']), ('1', '5', '2~9'));
    });

    test('switches locked by the forum are sent on; the list mode sends none of the thread settings', () {
      final json = _fixture('batchrate_confirm_range');
      final locked = BatchRateConfirm.fromJson({
        ...json,
        'antispam': {'locked': 1, 'rated': 1, 'same': 1, 'rated_overridden': 0},
      })!;
      final s = BatchRateSettings.of(locked)
        ..rated = false
        ..same = false;
      expect((s.fields(locked, submit: false)['as_rated'], s.fields(locked, submit: false)['as_same']), ('1', '1'));
      final list = _confirm('batchrate_confirm_list');
      final fields = (BatchRateSettings.of(list)..scores[6] = 1).fields(list, submit: false);
      expect(fields.keys.toSet(), {
        'formhash',
        'brmode',
        'fid',
        'tid',
        'tids',
        'pids',
        'floors',
        'recalc',
        'score6',
        'reason',
      });
      expect(fields['tids'], '9202952,9202810,1019');
    });
  });

  group('checks before sending', () {
    test('no score; then nothing in the way', () {
      final c = _confirm('batchrate_confirm_range');
      final s = BatchRateSettings.of(c);
      expect(batchRateHolds(c, s), [BatchRateHold.noScore]);
      s.scores[6] = 5;
      expect(batchRateHolds(c, s), isEmpty);
    });

    test('a quota short is held although the plugin does not block it', () {
      final c = _confirm('batchrate_confirm_quota');
      expect(c.blocked, isFalse);
      expect(c.errors, isEmpty);
      expect(c.quota.single, (id: 6, title: '精灵', need: 10200, left: 500, ok: false));
      expect(batchRateHolds(c, BatchRateSettings.of(c)), containsAll([BatchRateHold.quota, BatchRateHold.range]));
    });

    test("the plugin's block and reasons; a score times a multiple out of range", () {
      final c = _confirm('batchrate_confirm_blocked');
      expect(c.blocked, isTrue);
      expect(c.errors.single, startsWith('排除清單中有找不到的用戶名'));
      final s = BatchRateSettings.of(c);
      expect(batchRateOutOfRange(c, s), {37, 46});
      expect(batchRateHolds(c, s), containsAll([BatchRateHold.blocked, BatchRateHold.quota, BatchRateHold.range]));
      s
        ..mults[37] = 1
        ..mults[46] = 1;
      expect(batchRateOutOfRange(c, s), isEmpty);
    });

    test('nothing rated (a threshold no one reaches); a reason required', () {
      final cond = _confirm('batchrate_confirm_cond');
      expect((cond.apply, cond.ratedOverridden, cond.credits.single.cond), (0, true, '5'));
      expect(batchRateHolds(cond, BatchRateSettings.of(cond)), [BatchRateHold.nothing]);
      final json = _fixture('batchrate_confirm_recalc');
      final required = BatchRateConfirm.fromJson({
        ...json,
        'reason': {'value': '', 'required': 1},
      })!;
      expect(batchRateHolds(required, BatchRateSettings.of(required)), [BatchRateHold.reason]);
    });
  });

  group('page', () {
    testWidgets('a change computed again before sending; sent once after the confirmation', (tester) async {
      final posted = <Map<String, String>>[];
      final answers = <Object?>[
        _fixture('batchrate_confirm_range'),
        _fixture('batchrate_confirm_recalc'),
        _fixture('batchrate_batch_made'),
        _fixture('batchrate_run_done'),
      ];
      final gets = <String>[];
      final repo = BatchRateRepository(
        ask: (_) async => null,
        get: (url) async {
          gets.add(url);
          return _fixture('batchrate_result_done');
        },
        post: (url, data) async {
          posted.add(data);
          return answers.removeAt(0);
        },
        currentUid: () => 31,
      );
      await _pump(
        tester,
        BatchRateConfirmPage(
          info: BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!,
          selection: const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~4 7 9~'),
          repository: repo,
        ),
      );
      expect(posted.single, {'formhash': 'f1f2f3f4', 'brmode': '3', 'fid': '2', 'tid': '1019', 'floors': '2~4 7 9~'});
      final send = find.byKey(const ValueKey('batch-rate-send'));
      expect(tester.widget<FilledButton>(send).onPressed, isNull, reason: 'no score yet');
      expect(find.text('精灵'), findsWidgets);
      expect(find.text('很给力!'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-rate-mult-37')), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-rate-mult-38')), findsNothing, reason: 'a floor skipped has no multiple');

      await tester.enterText(find.byKey(const ValueKey('batch-rate-score-6')), '5');
      await tester.enterText(find.byKey(const ValueKey('batch-rate-mult-46')), '3');
      await tester.pumpAndSettle();
      expect(find.text('Settings changed: recalculate first'), findsOneWidget);
      expect(tester.widget<FilledButton>(send).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('batch-rate-recalc')));
      await tester.pumpAndSettle();
      expect(posted[1], containsPair('recalc', '1'));
      expect(posted[1], containsPair('score6', '5'));
      expect(posted[1], containsPair('mult[46]', '3'));
      expect(posted[1], containsPair('as_rated', '1'));
      expect(posted[1], containsPair('as_same', '1'));
      expect(posted[1], containsPair('exclude', 'gl_dave'));
      expect(posted[1], containsPair('floors', '2~4 7 9~'));
      expect(find.textContaining('Needs 20'), findsOneWidget);
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);

      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(posted, hasLength(2), reason: 'nothing sent before the confirmation');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      await tester.pump();
      expect(posted[2], containsPair('ratesubmit', '1'));
      expect(posted[2].containsKey('recalc'), isFalse);
      await tester.pumpAndSettle();
      // The batch made is run, then its result read.
      expect(posted[3], {'formhash': 'f1f2f3f4', 'batchid': '52'});
      expect(gets.single, '$baseUrl/plugin.php?id=batchrate:rate&brmode=result&batchid=52');
      expect(find.byType(BatchRateRunPage), findsNothing);
      expect(find.text('Batch rate #51'), findsOneWidget);
    });

    testWidgets("the plugin's refusal shown as it said it, and nothing else", (tester) async {
      await _pump(
        tester,
        BatchRateConfirmPage(
          info: BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!,
          selection: const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~'),
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => null,
            post: (_, _) async => _fixture('batchrate_message_norate'),
            currentUid: () => 31,
          ),
        ),
      );
      expect(find.text('您在本版塊沒有評分權限，無法使用批量評分。'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-rate-send')), findsNothing);
    });

    testWidgets('a sending not answered is not sent again', (tester) async {
      final answers = <Object?>[
        _fixture('batchrate_confirm_recalc'),
        null,
      ];
      var posts = 0;
      await _pump(
        tester,
        BatchRateConfirmPage(
          info: BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!,
          selection: const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~4 7 9~'),
          repository: BatchRateRepository(
            ask: (_) async => null,
            get: (_) async => null,
            post: (_, _) async {
              posts++;
              return answers.removeAt(0);
            },
            currentUid: () => 31,
          ),
        ),
      );
      final send = find.byKey(const ValueKey('batch-rate-send'));
      await tester.tap(send);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();
      expect(posts, 2);
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      expect(find.text('Could not confirm the result; check the batch rates'), findsWidgets);
    });
  });
}
