/// The admin token's life in the app (tsdmapp 3.9.0 §1, §2): kept as long as the forum's last answer says (`session`
/// `expires` as of the answer's `time`), not ended when an admin page is left, so a second action on the same member
/// from the profile asks the password once; ended (logged out with it, dropped first) when the app lock locks, when the
/// app comes back after five minutes or more in the background, by hand on the pages and the panel, and before the
/// account in use changes, while the forum still takes it as that account's.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_group_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import 'admin_tools_fakes.dart';

const _token = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: home),
    ),
  );
  await tester.pumpAndSettle();
}

/// An answer of the forum at [time] saying the token holds until [expires].
Map<String, dynamic> _active({int time = 1700000000, int expires = 1700000900}) => {
  'ok': 1,
  'uid': 96,
  'time': time,
  'formhash': 'f1f2f3f4',
  'session': {'active': 1, 'expires': expires, 'ttl': 900, 'max': 7200, 'checkip': 1},
};

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('expiry', () {
    test("kept until the forum's expiry (less the margin), counted from the answer's time", () {
      var now = DateTime(2026, 11, 13, 10);
      final session = AdminSession(clock: () => now)
        ..keep(96, _token)
        ..noteAnswer(_token, _active(expires: 1700000000 + 600));
      now = now.add(const Duration(seconds: 569));
      expect(session.holds(96), isTrue);
      expect(session.tokenFor(96), _token);
      now = now.add(const Duration(seconds: 1));
      expect(session.holds(96), isFalse, reason: '600 s less the 30 s margin');
      expect(session.tokenFor(96), isNull);
    });

    test('each answer moves it on; an answer of another token or without session changes nothing', () {
      var now = DateTime(2026, 11, 13, 10);
      final session = AdminSession(clock: () => now)
        ..keep(96, _token)
        ..noteAnswer(_token, _active());
      now = now.add(const Duration(minutes: 10));
      session
        ..noteAnswer(_token, _active(time: 1700000600, expires: 1700001500))
        ..noteAnswer('other-token', _active(expires: 1700000001))
        ..noteAnswer(_token, {'ok': 1, 'uid': 96});
      now = now.add(const Duration(minutes: 14));
      expect(session.holds(96), isTrue);
      now = now.add(const Duration(seconds: 31));
      expect(session.holds(96), isFalse);
    });

    test('without the time, the idle time told counts', () {
      var now = DateTime(2026, 11, 13, 10);
      final session = AdminSession(clock: () => now)
        ..keep(96, _token)
        ..noteAnswer(_token, {
          'session': {'active': 1, 'expires': 0, 'ttl': 300},
        });
      now = now.add(const Duration(seconds: 269));
      expect(session.holds(96), isTrue);
      now = now.add(const Duration(seconds: 1));
      expect(session.holds(96), isFalse);
    });

    test("the login's answer and every answer to the token kept set it", () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [adminLoginOk()],
        'GET:admincredit': [adminFixture('credit_members')],
      });
      final repo = forum.repository();
      await repo.login(password: 'x');
      expect(forum.session.holds(96), isTrue);
      final reply = await repo.request(AdminActions.credit, query: const {'uids': '101'});
      expect(reply.ok, isTrue);
      expect(forum.of('admincredit').single.headers[adminTokenHeader], _token);
      expect(forum.session.holds(96), isTrue);
    });
  });

  group('pages', () {
    testWidgets('leaving an admin page sends nothing: the next one uses the same token', (tester) async {
      final forum = FakeAdminForum({
        'GET:admincredit': [adminFixture('credit_members')],
        'GET:admingroup': [adminFixture('group_member')],
      });
      forum.session.keep(96, _token);
      await _pump(tester, AdminCreditPage(repository: forum.repository(), initialMembers: '101', writable: true));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(forum.of('admin', 'POST'), isEmpty, reason: 'no logout');
      expect(forum.session.holds(96), isTrue);

      await _pump(
        tester,
        AdminGroupPage(key: UniqueKey(), repository: forum.repository(), initialMember: '101', writable: true),
      );
      expect(forum.of('admingroup').single.headers[adminTokenHeader], _token);
      expect(find.byType(AlertDialog), findsNothing, reason: 'no password asked again');
    });

    testWidgets('logged out by hand on a page: the button shown only while a token is kept', (tester) async {
      final forum = FakeAdminForum({
        'GET:admincredit': [adminFixture('credit_members')],
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [
          {'ok': 1, 'type': 'admin', 'op': 'logout', 'uid': 96},
        ],
      });
      await _pump(tester, AdminCreditPage(repository: forum.repository(), initialMembers: '101', writable: true));
      expect(find.byKey(const ValueKey('admin-logout')), findsNothing);

      forum.session.keep(96, _token);
      await tester.pump();
      expect(find.byTooltip(t.adminTools.logout), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('admin-logout')));
      await tester.pumpAndSettle();
      final logout = forum.of('admin', 'POST').single;
      expect(logout.data['op'], 'logout');
      expect(logout.headers[adminTokenHeader], _token);
      expect(forum.session.holds(96), isFalse);
      expect(find.byKey(const ValueKey('admin-logout')), findsNothing);
    });

    testWidgets('the panel offers it too, and leaving the panel sends nothing', (tester) async {
      final forum = FakeAdminForum();
      forum.session.keep(96, _token);
      await _pump(
        tester,
        ModeratorPanelPage(
          staffTools: () async => null,
          adminAccess: () async => AdminAccess.fromJson(adminFixture('admin_founder')),
          adminRepository: forum.repository(),
        ),
      );
      expect(find.byKey(const ValueKey('admin-logout')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(forum.requests, isEmpty);
      expect(forum.session.holds(96), isTrue);
    });
  });

  group('ended', () {
    test('when the app lock locks', () async {
      var logouts = 0;
      final guard = AdminSessionGuard(logout: () async => logouts++);
      final lock = StreamController<bool>();
      guard.watchLock(lock.stream);
      lock.add(false);
      await pumpEventQueue();
      expect(logouts, 0);
      lock.add(true);
      await pumpEventQueue();
      expect(logouts, 1);
      await guard.dispose();
      await lock.close();
    });

    test('when the app comes back after five minutes or more in the background, not sooner', () {
      var now = DateTime(2026, 11, 13, 10);
      var logouts = 0;
      final guard = AdminSessionGuard(logout: () async => logouts++, clock: () => now)
        ..onLifecycle(AppLifecycleState.inactive)
        ..onLifecycle(AppLifecycleState.hidden)
        ..onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      guard.onLifecycle(AppLifecycleState.resumed);
      expect(logouts, 0);

      // Counted from when it went: hidden then paused is one stay.
      guard.onLifecycle(AppLifecycleState.hidden);
      now = now.add(const Duration(minutes: 3));
      guard.onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 2));
      guard.onLifecycle(AppLifecycleState.resumed);
      expect(logouts, 1);

      // A switch through the app switcher only (inactive) does not count.
      guard.onLifecycle(AppLifecycleState.inactive);
      now = now.add(const Duration(minutes: 10));
      guard.onLifecycle(AppLifecycleState.resumed);
      expect(logouts, 1);
    });

    test('before the account changes: sent as the account the token belongs to, never waited for long', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [
          {'ok': 1, 'type': 'admin', 'op': 'logout', 'uid': 96},
        ],
      });
      // Nothing kept: nothing sent.
      await AdminRepository.logoutBeforeIdentityChange(repository: forum.repository());
      expect(forum.requests, isEmpty);

      // The forum's session gone: only forgotten.
      forum.session.keep(96, _token);
      await AdminRepository.logoutBeforeIdentityChange(canSend: false, repository: forum.repository());
      expect(forum.requests, isEmpty);
      expect(forum.session.holds(96), isFalse);

      forum.session.keep(96, _token);
      await AdminRepository.logoutBeforeIdentityChange(repository: forum.repository());
      expect(forum.of('admin', 'POST').single.headers[adminTokenHeader], _token);
      expect(forum.session.holds(96), isFalse);

      // A forum that does not answer: dropped all the same, the change goes on.
      final slow = AdminSession()..keep(96, _token);
      final never = Completer<Map<String, dynamic>?>();
      final repo = AdminRepository(
        get: (_, _, _) async => adminFixture('admin_member_manager'),
        post: (_, _, _) => never.future,
        currentUid: () => 96,
        session: slow,
      );
      await AdminRepository.logoutBeforeIdentityChange(repository: repo, limit: const Duration(milliseconds: 50));
      expect(slow.holds(96), isFalse);
    });

    test('a logout answered busy is sent once more after the wait asked', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [
          adminError('busy', {'retry_after': 3}),
          {'ok': 1, 'type': 'admin', 'op': 'logout', 'uid': 96},
        ],
      });
      forum.session.keep(96, _token);
      await forum.repository().logout();
      final posts = forum.of('admin', 'POST');
      expect(posts, hasLength(2));
      expect(posts.map((r) => r.headers[adminTokenHeader]), [_token, _token]);
      expect(forum.waits.single, const Duration(milliseconds: 3300));
    });
  });
}
