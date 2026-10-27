/// [ScrollTravel]: what follows the scrolling of a list (the app bar of the thread page, the post button of a forum,
/// the "back to top" button of the homepage) follows the distance the user scrolled since the list last turned, not
/// the direction every drag starts in, so a flaky touch screen or a wobbling thumb no longer pulls it out and in at
/// every turn. Only the user's scrolling counts; the list placing itself never does.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/widgets/scroll_travel.dart';

void main() {
  late ScrollTravel travel;
  late BuildContext context;
  var pixels = 500.0;

  var maxScrollExtent = 4000.0;

  ScrollMetrics metrics({Axis axis = Axis.vertical}) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: maxScrollExtent,
    pixels: pixels,
    viewportDimension: 800,
    axisDirection: axis == Axis.vertical ? AxisDirection.down : AxisDirection.right,
    devicePixelRatio: 1,
  );

  /// A drag starts in [direction], as the list tells before it moves.
  void dragStarts(ScrollDirection direction) {
    travel.onNotification(UserScrollNotification(metrics: metrics(), context: context, direction: direction));
  }

  /// The list moved by [delta] (positive: down the list): by the user (a drag told first), or the list placing itself
  /// ([user] false). The answer of the travel.
  ScrollTravelDirection? scroll(double delta, {Axis axis = Axis.vertical, bool user = true}) {
    dragStarts(user ? (delta > 0 ? ScrollDirection.reverse : ScrollDirection.forward) : ScrollDirection.idle);
    pixels = pixels + delta;
    return travel.onNotification(
      ScrollUpdateNotification(
        metrics: metrics(axis: axis),
        context: context,
        scrollDelta: delta,
      ),
    );
  }

  Future<void> ready(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    context = tester.element(find.byType(SizedBox));
    travel = ScrollTravel();
    pixels = 500;
    maxScrollExtent = 4000;
  }

  testWidgets('the direction a drag starts in answers nothing', (tester) async {
    await ready(tester);
    dragStarts(ScrollDirection.reverse);
    dragStarts(ScrollDirection.forward);
    expect(scroll(1), isNull);
  });

  testWidgets('down once the list travelled the threshold, up once as far up', (tester) async {
    await ready(tester);
    expect(scroll(ScrollTravel.defaultThreshold - 1), isNull, reason: 'not yet');
    expect(scroll(1), ScrollTravelDirection.down);
    expect(scroll(10), ScrollTravelDirection.down, reason: 'still, until the list turns');
    expect(scroll(-(ScrollTravel.defaultThreshold - 1)), isNull, reason: 'turned, not yet');
    expect(scroll(-1), ScrollTravelDirection.up);
  });

  testWidgets('a few pixels each way (a flaky touch) answer nothing', (tester) async {
    await ready(tester);
    for (var i = 0; i < 20; i++) {
      expect(scroll(30), isNull);
      expect(scroll(-30), isNull);
    }
  });

  testWidgets('a turn starts the travel over', (tester) async {
    await ready(tester);
    scroll(40);
    scroll(-10);
    expect(scroll(40), isNull, reason: '40 since the turn, not 80');
    expect(scroll(16), ScrollTravelDirection.down);
  });

  testWidgets('the list placing itself (a jump to a row) answers nothing', (tester) async {
    await ready(tester);
    expect(scroll(300, user: false), isNull);
    expect(scroll(-300, user: false), isNull);
  });

  testWidgets('the bounce past an end of the list, and the spring back, answer nothing', (tester) async {
    await ready(tester);
    maxScrollExtent = 520;
    expect(scroll(20), isNull, reason: 'at the end');
    expect(scroll(100), isNull, reason: 'past it');
    expect(scroll(-100), isNull, reason: 'the spring back');
    expect(scroll(-40), isNull, reason: 'in range again: 40 up, not 140');
    expect(scroll(-16), ScrollTravelDirection.up);
    // A drag from past the end counts from the end: 30 of the 60 are within the list.
    scroll(10);
    pixels = 550;
    expect(scroll(-60), isNull, reason: '30 up');
    expect(scroll(-26), ScrollTravelDirection.up);
  });

  testWidgets('a list nested in the one the user scrolls, moving in the same drag, answers nothing', (tester) async {
    await ready(tester);
    await tester.pumpWidget(
      const Column(
        children: [
          SizedBox(),
          Text('inner', textDirection: TextDirection.ltr),
        ],
      ),
    );
    context = tester.element(find.byType(SizedBox));
    final inner = tester.element(find.text('inner'));
    dragStarts(ScrollDirection.reverse);
    for (var i = 0; i < 5; i++) {
      // The nested list moves with the finger as well, its own context.
      expect(
        travel.onNotification(ScrollUpdateNotification(metrics: metrics(), context: inner, scrollDelta: 20)),
        isNull,
      );
      pixels += 20;
    }
    expect(scroll(20), isNull, reason: '20 of the list told of, the 100 of the nested one apart');
    expect(scroll(36), ScrollTravelDirection.down);
  });

  testWidgets('a list scrolled sideways answers nothing', (tester) async {
    await ready(tester);
    expect(scroll(300, axis: Axis.horizontal), isNull);
  });

  testWidgets('a threshold of its own; reset forgets the travel', (tester) async {
    await ready(tester);
    travel = ScrollTravel(threshold: 20);
    expect(scroll(19), isNull);
    travel.reset();
    expect(scroll(19), isNull, reason: 'the 19 of before do not count');
    expect(scroll(1), ScrollTravelDirection.down);
  });
}
