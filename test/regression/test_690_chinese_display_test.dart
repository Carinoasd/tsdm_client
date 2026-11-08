/// Chinese text can be shown as Traditional or Simplified (settings, appearance), converted on screen only.
///
/// The converter follows OpenCC (`s2t` and `t2s`, longest match), with the dictionaries of
/// `assets/text/opencc` (built by `tools/opencc/build_dict.py`): phrases decide the characters that have several
/// readings (`皇后` stays, `后来` becomes `後來`), ASCII and text with kana stay as they are. The html muncher converts
/// the text nodes it lays out, and the widgets that show a title or a forum name convert it through
/// `BuildContext.displayText`; a [ChineseDisplayHost] provides the mode and a change of it builds them again.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

ChineseConverter _load(String name) => ChineseConverter.parse(File('assets/text/opencc/$name.txt').readAsStringSync());

Widget _app(ChineseDisplayMode mode, Widget body) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: ChineseDisplayHost(
        mode: mode,
        child: SingleChildScrollView(child: SizedBox(width: 400, child: body)),
      ),
    ),
  ),
);

String _richText(WidgetTester tester) =>
    (find.byType(RichText).evaluate().first.widget as RichText).text.toPlainText(includeSemanticsLabels: false);

void main() {
  late ChineseConverter s2t;
  late ChineseConverter t2s;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    s2t = _load('s2t');
    t2s = _load('t2s');
  });

  tearDown(() => ChineseDisplay.instance.useConverters(s2t: s2t, t2s: t2s));

  group('converter', () {
    test('converts common words by phrase', () {
      expect(s2t.convert('软件开发'), '軟件開發');
      expect(s2t.convert('头发和发展'), '頭髮和發展');
      expect(s2t.convert('皇后'), '皇后');
      expect(s2t.convert('后来'), '後來');
      expect(s2t.convert('天使动漫论坛'), '天使動漫論壇');
      expect(t2s.convert('軟件開發'), '软件开发');
      expect(t2s.convert('頭髮和發展'), '头发和发展');
      expect(t2s.convert('天使動漫論壇'), '天使动漫论坛');
    });

    test('leaves ASCII, digits, symbols and untouched characters', () {
      const text = 'Hello, World! 2026-11-09 https://example.com/a?b=c [b]x[/b] 【】！？';
      expect(s2t.convert(text), text);
      expect(t2s.convert(text), text);
      expect(s2t.convert('Windows 11 终于更新了'), 'Windows 11 終於更新了');
    });

    test('leaves text with kana as it is', () {
      expect(s2t.convert('私は学生です'), '私は学生です');
      expect(s2t.convert('国のアニメ'), '国のアニメ');
      expect(s2t.convert('ｱﾆﾒ 国'), 'ｱﾆﾒ 国');
      expect(t2s.convert('體のゲーム'), '體のゲーム');
    });

    test('handles empty text, astral characters and a text already converted', () {
      expect(s2t.convert(''), '');
      expect(s2t.convert('😀 动漫 😀'), '😀 動漫 😀');
      expect(s2t.convert(s2t.convert('动漫')), '動漫');
      expect(t2s.convert(t2s.convert('動漫')), '动漫');
    });

    test('keeps a converted string and starts over when the cache is full', () {
      final small = ChineseConverter.parse('动\t動\n漫\t漫\n', cacheLimit: 2);
      expect(small.convert('动'), '動');
      expect(small.convert('动'), '動');
      expect(small.cachedCount, 1);
      small
        ..convert('动动')
        ..convert('动动动');
      expect(small.cachedCount, 1);
    });

    test('the dictionaries stay small', () {
      expect(File('assets/text/opencc/s2t.txt').lengthSync(), lessThan(300 * 1024));
      expect(File('assets/text/opencc/t2s.txt').lengthSync(), lessThan(60 * 1024));
    });
  });

  group('mode', () {
    test('is read from its index, off when out of range', () {
      expect(ChineseDisplayMode.fromIndex(1), ChineseDisplayMode.traditional);
      expect(ChineseDisplayMode.fromIndex(2), ChineseDisplayMode.simplified);
      expect(ChineseDisplayMode.fromIndex(9), ChineseDisplayMode.off);
      expect(ChineseDisplayMode.fromIndex(-1), ChineseDisplayMode.off);
    });

    test('is off by default and saved as an index', () {
      expect(SettingsKeys.chineseDisplayMode.defaultValue, ChineseDisplayMode.off.index);
    });
  });

  group('widgets', () {
    testWidgets('the muncher converts the text it lays out', (tester) async {
      ChineseDisplay.instance.useConverters(s2t: s2t, t2s: t2s);
      await tester.pumpWidget(_app(ChineseDisplayMode.traditional, const MunchedHtml('<p>软件<b>开发</b> abc</p>')));
      await tester.pump();
      expect(_richText(tester), '軟件開發 abc');

      await tester.pumpWidget(_app(ChineseDisplayMode.simplified, const MunchedHtml('<p>軟件<b>開發</b> abc</p>')));
      await tester.pump();
      expect(_richText(tester), '软件开发 abc');

      await tester.pumpWidget(_app(ChineseDisplayMode.off, const MunchedHtml('<p>软件<b>开发</b> abc</p>')));
      await tester.pump();
      expect(_richText(tester), '软件开发 abc');
    });

    testWidgets('preformatted text is not rewritten', (tester) async {
      ChineseDisplay.instance.useConverters(s2t: s2t, t2s: t2s);
      await tester.pumpWidget(_app(ChineseDisplayMode.traditional, const MunchedHtml('<pre>动漫</pre>')));
      await tester.pump();
      expect(_richText(tester), contains('动漫'));
    });

    testWidgets('changing the mode builds the text again', (tester) async {
      ChineseDisplay.instance.useConverters(s2t: s2t, t2s: t2s);
      Widget app(ChineseDisplayMode mode) => _app(
        mode,
        Column(
          children: [
            const MunchedHtml('<p>动漫</p>', key: ValueKey('munched')),
            Builder(builder: (context) => Text(context.displayText('论坛'), key: const ValueKey('title'))),
          ],
        ),
      );
      String title() => tester.widget<Text>(find.byKey(const ValueKey('title'))).data!;

      await tester.pumpWidget(app(ChineseDisplayMode.off));
      expect(title(), '论坛');
      await tester.pumpWidget(app(ChineseDisplayMode.traditional));
      await tester.pump();
      expect(title(), '論壇');
      expect(_richText(tester), '動漫');
      await tester.pumpWidget(app(ChineseDisplayMode.off));
      await tester.pump();
      expect(title(), '论坛');
      expect(_richText(tester), '动漫');
    });

    testWidgets('shows the text as it is until the dictionary is loaded', (tester) async {
      ChineseDisplay.instance.useConverters();
      await tester.pumpWidget(
        _app(
          ChineseDisplayMode.traditional,
          Builder(builder: (context) => Text(context.displayText('论坛'), key: const ValueKey('title'))),
        ),
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey('title'))).data, '论坛');
    });
  });
}
