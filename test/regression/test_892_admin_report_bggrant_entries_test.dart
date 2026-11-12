/// The entries of sending backgrounds and handling reports (tsdmapp 3.9.0): a tile each on the moderator's panel only
/// when the forum offers it (`status.modcp_report`, `bggrant`'s `can_grant`), and sending backgrounds in the admin
/// menu of a member's profile, opened with the member's UID filled in; an ordinary member asks nothing for them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/background_grant/repository/background_grant_repository.dart';
import 'package:tsdm_client/features/background_grant/view/background_grant_page.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/profile/widgets/member_admin_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

BackgroundGrantRepository _repo() => BackgroundGrantRepository(
  ask: (_) async {
    final json = jsonDecode(File('test/data/tsdmapp_390/bggrant_can.json').readAsStringSync()) as Map<String, dynamic>;
    return {...json, 'backgrounds': <Object>[]};
  },
  post: (_, _) async => null,
  currentUid: () => 31,
);

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(TranslationProvider(child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    PanelToolsAccess.reset();
    ManagementGroupCache.reset();
  });

  group('moderator panel', () {
    const report = ValueKey('modcp-report');
    const background = ValueKey('modcp-background-grant');

    testWidgets('a tile each only when the forum offers it', (tester) async {
      await _pump(
        tester,
        ModeratorPanelPage(
          staffTools: () async => (grant: false, issue: false),
          panelTools: () async => (background: true, modcpReport: true),
        ),
      );
      expect(find.byKey(report), findsOneWidget);
      expect(find.byKey(background), findsOneWidget);

      await _pump(
        tester,
        ModeratorPanelPage(
          key: UniqueKey(),
          staffTools: () async => (grant: true, issue: true),
          panelTools: () async => (background: false, modcpReport: true),
        ),
      );
      expect(find.byKey(report), findsOneWidget);
      expect(find.byKey(background), findsNothing);

      await _pump(
        tester,
        ModeratorPanelPage(
          key: UniqueKey(),
          staffTools: () async => null,
          panelTools: () async => (background: true, modcpReport: false),
        ),
      );
      expect(find.byKey(report), findsNothing);
      expect(find.byKey(background), findsOneWidget);
    });

    testWidgets('none when the forum can not tell, or without an account', (tester) async {
      await _pump(tester, ModeratorPanelPage(panelTools: () async => null));
      expect(find.byKey(report), findsNothing);
      expect(find.byKey(background), findsNothing);
      await _pump(tester, ModeratorPanelPage(key: UniqueKey()));
      expect(find.byKey(report), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('profile', () {
    test('asked only for an account of a management group', () async {
      var asked = 0;
      Future<PanelTools?> check() async {
        asked++;
        return (background: true, modcpReport: true);
      }

      expect(await memberBackgroundGrantOf(31, isManager: () async => false, check: check), isFalse);
      expect(await memberBackgroundGrantOf(32, isManager: () async => null, check: check), isFalse);
      expect(asked, 0);
      expect(await memberBackgroundGrantOf(33, isManager: () async => true, check: check), isTrue);
      expect(asked, 1);
      expect(
        await memberBackgroundGrantOf(34, isManager: () async => true, check: () async => null),
        isFalse,
      );
    });

    testWidgets('listed after the medal and title tools, alone when only it is allowed', (tester) async {
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
      expect(memberAdminItems(ctx, (grant: true, issue: true), background: true).map((e) => e.path), [
        ScreenPaths.medalGrant,
        ScreenPaths.titleIssue,
        ScreenPaths.backgroundGrant,
      ]);
      expect(memberAdminItems(ctx, (grant: false, issue: false), background: true).map((e) => e.path), [
        ScreenPaths.backgroundGrant,
      ]);
      expect(memberAdminItems(ctx, (grant: true, issue: false)).map((e) => e.path), [ScreenPaths.medalGrant]);
    });

    testWidgets('the pick opens the page with the member filled in', (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showMemberAdminSheet(context, uid: 4512, can: (grant: false, issue: false), background: true),
                child: const Text('open'),
              ),
            ),
          ),
          GoRoute(
            path: '/backgroundGrant',
            name: ScreenPaths.backgroundGrant,
            builder: (_, s) => BackgroundGrantPage(repository: _repo(), initialMembers: s.uri.queryParameters['uid']),
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
      await tester.tap(find.byKey(const ValueKey('member-admin-background-grant')));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundGrantPage), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('bggrant-members'))).controller!.text, '4512');
    });
  });
}
