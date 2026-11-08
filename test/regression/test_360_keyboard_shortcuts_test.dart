// Calls on the selection read better one per line.
// ignore_for_file: cascade_invocations
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_shortcut_catalog.dart';
import 'package:tsdm_client/features/keyboard/view/keyboard_shortcuts_page.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_page_actions.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_selectable.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Keyboard shortcuts of the desktop app: every key reaches the page that answers it on desktop only, the plain keys
/// stay with a focused text input, and the list page tells them all.
void main() {
  late List<String> log;
  var canOpen = true;

  setUp(() {
    KeyboardShortcutsHost.enabledOverride = true;
    log = [];
    canOpen = true;
  });
  tearDown(() => KeyboardShortcutsHost.enabledOverride = null);

  Widget app({bool field = false}) => MaterialApp(
    builder: (context, child) => KeyboardShortcutsHost(
      onSearch: () => log.add('search'),
      onSettings: () => log.add('settings'),
      child: child ?? const SizedBox.shrink(),
    ),
    home: KeyboardPageActions(
      onRefresh: () => log.add('refresh'),
      onNextItem: () => log.add('next-item'),
      onPreviousItem: () => log.add('previous-item'),
      onOpenItem: () => log.add('open'),
      canOpenItem: () => canOpen,
      onNextPage: () => log.add('next-page'),
      onPreviousPage: () => log.add('previous-page'),
      onReply: () => log.add('reply'),
      onScrollToStart: () => log.add('start'),
      onScrollToEnd: () => log.add('end'),
      onCopyLink: () => log.add('copy-link'),
      child: Scaffold(
        body: Column(
          children: [
            if (field) const TextField(key: Key('field'), autofocus: true),
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(title: Text('Dialog')),
                ),
                child: const Text('dialog'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool meta = false,
    bool shift = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  group('on desktop', () {
    testWidgets('every plain key reaches the page', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      for (final key in [
        LogicalKeyboardKey.keyJ,
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.f5,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(log, [
        'next-item',
        'previous-item',
        'next-page',
        'previous-page',
        'reply',
        'open',
        'start',
        'end',
        'refresh',
      ]);
    });

    testWidgets('Ctrl and Cmd combinations', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyF, control: true);
      await chord(tester, LogicalKeyboardKey.keyF, meta: true);
      await chord(tester, LogicalKeyboardKey.comma, control: true);
      await chord(tester, LogicalKeyboardKey.keyR, control: true);
      await chord(tester, LogicalKeyboardKey.keyC, control: true, shift: true);
      expect(log, ['search', 'search', 'settings', 'refresh', 'copy-link']);
    });

    testWidgets('a combination is not the plain key', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyJ, control: true);
      await chord(tester, LogicalKeyboardKey.keyR, control: true, shift: true);
      expect(log, isEmpty);
    });

    testWidgets('Enter is left to the focused button when nothing is selected', (tester) async {
      canOpen = false;
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(log, isEmpty);
    });

    testWidgets('a text input keeps the plain keys but not the combinations', (tester) async {
      await tester.pumpWidget(app(field: true));
      await tester.pump();
      for (final key in [
        LogicalKeyboardKey.keyJ,
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(log, isEmpty);
      await chord(tester, LogicalKeyboardKey.keyR, control: true);
      await chord(tester, LogicalKeyboardKey.keyF, control: true);
      expect(log, ['refresh', 'search']);
    });

    testWidgets('nothing happens above a dialog', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await chord(tester, LogicalKeyboardKey.keyF, control: true);
      expect(log, isEmpty);
    });
  });

  group('focus', () {
    testWidgets('the keys come back after a text input gave the focus up', (tester) async {
      await tester.pumpWidget(app(field: true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      expect(log, isEmpty);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await chord(tester, LogicalKeyboardKey.keyR, control: true);
      expect(log, ['next-item', 'refresh']);
    });

    testWidgets('a click on a page takes the keys from the page beside it', (tester) async {
      KeyboardPageActions page(String name) => KeyboardPageActions(
        onNextItem: () => log.add(name),
        child: SizedBox(width: 200, height: 200, child: Center(child: Text(name))),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => KeyboardShortcutsHost(
            onSearch: () {},
            onSettings: () {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(body: Row(children: [page('left'), page('right')])),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.tap(find.text('right'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.tap(find.text('left'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      expect(log, ['left', 'right', 'left']);
    });

    testWidgets('a click takes the keys from a text input of the page beside it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => KeyboardShortcutsHost(
            onSearch: () {},
            onSettings: () {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: Row(
              children: [
                KeyboardPageActions(
                  onNextItem: () => log.add('left'),
                  child: const SizedBox(width: 300, height: 200, child: TextField(autofocus: true)),
                ),
                KeyboardPageActions(
                  onNextItem: () => log.add('right'),
                  child: const SizedBox(width: 200, height: 200, child: Center(child: Text('right'))),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      // A mouse click: only then does the text input give its focus up when a click lands outside of it.
      await tester.tap(find.text('right'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      expect(log, ['right']);
    });

    testWidgets('the keys stay with a page when the one beside it that had them is replaced', (tester) async {
      var generation = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => KeyboardShortcutsHost(
            onSearch: () {},
            onSettings: () {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Row(
                  children: [
                    KeyboardPageActions(
                      onNextItem: () => log.add('left'),
                      child: const SizedBox(width: 200, height: 200, child: Center(child: Text('left'))),
                    ),
                    KeyedSubtree(
                      key: ValueKey(generation),
                      child: KeyboardPageActions(
                        onNextItem: () => log.add('right$generation'),
                        child: const SizedBox(width: 200, height: 200, child: Center(child: Text('right'))),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('right'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      update(() => generation = 1);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      expect(log.first, 'right0');
      expect(log, hasLength(2));
      expect(log.last, 'left');
    });

    testWidgets('Enter stays with a focused button even with an item to open', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(log, ['open']);
      log.clear();
      Focus.of(tester.element(find.text('dialog'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      expect(find.text('Dialog'), findsOneWidget);
    });
  });

  test('the list tells the keys that are bound', () {
    final bound = {
      for (final activator in KeyboardShortcutsHost.shortcuts.keys)
        if (activator is SingleActivator && activator.trigger != LogicalKeyboardKey.numpadEnter)
          activator.trigger.keyLabel,
    };
    final listed = {
      // The editors bind their own keys.
      for (final entry in keyboardShortcutCatalog.where((e) => e.group != KeyboardShortcutGroup.editor))
        for (final keys in entry.alternatives)
          for (final key in keys)
            // The tabs of the detail pane: Ctrl+Tab is Ctrl on every platform, "1–9" one row for nine keys.
            if (key == '1–9')
              for (var i = 1; i <= 9; i++) '$i'
            else if (!{primaryModifierToken, 'Ctrl', 'Shift', 'Esc'}.contains(key))
              key,
    };
    expect(listed, bound);
  });

  group('on other platforms', () {
    testWidgets('no key is taken', (tester) async {
      KeyboardShortcutsHost.enabledOverride = false;
      await tester.pumpWidget(app());
      await tester.pump();
      for (final key in [LogicalKeyboardKey.keyJ, LogicalKeyboardKey.keyR, LogicalKeyboardKey.f5]) {
        await tester.sendKeyEvent(key);
      }
      await chord(tester, LogicalKeyboardKey.keyF, control: true);
      await chord(tester, LogicalKeyboardKey.keyR, control: true);
      expect(log, isEmpty);
    });
  });

  group('selection', () {
    test('moves within the list and starts at its ends', () {
      final selection = KeyboardSelection();
      selection.move(-1, 3);
      expect(selection.index, 2);
      selection.move(1, 3);
      expect(selection.index, 2);
      selection.move(-1, 3);
      expect(selection.index, 1);
      selection.move(1, 0);
      expect(selection.index, 1);
      selection.clear();
      expect(selection.index, isNull);
      selection.move(1, 3);
      expect(selection.index, 0);
    });

    testWidgets('the selected item is outlined', (tester) async {
      final selection = KeyboardSelection();
      await tester.pumpWidget(
        MaterialApp(
          home: ListView(
            children: [
              for (var i = 0; i < 3; i++)
                KeyboardSelectable(
                  selection: selection,
                  index: i,
                  child: SizedBox(height: 50, child: Text('item $i')),
                ),
            ],
          ),
        ),
      );
      BoxDecoration? outline(int i) {
        final boxes = find.ancestor(of: find.text('item $i'), matching: find.byType(DecoratedBox));
        return boxes
            .evaluate()
            .map((e) => (e.widget as DecoratedBox).decoration)
            .whereType<BoxDecoration>()
            .firstOrNull;
      }

      expect(outline(1), isNull);
      selection.move(1, 3);
      selection.move(1, 3);
      await tester.pumpAndSettle();
      expect(outline(0), isNull);
      expect(outline(1)?.border, isNotNull);
    });
  });

  group('the list page', () {
    testWidgets('tells every shortcut of the catalog', (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: KeyboardShortcutsPage())));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(keyboardShortcutCatalog.length));
      expect(find.text('Next floor'), findsOneWidget);
      expect(find.text('Ctrl'), findsWidgets);
    });

    test('names the primary modifier of the platform', () {
      expect(KeyboardShortcutsPage.keyLabel(primaryModifierToken, mac: true), 'Cmd');
      expect(KeyboardShortcutsPage.keyLabel(primaryModifierToken, mac: false), 'Ctrl');
      expect(KeyboardShortcutsPage.keyLabel('F5', mac: false), 'F5');
    });
  });
}
