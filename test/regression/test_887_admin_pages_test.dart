/// The three admin pages on members (plugin 3.9.0, spec §3, §4, §6, §8): credits (`admincredit`), user groups
/// (`admingroup`) and cleaning up a spammer (`adminban`). The answers of the test forum are read as the spec writes them,
/// the forms carry the spec's field names, a write keeps its `opid` while it is sent again, the group form is the whole
/// state, and the clearing of a spammer's posts goes batch by batch with its cursor, on after a new login and from
/// where it stopped.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_ban_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_group_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import 'admin_tools_fakes.dart';

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

Future<void> _confirm(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, t.adminTools.confirm));
  await tester.pumpAndSettle();
}

/// A batch of the clearing of member [target]: the top `uid` is the account asking (96), the member `target_uid`
/// (tsdmapp 3.9.0 second round).
Map<String, dynamic> _clearStep(int target, {required bool done, String cursor = '', int remaining = 0}) => {
  'ok': 1,
  'type': 'adminban',
  'schema': 30,
  'op': 'clear',
  'uid': 96,
  'target_uid': target,
  'done': done ? 1 : 0,
  'cursor': cursor,
  'remaining': remaining,
  'posts': 2,
  'threads': 0,
};

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(AdminAccessCache.reset);

  group('credits', () {
    test('the answer: the credits on, the limits, the members with their credits, the missing', () {
      final info = AdminCreditInfo.fromJson(adminFixture('credit_members'))!;
      expect(info.credits.map((c) => c.id), [1, 2, 3, 4, 5, 6]);
      expect(info.credits[1].title, '天使币');
      expect((info.maxUsers, info.maxDelta, info.maxReason, info.reasonRequired), (50, 99999999, 200, false));
      expect(info.members.map((m) => m.member.uid), [101, 103]);
      expect(info.members.first.credits[2], 0);
      expect(info.missing, ['nobody_x']);
      final empty = AdminCreditInfo.fromJson(adminFixture('credit_empty'))!;
      expect(empty.members, isEmpty);
      expect(empty.missing, isEmpty);
      expect(AdminCreditInfo.fromJson(adminFixture('admin_login_needed')), isNull);
    });

    test('targets, changes and the form as the spec names them', () {
      final targets = adminTargetsOf('101\nfoo, 102，101\n\n bar ');
      expect(targets.uids, [101, 102]);
      expect(targets.usernames, ['foo', 'bar']);
      expect(adminCreditDeltasOf({1: '-2', 2: '+5', 3: '', 4: '0'}), {1: -2, 2: 5});
      expect(adminCreditDeltasOf({1: '1.5'}), isNull);
      expect(adminCreditForm(uids: [101, 103], deltas: {2: 5, 1: -2}, reason: ' 活动 ', notify: true), {
        'uids': '101,103',
        'credits[2]': '5',
        'credits[1]': '-2',
        'reason': '活动',
        'notify': '1',
      });
      expect(adminCreditForm(uids: [101], deltas: {2: 1}), {'uids': '101', 'credits[2]': '1'});
      final result = adminCreditResultOf({
        'ok': 1,
        'type': 'admincredit',
        'op': 'reward',
        'changed': {'2': 5, '1': -2},
        'notified': 2,
        'members': adminFixture('credit_members')['members'],
      })!;
      expect(result.changed, {2: 5, 1: -2});
      expect(result.notified, 2);
      expect(result.members, hasLength(2));
    });

    testWidgets('looked up first; a missing member is shown and nothing can be sent', (tester) async {
      final forum = FakeAdminForum({
        'GET:admincredit': [adminFixture('credit_members')],
      });
      await _pump(
        tester,
        AdminCreditPage(repository: forum.repository(), initialMembers: '101\n103\nnobody_x', writable: true),
      );
      expect(forum.requests.single.data, {'uids': '101,103', 'usernames': 'nobody_x'});
      expect(find.byKey(const ValueKey('admin-credit-missing')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('admin-credit-2')), '5');
      await tester.tap(find.byKey(const ValueKey('admin-credit-submit')));
      await tester.pumpAndSettle();
      expect(forum.of('admincredit', 'POST'), isEmpty);
    });

    testWidgets('sent with the same opid again after a failed request; a new one after the answer', (tester) async {
      final found = adminFixture('credit_members')..['missing'] = <Object>[];
      final ok = {
        'ok': 1,
        'type': 'admincredit',
        'schema': 26,
        'op': 'reward',
        'changed': {'2': 5, '1': -2},
        'notified': 2,
        'members': found['members'],
      };
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:admincredit': [found],
        'POST:admincredit': [null, ok],
      });
      await _pump(tester, AdminCreditPage(repository: forum.repository(), initialMembers: '101,103', writable: true));
      await tester.enterText(find.byKey(const ValueKey('admin-credit-2')), '5');
      await tester.enterText(find.byKey(const ValueKey('admin-credit-1')), '-2');
      await tester.enterText(find.byKey(const ValueKey('admin-credit-reason')), '活动奖励');
      await tester.tap(find.byKey(const ValueKey('admin-credit-notify')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-credit-submit')));
      await _confirm(tester);
      // Only looking at the reason (the cursor moved) keeps the operation the same.
      tester.widget<TextField>(find.byKey(const ValueKey('admin-credit-reason'))).controller!.selection =
          const TextSelection.collapsed(offset: 1);
      await tester.tap(find.byKey(const ValueKey('admin-credit-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-credit-submit')));
      await _confirm(tester);
      final posts = forum.of('admincredit', 'POST');
      expect(posts, hasLength(2));
      final opid = posts[0].data['opid'];
      expect(posts[1].data, posts[0].data, reason: 'the same operation sent again');
      expect(posts[0].data, {
        'uids': '101,103',
        'credits[2]': '5',
        'credits[1]': '-2',
        'reason': '活动奖励',
        'notify': '1',
        'opid': opid,
        'formhash': 'f1f2f3f4',
      });
      expect(find.byKey(const ValueKey('admin-credit-result')), findsOneWidget);
      expect(find.textContaining(t.adminTools.notified(n: 2)), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('admin-credit-2'))).controller!.text, isEmpty);
    });

    testWidgets('a lookup that failed after one that answered: told, and nothing sent to the members before', (
      tester,
    ) async {
      final found = adminFixture('credit_members')..['missing'] = <Object>[];
      final forum = FakeAdminForum({
        'GET:admincredit': [found, null],
      });
      await _pump(tester, AdminCreditPage(repository: forum.repository(), initialMembers: '101,103', writable: true));
      FilledButton submit() => tester.widget<FilledButton>(find.byKey(const ValueKey('admin-credit-submit')));
      expect(submit().onPressed, isNotNull);
      await tester.enterText(find.byKey(const ValueKey('admin-target')), '104');
      await tester.pumpAndSettle();
      expect(submit().onPressed, isNull, reason: 'the text is not what was looked up');
      await tester.tap(find.byKey(const ValueKey('admin-lookup')));
      await tester.pumpAndSettle();
      expect(find.text(t.adminTools.errorFailed), findsOneWidget);
      expect(submit().onPressed, isNull);
    });

    testWidgets('write 0: no submit button', (tester) async {
      final forum = FakeAdminForum({
        'GET:admincredit': [adminFixture('credit_empty')],
      });
      await _pump(tester, AdminCreditPage(repository: forum.repository(), writable: false));
      expect(find.byKey(const ValueKey('admin-credit-submit')), findsNothing);
    });
  });

  group('user groups', () {
    test('the answer: the member, the groups offered and which may be chosen', () {
      final info = AdminGroupInfo.fromJson(adminFixture('group_member'))!;
      expect(info.member.member.uid, 101);
      expect(info.member.member.groupType, 'member');
      expect((info.can, info.adminGrant), (true, false));
      expect(info.groupOf(1)!.allowed, isFalse, reason: 'the administrator group, not a founder');
      expect(info.groupOf(22)!.relatedAdmin, isTrue);
      expect(info.groupOf(21)!.type, 'specialadmin');
      expect(info.extGroups.where((g) => !g.allowed).map((g) => g.groupId), [1, 18]);
      expect(info.expGroups.first.groupId, 0);
      expect(info.expGroups.every((g) => g.allowed), isTrue);
      expect(info.adminIds, [0, 3, 2]);
      expect(info.maxExtLength, 30);
      final founder = AdminGroupInfo.fromJson(adminFixture('group_founder_view'))!;
      expect(founder.adminGrant, isTrue);
      expect(founder.adminIds, [0, 3, 2, 1]);
    });

    test('the form starts from the member now, dates padded; it is the whole state', () {
      expect(adminPadDate('2026-1-5'), '2026-01-05');
      expect(adminPadDate('2026-11-19'), '2026-11-19');
      expect(adminPadDate(''), '');
      final json = adminFixture('group_member');
      final m = json['member'] as Map<String, dynamic>;
      m['groupid'] = 22;
      m['adminid'] = 3;
      m['extgroupids'] = [23, 24];
      m['expiry'] = {'time': 1800000000, 'date': '2027-1-15', 'groupid': 10, 'adminid': 0};
      m['ext_expiry'] = [
        {'groupid': 23, 'title': '低权组', 'time': 1800000000, 'date': '2027-2-1'},
        {'groupid': 24, 'title': '效能组', 'time': 0, 'date': ''},
      ];
      final info = AdminGroupInfo.fromJson(json)!;
      final draft = AdminGroupDraft.of(info);
      expect((draft.groupId, draft.adminId, draft.expiry, draft.expGroupId), (22, 3, '2027-01-15', 10));
      expect(draft.extGroupIds, [23, 24]);
      expect(draft.extExpiry, {23: '2027-02-01'});
      expect(adminGroupForm(uid: 101, info: info, draft: draft, reason: '调整', notify: true), {
        'uid': '101',
        'groupid': '22',
        'adminid': '3',
        'expiry': '2027-01-15',
        'expgroupid': '10',
        'extgroupids[0]': '23',
        'extgroupids[1]': '24',
        'extexpiry[23]': '2027-02-01',
        'reason': '调整',
        'notify': '1',
      });
      // A plain group takes no related admin level; no expiry, no group after it; no reason, no notice.
      final plain = draft.copyWith(groupId: 10, expiry: '', extGroupIds: const []);
      expect(adminGroupForm(uid: 101, info: info, draft: plain, notify: true), {
        'uid': '101',
        'groupid': '10',
        'expiry': '',
      });
      expect(adminGroupChanges(draft, draft), isEmpty);
      expect(adminGroupChanges(draft, plain), [
        AdminGroupField.group,
        AdminGroupField.expiry,
        AdminGroupField.extGroups,
      ]);
      expect(adminGroupChanges(draft, draft.copyWith(extExpiry: {23: '2027-03-01'})), [AdminGroupField.extExpiry]);
      expect(adminGroupChanges(draft, draft.copyWith(adminId: 2)), [AdminGroupField.adminId]);
      expect(adminExtGroupsFit([for (var i = 10; i < 20; i++) i], 30), isTrue);
      expect(adminExtGroupsFit([for (var i = 10; i < 21; i++) i], 30), isFalse);
    });

    testWidgets('a change is confirmed with what changed and sent as the whole state', (tester) async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:admingroup': [adminFixture('group_member')],
        'POST:admingroup': [
          {'ok': 1, 'type': 'admingroup', 'schema': 27, 'op': 'group', 'notified': 0, 'member': <String, Object?>{}},
        ],
      });
      await _pump(tester, AdminGroupPage(repository: forum.repository(), initialMember: '101', writable: true));
      expect(forum.of('admingroup').single.data, {'uid': '101'});
      // Nothing changed: nothing sent.
      await tester.tap(find.byKey(const ValueKey('admin-group-submit')));
      await tester.pumpAndSettle();
      expect(find.text(t.adminTools.noChanges), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('admin-group-ext-22')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-group-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('${t.adminTools.extGroups}：${t.adminTools.none} → 字幕组'), findsOneWidget);
      await _confirm(tester);
      final post = forum.of('admingroup', 'POST').single.data;
      expect(post['groupid'], '10');
      expect(post['extgroupids[0]'], '22');
      expect(post['expiry'], '');
      expect(post.containsKey('notify'), isFalse);
      expect(post['opid'], isNotEmpty);
      expect(forum.of('admingroup', 'GET'), hasLength(2), reason: 'read again after the change');
    });

    testWidgets('another member looked up: the form is theirs, not the one before', (tester) async {
      final other = adminFixture('group_founder_view')..['uid'] = 96;
      final forum = FakeAdminForum({
        'GET:admingroup': [adminFixture('group_member'), other],
      });
      await _pump(tester, AdminGroupPage(repository: forum.repository(), initialMember: '101', writable: true));
      expect(
        tester.widget<DropdownButtonFormField<int>>(find.byKey(const ValueKey('admin-group-main'))).initialValue,
        10,
      );
      await tester.enterText(find.byKey(const ValueKey('admin-target')), '37');
      await tester.tap(find.byKey(const ValueKey('admin-lookup')));
      await tester.pumpAndSettle();
      expect(forum.of('admingroup').last.data, {'uid': '37'});
      final field = find.byKey(const ValueKey('admin-group-main'));
      expect(find.descendant(of: field, matching: find.text('字幕组')), findsOneWidget);
      expect(find.descendant(of: field, matching: find.text('新手上路')), findsNothing);
    });

    test('a member object without founder (only a founder is told it) reads as not one', () {
      final json = adminFixture('group_member');
      (json['member'] as Map<String, dynamic>).remove('founder');
      expect(AdminGroupInfo.fromJson(json)!.member.member.founder, isFalse);
      final admin = adminFixture('admin_member_manager')..remove('founder');
      expect(AdminAccess.fromJson(admin)!.founder, isFalse);
    });

    testWidgets('groups not allowed cannot be chosen; can 0 shows only the reason', (tester) async {
      final forum = FakeAdminForum({
        'GET:admingroup': [adminFixture('group_member')],
      });
      await _pump(tester, AdminGroupPage(repository: forum.repository(), initialMember: '101', writable: true));
      final ext1 = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('admin-group-ext-1')));
      expect(ext1.onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('admin-group-main')));
      await tester.pumpAndSettle();
      final items = tester.widgetList<DropdownMenuItem<int>>(find.byType(DropdownMenuItem<int>));
      expect(items.where((i) => i.value == 1 || i.value == 18).every((i) => !i.enabled), isTrue);
      expect(items.where((i) => i.value == 10).every((i) => i.enabled), isTrue);

      final self = adminFixture('group_member')
        ..['can'] = 0
        ..['why'] = 'self';
      final forum2 = FakeAdminForum({
        'GET:admingroup': [self],
      });
      await _pump(
        tester,
        AdminGroupPage(key: UniqueKey(), repository: forum2.repository(), initialMember: '96', writable: true),
      );
      expect(find.byKey(const ValueKey('admin-group-cannot')), findsOneWidget);
      expect(find.text(t.adminTools.errorSelf), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-group-submit')), findsNothing);
    });
  });

  group('cleaning up a spammer', () {
    test('the answer: state, offences, the choices; protected members', () {
      final info = AdminBanInfo.fromJson(adminFixture('ban_banned'))!;
      expect(info.member.banned, 'post');
      expect(info.member.member.groupId, 4);
      expect(info.bans, ['', 'post', 'visit', 'status']);
      expect(info.days, [0, 1, 3, 5, 7, 14, 30, 60, 90, 180, 365]);
      expect(info.clear, ['post', 'postcomment', 'avatar', 'profile']);
      expect((info.batch, info.maxDays, info.timeOffset), (200, 3650, 8));
      expect(info.crimes.single.action, 'crime_banspeak');
      expect(info.crimes.single.text, '禁止发言');
      final protected = AdminBanInfo.fromJson(adminFixture('ban_protected'))!;
      expect((protected.can, protected.why), (false, 'protected'));
      expect((protected.member.posts, protected.member.threads, protected.member.postRows), (623, 444, 625));
      expect(AdminBanInfo.fromJson(adminFixture('ban_member'))!.crimes, isEmpty);
    });

    test('the ban form, the ban result and a batch', () {
      expect(adminBanForm(uid: 99, ban: 'post', days: 7, reason: '广告', clear: ['post', 'profile']), {
        'op': 'ban',
        'uid': '99',
        'bannew': 'post',
        'banexpirynew': '7',
        'reason': '广告',
        'clear[0]': 'post',
        'clear[1]': 'profile',
      });
      expect(adminBanForm(uid: 99, ban: 'status', days: 7), {'op': 'ban', 'uid': '99', 'bannew': 'status'});
      expect(adminBanForm(uid: 99, ban: ''), {'op': 'ban', 'uid': '99', 'bannew': ''});
      final result = adminBanResultOf({
        'ok': 1,
        'type': 'adminban',
        'op': 'ban',
        'member': {
          ...(adminFixture('ban_member')['member'] as Map<String, dynamic>),
          'banned': 'post',
          'banexpiry': 1700600000,
        },
        'cleared': ['postcomment', 'profile'],
        'clear_posts': {'pending': 1, 'cursor': '0-0', 'remaining': 6, 'batch': 200},
      })!;
      expect(result.member!.banned, 'post');
      expect(result.cleared, ['postcomment', 'profile']);
      expect(result.clearPosts, (pending: true, cursor: '0-0', remaining: 6, batch: 200));
      expect(adminBanResultOf({'ok': 1, 'op': 'ban', 'clear_posts': null})!.clearPosts, isNull);
      expect(adminClearForm(uid: 99, cursor: '0-11943'), {'op': 'clear', 'uid': '99', 'cursor': '0-11943'});
      expect(adminClearStepOf(_clearStep(99, done: false, cursor: '0-11943', remaining: 33)), (
        done: false,
        cursor: '0-11943',
        remaining: 33,
        posts: 2,
        threads: 0,
      ));
      expect(adminClearStepOf(adminError('admin_login')), isNull);
    });

    test('the clearing goes batch by batch with the cursor, until done; no opid', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          _clearStep(99, done: false, cursor: '0-100', remaining: 4),
          _clearStep(99, done: false, cursor: '0-200', remaining: 2),
          _clearStep(99, done: true),
        ],
      });
      final left = <int>[];
      final outcome = await runAdminClear(
        forum.repository(),
        target: 99,
        cursor: adminClearStart,
        total: 6,
        remaining: 6,
        onStep: (s) => left.add(s.remaining),
        stopped: () => false,
      );
      expect(outcome.done, isTrue);
      expect(left, [4, 2, 0]);
      expect(forum.of('adminban', 'POST').map((r) => r.data['cursor']), ['0-0', '0-100', '0-200']);
      expect(forum.of('adminban', 'POST').every((r) => !r.data.containsKey('opid') && r.data['op'] == 'clear'), isTrue);
      expect(forum.session.clearCursor(96, 99), isNull);
    });

    test('an expired token mid-way: a new login and the same cursor again', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          _clearStep(99, done: false, cursor: '0-100', remaining: 4),
          adminError('admin_login'),
          _clearStep(99, done: true),
        ],
      });
      var logins = 0;
      final outcome = await runAdminClear(
        forum.repository(),
        target: 99,
        cursor: adminClearStart,
        total: 6,
        remaining: 6,
        onStep: (_) {},
        stopped: () => false,
        reauth: (_) async {
          logins++;
          return true;
        },
      );
      expect(outcome.done, isTrue);
      expect(logins, 1);
      expect(forum.of('adminban', 'POST').map((r) => r.data['cursor']), ['0-0', '0-100', '0-100']);
    });

    test('stopped or failed: where it stopped is kept, and it goes on from there', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          _clearStep(99, done: false, cursor: '0-100', remaining: 4),
          null,
          _clearStep(99, done: true),
        ],
      });
      final repo = forum.repository();
      final failed = await runAdminClear(
        repo,
        target: 99,
        cursor: adminClearStart,
        total: 6,
        remaining: 6,
        onStep: (_) {},
        stopped: () => false,
      );
      expect(failed.done, isFalse);
      expect(failed.reply!.json, isNull);
      expect(forum.session.clearCursor(96, 99), (cursor: '0-100', total: 6, remaining: 4));
      // Another account does not see it.
      expect(forum.session.clearCursor(31, 99), isNull);

      var steps = 0;
      final stopped = await runAdminClear(
        repo,
        target: 99,
        cursor: '0-100',
        total: 6,
        remaining: 4,
        onStep: (_) => steps++,
        stopped: () => true,
      );
      expect(stopped, (done: false, reply: null));
      expect(steps, 0);
      expect(forum.session.clearCursor(96, 99)!.cursor, '0-100');

      final kept = forum.session.clearCursor(96, 99)!;
      final resumed = await runAdminClear(
        repo,
        target: 99,
        cursor: kept.cursor,
        total: kept.total,
        remaining: kept.remaining,
        onStep: (_) {},
        stopped: () => false,
      );
      expect(resumed.done, isTrue);
      expect(forum.of('adminban', 'POST').last.data['cursor'], '0-100');
      expect(forum.session.clearCursor(96, 99), isNull);
    });

    testWidgets('ban with the posts cleared: confirmed, then the batches with their progress', (tester) async {
      final member = adminFixture('ban_member');
      (member['member'] as Map<String, dynamic>)
        ..['posts'] = 5
        ..['threads'] = 1
        ..['post_rows'] = 6;
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:adminban': [member],
        'POST:adminban': [
          (AdminRequest r) => r.data['op'] == 'ban'
              ? {
                  'ok': 1,
                  'type': 'adminban',
                  'schema': 30,
                  'op': 'ban',
                  'member': member['member'],
                  'cleared': <Object>[],
                  'clear_posts': {'pending': 1, 'cursor': '0-0', 'remaining': 6, 'batch': 200},
                }
              : (r.data['cursor'] == '0-0'
                    ? _clearStep(99, done: false, cursor: '0-50', remaining: 2)
                    : _clearStep(99, done: true)),
        ],
      });
      await _pump(tester, AdminBanPage(repository: forum.repository(), initialMember: '99', writable: true));
      expect(forum.of('adminban', 'GET').single.data, {'uid': '99'});
      await tester.tap(find.byKey(const ValueKey('admin-ban-type-visit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('admin-ban-reason')), '广告');
      await tester.tap(find.byKey(const ValueKey('admin-ban-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining(t.adminTools.clearPost), findsWidgets);
      await _confirm(tester);
      final posts = forum.of('adminban', 'POST');
      expect(posts.first.data, {
        'op': 'ban',
        'uid': '99',
        'bannew': 'visit',
        'reason': '广告',
        'clear[0]': 'post',
        'opid': posts.first.data['opid'],
        'formhash': 'f1f2f3f4',
      });
      expect(posts.skip(1).map((r) => r.data['cursor']), ['0-0', '0-50']);
      expect(forum.session.clearCursor(96, 99), isNull);
      expect(forum.of('adminban', 'GET'), hasLength(2));
    });

    testWidgets('a clearing kept from before is offered to go on; protected shows only the reason', (tester) async {
      // The forum says the clearing is open (`clear_pending`, second round) with 300 of 600 rows left.
      final pending = adminFixture('ban_member');
      (pending['member'] as Map<String, dynamic>)
        ..['post_rows'] = 600
        ..['post_left'] = 300
        ..['clear_pending'] = 1;
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'GET:adminban': [pending, adminFixture('ban_member')],
        'POST:adminban': [_clearStep(99, done: true)],
      });
      forum.session.keepClearCursor(96, 99, (cursor: '0-300', total: 600, remaining: 300));
      await _pump(tester, AdminBanPage(repository: forum.repository(), initialMember: '99', writable: true));
      expect(find.text(t.adminTools.clearProgress(done: 300, total: 600)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('admin-ban-resume')));
      await tester.pumpAndSettle();
      expect(forum.of('adminban', 'POST').single.data, {
        'op': 'clear',
        'uid': '99',
        'cursor': '0-300',
        'formhash': 'f1f2f3f4',
      });
      expect(find.byKey(const ValueKey('admin-ban-resume')), findsNothing);

      final p = FakeAdminForum({
        'GET:adminban': [adminFixture('ban_protected')],
      });
      await _pump(
        tester,
        AdminBanPage(key: UniqueKey(), repository: p.repository(), initialMember: '33', writable: true),
      );
      expect(find.byKey(const ValueKey('admin-ban-cannot')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-ban-submit')), findsNothing);
    });
  });
}
