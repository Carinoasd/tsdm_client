/// The keyboard shortcuts of the desktop app on Android with a hardware keyboard (a tablet, a phone with a keyboard;
/// PR #406 left Android out).
///
/// The input methods of Android send some keys as key events of a keyboard source, and the volume and back keys come
/// as key events too: a key never turns the shortcuts on there. The activity tells whether a hardware keyboard is in
/// use (its configuration), when it starts and on every change, over the main channel.
///
/// 1. without a keyboard nothing changes: keys of any source go on untouched, the page takes no focus;
/// 2. the activity telling of a keyboard turns the shortcuts on, keeping the page's state and the focused text field;
/// 3. telling it gone turns them off again, keeping the state too;
/// 4. a keyboard there at the start is asked for;
/// 5. Ctrl+Enter in the editors waits for the keyboard too; the mouse's back button is the system's on Android;
/// 6. the main channel takes both calls from Android (network and keyboard); the activity sends the keyboard.
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/keyboard/utils/hardware_keyboard_presence.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_page_actions.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/widgets/desktop_back_handler.dart';

void main() {
  late List<String> log;
  void Function({required bool present})? tell;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() {
    KeyboardShortcutsHost.enabledOverride = null;
    HardwareKeyboardPresence.reset();
    HardwareKeyboardPresence.touchPlatformOverride = true;
    HardwareKeyboardPresence.androidOverride = true;
    log = [];
    tell = null;
  });
  tearDown(() {
    HardwareKeyboardPresence.reset();
    HardwareKeyboardPresence.touchPlatformOverride = null;
    HardwareKeyboardPresence.androidOverride = null;
  });

  /// Watch as Android does, the activity answering [atStart]; [tell] then plays the activity's later calls.
  void watch({bool atStart = false}) => HardwareKeyboardPresence.watch(
    present: () async => atStart,
    listen: (onChanged) => tell = onChanged,
  );

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
            KeyboardCallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): () => log.add('send')},
              child: const TextField(key: Key('editor')),
            ),
            const Text('page'),
          ],
        ),
      ),
    ),
  );

  FocusScopeNode? pageScope() {
    final scopes = [
      for (final node in FocusManager.instance.rootScope.descendants)
        if (node is FocusScopeNode && node.debugLabel == 'KeyboardPageActions') node,
    ];
    return scopes.isEmpty ? null : scopes.single;
  }

  Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('no hardware keyboard: keys of a keyboard source turn nothing on, the page takes no focus', (
    tester,
  ) async {
    watch();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(keyboardShortcutsEnabled, isFalse);
    expect(pageScope(), isNull);
    // What an input method sends (Enter, Delete), and keys a desktop would take.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await ctrl(tester, LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(HardwareKeyboardPresence.seen.value, isFalse);
    expect(keyboardShortcutsEnabled, isFalse);
    expect(pageScope(), isNull);
    expect(log, isEmpty);
  });

  testWidgets('Ctrl+Enter in an editor goes on to it without a keyboard, sends with one', (tester) async {
    watch();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor')));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.enter);
    expect(log, isEmpty);
    tell!(present: true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor')));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.enter);
    expect(log, ['send']);
  });

  testWidgets('attached: on, keeping the state below and the focused text field; removed: off, keeping them too', (
    tester,
  ) async {
    watch();
    await tester.pumpWidget(app(field: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('field')), 'typed');
    final fieldFocus = tester
        .widget<EditableText>(find.descendant(of: find.byKey(const Key('field')), matching: find.byType(EditableText)))
        .focusNode;
    expect(fieldFocus.hasPrimaryFocus, isTrue);

    tell!(present: true);
    await tester.pumpAndSettle();
    expect(keyboardShortcutsEnabled, isTrue);
    expect(pageScope(), isNotNull);
    expect(find.text('count 1'), findsOneWidget);
    expect(find.text('typed'), findsOneWidget);
    expect(fieldFocus.hasPrimaryFocus, isTrue);
    await ctrl(tester, LogicalKeyboardKey.keyK);
    expect(log, ['quick-open']);

    tell!(present: false);
    await tester.pumpAndSettle();
    expect(keyboardShortcutsEnabled, isFalse);
    expect(pageScope(), isNull);
    expect(find.text('count 1'), findsOneWidget);
    expect(find.text('typed'), findsOneWidget);
    expect(fieldFocus.hasPrimaryFocus, isTrue);
    await ctrl(tester, LogicalKeyboardKey.keyK);
    expect(log, ['quick-open']);
  });

  testWidgets('attached with the page alone: the page takes the focus and its plain keys work', (tester) async {
    watch();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    tell!(present: true);
    await tester.pumpAndSettle();
    expect(pageScope()?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(log, ['next-item', 'reply']);
  });

  testWidgets('a keyboard there at the start is asked for', (tester) async {
    watch(atStart: true);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(HardwareKeyboardPresence.seen.value, isTrue);
    expect(keyboardShortcutsEnabled, isTrue);
    expect(pageScope()?.hasFocus, isTrue);
  });

  testWidgets('the same value told again changes nothing', (tester) async {
    watch();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    var changes = 0;
    void count() => changes++;
    HardwareKeyboardPresence.seen.addListener(count);
    addTearDown(() => HardwareKeyboardPresence.seen.removeListener(count));
    tell!(present: false);
    tell!(present: true);
    tell!(present: true);
    expect(changes, 1);
  });

  group('the mouse back button', () {
    Widget pages() => MaterialApp(
      builder: (context, child) => DesktopBackHandler(child: child!),
      home: const Text('first'),
      routes: {'/second': (_) => const Scaffold(body: Text('second'))},
    );

    Future<void> pressBack(WidgetTester tester) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await gesture.down(tester.getCenter(find.text('second')));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('is left to Android, which turns it into its back key', (tester) async {
      watch();
      await tester.pumpWidget(pages());
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/second').ignore();
      await tester.pumpAndSettle();
      await pressBack(tester);
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('pops the page on iOS as before', (tester) async {
      HardwareKeyboardPresence.androidOverride = false;
      await tester.pumpWidget(pages());
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/second').ignore();
      await tester.pumpAndSettle();
      await pressBack(tester);
      expect(find.text('second'), findsNothing);
      expect(find.text('first'), findsOneWidget);
    });
  });

  testWidgets('the main channel takes the network and the keyboard calls from Android, both', (tester) async {
    final told = <String>[];
    androidOnNetworkMeteredChanged(({required metered}) => told.add('metered $metered'));
    androidOnHardwareKeyboardChanged(({required present}) => told.add('keyboard $present'));
    const codec = StandardMethodCodec();
    Future<void> call(String method, Object? arguments) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'kzs.th000.tsdm_client/mainChannel',
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    await call('networkMeteredChanged', true);
    await call('hardwareKeyboardChanged', true);
    await call('hardwareKeyboardChanged', false);
    await call('networkMeteredChanged', false);
    expect(told, ['metered true', 'keyboard true', 'keyboard false', 'metered false']);
  });

  group('Android side', () {
    final activity = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
    final keyboards = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/HardwareKeyboards.kt').readAsStringSync();
    final channel = File('lib/utils/method_channel.dart').readAsStringSync();
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    String body(String signature) =>
        RegExp('${RegExp.escape(signature)}[\\s\\S]*?\\n    \\}').firstMatch(activity)!.group(0)!;

    test('the names agree on both sides', () {
      expect(activity, contains('HAS_HARDWARE_KEYBOARD = "hasHardwareKeyboard"'));
      expect(activity, contains('HARDWARE_KEYBOARD_CHANGED = "hardwareKeyboardChanged"'));
      expect(channel, contains("_methodHasHardwareKeyboard = 'hasHardwareKeyboard'"));
      expect(channel, contains("_methodHardwareKeyboardChanged = 'hardwareKeyboardChanged'"));
    });

    test('the activity tells on every configuration change and when it comes to the front', () {
      expect(body('override fun onConfigurationChanged('), contains('notifyHardwareKeyboard(newConfig)'));
      expect(body('override fun onResume()'), contains('notifyHardwareKeyboard(resources.configuration)'));
    });

    test('a full keyboard that is not hidden', () {
      expect(keyboards, contains('config.keyboard == Configuration.KEYBOARD_QWERTY'));
      expect(keyboards, contains('config.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO'));
    });

    test('the activity handles the keyboard changes itself: no restart, the change reaches it', () {
      final tag = RegExp(r'<activity\s[^>]*android:name="\.MainActivityImpl"[^>]*>').firstMatch(manifest)!.group(0)!;
      final changes = RegExp('android:configChanges="([^"]*)"').firstMatch(tag)!.group(1)!.split('|');
      expect(changes, containsAll(['keyboard', 'keyboardHidden']));
    });
  });
}

/// A state of a page, kept when the shortcuts turn on and off.
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
