/// Rating in batches, the confirmation: a setting changed and changed back to what the plugin last computed with no
/// longer asks to compute again (the text fields, the threshold, the multiples, the reason and the switches alike);
/// one left changed still does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_confirm_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('changed back to the computed value: up to date again', (tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final answers = <Object?>[_fixture('batchrate_confirm_range'), _fixture('batchrate_confirm_recalc')];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: BatchRateConfirmPage(
            info: BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!,
            selection: const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~4 7 9~'),
            repository: BatchRateRepository(
              ask: (_) async => null,
              get: (_) async => null,
              post: (_, _) async => answers.removeAt(0),
              currentUid: () => 31,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('batch-rate-score-6')), '5');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-rate-recalc')));
    await tester.pumpAndSettle();

    final stale = find.text(t.batchRate.holdStale);
    final send = find.byKey(const ValueKey('batch-rate-send'));
    expect(stale, findsNothing);
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);

    TextEditingController field(String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;
    for (final (key, other) in [
      ('batch-rate-score-6', '7'),
      ('batch-rate-mult-46', '2'),
      ('batch-rate-cond-6', '3'),
      ('batch-rate-reason', 'other reason'),
      ('batch-rate-floors', '2~4'),
    ]) {
      final computed = field(key).text;
      await tester.enterText(find.byKey(ValueKey(key)), other);
      await tester.pumpAndSettle();
      expect(stale, findsOneWidget, reason: key);
      expect(tester.widget<FilledButton>(send).onPressed, isNull, reason: key);
      await tester.enterText(find.byKey(ValueKey(key)), computed);
      await tester.pumpAndSettle();
      expect(stale, findsNothing, reason: '$key back to "$computed"');
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull, reason: key);
    }

    for (final key in ['batch-rate-same', 'batch-rate-rated']) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(stale, findsOneWidget, reason: key);
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(stale, findsNothing, reason: '$key back');
    }

    // Two changed, one changed back: still to compute again.
    final score = field('batch-rate-score-6').text;
    await tester.enterText(find.byKey(const ValueKey('batch-rate-score-6')), '9');
    await tester.tap(find.byKey(const ValueKey('batch-rate-same')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('batch-rate-score-6')), score);
    await tester.pumpAndSettle();
    expect(stale, findsOneWidget);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
  });
}
