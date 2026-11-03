/// The quick phrases of the editors: a toolbar button opens the saved phrases, one tap inserts it at the cursor, a page
/// arranges them (add, edit, drag to sort, swipe to delete).
///
/// 1. saving: one JSON list in the settings (so a backup carries it) that survives a restart, reads damaged values as
///    nothing, and keeps at most 100 phrases of 2000 characters (the unit the field counts: an emoji is one, so a phrase
///    the field let through is read back whole);
/// 2. the sheet lists the phrases (two lines at most) and inserts the tapped one at the cursor, as text;
/// 3. without a phrase the button opens the page at once, and back from the page the sheet shows what there is now;
/// 4. the page adds, edits, sorts and deletes, and stops at the limits;
/// 5. the editor of a fast reply template has no quick phrases button.
///
/// Synthetic data only: no network, nothing is sent.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
// The editor package's own dependency: the selection is set with its change source.
// ignore: depend_on_referenced_packages
import 'package:flutter_quill/flutter_quill.dart' show Attribute, ChangeSource;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/editor/utils/quick_phrases.dart';
import 'package:tsdm_client/features/editor/view/quick_phrases_page.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/post/view/fast_reply_edit_template_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

const _phone = Size(390, 844);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc bloc;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    await settings.init();
    bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
  });

  tearDown(() async {
    await bloc.close();
    await settings.dispose();
    await db.close();
  });

  /// Let the database writes of the page finish: drift answers on real time, not on the fake clock of a test.
  Future<void> settled(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  List<String> saved() => decodeQuickPhrases(settings.currentSettings.editorQuickPhrases);

  Future<void> save(WidgetTester tester, List<String> phrases) async {
    await tester.runAsync(() async {
      await settings.setValue(SettingsKeys.editorQuickPhrases, encodeQuickPhrases(phrases));
      // The bloc takes the new settings from the repository's stream.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  }

  group('saving', () {
    test('the order is kept, damaged values read as nothing', () {
      expect(decodeQuickPhrases(''), isEmpty);
      expect(decodeQuickPhrases('not json'), isEmpty);
      expect(decodeQuickPhrases('{"a":1}'), isEmpty);
      expect(decodeQuickPhrases('["b","a","c"]'), ['b', 'a', 'c']);
      expect(decodeQuickPhrases('["a",3,null,"  ","","b"]'), ['a', 'b']);
      expect(decodeQuickPhrases(encodeQuickPhrases(['一', '[b]x[/b]', 'line\nbreak'])), [
        '一',
        '[b]x[/b]',
        'line\nbreak',
      ]);
    });

    test('at most 100 phrases of 2000 characters', () {
      final many = [for (var i = 0; i < 130; i++) 'p$i'];
      final read = decodeQuickPhrases(jsonEncode(many));
      expect(read, hasLength(quickPhraseMaxCount));
      expect(read.last, 'p99');
      final long = decodeQuickPhrases(jsonEncode(['x' * 2500]));
      expect(long.single, hasLength(quickPhraseMaxLength));
      expect(quickPhraseMaxCount, 100);
      expect(quickPhraseMaxLength, 2000);
    });

    test('the length is counted in characters, so an emoji phrase the field took is read back whole', () {
      // Each is one character of two code units: the field takes 2000 of them, 4000 code units.
      final emoji = '😀' * quickPhraseMaxLength;
      expect(emoji.length, 2 * quickPhraseMaxLength);
      expect(decodeQuickPhrases(encodeQuickPhrases([emoji])).single, emoji);

      // One too many is cut after a whole emoji, never inside a surrogate pair.
      final cut = decodeQuickPhrases(encodeQuickPhrases(['$emoji😀'])).single;
      expect(cut, emoji);
      expect(cut.characters.length, quickPhraseMaxLength);
      expect(cut.runes.where((r) => r >= 0xD800 && r <= 0xDFFF), isEmpty, reason: 'no lone surrogate');

      // A family of four is one character.
      final family = '👨‍👩‍👧‍👦' * (quickPhraseMaxLength + 1);
      final cutFamily = decodeQuickPhrases(encodeQuickPhrases([family])).single;
      expect(cutFamily.characters.length, quickPhraseMaxLength);
      expect(cutFamily, '👨‍👩‍👧‍👦' * quickPhraseMaxLength);
    });

    test('kept in the settings across a restart, for every account', () async {
      expect(settings.currentSettings.editorQuickPhrases, isEmpty);
      await settings.setValue(SettingsKeys.editorQuickPhrases, encodeQuickPhrases(['hello', '谢谢']));
      expect(saved(), ['hello', '谢谢']);

      final restarted = SettingsRepository(storage);
      await restarted.init();
      expect(decodeQuickPhrases(restarted.currentSettings.editorQuickPhrases), ['hello', '谢谢']);
      await restarted.dispose();
    });
  });

  group('inserting', () {
    test('at the cursor as text, over a selection, at the end without a cursor', () {
      final controller = buildBBCodeEditorController(initialText: 'abcd')
        ..updateSelection(const TextSelection.collapsed(offset: 2), ChangeSource.local)
        ..insertTextAtCursor('[b]X[/b]');
      expect(controller.document.toPlainText(), 'ab[b]X[/b]cd\n');
      expect(controller.selection.baseOffset, 2 + '[b]X[/b]'.length);

      controller
        ..updateSelection(const TextSelection(baseOffset: 0, extentOffset: 2), ChangeSource.local)
        ..insertTextAtCursor('Z');
      expect(controller.document.toPlainText(), 'Z[b]X[/b]cd\n');

      controller
        ..updateSelection(const TextSelection(baseOffset: 3, extentOffset: 1), ChangeSource.local)
        ..insertTextAtCursor('Q');
      expect(controller.document.toPlainText(), 'ZQ]X[/b]cd\n');

      final fresh = buildBBCodeEditorController(initialText: 'ab')
        ..updateSelection(const TextSelection.collapsed(offset: -1), ChangeSource.local)
        ..insertTextAtCursor('end');
      expect(fresh.document.toPlainText(), 'abend\n');
      controller.dispose();
      fresh.dispose();
    });

    test('several lines inside a quote or a list keep the block of every line', () {
      for (final attribute in <Attribute<dynamic>>[Attribute.blockQuote, Attribute.ul, Attribute.codeBlock]) {
        final controller = buildBBCodeEditorController(initialText: 'abcd')
          ..updateSelection(const TextSelection.collapsed(offset: 2), ChangeSource.local)
          ..formatSelection(attribute)
          ..insertTextAtCursor('X\nY\nZ');
        expect(controller.document.toPlainText(), 'abX\nY\nZcd\n');
        final lines = controller.document.toDelta().toList().where((op) => op.data == '\n').toList();
        expect(lines, hasLength(3));
        for (final line in lines) {
          expect(line.attributes?[attribute.key], attribute.value, reason: '${attribute.key} on every line');
        }
        controller.dispose();
      }
    });

    test('a toggled style covers the whole phrase, a carriage return is dropped', () {
      final controller = buildBBCodeEditorController(initialText: 'abcd')
        ..updateSelection(const TextSelection.collapsed(offset: 2), ChangeSource.local)
        ..formatSelection(Attribute.bold)
        ..insertTextAtCursor('one\r\ntwo');
      expect(controller.document.toPlainText(), 'abone\ntwocd\n');
      expect(controller.selection.baseOffset, 2 + 'one\ntwo'.length);
      final bold = controller.document.toDelta().toList().where((op) => op.attributes?['bold'] == true).toList();
      expect(
        bold.map((op) => op.data).join(),
        'one\ntwo'.replaceAll('\n', ''),
        reason: 'the text of both lines is bold',
      );
      controller.dispose();
    });
  });

  /// The toolbar under a router that has the arranging page.
  Future<BBCodeEditorController> pumpToolbar(WidgetTester tester, {String text = 'abcd'}) async {
    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = buildBBCodeEditorController(initialText: text);
    addTearDown(controller.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: EditorToolbar(bbcodeController: controller)),
        ),
        GoRoute(
          path: ScreenPaths.quickPhrases,
          name: ScreenPaths.quickPhrases,
          builder: (_, _) => const QuickPhrasesPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  final button = find.byKey(const ValueKey('editor-quick-phrases'));

  group('the sheet', () {
    testWidgets('lists the phrases, two lines at most, and inserts the tapped one at the cursor', (tester) async {
      await save(tester, ['first', 'long ${'line ' * 200}', '[b]raw[/b]']);
      final controller = await pumpToolbar(tester);
      controller.updateSelection(const TextSelection.collapsed(offset: 2), ChangeSource.local);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-phrases-manage')), findsOneWidget);
      final long = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey('quick-phrase-item-1')), matching: find.byType(Text)),
      );
      expect(long.maxLines, 2);
      expect(long.overflow, TextOverflow.ellipsis);

      await tester.tap(find.text('[b]raw[/b]'));
      await tester.pumpAndSettle();
      expect(find.text('first'), findsNothing);
      expect(controller.document.toPlainText(), 'ab[b]raw[/b]cd\n');
    });

    testWidgets('the manage button opens the page', (tester) async {
      await save(tester, ['first']);
      await pumpToolbar(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick-phrases-manage')));
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsOneWidget);
      expect(find.text('first'), findsOneWidget);
    });

    testWidgets('without a phrase the page opens at once', (tester) async {
      await pumpToolbar(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsOneWidget);
      expect(find.text(tr.bbcodeEditor.quickPhrases.empty), findsOneWidget);
    });

    testWidgets('back from the page with a phrase added there, the sheet opens with it', (tester) async {
      await pumpToolbar(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('quick-phrases-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick-phrase-field')), 'fresh');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-phrase-ok')));
      await tester.pumpAndSettle();
      await settled(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsNothing);
      expect(find.byKey(const ValueKey('quick-phrases-manage')), findsOneWidget, reason: 'the sheet is open');
      expect(find.byKey(const ValueKey('quick-phrase-item-0')), findsOneWidget);
      expect(find.text('fresh'), findsOneWidget);
    });

    testWidgets('back from the manage button, the sheet shows the phrases as they are now', (tester) async {
      await save(tester, ['one', 'two']);
      final controller = await pumpToolbar(tester);
      controller.updateSelection(const TextSelection.collapsed(offset: 4), ChangeSource.local);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick-phrases-manage')));
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsOneWidget);

      await tester.drag(find.text('one'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await settled(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsNothing);
      expect(find.byKey(const ValueKey('quick-phrases-manage')), findsOneWidget, reason: 'the sheet reopened');
      expect(find.text('one'), findsNothing);
      expect(find.byKey(const ValueKey('quick-phrase-item-0')), findsOneWidget);

      await tester.tap(find.text('two'));
      await tester.pumpAndSettle();
      expect(controller.document.toPlainText(), 'abcdtwo\n');
    });

    testWidgets('back from the page with every phrase deleted, nothing opens', (tester) async {
      await save(tester, ['only']);
      await pumpToolbar(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick-phrases-manage')));
      await tester.pumpAndSettle();
      await tester.drag(find.text('only'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await settled(tester);
      expect(find.text(tr.bbcodeEditor.quickPhrases.empty), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsNothing);
      expect(find.byKey(const ValueKey('quick-phrases-manage')), findsNothing);
      expect(find.text(tr.bbcodeEditor.quickPhrases.title), findsNothing);
      expect(button, findsOneWidget);
    });

    testWidgets('the editor of a fast reply template has no quick phrases button', (tester) async {
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      addTearDown(getIt.reset);
      await save(tester, ['one']);
      tester.view
        ..physicalSize = const Size(1200, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: const MaterialApp(home: FastReplyTemplateEditPage(FastReplyTemplateEditType.create, null)),
          ),
        ),
      );
      await settled(tester);
      expect(find.byType(EditorToolbar), findsOneWidget);
      expect(find.descendant(of: find.byType(EditorToolbar), matching: find.byType(IconButton)), findsWidgets);
      expect(button, findsNothing);
    });

    testWidgets('on a narrow toolbar every wrapped row starts at the left edge, the button ends the first row', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(260, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: MaterialApp(
              home: Scaffold(body: EditorToolbar(bbcodeController: controller)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final buttons = find.descendant(of: find.byType(EditorToolbar), matching: find.byType(IconButton));
      final tops = <double>{};
      var left = double.infinity;
      for (final element in buttons.evaluate()) {
        final rect = tester.getRect(find.byElementPredicate((e) => e == element));
        tops.add(rect.top);
        if (rect.left < left) {
          left = rect.left;
        }
      }
      expect(tops.length, greaterThan(1), reason: 'the toolbar wraps');
      for (final top in tops) {
        final rowLeft = buttons
            .evaluate()
            .map((e) => tester.getRect(find.byElementPredicate((x) => x == e)))
            .where((r) => r.top == top)
            .map((r) => r.left)
            .reduce((a, b) => a < b ? a : b);
        expect(rowLeft, left, reason: 'row at $top starts at the left edge');
      }
      final phrases = tester.getRect(button);
      expect(phrases.top, tops.reduce((a, b) => a < b ? a : b));
      expect(phrases.left, greaterThan(left));
    });

    testWidgets('the feature can be switched off', (tester) async {
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: MaterialApp(
              home: Scaffold(
                body: EditorToolbar(
                  bbcodeController: controller,
                  disabledFeatures: const {EditorFeatures.quickPhrases},
                ),
              ),
            ),
          ),
        ),
      );
      expect(button, findsNothing);
    });
  });

  group('the page', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view
        ..physicalSize = _phone
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: const MaterialApp(home: QuickPhrasesPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> add(WidgetTester tester, String text) async {
      await tester.tap(find.byKey(const ValueKey('quick-phrases-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick-phrase-field')), text);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-phrase-ok')));
      await tester.pumpAndSettle();
    }

    testWidgets('adds phrases in order and keeps them', (tester) async {
      await pumpPage(tester);
      expect(find.text(tr.bbcodeEditor.quickPhrases.empty), findsOneWidget);
      await add(tester, 'one');
      await add(tester, 'two\nlines');
      await settled(tester);
      expect(find.text(tr.bbcodeEditor.quickPhrases.empty), findsNothing);
      expect(saved(), ['one', 'two\nlines']);
    });

    testWidgets('a blank phrase can not be saved, cancel adds nothing', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('quick-phrases-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick-phrase-field')), '   ');
      await tester.pump();
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('quick-phrase-ok'))).onPressed, isNull);
      await tester.tap(find.text(tr.general.cancel));
      await tester.pumpAndSettle();
      await settled(tester);
      expect(saved(), isEmpty);
    });

    testWidgets('a tap edits the phrase', (tester) async {
      await save(tester, ['one', 'two']);
      await pumpPage(tester);
      await tester.tap(find.text('two'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'two'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('quick-phrase-field')), 'second');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-phrase-ok')));
      await tester.pumpAndSettle();
      await settled(tester);
      expect(saved(), ['one', 'second']);
    });

    testWidgets('dragging the handle sorts', (tester) async {
      await save(tester, ['a', 'b', 'c']);
      await pumpPage(tester);
      final handle = find.byKey(const ValueKey('quick-phrase-handle-0'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 130));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      await settled(tester);
      expect(saved(), ['b', 'c', 'a']);
      final tops = [
        for (final t in ['b', 'c', 'a']) tester.getTopLeft(find.text(t)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
    });

    testWidgets('swiping deletes', (tester) async {
      await save(tester, ['a', 'b', 'c']);
      await pumpPage(tester);
      await tester.drag(find.text('b'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await settled(tester);
      expect(find.text('b'), findsNothing);
      expect(saved(), ['a', 'c']);
    });

    testWidgets('a full list adds nothing more', (tester) async {
      await save(tester, [for (var i = 0; i < quickPhraseMaxCount; i++) 'p$i']);
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('quick-phrases-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-phrase-field')), findsNothing);
      expect(saved(), hasLength(quickPhraseMaxCount));
    });

    testWidgets('the field takes 2000 characters', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('quick-phrases-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick-phrase-field')), 'x' * 2100);
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('quick-phrase-field')));
      expect(field.controller!.text, hasLength(quickPhraseMaxLength));
    });

    testWidgets('the field counts an emoji as one character, and what it took is saved whole', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('quick-phrases-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick-phrase-field')), '😀' * (quickPhraseMaxLength + 100));
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('quick-phrase-field')));
      final text = field.controller!.text;
      expect(text.characters.length, quickPhraseMaxLength);
      expect(text.length, 2 * quickPhraseMaxLength);
      await tester.tap(find.byKey(const ValueKey('quick-phrase-ok')));
      await tester.pumpAndSettle();
      await settled(tester);
      expect(saved().single, text);
    });
  });
}
