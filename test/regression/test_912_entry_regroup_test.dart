/// The entries regrouped (plan A): the moderator's panel in four groups under headers (moderation, members and forums,
/// rewards, site), a group without a tile not shown at all and a tile never moving to another group while the six
/// answers come in one after another; the overflow menu of another member's profile in sections apart by dividers
/// (social, tools, admin), and the admin sheet in two (rewards, the forum's admin actions).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/utils/batch_rate_access.dart';
import 'package:tsdm_client/features/medal_title_tools/utils/staff_access.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/profile/widgets/member_admin_sheet.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/overflow_actions.dart';

import 'admin_tools_fakes.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

/// The group of each tile of the panel.
const _groupOf = {
  'modcp-queue': 'moderation',
  'modcp-recycle-bin': 'moderation',
  'modcp-log': 'moderation',
  'modcp-notes': 'moderation',
  'modcp-threads': 'moderation',
  'modcp-posts': 'moderation',
  'modcp-report': 'moderation',
  'modcp-forum-access': 'members',
  'modcp-members': 'members',
  'modcp-member-review': 'members',
  'modcp-rules': 'members',
  'modcp-announcements': 'members',
  'modcp-medal-grant': 'rewards',
  'modcp-title-issue': 'rewards',
  'modcp-background-grant': 'rewards',
  'modcp-batch-rate': 'rewards',
  'modcp-admin-credit': 'site',
  'modcp-admin-group': 'site',
  'modcp-admin-ban': 'site',
};

/// The panel's first page, its menu linking [links].
String _menu(List<String> links) =>
    '<script>var discuz_uid = \'33\';</script><div class="appl"><ul>'
    '${links.map((l) => '<li><a href="forum.php?mod=modcp&action=$l">x</a></li>').join()}</ul></div>';

/// The six answers the panel waits for, each given when the test says.
final class _Answers {
  final menu = Completer<List<String>>();
  final staff = Completer<StaffTools?>();
  final panel = Completer<PanelTools?>();
  final admin = Completer<AdminAccess?>();
  final batchRate = Completer<BatchRateInfo?>();
  final pages = Completer<Set<String>?>();
}

