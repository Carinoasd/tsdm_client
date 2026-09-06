import 'dart:io';

import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:universal_html/parsing.dart';

/// Two problems behind "折叠标签不行" on Discuz! X5.
///
/// 1. X5 renders `[spoiler]` with new class names (`spoilerheader` / `spoilerbutton` / `spoilerbody`, body wrapped in
///    a one-cell table); the muncher only knew the old ones and showed the text flat.
/// 2. When a colour is applied across the spoiler pieces, the editor exports each piece wrapped in its own colour
///    tag. Loading that text again turns the head into a second tail, and the post is saved with two `[/spoiler]`
///    and no head. Text is normalized on its way into and out of the editor.
///
/// Fixture: a reply posted on 2026-09-06 with a test account on the test thread (post id replaced): case A well
/// nested, case B the nesting the editor produces, both as the forum served them.
String _data(String name) => File('test/data/$name').readAsStringSync();

/// What the editor exported for the tester's post.
const _wrapped =
    '[color=#0cc][spoiler=展开/收起][/color]\n'
    '[size=3][color=#0cc]不同积分（威望）对应不同的用户组。[/color][/size]\n'
    '[color=#0cc][/spoiler][/color]';

/// The same with bare pieces.
const _bare =
    '[spoiler=展开/收起]\n'
    '[size=3][color=#0cc]不同积分（威望）对应不同的用户组。[/color][/size]\n'
    '[/spoiler]';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('normalizeBlockMarkerNesting', () {
    test('unwraps a style tag holding nothing but a spoiler piece', () {
      expect(normalizeBlockMarkerNesting(_wrapped), _bare);
    });

    test('peels nested wrappers and tolerates whitespace and case', () {
      expect(
        normalizeBlockMarkerNesting('[size=3][COLOR=red] [spoiler=x] [/COLOR][/size]body[b][/spoiler][/b]'),
        '[spoiler=x]body[/spoiler]',
      );
    });

    test('covers hide and free pieces', () {
      expect(
        normalizeBlockMarkerNesting('[color=red][hide][/color]a[color=red][/hide][/color][i][free=1][/i]b[i][/free][/i]'),
        '[hide]a[/hide][free=1]b[/free]',
      );
    });

    test('is stable and leaves ordinary text and well nested tags alone', () {
      const untouched =
          '[color=red]text[/color] [spoiler=t][color=red]inside[/color][/spoiler] [b]bold [spoiler=x]y[/spoiler][/b]';
      expect(normalizeBlockMarkerNesting(untouched), untouched);
      expect(normalizeBlockMarkerNesting(_bare), _bare);
      expect(normalizeBlockMarkerNesting(normalizeBlockMarkerNesting(_wrapped)), _bare);
      expect(normalizeBlockMarkerNesting(''), '');
    });
  });

  group('editor round trip through the BBCode parser (how a post is loaded for editing)', () {
    String roundTrip(String bbcode) {
      final controller = buildBBCodeEditorController()..setDocumentFromDelta(parseBBCodeTextToDelta(bbcode));
      return controller.toBBCode();
    }

    test("a head wrapped in a style tag comes back as a second tail: the corruption in the tester's post", () {
      final out = roundTrip(_wrapped);
      expect(out, isNot(contains('[spoiler=')), reason: out);
      expect('[/spoiler]'.allMatches(out).length, 2, reason: out);
    });

    test('bare pieces survive, so normalizing on the way in keeps the spoiler', () {
      final out = roundTrip(normalizeBlockMarkerNesting(_wrapped));
      expect('[spoiler=展开/收起]'.allMatches(out).length, 1, reason: out);
      expect('[/spoiler]'.allMatches(out).length, 1, reason: out);
      expect(out, contains('不同积分'));
      expect(roundTrip(_bare), out, reason: 'same document as the well formed text');
    });

    test('toForumBBCode repairs the nesting on the way out', () {
      final controller = buildBBCodeEditorController(initialText: _wrapped);
      expect(controller.toBBCode(), _wrapped, reason: 'plain text is kept as typed');
      expect(controller.toForumBBCode(), _bare);
    });
  });

  group('muncher', () {
    Widget page(String html) => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(builder: (context) => munchElement(context, parseHtmlDocument(html).body!)),
          ),
        ),
      ),
    );

    testWidgets('X5 spoiler markup becomes a collapse card, for both nesting cases', (tester) async {
      await tester.pumpWidget(page(_data('spoiler_post_x5.html')));
      await tester.pumpAndSettle();
      final cards = tester.widgetList<SpoilerCard>(find.byType(SpoilerCard)).toList();
      expect(cards, hasLength(2), reason: 'one card per spoiler');
      expect(cards.map((c) => c.title.toPlainText()), ['测试折叠A', '测试折叠B']);
      expect(cards[0].content.toPlainText(), contains('内容A：这一行应该被折叠'));
      expect(cards[1].content.toPlainText(), contains('内容B：这一行也应该被折叠'));
      // The header hint and the one-cell table wrapper are not part of the card.
      expect(cards[0].content.toPlainText(), isNot(contains('點擊展開')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the old forum markup still renders', (tester) async {
      await tester.pumpWidget(
        page(
          '<div><div class="spoiler"><div class="spoiler_control"><input type="button" class="spoiler_btn" '
          'value="舊標題"/></div><div class="spoiler_content">舊內容</div></div></div>',
        ),
      );
      await tester.pumpAndSettle();
      final cards = tester.widgetList<SpoilerCard>(find.byType(SpoilerCard)).toList();
      expect(cards, hasLength(1));
      expect(cards.single.title.toPlainText(), '舊標題');
      expect(cards.single.content.toPlainText(), contains('舊內容'));
      expect(tester.takeException(), isNull);
    });
  });
}
