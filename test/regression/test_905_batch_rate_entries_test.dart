/// Rating in batches, the entries: the panel's tile of the batches only when the forum says the account may read them
/// (none when it can not tell, for an older plugin, or without an account), and a thread's floors picked by number
/// (read the plugin's way, refused when it can not be) or one by one among those loaded, each sent as its own way of
/// picking to the confirmation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/utils/batch_rate_access.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_confirm_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_floors_page.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: home),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    PanelToolsAccess.reset();
    BatchRateAccess.reset();
  });

  group('moderator panel', () {
    const tile = ValueKey('modcp-batch-rate');

    testWidgets('the batches only when the account may read them', (tester) async {
      await _pump(
        tester,
        ModeratorPanelPage(
          staffTools: () async => null,
          panelTools: () async => null,
          batchRate: () async => BatchRateInfo.fromJson(_fixture('batchrate_info_nofid')),
        ),
      );
      expect(find.byKey(tile), findsOneWidget);

      for (final answer in [
        _fixture('batchrate_info_norate'),
        {..._fixture('batchrate_info_nofid'), 'supported': 0},
        {'ok': 1, 'uid': 31, 'type': 'batchrate', 'schema': 32, 'installed': 0},
        null,
      ]) {
        await _pump(
          tester,
          ModeratorPanelPage(
            key: UniqueKey(),
            staffTools: () async => null,
            panelTools: () async => null,
            batchRate: () async => answer == null ? null : BatchRateInfo.fromJson(answer),
          ),
        );
        expect(find.byKey(tile), findsNothing, reason: '$answer');
      }
      // Without an account nothing is asked.
      await _pump(tester, ModeratorPanelPage(key: UniqueKey(), staffTools: () async => null));
      expect(find.byKey(tile), findsNothing);
    });
  });

  group("a thread's floors", () {
    final info = BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!;
    const floors = [
      (pid: 37, floor: 2, author: 'gl_bob'),
      (pid: 38, floor: 3, author: 'gl_carol'),
      (pid: 39, floor: 4, author: 'gl_dave'),
    ];

    BatchRateRepository repo(List<Map<String, String>> posted) => BatchRateRepository(
      ask: (_) async => null,
      get: (_) async => null,
      post: (_, data) async {
        posted.add(data);
        return data['brmode'] == '2' ? _fixture('batchrate_confirm_check') : _fixture('batchrate_confirm_range');
      },
      currentUid: () => 31,
    );

    testWidgets('by number: from the second floor by default, written the plugin way', (tester) async {
      final posted = <Map<String, String>>[];
      await _pump(tester, BatchRateFloorsPage(info: info, tid: 1019, floors: floors, repository: repo(posted)));
      expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-rate-range'))).controller!.text, '2~');
      await tester.enterText(find.byKey(const ValueKey('batch-rate-range')), 'abc');
      await tester.tap(find.byKey(const ValueKey('batch-rate-next')));
      await tester.pumpAndSettle();
      expect(find.text('Floor numbers not understood'), findsOneWidget);
      expect(posted, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('batch-rate-range')), '9～，2-4 7');
      await tester.tap(find.byKey(const ValueKey('batch-rate-next')));
      await tester.pumpAndSettle();
      expect(find.byType(BatchRateConfirmPage), findsOneWidget);
      expect(posted.single, {'formhash': 'f1f2f3f4', 'brmode': '3', 'fid': '2', 'tid': '1019', 'floors': '2~4 7 9~'});
    });

    testWidgets('one by one among the floors loaded', (tester) async {
      final posted = <Map<String, String>>[];
      await _pump(tester, BatchRateFloorsPage(info: info, tid: 1019, floors: floors, repository: repo(posted)));
      await tester.tap(find.text('Pick floors'));
      await tester.pumpAndSettle();
      final next = find.byKey(const ValueKey('batch-rate-next'));
      expect(tester.widget<FilledButton>(next).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('batch-rate-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('batch-rate-floor-38')));
      await tester.pumpAndSettle();
      expect(find.text('2 picked'), findsOneWidget);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(posted.single, {'formhash': 'f1f2f3f4', 'brmode': '2', 'fid': '2', 'tid': '1019', 'pids': '37,39'});
    });

    testWidgets('no floors loaded: by number only', (tester) async {
      await _pump(tester, BatchRateFloorsPage(info: info, tid: 1019, floors: const [], repository: repo([])));
      await tester.tap(find.text('Pick floors'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('batch-rate-range')), findsOneWidget);
    });
  });
}
