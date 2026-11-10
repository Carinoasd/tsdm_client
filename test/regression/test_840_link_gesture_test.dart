/// A link in rendered content on a phone: a tap opens it once and only it, a long press shows what it is, a scroll
/// starting on it does not open it.
///
/// The phone's recognizer was a long press one whose cancel opened the link. A cancel is no claim on the touch: a
/// tappable container around the content (a card's ink well) won the same touch as a tap and opened its own page too
/// (GitHub #339, the notification card), and a drag starting on a link opened it when the scroll took the touch.
///
/// The host is a desktop: [debugMobileLinkGestureOverride] makes the content take the phone's recognizer, pressed
/// with real pointer events.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/link_gesture_recognizer.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
import 'package:universal_html/parsing.dart';

const _address = 'link@forum.test';
const _html = '<div><a href="mailto:$_address">链接文字</a></div><div>普通文字在这里</div>';

/// Counts of what a touch did.
final class _Counts {
  /// The link opened (reported by the muncher before navigating).
  int opened = 0;

  /// The container's tap.
  int outerTap = 0;

  /// The container's long press.
  int outerLongPress = 0;
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() {
    debugMobileLinkGestureOverride = true;
    addTearDown(() => debugMobileLinkGestureOverride = null);
  });

  Widget app(Widget body) => TranslationProvider(
    child: MaterialApp(home: Scaffold(body: body)),
  );

  Widget content(_Counts counts) => Builder(
    builder: (context) => munchElement(
      context,
      parseHtmlDocument('<html><body>$_html</body></html>').body!,
      options: MunchOptions(onUrlLaunched: () => counts.opened++),
    ),
  );

  /// The content in a tappable card.
  Future<_Counts> pumpCard(WidgetTester tester) async {
    final counts = _Counts();
    await tester.pumpWidget(
      app(
        Card(
          child: InkWell(
            onTap: () => counts.outerTap++,
            onLongPress: () => counts.outerLongPress++,
            child: Padding(padding: const EdgeInsets.all(16), child: content(counts)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return counts;
  }

  /// The center of [text] where it is painted.
  Offset centerOf(WidgetTester tester, String text) {
    final range = find.textRange.ofSubstring(text).evaluate().single;
    final boxes = range.renderObject.getBoxesForSelection(
      TextSelection(baseOffset: range.textRange.start, extentOffset: range.textRange.end),
    );
    return range.renderObject.localToGlobal(boxes.first.toRect().center);
  }

  /// Whether the email sheet of the link is shown (its tap and its long press both show it).
  Finder emailSheet() => find.textContaining(_address);

  group('in a tappable card', () {
    testWidgets('a tap on the link opens it once, the card does not take the tap', (tester) async {
      final counts = await pumpCard(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(counts.opened, 1);
      expect(counts.outerTap, 0);
      expect(counts.outerLongPress, 0);
      expect(emailSheet(), findsOneWidget);
    });

    testWidgets('a slow tap (held under the long press timeout) still opens the link once', (tester) async {
      final counts = await pumpCard(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(counts.opened, 1);
      expect(counts.outerTap, 0);
    });

    testWidgets('a tap outside the link is the card tap', (tester) async {
      final counts = await pumpCard(tester);
      await tester.tapAt(centerOf(tester, '普通文字在这里'));
      await tester.pumpAndSettle();
      expect(counts.opened, 0);
      expect(counts.outerTap, 1);
      expect(emailSheet(), findsNothing);
    });

    testWidgets('a long press on the link shows what it is, opens nothing, the card does nothing', (tester) async {
      final counts = await pumpCard(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(counts.opened, 0);
      expect(counts.outerTap, 0);
      expect(counts.outerLongPress, 0);
      expect(emailSheet(), findsOneWidget);
    });

    testWidgets('a touch moved off the link before lifting opens nothing', (tester) async {
      final counts = await pumpCard(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(counts.opened, 0);
      expect(emailSheet(), findsNothing);
    });

    testWidgets('a cancelled touch opens nothing', (tester) async {
      final counts = await pumpCard(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(counts.opened, 0);
      expect(counts.outerTap, 0);
      expect(emailSheet(), findsNothing);
    });
    testWidgets('a long press then a move off the link shows what it is once, opens nothing', (tester) async {
      final counts = await pumpCard(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(counts.opened, 0);
      expect(counts.outerTap, 0);
      expect(counts.outerLongPress, 0);
      expect(emailSheet(), findsOneWidget);
    });

    testWidgets('a container long press shorter than the link one takes the touch: the link does nothing', (
      tester,
    ) async {
      // The link wins a long press on it against a container long press of the same timeout because its timer starts
      // first (it is the deepest member of the arena); a shorter container long press is the container's.
      final counts = _Counts();
      await tester.pumpWidget(
        app(
          RawGestureDetector(
            gestures: {
              LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 300)),
                (r) => r.onLongPress = () => counts.outerLongPress++,
              ),
            },
            child: Padding(padding: const EdgeInsets.all(16), child: content(counts)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(counts.outerLongPress, 1);
      expect(counts.opened, 0);
      expect(emailSheet(), findsNothing);
    });
  });

  group('in a scrolling list', () {
    Future<(_Counts, ScrollController)> pumpList(WidgetTester tester) async {
      final counts = _Counts();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          ListView(
            controller: controller,
            children: [
              Padding(padding: const EdgeInsets.all(16), child: content(counts)),
              for (var i = 0; i < 40; i++) SizedBox(height: 80, child: Text('行 $i')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (counts, controller);
    }

    testWidgets('a drag starting on the link scrolls the list and does not open the link', (tester) async {
      final (counts, controller) = await pumpList(tester);
      final gesture = await tester.startGesture(centerOf(tester, '链接文字'));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(counts.opened, 0);
      expect(emailSheet(), findsNothing);
    });

    testWidgets('a tap on the link in the list opens it once', (tester) async {
      final (counts, controller) = await pumpList(tester);
      await tester.tapAt(centerOf(tester, '链接文字'));
      await tester.pumpAndSettle();
      expect(counts.opened, 1);
      expect(controller.offset, 0);
    });
  });

  group("the app's bbcode renderer", () {
    testWidgets('a tap on a link in a tappable card opens it once, the card does not take the tap', (tester) async {
      var outerTap = 0;
      await tester.pumpWidget(
        app(
          InkWell(
            onTap: () => outerTap++,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: PostBbcodeView([
                BbLink('mailto:$_address', [BbText('链接文字')]),
                BbText('\n普通文字在这里'),
              ]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(centerOf(tester, '链接文字'));
      await tester.pumpAndSettle();
      expect(outerTap, 0);
      expect(emailSheet(), findsOneWidget);
    });
  });

  testWidgets('the semantics of the link carry its tap', (tester) async {
    final handle = tester.ensureSemantics();
    final counts = _Counts();
    await tester.pumpWidget(app(content(counts)));
    await tester.pumpAndSettle();
    final link = find.semantics.byLabel('链接文字');
    expect(link.evaluate().single.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(link);
    await tester.pumpAndSettle();
    expect(counts.opened, 1);
    handle.dispose();
  });

  testWidgets('a desktop: a click on the link opens it once, the card does not take it', (tester) async {
    debugMobileLinkGestureOverride = false;
    final counts = await pumpCard(tester);
    await tester.tapAt(centerOf(tester, '链接文字'));
    await tester.pumpAndSettle();
    expect(counts.opened, 1);
    expect(counts.outerTap, 0);
  });
}
