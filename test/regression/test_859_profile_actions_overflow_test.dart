import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/widgets/overflow_actions.dart';

void main() {
  List<OverflowAction> build(List<String> tapped) => [
    for (final (i, p) in [
      OverflowPlacement.pinned,
      OverflowPlacement.adaptive,
      OverflowPlacement.adaptive,
      OverflowPlacement.adaptive,
      OverflowPlacement.pinned,
      OverflowPlacement.adaptive,
      OverflowPlacement.menuOnly,
    ].indexed)
      OverflowAction(icon: Icons.circle, label: 'a$i', placement: p, onPressed: () => tapped.add('a$i')),
  ];

  Future<void> pump(WidgetTester tester, double width, List<String> tapped) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [OverflowActions(actions: build(tapped))]),
          body: const SizedBox(),
        ),
      ),
    );
  }

  testWidgets('360dp keeps the back button clear and every action reachable', (tester) async {
    final tapped = <String>[];
    await pump(tester, 360, tapped);
    // Only the pinned ones stay in the bar, plus the menu button.
    expect(find.byType(IconButton), findsNWidgets(3));
    expect(find.byType(PopupMenuButton<OverflowAction>), findsOneWidget);
    final bar = tester.getRect(find.byType(OverflowActions));
    expect(bar.left, greaterThanOrEqualTo(56), reason: 'must not run under the leading button');
    expect(bar.right, lessThanOrEqualTo(360));

    for (final label in ['a1', 'a2', 'a3', 'a5', 'a6']) {
      await tester.tap(find.byType(PopupMenuButton<OverflowAction>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('a0'));
    await tester.tap(find.byTooltip('a4'));
    expect(tapped, ['a1', 'a2', 'a3', 'a5', 'a6', 'a0', 'a4']);
  });

  testWidgets('wide screens keep the buttons and only the menu-only action in the menu', (tester) async {
    final tapped = <String>[];
    await pump(tester, 800, tapped);
    expect(find.byType(IconButton), findsNWidgets(7));
    await tester.tap(find.byType(PopupMenuButton<OverflowAction>));
    await tester.pumpAndSettle();
    expect(find.text('a6'), findsOneWidget);
    expect(find.text('a1'), findsNothing);
  });
}