Future<void> _pump(WidgetTester tester, _Answers answers, {Size size = const Size(900, 2400)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async =>
      right((statusCode: 200, data: _menu(await answers.menu.future)));
  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async =>
      right((statusCode: 200, data: null));
  final panel = ModcpRepository(get: get, post: post, currentUid: () => 33);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: ModeratorPanelPage(
          repository: panel,
          staffTools: () => answers.staff.future,
          panelTools: () => answers.panel.future,
          adminAccess: () => answers.admin.future,
          adminRepository: FakeAdminForum().repository(),
          batchRate: () => answers.batchRate.future,
          modcpPages: () => answers.pages.future,
          pagesRepository: ModcpPagesRepository(panel: panel, get: get, post: post, currentUid: () => 33),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The groups shown, in order down the page, each with its header; and every tile shown in its own group.
void _expectGroups(WidgetTester tester, List<String> groups) {
  final titles = {
    'moderation': tr.modcp.groupModeration,
    'members': tr.modcp.groupMembers,
    'rewards': tr.modcp.groupRewards,
    'site': tr.modcp.groupSite,
  };
  double? top;
  for (final group in titles.keys) {
    final finder = find.byKey(ValueKey('modcp-group-$group'));
    if (!groups.contains(group)) {
      expect(finder, findsNothing, reason: group);
      expect(find.text(titles[group]!), findsNothing, reason: 'the header of $group');
      continue;
    }
    expect(finder, findsOneWidget, reason: group);
    expect(
      find.descendant(of: finder, matching: find.text(titles[group]!)),
      findsOneWidget,
      reason: group,
    );
    final at = tester.getTopLeft(finder).dy;
    if (top != null) {
      expect(at, greaterThan(top), reason: group);
    }
    top = at;
  }
  for (final MapEntry(key: tile, value: group) in _groupOf.entries) {
    if (find.byKey(ValueKey(tile)).evaluate().isNotEmpty) {
      expect(
        find.descendant(of: find.byKey(ValueKey('modcp-group-$group')), matching: find.byKey(ValueKey(tile))),
        findsOneWidget,
        reason: '$tile in $group',
      );
    }
  }
}

/// The tiles shown, in the order of [_groupOf].
List<String> _tiles() => [
  for (final tile in _groupOf.keys)
    if (find.byKey(ValueKey(tile)).evaluate().isNotEmpty) tile,
];

Map<String, dynamic> _batchRateFixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    AdminAccessCache.reset();
    ManagementGroupCache.reset();
    PanelToolsAccess.reset();
    BatchRateAccess.reset();
    TsdmAppApi.reset();
  });

  group('moderator panel', () {
    testWidgets('a moderator without the rewards nor the admin actions: two groups, the others not shown', (
      tester,
    ) async {
      final answers = _Answers();
      await _pump(tester, answers);
      answers.menu.complete(['home', 'announcement']);
      answers.staff.complete((grant: false, issue: false));
      answers.panel.complete((background: false, modcpReport: false));
      answers.admin.complete(null);
      answers.batchRate.complete(null);
      answers.pages.complete(const {});
      await tester.pumpAndSettle();
      _expectGroups(tester, ['moderation', 'members']);
      expect(_tiles(), [
        'modcp-queue',
        'modcp-recycle-bin',
        'modcp-log',
        'modcp-member-review',
        'modcp-announcements',
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the rewards without the admin actions: the site group not shown', (tester) async {
      final answers = _Answers();
      await _pump(tester, answers);
      answers.menu.complete(['home']);
      answers.staff.complete((grant: false, issue: true));
      answers.panel.complete(null);
      answers.admin.complete(null);
      answers.batchRate.complete(null);
      answers.pages.complete(null);
      await tester.pumpAndSettle();
      _expectGroups(tester, ['moderation', 'members', 'rewards']);
      expect(find.byKey(const ValueKey('modcp-title-issue')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the answers one after another: each tile in its group from the start, the groups as they fill', (
      tester,
    ) async {
      final answers = _Answers();
      await _pump(tester, answers);
      // Nothing answered yet: the pages every moderator has.
      _expectGroups(tester, ['moderation', 'members']);
      expect(_tiles(), ['modcp-queue', 'modcp-recycle-bin', 'modcp-log', 'modcp-member-review']);

      Future<void> step(void Function() answer, List<String> groups) async {
        final before = _tiles();
        answer();
        await tester.pumpAndSettle();
        _expectGroups(tester, groups);
        expect(_tiles(), containsAll(before), reason: 'a tile shown stays');
      }

      // The panel's report and the backgrounds: the reports with the moderation, the rewards group comes.
      await step(
        () => answers.panel.complete((background: true, modcpReport: true)),
        ['moderation', 'members', 'rewards'],
      );
      expect(find.byKey(const ValueKey('modcp-report')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-background-grant')), findsOneWidget);

      // The admin actions: the reports of the whole forum in the same place, the site group comes last.
      await step(
        () => answers.admin.complete(AdminAccess.fromJson(adminFixture('admin_founder'))),
        ['moderation', 'members', 'rewards', 'site'],
      );
      expect(find.byKey(const ValueKey('modcp-report')), findsOneWidget);
      for (final tile in ['modcp-admin-credit', 'modcp-admin-group', 'modcp-admin-ban']) {
        expect(find.byKey(ValueKey(tile)), findsOneWidget, reason: tile);
      }

      // The medals: before the backgrounds in the rewards.
      await step(
        () => answers.staff.complete((grant: true, issue: false)),
        ['moderation', 'members', 'rewards', 'site'],
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('modcp-medal-grant'))).dx,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('modcp-background-grant'))).dx),
      );

      // The menu, the pages answered as fields, the batch rates.
      await step(() => answers.menu.complete(['home', 'announcement']), ['moderation', 'members', 'rewards', 'site']);
      expect(find.byKey(const ValueKey('modcp-announcements')), findsOneWidget);
      await step(() => answers.pages.complete({'thread'}), ['moderation', 'members', 'rewards', 'site']);
      expect(find.byKey(const ValueKey('modcp-threads')), findsOneWidget);
      await step(
        () => answers.batchRate.complete(BatchRateInfo.fromJson(_batchRateFixture('batchrate_info_nofid'))),
        ['moderation', 'members', 'rewards', 'site'],
      );
      expect(find.byKey(const ValueKey('modcp-batch-rate')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow and a wide window: the groups render without overflow', (tester) async {
      for (final size in [const Size(320, 2400), const Size(1280, 2400)]) {
        final answers = _Answers();
        await _pump(tester, answers, size: size);
        answers.menu.complete(['home', 'announcement']);
        answers.staff.complete((grant: true, issue: true));
        answers.panel.complete((background: true, modcpReport: true));
        answers.admin.complete(AdminAccess.fromJson(adminFixture('admin_founder')));
        answers.batchRate.complete(null);
        answers.pages.complete({'thread'});
        await tester.pumpAndSettle();
        _expectGroups(tester, ['moderation', 'members', 'rewards', 'site']);
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('overflow menu sections', () {
    // The actions of another member's profile: social 0, tools 1, admin 2.
    List<OverflowAction> actions() => [
      OverflowAction(
        icon: Icons.article_outlined,
        label: 'threads',
        section: 1,
        placement: OverflowPlacement.pinned,
        onPressed: () {},
      ),
      OverflowAction(icon: Icons.search, label: 'search', section: 1, onPressed: () {}),
      OverflowAction(icon: Icons.qr_code, label: 'qr', section: 1, onPressed: () {}),
      OverflowAction(icon: Icons.person_add, label: 'friend', section: 0, onPressed: () {}),
      OverflowAction(
        icon: Icons.email,
        label: 'pm',
        section: 0,
        placement: OverflowPlacement.pinned,
        onPressed: () {},
      ),
      OverflowAction(icon: Icons.block, label: 'block', section: 1, onPressed: () {}),
      OverflowAction(
        icon: Icons.admin_panel_settings,
        label: 'admin',
        section: 2,
        placement: OverflowPlacement.menuOnly,
        onPressed: () {},
      ),
      OverflowAction(
        icon: Icons.waving_hand,
        label: 'poke',
        section: 0,
        placement: OverflowPlacement.menuOnly,
        onPressed: () {},
      ),
      OverflowAction(
        icon: Icons.person_add_alt,
        label: 'follow',
        section: 0,
        placement: OverflowPlacement.menuOnly,
        onPressed: () {},
      ),
    ];

    Future<void> open(WidgetTester tester, double width, List<OverflowAction> actions) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [OverflowActions(actions: actions)]),
            body: const SizedBox(),
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<OverflowAction>));
      await tester.pumpAndSettle();
    }

    /// The labels of the menu top down, a divider as `-`.
    List<String> menu(WidgetTester tester) {
      final widgets =
          find.byWidgetPredicate((w) => w is PopupMenuItem<OverflowAction> || w is PopupMenuDivider).evaluate().toList()
            ..sort(
              (a, b) => (a.renderObject! as RenderBox)
                  .localToGlobal(Offset.zero)
                  .dy
                  .compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dy),
            );
      return [
        for (final e in widgets)
          switch (e.widget) {
            PopupMenuItem<OverflowAction>(:final value?) => value.label,
            _ => '-',
          },
      ];
    }

    testWidgets('narrow: social, tools, admin, apart by dividers', (tester) async {
      await open(tester, 360, actions());
      expect(menu(tester), ['friend', 'poke', 'follow', '-', 'search', 'qr', 'block', '-', 'admin']);
    });

    testWidgets('wide: only the dividers between the sections left in the menu', (tester) async {
      await open(tester, 800, actions());
      expect(menu(tester), ['poke', 'follow', '-', 'admin']);
      // The buttons of the bar keep the order given.
      final labels = {for (final a in actions()) a.label};
      final tooltips = [
        for (final button in tester.widgetList<IconButton>(find.byType(IconButton)))
          if (labels.contains(button.tooltip)) button.tooltip,
      ];
      expect(tooltips, ['threads', 'search', 'qr', 'friend', 'pm', 'block']);
    });

    testWidgets('a menu without sections: no divider', (tester) async {
      await open(tester, 360, [
        for (final label in ['a', 'b', 'c'])
          OverflowAction(icon: Icons.circle, label: label, placement: OverflowPlacement.menuOnly, onPressed: () {}),
      ]);
      expect(menu(tester), ['a', 'b', 'c']);
    });
  });

  group('admin sheet', () {
    Future<void> open(WidgetTester tester, StaffTools can, {bool background = false, AdminAccess? admin}) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showMemberAdminSheet(context, uid: 4512, can: can, background: background, admin: admin),
                child: const Text('open'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final sheet = find.byType(BottomSheet);

    testWidgets('the rewards and the admin actions apart by a divider', (tester) async {
      await open(
        tester,
        (grant: true, issue: true),
        background: true,
        admin: AdminAccess.fromJson(adminFixture('admin_founder')),
      );
      expect(find.descendant(of: sheet, matching: find.byType(Divider)), findsOneWidget);
      final divider = tester.getTopLeft(find.descendant(of: sheet, matching: find.byType(Divider))).dy;
      for (final key in ['member-admin-medal-grant', 'member-admin-title-issue', 'member-admin-background-grant']) {
        expect(tester.getTopLeft(find.byKey(ValueKey(key))).dy, lessThan(divider), reason: key);
      }
      for (final key in ['member-admin-credit', 'member-admin-group', 'member-admin-ban']) {
        expect(tester.getTopLeft(find.byKey(ValueKey(key))).dy, greaterThan(divider), reason: key);
      }
    });

    testWidgets('one section only: no divider', (tester) async {
      await open(tester, (grant: true, issue: true), background: true);
      expect(find.byKey(const ValueKey('member-admin-medal-grant')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.byType(Divider)), findsNothing);
    });
  });
}
