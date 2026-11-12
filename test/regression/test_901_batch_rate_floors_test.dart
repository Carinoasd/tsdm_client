/// Rating in batches: the floor numbers read as the batch rate plugin reads them (`3~5 10 15~20`, `30~` to the last;
/// blanks, commas, `、`, `;` apart; `~`, `～`, `-` between; at most the forum's segments) and written its way, and the
/// first request of each way of picking (the list's threads, a thread's floors picked, a thread's floor numbers) posted
/// to the plugin's confirmation with the entry's form hash.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('floor numbers', () {
    test('read and written the plugin way', () {
      expect(parseBatchRateFloors('3~5 10 15~20'), '3~5 10 15~20');
      expect(parseBatchRateFloors('30~'), '30~');
      expect(parseBatchRateFloors('  15～20，3-5、10;30 ~ '), '3~5 10 15~20 30~');
      expect(parseBatchRateFloors('2 ~ 4,7 9~'), '2~4 7 9~');
      expect(parseBatchRateFloors('5~5'), '5');
      expect(parseBatchRateFloors('2－9'), '2~9');
    });

    test('anything else is refused', () {
      for (final bad in ['', '   ', 'abc', '0', '0~3', '5~3', '3~5~7', '~5', '1.5', '12345678']) {
        expect(parseBatchRateFloors(bad), isNull, reason: bad);
      }
      final fifty = [for (var i = 1; i <= 50; i++) '$i'].join(' ');
      expect(parseBatchRateFloors(fifty), fifty);
      expect(parseBatchRateFloors('$fifty 51'), isNull);
      expect(parseBatchRateFloors('1 2 3', maxSegments: 2), isNull);
    });
  });

  group('first request', () {
    test('the fields of each way of picking', () {
      expect(const BatchRateSelection.threads(fid: 2, tids: [9202952, 9202810, 1019]).fields, {
        'brmode': '1',
        'fid': '2',
        'tids': '9202952,9202810,1019',
      });
      expect(const BatchRateSelection.posts(fid: 2, tid: 1019, pids: [37, 38, 39]).fields, {
        'brmode': '2',
        'fid': '2',
        'tid': '1019',
        'pids': '37,38,39',
      });
      expect(const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~4 7 9~').fields, {
        'brmode': '3',
        'fid': '2',
        'tid': '1019',
        'floors': '2~4 7 9~',
      });
    });

    test('posted once to the confirmation with the form hash, each mode read back', () async {
      final posted = <(String, Map<String, String>)>[];
      final answers = {
        '1': _fixture('batchrate_confirm_list'),
        '2': _fixture('batchrate_confirm_check'),
        '3': _fixture('batchrate_confirm_range'),
      };
      final repo = BatchRateRepository(
        ask: (_) async => null,
        get: (_) async => null,
        post: (url, data) async {
          posted.add((url, data));
          return answers[data['brmode']];
        },
        currentUid: () => 31,
      );
      final info = BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!;
      final list = await repo.confirm(info, const BatchRateSelection.threads(fid: 2, tids: [9202952, 9202810, 1019]));
      final check = await repo.confirm(info, const BatchRateSelection.posts(fid: 2, tid: 1019, pids: [37, 38, 39]));
      final range = await repo.confirm(info, const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~4 7 9~'));
      expect(posted.map((e) => e.$1).toSet(), {'$baseUrl/plugin.php?id=batchrate:rate'});
      expect(posted.map((e) => e.$2['formhash']).toSet(), {'f1f2f3f4'});
      expect(posted.any((e) => e.$2.containsKey('recalc') || e.$2.containsKey('ratesubmit')), isFalse);
      final l = (list as BatchRateAnswered<BatchRateConfirm>).value;
      expect((l.mode, l.inThread, l.total, l.apply), (BatchRateMode.list, false, 3, 3));
      expect(l.items.map((i) => (i.tid, i.position, i.subject)).first, (9202952, 1, 'VD測試 影片與音樂'));
      final c = (check as BatchRateAnswered<BatchRateConfirm>).value;
      expect((c.mode, c.tid, c.exclude), (BatchRateMode.check, 1019, 'gl_dave'));
      expect(c.submit.fields['pids'], '37,38,39');
      final r = (range as BatchRateAnswered<BatchRateConfirm>).value;
      expect((r.mode, r.floors, r.total, r.apply), (BatchRateMode.range, '2~4 7 9~', 5, 2));
    });

    test("the plugin's refusal is its sentence, without a language key", () async {
      final repo = BatchRateRepository(
        ask: (_) async => null,
        get: (_) async => null,
        post: (_, _) async => _fixture('batchrate_message_floors'),
        currentUid: () => 31,
      );
      final info = BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!;
      final reply = await repo.confirm(info, const BatchRateSelection.floors(fid: 2, tid: 1019, floors: 'abc'));
      expect(reply, isA<BatchRateRefused<BatchRateConfirm>>());
      final refused = reply as BatchRateRefused<BatchRateConfirm>;
      expect(refused.message, startsWith('樓層寫法看不懂'));
      expect(refused.login, isFalse);
      // The forum's own error page (a form hash refused, HTTP 503) is not JSON: a failure, never sent again.
      final failing = BatchRateRepository(
        ask: (_) async => null,
        get: (_) async => null,
        post: (_, _) async => '<!DOCTYPE html><html><body>Discuz! System Error</body></html>',
        currentUid: () => 31,
      );
      expect(
        await failing.confirm(info, const BatchRateSelection.posts(fid: 2, tid: 1019, pids: [37])),
        isA<BatchRateFailed<BatchRateConfirm>>(),
      );
    });
  });
}
