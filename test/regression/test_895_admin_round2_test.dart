/// The admin actions follow the second round of plugin tsdmapp 3.9.0 (spec 3.9.0 §9): the top `uid` of every answer
/// is the account asking (a batch of the clearing names its member `target_uid`); `admin_login` voids only the token
/// the request carried, and a logout answered `admin_login` is a logout; the clearing goes on only where the forum says
/// one is open (`clear_pending`, `post_left`), stops on `clear_start` and `clear_stuck`; UIDs and usernames are
/// separated before they are sent; a credit change past what the forum stores tells who and which credit; `admin_off`
/// is the answer of an account that is no administrator; a request sent right after the second login waits for
/// nothing unless the forum says `busy`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_ban_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
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

Map<String, dynamic> _step(int target, {required bool done, int uid = 96, int remaining = 0, String cursor = ''}) => {
  'ok': 1,
  'type': 'adminban',
  'schema': 30,
  'op': 'clear',
  'uid': uid,
  'target_uid': target,
  'done': done ? 1 : 0,
  'cursor': cursor,
  'remaining': remaining,
  'posts': 2,
  'threads': 0,
};

Future<AdminClearOutcome> _clear(FakeAdminForum forum, {int target = 99}) => runAdminClear(
  forum.repository(),
  target: target,
  cursor: adminClearStart,
  total: 6,
  remaining: 6,
  onStep: (_) {},
  stopped: () => false,
);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(AdminAccessCache.reset);

  group('the account of an answer', () {
    test('a batch of the clearing: the caller on top, the member in target_uid', () async {
      final ok = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [_step(99, done: true)],
      });
      expect((await _clear(ok)).done, isTrue);

      // The member on top (the first round's reading) is another account now: dropped.
      final other = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [_step(99, uid: 99, done: true)],
      });
      final dropped = await _clear(other);
      expect(dropped.done, isFalse);
      expect(dropped.reply!.identityChanged, isTrue);

      // A batch of another member is not this clearing.
      expect(adminClearStepOf(_step(100, done: true), target: 99), isNull);
      expect(adminClearStepOf(_step(99, done: true), target: 99)!.done, isTrue);
    });

    test('admin_login voids only the token the request carried', () async {
      final forum = FakeAdminForum();
      forum.answers['GET:adminban'] = [
        (AdminRequest r) {
          // A login made meanwhile (another page) keeps its own token.
          forum.session.keep(96, 'new-token-0000');
          return adminError('admin_login');
        },
      ];
      forum.session.keep(96, _token);
      final reply = await forum.repository().request(AdminActions.ban, query: const {'uid': '99'});
      expect(reply.error, 'admin_login');
      expect(forum.of('adminban').single.headers, {adminTokenHeader: _token});
      expect(forum.session.tokenFor(96), 'new-token-0000');

      final plain = FakeAdminForum({
        'GET:adminban': [adminError('admin_login')],
      });
      plain.session.keep(96, _token);
      await plain.repository().request(AdminActions.ban, query: const {'uid': '99'});
      expect(plain.session.tokenFor(96), isNull);
    });

    test('a logout answered admin_login (the token was void) is a logout, sent with the token', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [adminFixture('logout_admin_login')],
      });
      forum.session.keep(96, _token);
      await forum.repository().logout();
      final post = forum.of('admin', 'POST').single;
      expect(post.data, {'op': 'logout', 'formhash': 'f1f2f3f4'});
      expect(post.headers, {adminTokenHeader: _token});
      expect(forum.session.tokenFor(96), isNull);
    });

    test('a request sent right after the second login waits for nothing unless busy', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [adminLoginOk()],
        'GET:adminban': [adminError('admin_login'), adminFixture('ban_post_left')],
      });
      final repo = forum.repository();
      final reply = await repo.request(
        AdminActions.ban,
        query: const {'uid': '100'},
        reauth: (_) async => (await repo.login(password: 'x')).ok,
      );
      expect(reply.ok, isTrue);
      expect(forum.of('adminban'), hasLength(2));
      expect(forum.waits, isEmpty);
    });
  });

  group('no entry', () {
    test('an account that is no administrator: switched off, nothing to offer', () async {
      final mid = AdminAccess.fromJson(adminFixture('admin_not_admin'))!;
      expect((mid.enabled, mid.eligible), (false, false));
      expect(mid.memberActions, isEmpty);
      expect(mid.canRead(AdminActions.report), isFalse);

      // An action answering admin_off or admin_noperm (not a permission of one action) forgets the entry.
      for (final error in [
        adminError('admin_off'),
        adminError('admin_noperm', {'why': 'cpaccess'}),
      ]) {
        final forum = FakeAdminForum({
          'admin': [adminFixture('admin_member_manager')],
          'GET:adminreport': [error],
        });
        final access = await AdminAccessCache.check(96, repository: forum.repository(), switchOn: () async => true);
        expect(access!.canRead(AdminActions.ban), isTrue);
        forum.session.keep(96, _token);
        await forum.repository().request(AdminActions.report);
        expect(AdminAccessCache.cached(96), isNull);
        expect(forum.session.tokenFor(96), isNull);
      }
    });
  });

  group('members as typed', () {
    test('UIDs and usernames apart; only digits alone are a UID', () {
      final targets = adminTargetsOf('101、102；103;ag_low2\n12abc，Blue Bird, 101');
      expect(targets.uids, [101, 102, 103]);
      expect(targets.usernames, ['ag_low2', '12abc', 'Blue Bird']);
    });

    testWidgets('a credit change past what the forum stores: who and which credit', (tester) async {
      final members = adminFixture('credit_members')..['missing'] = <String>[];
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:admincredit': [members],
        'POST:admincredit': [
          adminError('credits', {
            'overflow': [
              {'uid': 101, 'id': 2},
            ],
          }),
        ],
      });
      await _pump(tester, AdminCreditPage(repository: forum.repository(), initialMembers: '101', writable: true));
      await tester.enterText(find.byKey(const ValueKey('admin-credit-2')), '99999999');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-credit-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.adminTools.confirm));
      await tester.pumpAndSettle();
      final get = forum.of('admincredit', 'GET').first.data;
      expect(get, {'uids': '101'});
      expect(forum.of('admincredit', 'POST').single.data['uids'], isNot(contains('abc')));
      final told = find.textContaining(t.adminTools.creditOverflow(list: 'member101 '));
      expect(told, findsOneWidget);
    });
  });

  group('the clearing', () {
    test('post_left and clear_pending of the member', () {
      final info = AdminBanInfo.fromJson(adminFixture('ban_post_left'))!;
      expect((info.member.postRows, info.member.postLeft, info.member.clearPending), (233, 233, false));
      final older = AdminBanInfo.fromJson(adminFixture('ban_member'))!;
      expect((older.member.postLeft, older.member.clearPending), (null, false));
    });

    test('clear_start drops the cursor kept and stops; clear_stuck stops with the error', () async {
      final start = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          adminError('clear_start', {'target_uid': 99, 'remaining': 6}),
        ],
      });
      final started = await _clear(start);
      expect(started.done, isFalse);
      expect(started.reply!.error, 'clear_start');
      expect(start.session.clearCursor(96, 99), isNull);
      expect(start.of('adminban', 'POST'), hasLength(1), reason: 'never a ban sent by itself');

      final stuck = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          _step(99, done: false, cursor: '0-10', remaining: 4),
          adminError('clear_stuck', {'target_uid': 99}),
        ],
      });
      final stopped = await _clear(stuck);
      expect(stopped.done, isFalse);
      expect(stopped.reply!.error, 'clear_stuck');
      expect(stuck.of('adminban', 'POST'), hasLength(2));
    });

    testWidgets('open on the forum: offered to go on with its progress, even with nothing kept in the app', (
      tester,
    ) async {
      final pending = adminFixture('ban_post_left');
      (pending['member'] as Map<String, dynamic>)
        ..['banned'] = 'visit'
        ..['post_left'] = 33
        ..['clear_pending'] = 1;
      final done = adminFixture('ban_post_left');
      (done['member'] as Map<String, dynamic>)
        ..['banned'] = 'visit'
        ..['post_left'] = 0;
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:adminban': [pending, done],
        'POST:adminban': [_step(100, done: true)],
      });
      await _pump(tester, AdminBanPage(repository: forum.repository(), initialMember: '100', writable: true));
      expect(find.text(t.adminTools.clearProgress(done: 200, total: 233)), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-ban-clear-posts')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('admin-ban-resume')));
      await tester.pumpAndSettle();
      expect(forum.of('adminban', 'POST').single.data, {
        'op': 'clear',
        'uid': '100',
        'cursor': adminClearStart,
        'formhash': 'f1f2f3f4',
      });
      expect(find.byKey(const ValueKey('admin-ban-resume')), findsNothing);
    });

    testWidgets('not open on the forum: nothing to go on with, a cursor kept from before is dropped', (tester) async {
      final banned = adminFixture('ban_post_left');
      (banned['member'] as Map<String, dynamic>)['banned'] = 'post';
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:adminban': [banned],
      });
      forum.session.keepClearCursor(96, 100, (cursor: '0-300', total: 233, remaining: 100));
      await _pump(tester, AdminBanPage(repository: forum.repository(), initialMember: '100', writable: true));
      expect(find.byKey(const ValueKey('admin-ban-resume')), findsNothing);
      expect(find.byKey(const ValueKey('admin-ban-clear-posts')), findsNothing);
      expect(forum.session.clearCursor(96, 100), isNull);
      expect(forum.of('adminban', 'POST'), isEmpty);
    });

    testWidgets('clear_start on going on: told, the ban form keeps clearing the posts', (tester) async {
      final pending = adminFixture('ban_post_left');
      (pending['member'] as Map<String, dynamic>)
        ..['banned'] = 'visit'
        ..['clear_pending'] = 1;
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:adminban': [pending, adminFixture('ban_post_left')],
        'POST:adminban': [
          adminError('clear_start', {'target_uid': 100, 'remaining': 233}),
        ],
      });
      await _pump(tester, AdminBanPage(repository: forum.repository(), initialMember: '100', writable: true));
      await tester.tap(find.byKey(const ValueKey('admin-ban-resume')));
      await tester.pumpAndSettle();
      expect(find.text(t.adminTools.errorClearStart), findsOneWidget);
      expect(forum.of('adminban', 'POST'), hasLength(1));
      final clearPosts = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('admin-ban-clear-post')));
      expect(clearPosts.value, isTrue);
    });
  });
}
