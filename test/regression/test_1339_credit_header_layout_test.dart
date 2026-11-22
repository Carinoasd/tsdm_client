/// The header of "my credits" with the transfer and exchange buttons: beside the title on one line while they fit,
/// and as one row under the title otherwise (narrow windows, large text, English); the two buttons never stacked
/// one under the other, nothing overflowing. One button alone sits the same way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/points/widgets/section_header_with_actions.dart';

const ValueKey<String> _transfer = ValueKey('transfer');
const ValueKey<String> _exchange = ValueKey('exchange');

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double textScale,
  required String title,
  required List<String> buttons,
}) async {
  tester.view
    ..physicalSize = Size(width, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Padding(
            // The page's side padding and the card's.
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeaderWithActions(
                  key: const ValueKey('header'),
                  title: title,
                  icon: Icons.bar_chart_outlined,
                  actions: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (i, label) in buttons.indexed)
                        TextButton.icon(
                          key: i == 0 && buttons.length > 1 ? _transfer : _exchange,
                          onPressed: () {},
                          icon: const Icon(Icons.send_outlined),
                          label: Text(label),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _centerY(WidgetTester tester, Finder f) => tester.getCenter(f).dy;

void main() {
  testWidgets('a phone, normal text: the title and both buttons on one line', (tester) async {
    await _pump(tester, width: 411, textScale: 1, title: '我的积分', buttons: const ['转账', '兑换']);
    expect(_centerY(tester, find.byKey(_transfer)), _centerY(tester, find.byKey(_exchange)));
    expect(
      (_centerY(tester, find.text('我的积分')) - _centerY(tester, find.byKey(_transfer))).abs(),
      lessThan(4),
      reason: 'beside the title',
    );
    // As tall as one line of buttons.
    expect(tester.getSize(find.byKey(const ValueKey('header'))).height, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  for (final (name, width, scale, title, buttons) in const [
    ('narrow, text 1.3', 320.0, 1.3, '我的积分', ['转账', '兑换']),
    ('narrow, English, text 1.3', 320.0, 1.3, 'My credits', ['Transfer', 'Exchange']),
    ('narrow, English, text 2', 360.0, 2.0, 'My credits', ['Transfer', 'Exchange']),
  ]) {
    testWidgets('$name: the two buttons stay in one row, under the title, nothing overflows', (tester) async {
      await _pump(tester, width: width, textScale: scale, title: title, buttons: buttons);
      expect(tester.takeException(), isNull);
      expect(_centerY(tester, find.byKey(_transfer)), _centerY(tester, find.byKey(_exchange)));
      final header = tester.getRect(find.byKey(const ValueKey('header')));
      expect(
        tester.getRect(find.byKey(_transfer)).top,
        greaterThanOrEqualTo(tester.getRect(find.text(title)).bottom - 0.5),
        reason: 'under the title',
      );
      for (final key in [_transfer, _exchange]) {
        final rect = tester.getRect(find.byKey(key));
        expect(rect.left >= header.left - 0.5 && rect.right <= header.right + 0.5, isTrue, reason: '$key inside');
      }
    });
  }

  testWidgets('one button alone: beside the title', (tester) async {
    await _pump(tester, width: 411, textScale: 1, title: '我的积分', buttons: const ['兑换']);
    expect(
      (_centerY(tester, find.text('我的积分')) - _centerY(tester, find.byKey(_exchange))).abs(),
      lessThan(4),
    );
    expect(
      tester.getRect(find.byKey(_exchange)).right,
      closeTo(tester.getRect(find.byKey(const ValueKey('header'))).right, 0.5),
      reason: 'at the end of the line',
    );
    expect(tester.takeException(), isNull);
  });
}
