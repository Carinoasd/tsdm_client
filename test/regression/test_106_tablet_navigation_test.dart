import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// GitHub #103: a double tap on the tablet navigation rail, or on the navigation drawer of a large window, scrolls the
/// tab to top (or refreshes it at the top) like a double tap on the phone navigation bar does.
///
/// The three widgets are the real ones, under a shell route with the three home tabs; the tab pages are placeholders.
/// What the real topics page does with the event (scroll to top, or refresh when already there) is covered end to end
/// in test_043_topics_favorite_forums_test.dart.
Translations get tr => LocaleSettings.instance.currentTranslations;

/// phone: bottom bar (compact), tablet: rail (medium), desktop: drawer (large and up, as in HomePage).
enum _Layout { phone, tablet, desktop }

/// The navigation widget type drawn in [layout].
Type _navigationType(_Layout layout) => switch (layout) {
  _Layout.phone => NavigationBar,
  _Layout.tablet => NavigationRail,
  _Layout.desktop => NavigationDrawer,
};

/// Records every tab switch the navigation asks for; each one comes with a `goNamed`.
final class _HomeCubit extends HomeCubit {
  final switches = <HomeTab>[];

  @override
  void setTab(HomeTab tab) {
    switches.add(tab);
    super.setTab(tab);
  }
}

const Map<HomeTab, String> _paths = {
  HomeTab.home: ScreenPaths.homepage,
  HomeTab.topic: ScreenPaths.topic,
  HomeTab.settings: '/settings',
};

const Map<HomeTab, (IconData, IconData)> _icons = {
  HomeTab.home: (Icons.home_outlined, Icons.home),
  HomeTab.topic: (Icons.topic_outlined, Icons.topic),
  HomeTab.settings: (Icons.settings_outlined, Icons.settings),
};

