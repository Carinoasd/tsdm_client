/// The keyboard shortcuts of the desktop app on iOS with a hardware keyboard (an iPad, an iPhone with a keyboard).
///
/// 1. on a touch platform the shortcuts are off until a key of a hardware keyboard is pressed (iOS sends no key events
///    for its on-screen keyboard), and a page takes no focus meanwhile;
/// 2. the first key turns them on and works itself: Cmd+K opens the quick open box;
/// 3. turning them on keeps what is below: the pages' state, the focused text field's focus and text;
/// 4. once on, the page takes the focus and its plain keys work; a focused text field keeps them;
/// 5. the bindings leave the combinations iPadOS keeps for itself alone; desktop is unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_intents.dart';
import 'package:tsdm_client/features/keyboard/utils/hardware_keyboard_presence.dart';
import 'package:tsdm_client/features/keyboard/view/keyboard_shortcuts_page.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_page_actions.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';

void main() {
  late List<String> log;

  setUp(() {
    KeyboardShortcutsHost.enabledOverride = null;
    HardwareKeyboardPresence.reset();
    HardwareKeyboardPresence.touchPlatformOverride = true;
    log = [];
  });
  tearDown(() {
    HardwareKeyboardPresence.reset();
    HardwareKeyboardPresence.touchPlatformOverride = null;
  });

  Widget app({bool field = false}) => MaterialApp(
    builder: (context, child) => KeyboardShortcutsHost(
      onSearch: () => log.add('search'),
      onSettings: () => log.add('settings'),
      onQuickOpen: () => log.add('quick-open'),
      child: child ?? const SizedBox.shrink(),
    ),
    home: KeyboardPageActions(
      onNextItem: () => log.add('next-item'),
      onReply: () => log.add('reply'),
      child: Scaffold(
        body: Column(
          children: [
            const _Counter(),
            if (field) const TextField(key: Key('field'), autofocus: true),
            const Text('page'),
          ],
        ),
      ),
    ),
  );

  FocusScopeNode? pageScope() {
    final scopes = _pageScopes();
    return scopes.isEmpty ? null : scopes.single;
  }

  Future<void> cmd(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  testWidgets('no hardware keyboard: off, and the page takes no focus', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(HardwareKeyboardPresence.seen.value, isFalse);
    expect(keyboardShortcutsEnabled, isFalse);
    expect(keyboardShortcutsBuilt, isTrue);
    expect(pageScope(), isNull);
    // The actions are there but off: a key would go on untouched.
    final context = tester.element(find.text('page'));
    final search = Actions.maybeFind<OpenSearchIntent>(context, intent: const OpenSearchIntent());
    expect(search, isNotNull);
    expect(search!.isEnabled(const OpenSearchIntent()), isFalse);

    // A tap on the page leaves the focus where it is.
    final before = FocusManager.instance.primaryFocus;
    await tester.tap(find.text('page'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, before);
    expect(log, isEmpty);
  });

  testWidgets('the first key turns them on and works itself', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await cmd(tester, LogicalKeyboardKey.keyK);
    expect(HardwareKeyboardPresence.seen.value, isTrue);
    expect(keyboardShortcutsEnabled, isTrue);
    expect(log, ['quick-open']);
    await cmd(tester, LogicalKeyboardKey.keyF);
    expect(log, ['quick-open', 'search']);
  });

  testWidgets('turning them on keeps the state below and the focused text field', (tester) async {
    await tester.pumpWidget(app(field: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add')));
    await tester.pump();
    expect(find.text('count 1'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field')), 'typed');
    final fieldFocus = tester
        .widget<EditableText>(find.descendant(of: find.byKey(const Key('field')), matching: find.byType(EditableText)))
        .focusNode;
    expect(fieldFocus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(HardwareKeyboardPresence.seen.value, isTrue);
    expect(pageScope(), isNotNull);
    expect(find.text('count 1'), findsOneWidget);
    expect(find.text('typed'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, fieldFocus);
    expect(fieldFocus.hasPrimaryFocus, isTrue);

    // The text field keeps the plain keys, the combinations still work.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(log, isEmpty);
    await cmd(tester, LogicalKeyboardKey.keyK);
    expect(log, ['quick-open']);
  });

  testWidgets('once on, the page takes the focus and its plain keys work', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // The first plain key only tells the keyboard: nothing had the page focused yet.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(pageScope()?.hasFocus, isTrue);
    log.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(log, ['next-item', 'reply']);
  });

  test('the bindings leave the combinations of iPadOS alone', () {
    const reserved = [
      SingleActivator(LogicalKeyboardKey.keyH, meta: true),
      SingleActivator(LogicalKeyboardKey.space, meta: true),
      SingleActivator(LogicalKeyboardKey.tab, meta: true),
      SingleActivator(LogicalKeyboardKey.tab, meta: true, shift: true),
      SingleActivator(LogicalKeyboardKey.digit3, meta: true, shift: true),
      SingleActivator(LogicalKeyboardKey.digit4, meta: true, shift: true),
      SingleActivator(LogicalKeyboardKey.digit5, meta: true, shift: true),
      SingleActivator(LogicalKeyboardKey.keyD, meta: true, alt: true),
      SingleActivator(LogicalKeyboardKey.backquote, meta: true),
    ];
    final bound = KeyboardShortcutsHost.shortcuts.keys.whereType<SingleActivator>().toList();
    for (final r in reserved) {
      expect(
        bound.where(
          (b) =>
              b.trigger == r.trigger &&
              b.meta == r.meta &&
              b.shift == r.shift &&
              b.alt == r.alt &&
              b.control == r.control,
        ),
        isEmpty,
        reason: r.debugDescribeKeys(),
      );
    }
  });

  test('the list page tells Cmd on iOS as on macOS', () {
    expect(KeyboardShortcutsPage.keyLabel('mod', mac: true), 'Cmd');
    expect(KeyboardShortcutsPage.keyLabel('mod', mac: false), 'Ctrl');
  });

  testWidgets('desktop: on from the start, without a key', (tester) async {
    HardwareKeyboardPresence.touchPlatformOverride = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(keyboardShortcutsEnabled, isTrue);
    expect(pageScope()?.hasFocus, isTrue);
    expect(HardwareKeyboardPresence.seen.value, isFalse);
  });
}

/// The focus scopes of [KeyboardPageActions] in the tree.
List<FocusScopeNode> _pageScopes() => [
  for (final node in FocusManager.instance.rootScope.descendants)
    if (node is FocusScopeNode && node.debugLabel == 'KeyboardPageActions') node,
];

/// A state of a page, kept when the shortcuts turn on.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    key: const Key('add'),
    onPressed: () => setState(() => _count++),
    child: Text('count $_count'),
  );
}
