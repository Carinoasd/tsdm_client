/// The floating label of the first text field in a dialog is not cut off.
///
/// [CustomAlertDialog] clips its scrolling content so it stops at the dividers. An outlined text field's floating
/// label sits on the field's top border, half above it: when the field is the first thing in the content and is
/// focused or filled (the reward price and red packet dialogs open with the field focused), the label's upper half
/// was clipped away. The content now starts a little below the clip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

void main() {
  testWidgets('a focused outlined field at the top of the content keeps its whole label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CustomAlertDialog.sync(
                    title: const Text('Title'),
                    content: const TextField(
                      autofocus: true,
                      decoration: InputDecoration(labelText: 'Price', border: OutlineInputBorder()),
                    ),
                    actions: [TextButton(onPressed: () {}, child: const Text('Ok'))],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final label = find.text('Price');
    expect(label, findsOneWidget);
    final clip = find.descendant(of: find.byType(CustomAlertDialog<void>), matching: find.byType(Card));
    expect(clip, findsOneWidget);
    expect(
      tester.getTopLeft(label).dy,
      greaterThanOrEqualTo(tester.getTopLeft(clip).dy),
      reason: 'the label starts inside the clipped area, not above it',
    );
  });
}