void main() {
  late _HomeCubit cubit;
  late GoRouter router;
  late StreamSubscription<ScrollToTopEvent> sub;
  late DateTime now;
  final events = <int>[];

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    now = DateTime(2026, 9, 23, 12);
    HomeTabDoubleTapDetector.clock = () => now;
    events.clear();
    sub = scrollToTopStream.stream.listen((e) => events.add(e.tabIndex));
  });

  tearDown(() async {
    HomeTabDoubleTapDetector.clock = DateTime.now;
    await sub.cancel();
  });

  void wait(int ms) => now = now.add(Duration(milliseconds: ms));

  String location() => router.routerDelegate.currentConfiguration.uri.path;

  Future<void> pumpHome(WidgetTester tester, _Layout layout) async {
    expect(ScreenPaths.settings.path, _paths[HomeTab.settings]);
    cubit = _HomeCubit();
    router = GoRouter(
      initialLocation: ScreenPaths.homepage,
      routes: [
        ShellRoute(
          builder: (context, state, child) => switch (layout) {
            _Layout.phone => Scaffold(body: child, bottomNavigationBar: const HomeNavigationBar()),
            _Layout.tablet => Scaffold(
              body: Row(
                children: [
                  const HomeNavigationRail(),
                  Expanded(child: child),
                ],
              ),
            ),
            // Same constraint as HomePage puts on the drawer.
            _Layout.desktop => Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 250, child: HomeNavigationDrawer()),
                  Expanded(child: child),
                ],
              ),
            ),
          },
          routes: [
            for (final path in _paths.values)
              GoRoute(
                path: path,
                name: path,
                pageBuilder: (context, state) => NoTransitionPage(child: Center(child: Text('page $path'))),
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(cubit.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<HomeCubit>.value(
          value: cubit,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    for (final other in _Layout.values) {
      expect(find.byType(_navigationType(other)), other == layout ? findsOneWidget : findsNothing);
    }
  }

  String label(HomeTab tab) => switch (tab) {
    HomeTab.home => tr.navigation.homepage,
    HomeTab.topic => tr.navigation.topics,
    HomeTab.settings => tr.navigation.settings,
  };

  /// The icon currently drawn for [tab]: the filled one when selected.
  Finder icon(HomeTab tab) {
    final (outlined, filled) = _icons[tab]!;
    return find.byIcon(cubit.state.tab == tab ? filled : outlined);
  }

  /// Tap the destination of [tab] like a user, on its icon or (bar and drawer: the rail hides its labels) its label.
  Future<void> tap(WidgetTester tester, HomeTab tab, {bool onLabel = false}) async {
    await tester.tap(onLabel ? find.text(label(tab)) : icon(tab));
    await tester.pump();
  }

  for (final layout in _Layout.values) {
    group('${layout.name} navigation', () {
      testWidgets('a single tap on another tab switches to it, no scroll event', (tester) async {
        await pumpHome(tester, layout);
        await tap(tester, HomeTab.topic);
        expect(cubit.switches, [HomeTab.topic]);
        expect(location(), ScreenPaths.topic);
        expect(find.text('page ${ScreenPaths.topic}'), findsOneWidget);
        expect(events, isEmpty);

        wait(1000);
        await tap(tester, HomeTab.settings);
        expect(cubit.switches, [HomeTab.topic, HomeTab.settings]);
        expect(location(), '/settings');
        wait(1000);
        await tap(tester, HomeTab.home);
        expect(location(), ScreenPaths.homepage);
        expect(events, isEmpty);
      });

      for (final tab in HomeTab.values) {
        testWidgets('a double tap on ${tab.name} sends one event for its index and does not route twice', (
          tester,
        ) async {
          await pumpHome(tester, layout);
          await tap(tester, tab);
          wait(200);
          await tap(tester, tab);
          expect(cubit.switches, [tab], reason: 'the second tap does not route');
          expect(location(), _paths[tab]);
          expect(events, [tab.index]);
        });
      }

      if (layout != _Layout.tablet) {
        testWidgets('a double tap on the label works like one on the icon', (tester) async {
          await pumpHome(tester, layout);
          await tap(tester, HomeTab.topic, onLabel: true);
          wait(100);
          await tap(tester, HomeTab.topic, onLabel: true);
          expect(cubit.switches, [HomeTab.topic]);
          expect(events, [HomeTab.topic.index]);
        });

        testWidgets('icon then label of the same destination is a double tap too', (tester) async {
          await pumpHome(tester, layout);
          await tap(tester, HomeTab.settings);
          wait(100);
          await tap(tester, HomeTab.settings, onLabel: true);
          expect(cubit.switches, [HomeTab.settings]);
          expect(events, [HomeTab.settings.index]);
        });
      }

      testWidgets('a rebuilt ${layout.name} navigation keeps counting the double tap', (tester) async {
        await pumpHome(tester, layout);
        await tap(tester, HomeTab.topic);
        // The shell rebuilt with the new location and selected index between the two taps.
        await tester.pump();
        wait(300);
        await tap(tester, HomeTab.topic);
        expect(events, [HomeTab.topic.index]);
      });

      testWidgets('a triple tap sends one event; the third tap is an ordinary tap', (tester) async {
        await pumpHome(tester, layout);
        await tap(tester, HomeTab.topic);
        wait(100);
        await tap(tester, HomeTab.topic);
        wait(100);
        await tap(tester, HomeTab.topic);
        expect(events, [HomeTab.topic.index]);
        expect(cubit.switches, [HomeTab.topic, HomeTab.topic]);
        expect(location(), ScreenPaths.topic);

        // A fourth quick tap pairs with the third one.
        wait(100);
        await tap(tester, HomeTab.topic);
        expect(events, [HomeTab.topic.index, HomeTab.topic.index]);
        expect(cubit.switches, hasLength(2));
      });

      testWidgets('quick taps on different tabs are two switches, never a double tap', (tester) async {
        await pumpHome(tester, layout);
        await tap(tester, HomeTab.home);
        wait(100);
        await tap(tester, HomeTab.topic);
        wait(100);
        await tap(tester, HomeTab.home);
        expect(events, isEmpty);
        expect(cubit.switches, [HomeTab.home, HomeTab.topic, HomeTab.home]);
        expect(location(), ScreenPaths.homepage);
      });

      testWidgets('slow taps on the same tab are not a double tap', (tester) async {
        await pumpHome(tester, layout);
        await tap(tester, HomeTab.topic);
        wait(HomeTabDoubleTapDetector.interval.inMilliseconds);
        await tap(tester, HomeTab.topic);
        wait(900);
        await tap(tester, HomeTab.topic);
        expect(events, isEmpty);
        expect(cubit.switches, [HomeTab.topic, HomeTab.topic, HomeTab.topic]);
        expect(location(), ScreenPaths.topic);
      });

      testWidgets('A-B-B: only the pair on the same tab is a double tap', (tester) async {
        await pumpHome(tester, layout);
        await tap(tester, HomeTab.home);
        wait(100);
        await tap(tester, HomeTab.settings);
        wait(100);
        await tap(tester, HomeTab.settings);
        expect(events, [HomeTab.settings.index]);
        expect(cubit.switches, [HomeTab.home, HomeTab.settings]);
        expect(location(), '/settings');
      });
    });
  }

  testWidgets('bar, rail and drawer answer the same tap script identically', (tester) async {
    // (tab, milliseconds since the previous tap): switches, double taps, a triple tap, a slow pair, A-B-B.
    const script = [
      (HomeTab.topic, 1000),
      (HomeTab.topic, 200),
      (HomeTab.topic, 100),
      (HomeTab.home, 100),
      (HomeTab.settings, 100),
      (HomeTab.settings, 100),
      (HomeTab.settings, 600),
      (HomeTab.home, 1000),
      (HomeTab.home, 499),
    ];
    final results = <_Layout, (List<int>, List<HomeTab>, List<String>)>{};
    for (final layout in _Layout.values) {
      events.clear();
      // Start from an empty tree so no navigation state carries over from the previous layout.
      await tester.pumpWidget(const SizedBox());
      await pumpHome(tester, layout);
      final locations = <String>[];
      for (final (tab, ms) in script) {
        wait(ms);
        await tap(tester, tab);
        locations.add(location());
      }
      results[layout] = (List.of(events), List.of(cubit.switches), locations);
    }

    final phone = results[_Layout.phone]!;
    expect(phone.$1, [HomeTab.topic.index, HomeTab.settings.index, HomeTab.home.index]);
    expect(phone.$2, [
      HomeTab.topic,
      HomeTab.topic,
      HomeTab.home,
      HomeTab.settings,
      HomeTab.settings,
      HomeTab.home,
    ]);
    for (final layout in [_Layout.tablet, _Layout.desktop]) {
      final r = results[layout]!;
      expect(r.$1, phone.$1, reason: '${layout.name} scroll events');
      expect(r.$2, phone.$2, reason: '${layout.name} tab switches');
      expect(r.$3, phone.$3, reason: '${layout.name} locations');
    }
  });

  group('HomeTabDoubleTapDetector', () {
    test('second tap on the same index within the interval is a double tap, the third starts over', () {
      final d = HomeTabDoubleTapDetector();
      expect(d.tap(1), isFalse);
      wait(499);
      expect(d.tap(1), isTrue);
      wait(1);
      expect(d.tap(1), isFalse);
      wait(10);
      expect(d.tap(1), isTrue);
    });

    test('exactly the interval, another index, or a new detector is not a double tap', () {
      final d = HomeTabDoubleTapDetector();
      expect(d.tap(0), isFalse);
      wait(500);
      expect(d.tap(0), isFalse);
      wait(10);
      expect(d.tap(2), isFalse);
      expect(HomeTabDoubleTapDetector().tap(2), isFalse, reason: 'bar, rail and drawer do not share taps');
    });
  });
}
