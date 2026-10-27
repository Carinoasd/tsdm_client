/// The app bar of the thread page follows the distance the list scrolls, not the direction a drag starts in: a flaky
/// touch screen (the finger lost and found again a few pixels away) or a wobbling thumb used to pull the bar out and in
/// at every turn. The list has to travel [AppBarCollapser.threshold] in one direction since it last turned before the
/// bar hides or shows; the top of the list always shows it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/thread/v1/widgets/collapsing_app_bar.dart';

void main() {
  late AnimationController controller;
  late AppBarCollapser collapser;
  late BuildContext context;
  // Where the list is; every update moves it by its delta.
  var pixels = 500.0;

  ScrollMetrics metrics({double maxScrollExtent = 4000, Axis axis = Axis.vertical}) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: maxScrollExtent,
    pixels: pixels,
    viewportDimension: 800,
    axisDirection: axis == Axis.vertical ? AxisDirection.down : AxisDirection.right,
    devicePixelRatio: 1,
  );

  /// The list moved by [delta] (positive: down to later floors).
  void scroll(double delta, {double maxScrollExtent = 4000, Axis axis = Axis.vertical}) {
    pixels = (pixels + delta).clamp(0, maxScrollExtent);
    collapser.onNotification(
      ScrollUpdateNotification(
        metrics: metrics(maxScrollExtent: maxScrollExtent, axis: axis),
        context: context,
        scrollDelta: delta,
      ),
    );
  }

  /// A drag starts in [direction], as the list tells before it moves.
  void dragStarts(ScrollDirection direction) {
    collapser.onNotification(UserScrollNotification(metrics: metrics(), context: context, direction: direction));
  }

  /// A page to take the context of; the collapser of a bar of 100 that is shown.
  Future<void> ready(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    context = tester.element(find.byType(SizedBox));
    controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), value: 1);
    collapser = AppBarCollapser(controller)..barHeight = 100;
    pixels = 500;
    addTearDown(controller.dispose);
  }

  /// The bar is [status]; stopped there, since a bar still on its way when the test ends is a ticker left running.
  void expectStatus(AnimationStatus status, {String? reason}) {
    expect(controller.status, status, reason: reason);
    controller.stop();
  }

  testWidgets('the direction a drag starts in moves the bar no more', (tester) async {
    await ready(tester);
    dragStarts(ScrollDirection.reverse);
    expectStatus(AnimationStatus.completed, reason: 'shown, not hiding');
    controller.value = 0;
    dragStarts(ScrollDirection.forward);
    expectStatus(AnimationStatus.dismissed, reason: 'hidden, not showing');
  });

  testWidgets('scrolling down hides the bar once the list travelled the threshold', (tester) async {
    await ready(tester);
    scroll(AppBarCollapser.threshold - 1);
    expectStatus(AnimationStatus.completed, reason: 'not yet');
    scroll(1);
    expectStatus(AnimationStatus.reverse, reason: 'hiding');
  });

  testWidgets('scrolling up shows the bar once the list travelled the threshold', (tester) async {
    await ready(tester);
    controller.value = 0;
    scroll(-(AppBarCollapser.threshold - 1));
    expectStatus(AnimationStatus.dismissed, reason: 'not yet');
    scroll(-1);
    expectStatus(AnimationStatus.forward, reason: 'showing');
  });

  testWidgets('a few pixels each way (a flaky touch) leave the bar as it is', (tester) async {
    await ready(tester);
    for (var i = 0; i < 20; i++) {
      scroll(8);
      scroll(-8);
    }
    expectStatus(AnimationStatus.completed, reason: 'still shown');
    controller.value = 0;
    for (var i = 0; i < 20; i++) {
      scroll(-30);
      scroll(30);
    }
    expectStatus(AnimationStatus.dismissed, reason: 'still hidden');
  });

  testWidgets('a turn starts the travel over', (tester) async {
    await ready(tester);
    scroll(40);
    scroll(-10);
    scroll(40);
    expectStatus(AnimationStatus.completed, reason: '40 since the turn, not 80');
    scroll(16);
    expectStatus(AnimationStatus.reverse);
  });

  testWidgets('the top of the list shows the bar however it got there', (tester) async {
    await ready(tester);
    controller.value = 0;
    pixels = 10;
    scroll(-10);
    expectStatus(AnimationStatus.forward);
  });

  testWidgets('a list that scrolls no farther than the bar keeps it', (tester) async {
    await ready(tester);
    pixels = 0;
    scroll(80, maxScrollExtent: 90);
    expectStatus(AnimationStatus.completed);
  });

  testWidgets('a table scrolled sideways never moves the bar', (tester) async {
    await ready(tester);
    scroll(300, axis: Axis.horizontal);
    expectStatus(AnimationStatus.completed);
  });

  testWidgets('disabled: the bar shows and the travel is forgotten', (tester) async {
    await ready(tester);
    scroll(40);
    collapser.enabled = false;
    controller.value = 0;
    scroll(40);
    expectStatus(AnimationStatus.forward, reason: 'shown while disabled');
    controller
      ..stop()
      ..value = 1;
    collapser.enabled = true;
    scroll(40);
    expectStatus(AnimationStatus.completed, reason: 'the 40 of before do not count');
  });
}
