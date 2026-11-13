// What's new (P8): the changelog page (sections in the app language, markdown, the forum script setting, the releases
// marked new) and the line of the homepage that opens it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/update/models/changelog_release.dart';
import 'package:tsdm_client/features/update/repository/whats_new_controller.dart';
import 'package:tsdm_client/features/update/view/whats_new_page.dart';
import 'package:tsdm_client/features/update/widgets/whats_new_banner.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

const _changelog = '''
# Changelog

## [Unreleased]

## [2.1.0] - 2026-12-01

需要论坛接口插件。

### Added

- **加粗**的条目。
- 有子项的条目：
  - 子项一。

### Fixed

- 修复一。

## [2.0.0] - 2026-11-01

### Changed

- 变更一。

## [1.0.0] - 2026-10-01

### Removed

- 移除一。
''';

Future<List<ChangelogRelease>> _load() async => parseChangelog(_changelog);

ChineseConverter _converter(String name) =>
    ChineseConverter.parse(File('assets/text/opencc/$name.txt').readAsStringSync());

final class _Store {
  final Map<String, String> values = {};

  Future<String?> read(String key) async => values[key];

  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    ChineseDisplay.instance.useConverters(s2t: _converter('s2t'), t2s: _converter('t2s'));
  });

  tearDown(() async => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pumpPage(
    WidgetTester tester, {
    String? since,
    bool markNew = false,
    ChineseDisplayMode mode = ChineseDisplayMode.off,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => ChineseDisplayHost(mode: mode, child: child!),
          home: WhatsNewPage(since: since, markNew: markNew, currentVersion: '2.1.0', loadReleases: _load),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  testWidgets('releases newest first, sections in English, the changelog text as written', (tester) async {
    await pumpPage(tester);
    expect(find.text('Changelog'), findsOneWidget);
    final top = tester.getTopLeft(find.text('2.1.0')).dy;
    expect(top, lessThan(tester.getTopLeft(find.text('2.0.0')).dy));
    expect(tester.getTopLeft(find.text('2.0.0')).dy, lessThan(tester.getTopLeft(find.text('1.0.0')).dy));
    expect(find.text('2026-12-01'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Fixed'), findsOneWidget);
    expect(find.text('Changed'), findsOneWidget);
    expect(find.text('Removed'), findsOneWidget);
    expect(rich('需要论坛接口插件。'), findsOneWidget);
    expect(rich('子项一。'), findsOneWidget);
    expect(rich('修复一。'), findsOneWidget);
    expect(find.byKey(const ValueKey('whats-new-release-new')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bold markdown is bold', (tester) async {
    await pumpPage(tester);
    final spans = tester
        .widgetList<RichText>(find.byType(RichText))
        .expand((e) {
          final out = <TextSpan>[];
          e.text.visitChildren((span) {
            if (span is TextSpan) out.add(span);
            return true;
          });
          return out;
        })
        .where((e) => e.text == '加粗');
    expect(spans, isNotEmpty);
    expect(spans.first.style?.fontWeight, FontWeight.bold);
  });

  testWidgets('Chinese app language: section names translated', (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
    await pumpPage(tester);
    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('新增'), findsOneWidget);
    expect(find.text('修复'), findsOneWidget);
    expect(find.text('移除'), findsOneWidget);
  });

  testWidgets('Traditional script setting converts the changelog text', (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
    await pumpPage(tester, mode: ChineseDisplayMode.traditional);
    expect(find.text('修正'), findsOneWidget);
    expect(find.text('變更'), findsOneWidget);
    expect(rich('修復一。'), findsOneWidget);
    expect(rich('需要論壇接口插件。'), findsOneWidget);
    expect(rich('修复一。'), findsNothing);
  });

  testWidgets('opened from an update the releases since the version seen are marked', (tester) async {
    await pumpPage(tester, since: '1.0.0', markNew: true);
    expect(find.byKey(const ValueKey('whats-new-release-new')), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('whats-new-release-2.0.0')),
        matching: find.byKey(const ValueKey('whats-new-release-new')),
      ),
      findsOneWidget,
    );

    await pumpPage(tester, markNew: true);
    expect(find.byKey(const ValueKey('whats-new-release-new')), findsOneWidget);
  });

  testWidgets('a running version without an entry shows the releases there are', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: WhatsNewPage(since: '2.1.0', markNew: true, currentVersion: '2.2.0', loadReleases: _load),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2.1.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('whats-new-release-new')), findsNothing);
  });

  group('homepage line', () {
    late _Store store;
    late WhatsNewController controller;

    Future<void> pumpBanner(WidgetTester tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: ListView(children: [WhatsNewBanner(controller: controller)]),
            ),
          ),
          GoRoute(
            path: ScreenPaths.localChangelog,
            name: ScreenPaths.localChangelog,
            builder: (_, state) => WhatsNewPage(
              since: state.uri.queryParameters['since'],
              markNew: state.uri.queryParameters['new'] == '1',
              currentVersion: '2.1.0',
              loadReleases: _load,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();
    }

    setUp(() {
      store = _Store()..values[WhatsNewController.storageKey] = '1.0.0';
      controller = WhatsNewController(
        read: store.read,
        write: store.write,
        appVersion: '2.1.0+5',
        releasedVersions: () => changelogVersions(_changelog),
      );
    });

    tearDown(() => controller.dispose());

    testWidgets('nothing without an offer or a controller', (tester) async {
      await pumpBanner(tester);
      expect(find.byKey(const ValueKey('whats-new-banner')), findsNothing);
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(home: Scaffold(body: WhatsNewBanner())),
        ),
      );
      expect(find.byKey(const ValueKey('whats-new-banner')), findsNothing);
    });

    testWidgets('dismissed: gone and not offered again', (tester) async {
      await controller.resolve(hadPriorData: true);
      await pumpBanner(tester);
      expect(find.text('Updated to 2.1.0'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('whats-new-banner-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-banner')), findsNothing);
      expect(store.values[WhatsNewController.storageKey], '2.1.0');
    });

    testWidgets('opened: the changelog with every release since the version seen marked', (tester) async {
      await controller.resolve(hadPriorData: true);
      await pumpBanner(tester);
      await tester.tap(find.byKey(const ValueKey('whats-new-banner-open')));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewPage), findsOneWidget);
      expect(find.byKey(const ValueKey('whats-new-release-new')), findsNWidgets(2));
      expect(store.values[WhatsNewController.storageKey], '2.1.0');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-banner')), findsNothing);
    });
  });
}
