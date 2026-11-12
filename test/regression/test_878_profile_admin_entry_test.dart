/// The admin entry of a member's profile: an account of a management group sees "Manage" in the menu of another
/// member's profile, which lists sending medals and issuing titles (as the forum allows the account) and opens them
/// with the member's UID filled in. Ordinary members send no request for it; the answers are kept per account.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/utils/staff_access.dart';
import 'package:tsdm_client/features/medal_title_tools/view/medal_grant_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/title_issue_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/profile/widgets/member_admin_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

Map<String, dynamic> _form(String plugin, String action) => {
  'url': 'plugin.php?id=$plugin&action=$action',
  'fields': {'formhash': 'abcd1234'},
};

Map<String, dynamic> _grant(int can) => {
  'ok': 1,
  'installed': 1,
  'uid': 79,
  'can_grant': can,
  'supported': 1,
  'limits': {'users': 200, 'medals': 50, 'pairs': 1000, 'reason': 100},
  'medals': <Object>[],
  'records': {'page': 1, 'pages': 1, 'total': 0, 'batches': <Object>[]},
  'grant_form': _form('dsu_medalCenter:memcp', 'grantgrid'),
};

Map<String, dynamic> _issue(int can) => {
  'ok': 1,
  'installed': 1,
  'uid': 79,
  'can_issue': can,
  'supported': 1,
  'limits': {'users': 200, 'titles': 30, 'days': 36500, 'note': 80},
  'titles': <Object>[],
  'logs': <Object>[],
  'issue_form': _form('tsdmtitle:tsdmtitle', 'issue'),
};

