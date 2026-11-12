/// The entry of the forum's admin actions (plugin 3.9.0, spec §0, §1, §8): `status.admin` switches them on,
/// `action=admin` tells whether the account may use them and which; the answer is kept per account (a failed one is
/// not), an ordinary member sends no request for it, and the moderator panel and the "Manage" menu of a member's
/// profile list only the actions the account may read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/profile/widgets/member_admin_sheet.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

import 'admin_tools_fakes.dart';

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
    AdminAccessCache.reset();
    ManagementGroupCache.reset();
    TsdmAppApi.reset();
  });

  group('status.admin', () {
    test('a 3.9.0 status names the switch either way; an older one or another action does not', () {
      expect(
        TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': '3.9.0', 'actions': <Object>[], 'admin': 1})!.admin,
        isTrue,
      );
      expect(
        TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': '3.9.0', 'actions': <Object>[], 'admin': 0})!.admin,
        isFalse,
      );
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': '3.8.0', 'actions': <Object>[]})!.admin, isNull);
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': '3.9.0'})!.admin, isNull);
      expect(TsdmAppApi.knowsAdmin, isNull);
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.9.0', api: 1, nodoc: true, admin: true);
      expect(TsdmAppApi.knowsAdmin, isTrue);
      expect(expectedTsdmAppVersion, '3.9.0');
    });
  });

  group('action=admin', () {
    test('the answers of the test forum: founder, a restricted admin, read-only, no admin centre, not an admin', () {
      final founder = AdminAccess.fromJson(adminFixture('admin_founder'))!;
      expect(founder.enabled && founder.eligible && founder.founder, isTrue);
      expect(founder.memberActions, [AdminActions.credit, AdminActions.group, AdminActions.ban]);
      expect(founder.canWrite(AdminActions.ban), isTrue);

      final manager = AdminAccess.fromJson(adminFixture('admin_member_manager'))!;
      expect(manager.founder, isFalse);
      expect(manager.memberActions, [AdminActions.credit, AdminActions.group, AdminActions.ban]);
      expect(manager.canRead(AdminActions.report), isFalse);

      final readOnly = AdminAccess.fromJson(adminFixture('admin_read_only'))!;
      expect(readOnly.memberActions, isEmpty);
      expect(readOnly.canRead(AdminActions.report), isTrue);
      expect(readOnly.canWrite(AdminActions.report), isFalse, reason: 'read 1, write 0: no submit button');

      final cp = AdminAccess.fromJson(adminFixture('admin_cpaccess'))!;
      expect((cp.enabled, cp.eligible, cp.why), (true, false, 'cpaccess'));
      expect(cp.memberActions, isEmpty);
      final member = AdminAccess.fromJson(adminFixture('admin_adminid'))!;
      expect((member.eligible, member.why), (false, 'adminid'));

      // Switched off: no other field.
      final off = AdminAccess.fromJson({'ok': 1, 'type': 'admin', 'schema': 25, 'enabled': 0})!;
      expect(off.memberActions, isEmpty);
      expect(AdminAccess.fromJson(adminFixture('admin_login_needed')), isNull);
      expect(AdminAccess.fromJson(null), isNull);
    });

    test('a write 0 action is listed but not writable', () {
      final json = adminFixture('admin_member_manager');
      (json['actions'] as Map<String, dynamic>)['adminban'] = {'read': 1, 'write': 0, 'perm': 'members_ban'};
      final access = AdminAccess.fromJson(json)!;
      expect(access.canRead(AdminActions.ban), isTrue);
      expect(access.canWrite(AdminActions.ban), isFalse);
    });
  });

  group('kept per account', () {
    test('asked once per account and shared while on its way; another account on its own', () async {
      final forum = FakeAdminForum({
        'admin': [adminFixture('admin_member_manager')],
      });
      var switches = 0;
      Future<bool?> on() async {
        switches++;
        return true;
      }

      final both = await Future.wait([
        AdminAccessCache.check(96, repository: forum.repository(), switchOn: on),
        AdminAccessCache.check(96, repository: forum.repository(), switchOn: on),
      ]);
      expect(both[0]!.memberActions, hasLength(3));
      expect(identical(both[0], both[1]), isTrue);
      expect(forum.requests, hasLength(1));
      expect(switches, 1);
      await AdminAccessCache.check(96, repository: forum.repository(), switchOn: on);
      expect(forum.requests, hasLength(1));

      final other = FakeAdminForum({
        'admin': [adminFixture('admin_adminid')],
      })..uid = 31;
      final no = await AdminAccessCache.check(31, repository: other.repository(), switchOn: on);
      expect(no!.eligible, isFalse);
      expect(AdminAccessCache.cached(31), no, reason: 'eligible 0 is an answer');
      expect(AdminAccessCache.cached(96)!.memberActions, hasLength(3));
    });

    test('the switch off is kept without asking action=admin; a switch or entry not told is not kept', () async {
      final forum = FakeAdminForum({
        'admin': [adminFixture('admin_founder')],
      })..uid = 32;
      expect(
        await AdminAccessCache.check(32, repository: forum.repository(), switchOn: () async => false),
        AdminAccess.off,
      );
      expect(forum.requests, isEmpty);
      AdminAccessCache.reset();

      expect(await AdminAccessCache.check(32, repository: forum.repository(), switchOn: () async => null), isNull);
      expect(AdminAccessCache.cached(32), isNull);
      expect(forum.requests, isEmpty);

      final failing = FakeAdminForum()..uid = 32;
      expect(await AdminAccessCache.check(32, repository: failing.repository(), switchOn: () async => true), isNull);
      expect(AdminAccessCache.cached(32), isNull);

      expect(
        await AdminAccessCache.check(
          32,
          repository: forum.repository(),
          switchOn: () async => true,
          stillCurrent: () => false,
        ),
        isNull,
      );
      expect(AdminAccessCache.cached(32), isNull, reason: 'another account by then');
      expect(
        (await AdminAccessCache.check(32, repository: forum.repository(), switchOn: () async => true))!.founder,
        isTrue,
      );
    });

    test('admin_off and admin_noperm of an action forget the kept answer', () async {
      final forum = FakeAdminForum({
        'admin': [adminFixture('admin_member_manager')],
        'admincredit': [
          adminError('admin_off'),
          adminError('admin_noperm', {'why': 'perm', 'perm': 'members_reward'}),
        ],
      });
      await AdminAccessCache.check(96, repository: forum.repository(), switchOn: () async => true);
      expect(AdminAccessCache.cached(96), isNotNull);
      await forum.repository().request(AdminActions.credit);
      expect(AdminAccessCache.cached(96), isNull);
      await AdminAccessCache.check(96, repository: forum.repository(), switchOn: () async => true);
      await forum.repository().request(AdminActions.credit);
      expect(AdminAccessCache.cached(96), isNotNull, reason: 'a missing permission of one action is that action only');
    });
  });

  group('profile entry', () {
    test('an ordinary member sends no request; a manager asks once', () async {
      final forum = FakeAdminForum({
        'admin': [adminFixture('admin_member_manager')],
      })..uid = 35;
      var profiles = 0;
      Future<bool?> notManager() async {
        profiles++;
        return false;
      }

      expect(
        await memberAdminAccessOf(
          35,
          isManager: notManager,
          repository: forum.repository(),
          switchOn: () async => true,
        ),
        isNull,
      );
      expect(
        await memberAdminAccessOf(
          35,
          isManager: notManager,
          repository: forum.repository(),
          switchOn: () async => true,
        ),
        isNull,
      );
      expect(forum.requests, isEmpty);
      expect(profiles, 1, reason: 'the management group is kept');

      forum.uid = 96;
      final access = await memberAdminAccessOf(
        96,
        isManager: () async => true,
        repository: forum.repository(),
        switchOn: () async => true,
      );
      expect(access!.memberActions, hasLength(3));
      expect(forum.requests, hasLength(1));
    });

    test('nothing to offer on a member gives null (read-only, not eligible, switched off)', () async {
      for (final (name, on) in [('admin_read_only', true), ('admin_cpaccess', true), ('admin_founder', false)]) {
        AdminAccessCache.reset();
        final forum = FakeAdminForum({
          'admin': [adminFixture(name)],
        });
        expect(
          await memberAdminAccessOf(
            96,
            isManager: () async => true,
            repository: forum.repository(),
            switchOn: () async => on,
          ),
          isNull,
          reason: name,
        );
      }
    });

    testWidgets('the menu lists the three with the medal tools, by read permission', (tester) async {
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
      final founder = AdminAccess.fromJson(adminFixture('admin_founder'));
      expect(memberAdminItems(ctx, (grant: true, issue: false), admin: founder).map((e) => e.path), [
        ScreenPaths.medalGrant,
        ScreenPaths.adminCredit,
        ScreenPaths.adminGroup,
        ScreenPaths.adminBan,
      ]);
      final json = adminFixture('admin_member_manager');
      (json['actions'] as Map<String, dynamic>)['admingroup'] = {'read': 0, 'write': 0};
      expect(
        memberAdminItems(ctx, (grant: false, issue: false), admin: AdminAccess.fromJson(json)).map((e) => e.path),
        [
          ScreenPaths.adminCredit,
          ScreenPaths.adminBan,
        ],
      );
      expect(memberAdminItems(ctx, (grant: false, issue: false), admin: AdminAccess.off), isEmpty);
      expect(memberAdminItems(ctx, (grant: false, issue: true)).map((e) => e.path), [ScreenPaths.titleIssue]);
    });
  });

  group('moderator panel', () {
    testWidgets('lists the admin actions the account may read, and holds the session while open', (tester) async {
      final forum = FakeAdminForum();
      final repo = forum.repository();
      await _pump(
        tester,
        ModeratorPanelPage(
          staffTools: () async => null,
          adminAccess: () async => AdminAccess.fromJson(adminFixture('admin_founder')),
          adminRepository: repo,
        ),
      );
      expect(find.byKey(const ValueKey('modcp-admin-credit')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-admin-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-admin-ban')), findsOneWidget);
      expect(forum.session.leases, 1);
      await tester.pumpWidget(const SizedBox());
      expect(forum.session.leases, 0);
      expect(forum.requests, isEmpty, reason: 'no token kept: nothing to log out');
    });

    testWidgets('lists none for a read-only admin, a refused account or no answer', (tester) async {
      for (final access in [
        AdminAccess.fromJson(adminFixture('admin_read_only')),
        AdminAccess.fromJson(adminFixture('admin_adminid')),
        AdminAccess.off,
        null,
      ]) {
        final forum = FakeAdminForum();
        await _pump(
          tester,
          ModeratorPanelPage(
            key: UniqueKey(),
            staffTools: () async => null,
            adminAccess: () async => access,
            adminRepository: forum.repository(),
          ),
        );
        expect(find.byKey(const ValueKey('modcp-admin-credit')), findsNothing);
        expect(find.byKey(const ValueKey('modcp-admin-ban')), findsNothing);
        expect(forum.session.leases, 0);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
