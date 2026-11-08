import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_shortcut_catalog.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_page_actions.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/quick_open/repository/quick_open_sources_loader.dart';
import 'package:tsdm_client/features/quick_open/view/quick_open_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// The quick open box on screen: Ctrl+K opens it on desktop, the arrows move the selection, Enter opens the selected
/// line and the first one at first.
void _noop({List<QuickOpenForum>? forums, List<QuickOpenThread>? threads, List<QuickOpenUser>? users}) {}

bool _yes() => true;

void main() {
  late List<String> log;
  late GoRouter router;

  const sources = QuickOpenSources(
    forums: [(fid: 2, name: 'Anime Talk')],
    threads: [(tid: 800, title: 'Weekly anime chat')],
    users: [(uid: '31', name: 'Anime_fan')],
  );

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    KeyboardShortcutsHost.enabledOverride = true;
    log = [];
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => KeyboardPageActions(
            child: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const QuickOpenDialog(sources: sources),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
        for (final path in [ScreenPaths.forum, ScreenPaths.threadV1, ScreenPaths.profile, ScreenPaths.search])
          GoRoute(
            path: path,
            name: path,
            builder: (_, state) {
              log.add('$path ${state.pathParameters} ${state.uri.queryParameters}');
              return const Scaffold(body: Text('page'));
            },
          ),
      ],
    );
  });
  tearDown(() => KeyboardShortcutsHost.enabledOverride = null);

  Future<void> pumpApp(WidgetTester tester, {VoidCallback? onQuickOpen}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => KeyboardShortcutsHost(
            onSearch: () {},
            onSettings: () {},
            onQuickOpen: onQuickOpen,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openBox(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+K and Cmd+K open the box, on a page only', (tester) async {
    var opened = 0;
    await pumpApp(tester, onQuickOpen: () => opened++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(opened, 2);

    await openBox(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(opened, 2, reason: 'the box is not opened over itself');
  });

  testWidgets('the shortcut list tells the key', (tester) async {
    final entry = keyboardShortcutCatalog.singleWhere((e) => e.command == KeyboardCommand.quickOpen);
    expect(entry.group, KeyboardShortcutGroup.global);
    expect(entry.alternatives, [
      [primaryModifierToken, 'K'],
    ]);
  });

  testWidgets('nothing typed lists nothing; typed text lists the matches and the search', (tester) async {
    await pumpApp(tester);
    await openBox(tester);
    expect(find.byType(ListTile), findsNothing);

    await tester.enterText(find.byKey(const Key('quickOpenField')), 'anime');
    await tester.pump();
    expect(find.byType(ListTile), findsNWidgets(4));
    expect(find.text('Anime Talk'), findsOneWidget);
    expect(find.text('Weekly anime chat'), findsOneWidget);
    expect(find.text('Anime_fan'), findsOneWidget);
    expect(find.text('Search: anime'), findsOneWidget);
  });

  testWidgets('Enter opens the first line', (tester) async {
    await pumpApp(tester);
    await openBox(tester);
    await tester.enterText(find.byKey(const Key('quickOpenField')), 'anime');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(log, [contains(ScreenPaths.forum)]);
    expect(log.single, contains('{fid: 2}'));
    expect(find.byType(QuickOpenDialog), findsNothing);
  });

  testWidgets('the arrows move the selection, Enter opens it', (tester) async {
    await pumpApp(tester);
    await openBox(tester);
    await tester.enterText(find.byKey(const Key('quickOpenField')), 'anime');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('quickOpenItem2'))).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('quickOpenItem1'))).selected, isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(log.single, allOf(contains(ScreenPaths.profile), contains('uid: 31')));
  });

  testWidgets('a thread id opens that thread; text with no match opens the search', (tester) async {
    await pumpApp(tester);
    await openBox(tester);
    await tester.enterText(find.byKey(const Key('quickOpenField')), '4321');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(log.single, allOf(contains(ScreenPaths.threadV1), contains('tid: 4321')));

    router.pop();
    await tester.pumpAndSettle();
    log.clear();
    await openBox(tester);
    await tester.enterText(find.byKey(const Key('quickOpenField')), 'nothing here');
    await tester.pump();
    await tester.tap(find.text('Search: nothing here'));
    await tester.pumpAndSettle();
    expect(log.single, allOf(contains(ScreenPaths.search), contains('keyword: nothing here')));
  });

  testWidgets('a source arriving late keeps the selected line', (tester) async {
    late QuickOpenSourcesArrived arrived;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => QuickOpenDialog(
                          sources: sources,
                          loader: (context, {onLoaded = _noop, isActive = _yes}) async => arrived = onLoaded,
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openBox(tester);
    await tester.enterText(find.byKey(const Key('quickOpenField')), 'anime');
    await tester.pump();
    // Forum, user, thread, search: the thread is the third line.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('quickOpenItem2'))).selected, isTrue);

    arrived(forums: [(fid: 5, name: 'Anime News'), (fid: 2, name: 'Anime Talk')]);
    await tester.pump();
    // The new forum is a line more above the thread, the selection followed the thread.
    expect(find.byType(ListTile), findsNWidgets(5));
    expect(find.text('Weekly anime chat'), findsOneWidget);
    final selected = tester.widgetList<ListTile>(find.byType(ListTile)).where((e) => e.selected).single;
    expect((selected.title! as Text).data, 'Weekly anime chat');
  });

  testWidgets('Esc closes the box without opening anything', (tester) async {
    await pumpApp(tester);
    await openBox(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QuickOpenDialog), findsNothing);
    expect(log, isEmpty);
  });
}