/// A repository answering [grant] and [issue] (null: the forum can not answer) and counting the asks.
MedalTitleToolsRepository _repo({int grant = 1, int issue = 1, List<String>? asked, bool fail = false}) =>
    MedalTitleToolsRepository(
      ask: (action, _) async {
        asked?.add(action);
        if (fail) throw Exception('offline');
        return switch (action) {
          'medalgrant' => _grant(grant),
          'titleissue' => _issue(issue),
          _ => null,
        };
      },
      getJson: (_) async => null,
      post: (_, _) async => '',
    );

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(TranslationProvider(child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
}

String _membersText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller?.text ?? '';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    StaffToolsAccess.reset();
    ManagementGroupCache.reset();
  });

  group('access', () {
    test('asked once per account, shared while on its way, kept', () async {
      final asked = <String>[];
      final repo = _repo(issue: 0, asked: asked);
      final both = await Future.wait([
        StaffToolsAccess.check(35, repository: repo),
        StaffToolsAccess.check(35, repository: repo),
      ]);
      expect(both, everyElement((grant: true, issue: false)));
      expect(asked, ['medalgrant', 'titleissue']);
      await StaffToolsAccess.check(35, repository: repo);
      expect(asked.length, 2);
      expect(StaffToolsAccess.cached(35), (grant: true, issue: false));
      // Another account is asked on its own.
      expect(await StaffToolsAccess.check(36, repository: _repo(grant: 0, issue: 0, asked: asked)), (
        grant: false,
        issue: false,
      ));
      expect(asked.length, 4);
      expect(StaffToolsAccess.cached(35), (grant: true, issue: false));
    });

    test('a failed ask is not kept', () async {
      expect(await StaffToolsAccess.check(35, repository: _repo(fail: true)), isNull);
      expect(StaffToolsAccess.cached(35), isNull);
      expect(await StaffToolsAccess.check(35, repository: _repo()), (grant: true, issue: true));
    });

    test('an ordinary member sends no request for the tools', () async {
      final asked = <String>[];
      var read = 0;
      Future<bool?> notManager() async {
        read++;
        return false;
      }

      expect(
        await memberAdminToolsOf(
          35,
          isManager: notManager,
          repository: _repo(asked: asked),
        ),
        isNull,
      );
      expect(
        await memberAdminToolsOf(
          35,
          isManager: notManager,
          repository: _repo(asked: asked),
        ),
        isNull,
      );
      expect(asked, isEmpty);
      expect(read, 1);
      // A profile that could not be read is asked again, and sends nothing meanwhile.
      expect(
        await memberAdminToolsOf(
          36,
          isManager: () async => null,
          repository: _repo(asked: asked),
        ),
        isNull,
      );
      expect(ManagementGroupCache.cached(36), isNull);
      expect(asked, isEmpty);
    });

    test('a management group account is asked once, and each account on its own', () async {
      final asked = <String>[];
      Future<bool?> manager() async => true;
      expect(
        await memberAdminToolsOf(
          79,
          isManager: manager,
          repository: _repo(asked: asked),
        ),
        (
          grant: true,
          issue: true,
        ),
      );
      await memberAdminToolsOf(
        79,
        isManager: manager,
        repository: _repo(asked: asked),
      );
      expect(asked, ['medalgrant', 'titleissue']);
      expect(
        await memberAdminToolsOf(
          35,
          isManager: () async => false,
          repository: _repo(asked: asked),
        ),
        isNull,
      );
      expect(asked.length, 2);
    });
  });

  group('menu', () {
    testWidgets('lists what the account may do, in order', (tester) async {
      late BuildContext ctx;
      await _pump(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      );
      expect(memberAdminItems(ctx, (grant: true, issue: true)).map((e) => e.path), [
        ScreenPaths.medalGrant,
        ScreenPaths.titleIssue,
      ]);
      expect(memberAdminItems(ctx, (grant: false, issue: true)).map((e) => e.path), [ScreenPaths.titleIssue]);
      expect(memberAdminItems(ctx, (grant: false, issue: false)), isEmpty);
    });

    testWidgets('a pick opens the page with the member filled in; the medal centre way stays empty', (tester) async {
      final grantRepo = _repo();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => showMemberAdminSheet(context, uid: 4512, can: (grant: true, issue: true)),
                child: const Text('open'),
              ),
            ),
          ),
          GoRoute(
            path: '/medalGrant',
            name: ScreenPaths.medalGrant,
            builder: (_, s) => MedalGrantPage(repository: grantRepo, initialMembers: s.uri.queryParameters['uid']),
          ),
          GoRoute(
            path: '/titleIssue',
            name: ScreenPaths.titleIssue,
            builder: (_, s) => TitleIssuePage(repository: _repo(), initialMembers: s.uri.queryParameters['uid']),
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
      expect(find.byKey(const ValueKey('member-admin-medal-grant')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('member-admin-medal-grant')));
      await tester.pumpAndSettle();
      expect(find.byType(MedalGrantPage), findsOneWidget);
      expect(_membersText(tester), '4512');
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('member-admin-title-issue')));
      await tester.pumpAndSettle();
      expect(find.byType(TitleIssuePage), findsOneWidget);
      expect(_membersText(tester), '4512');

      await _pump(tester, TitleIssuePage(key: UniqueKey(), repository: _repo()));
      expect(_membersText(tester), '');
      await _pump(tester, MedalGrantPage(key: UniqueKey(), repository: _repo()));
      expect(_membersText(tester), '');
    });
  });

  group('moderator panel', () {
    testWidgets('lists the two tools the account may use', (tester) async {
      await _pump(tester, ModeratorPanelPage(staffTools: () async => (grant: true, issue: true)));
      expect(find.byKey(const ValueKey('modcp-medal-grant')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-title-issue')), findsOneWidget);

      await _pump(tester, ModeratorPanelPage(key: UniqueKey(), staffTools: () async => (grant: false, issue: true)));
      expect(find.byKey(const ValueKey('modcp-medal-grant')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-title-issue')), findsOneWidget);
    });

    testWidgets('lists none when the forum can not tell, or without an account', (tester) async {
      await _pump(tester, ModeratorPanelPage(staffTools: () async => null));
      expect(find.byKey(const ValueKey('modcp-medal-grant')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-title-issue')), findsNothing);
      await _pump(tester, ModeratorPanelPage(key: UniqueKey()));
      expect(find.byKey(const ValueKey('modcp-medal-grant')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
