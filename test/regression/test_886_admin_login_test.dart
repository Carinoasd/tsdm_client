/// The second login of the forum's admin actions and the token (plugin 3.9.0, spec §2): the login password (and the
/// security question when asked) for a token kept in memory for the account only, sent as `X-Tsdmapp-Admin`; an
/// `admin_login` answer asks the password and sends the very same request once more (a write with the same `opid`);
/// wrong passwords tell the tries left, the lock tells the wait; another account, the app lock and leaving the last
/// admin page drop the token (`op=logout`). The password and the token never reach a log.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

import 'admin_tools_fakes.dart';

const _token = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';

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

  setUp(AdminAccessCache.reset);

  group('login', () {
    test('the form: op, password, the question only when asked; the token kept, never handed on', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [adminLoginOk()],
      });
      final repo = forum.repository();
      final reply = await repo.login(password: 'secret-pass');
      expect(reply.ok, isTrue);
      expect(reply.json!.containsKey('token'), isFalse);
      expect(forum.session.tokenFor(96), _token);
      // The form hash came from the entry, asked first.
      expect(forum.requests.map((r) => '${r.method}:${r.action}'), ['GET:admin', 'POST:admin']);
      final post = forum.of('admin', 'POST').single;
      expect(post.data, {'op': 'login', 'password': 'secret-pass', 'formhash': 'f1f2f3f4'});
      expect(post.data.containsKey('questionid'), isFalse);
      expect(post.data.containsKey('answer'), isFalse);

      await repo.login(password: 'p', questionId: 3, answer: 'city');
      expect(forum.of('admin', 'POST').last.data, {
        'op': 'login',
        'password': 'p',
        'questionid': '3',
        'answer': 'city',
        'formhash': 'f1f2f3f4',
      });
    });

    test('a refused login keeps no token', () async {
      for (final e in ['admin_password', 'admin_secques', 'admin_locked', 'admin_noperm', 'admin_off']) {
        final forum = FakeAdminForum({
          'GET:admin': [adminFixture('admin_member_manager')],
          'POST:admin': [
            adminError(e, {'token': _token}),
          ],
        });
        expect((await forum.repository().login(password: 'x')).error, e);
        expect(forum.session.tokenFor(96), isNull, reason: e);
      }
    });

    test('the login state of an answer', () {
      final login = AdminLoginInfo.fromJson(const {'locked': 1, 'retry_after': 1800, 'tries_left': 0, 'secques': 1});
      expect((login.locked, login.retryAfter, login.triesLeft, login.secques), (true, 1800, 0, true));
      final none = AdminLoginInfo.fromJson(null);
      expect((none.locked, none.triesLeft, none.secques), (false, 4, false));
    });
  });

  group('requests with the token', () {
    test('the header goes with every request once a token is kept, never in the url', () async {
      final forum = FakeAdminForum({
        'admincredit': [adminFixture('credit_empty')],
      });
      final repo = forum.repository();
      await repo.request(AdminActions.credit);
      expect(forum.requests.single.headers, isEmpty);
      forum.session.keep(96, _token);
      await repo.request(AdminActions.credit, query: {'uids': '101'});
      expect(forum.requests.last.headers, {adminTokenHeader: _token});
      expect(forum.requests.last.data, {'uids': '101'});
      expect(forum.requests.last.data.values.join(), isNot(contains(_token)));
    });

    test('admin_login: the password is asked, the same write sent once more with the same opid', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admincredit': [
          adminError('admin_login', {
            'login': {'locked': 0, 'retry_after': 0, 'tries_left': 3, 'secques': 1},
          }),
          {
            'ok': 1,
            'type': 'admincredit',
            'schema': 26,
            'op': 'reward',
            'changed': {'2': 5},
            'notified': 0,
            'members': <Object>[],
          },
        ],
      });
      final repo = forum.repository();
      AdminLoginInfo? asked;
      final reply = await repo.request(
        AdminActions.credit,
        form: {'uids': '101', 'credits[2]': '5', 'opid': 'op-12345678'},
        reauth: (login) async {
          asked = login;
          forum.session.keep(96, _token);
          return true;
        },
      );
      expect(reply.ok, isTrue);
      expect(asked!.triesLeft, 3);
      expect(asked!.secques, isTrue);
      final posts = forum.of('admincredit', 'POST');
      expect(posts, hasLength(2));
      expect(posts[0].data['opid'], 'op-12345678');
      expect(posts[1].data, posts[0].data);
      expect(posts[0].headers, isEmpty);
      expect(posts[1].headers, {adminTokenHeader: _token});
    });

    test('busy right after the login: the same write once more after the wait, same opid', () async {
      final ok = {'ok': 1, 'type': 'adminban', 'schema': 30, 'op': 'ban', 'cleared': <Object>[], 'clear_posts': null};
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          adminError('admin_login'),
          adminError('busy', {'retry_after': 3}),
          ok,
        ],
      });
      final reply = await forum.repository().request(
        AdminActions.ban,
        form: {'op': 'ban', 'uid': '99', 'bannew': 'post', 'opid': 'op-zzzzzzzz'},
        reauth: (_) async {
          forum.session.keep(96, _token);
          return true;
        },
      );
      expect(reply.ok, isTrue);
      final posts = forum.of('adminban', 'POST');
      expect(posts, hasLength(3));
      expect(posts.map((p) => p.data['opid']).toSet(), {'op-zzzzzzzz'});
      expect(forum.waits, [const Duration(milliseconds: 3300)]);
    });

    test('a POST without JSON (the core refusing the form hash) asks the form hash again', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [null],
      });
      final repo = forum.repository();
      await repo.request(AdminActions.ban, form: {'op': 'clear', 'uid': '99', 'cursor': '0-0'});
      await repo.request(AdminActions.ban, form: {'op': 'clear', 'uid': '99', 'cursor': '0-0'});
      expect(forum.of('admin', 'GET'), hasLength(2));
    });

    test('a second admin_login is given back; a cancelled login sends nothing more', () async {
      final forum = FakeAdminForum({
        'GET:adminban': [adminError('admin_login')],
      });
      final repo = forum.repository();
      var asks = 0;
      final reply = await repo.request(
        AdminActions.ban,
        query: {'uid': '99'},
        reauth: (_) async {
          asks++;
          return true;
        },
      );
      expect(reply.error, 'admin_login');
      expect(asks, 1);
      expect(forum.of('adminban'), hasLength(2));

      final cancelled = await repo.request(AdminActions.ban, query: {'uid': '99'}, reauth: (_) async => false);
      expect(cancelled.error, 'admin_login');
      expect(forum.of('adminban'), hasLength(3));
    });

    test('admin_login drops the kept token (voided by a login elsewhere)', () async {
      final forum = FakeAdminForum({
        'adminban': [adminError('admin_login')],
      });
      forum.session.keep(96, _token);
      await forum.repository().request(AdminActions.ban, query: {'uid': '33'});
      expect(forum.session.tokenFor(96), isNull);
    });

    test('another account: the token is dropped and the answer too', () async {
      final forum = FakeAdminForum({
        'admingroup': [adminFixture('group_member')],
      });
      forum.session.keep(96, _token);
      forum.uid = 31;
      await forum.repository().request(AdminActions.group, query: {'uid': '101'});
      expect(forum.requests.single.headers, isEmpty, reason: 'the token of 96 never goes with 31');
      expect(forum.session.tokenFor(96), isNull);

      // The account changes while the request is on its way.
      final switching = FakeAdminForum();
      switching.answers['admingroup'] = [
        (AdminRequest _) {
          switching.uid = 35;
          return adminFixture('group_member');
        },
      ];
      final reply = await switching.repository().request(AdminActions.group, query: {'uid': '101'});
      expect(reply.identityChanged, isTrue);
      expect(reply.json, isNull);

      // An answer served to another account.
      final served = FakeAdminForum({
        'admingroup': [
          {...adminFixture('group_member'), 'uid': 32},
        ],
      });
      expect((await served.repository().request(AdminActions.group)).identityChanged, isTrue);
    });

    test('busy of a write comes back as it is: nothing sent again by itself', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:adminban': [
          adminError('busy', {'retry_after': 5}),
        ],
      });
      final reply = await forum.repository().request(
        AdminActions.ban,
        form: {'op': 'ban', 'uid': '99', 'bannew': 'post', 'opid': 'op-abcdefgh'},
        reauth: (_) async => true,
      );
      expect(reply.error, 'busy');
      expect(reply.retryAfter, 5);
      expect(forum.of('adminban', 'POST'), hasLength(1));
    });

    test('an operation id: 8 to 64 characters of letters, digits, - and _; new each time', () {
      final a = newAdminOpId();
      expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(a), isTrue);
      expect(newAdminOpId(), isNot(a));
    });
  });

  group('the session', () {
    test('logout ends the token with op=logout and the header, then forgets it', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [
          {
            ...adminLoginOk(),
            'op': 'logout',
            'session': {'active': 0},
          }..remove('token'),
        ],
      });
      forum.session.keep(96, _token);
      await forum.repository().logout();
      final post = forum.of('admin', 'POST').single;
      expect(post.data, {'op': 'logout', 'formhash': 'f1f2f3f4'});
      expect(post.headers, {adminTokenHeader: _token});
      expect(forum.session.tokenFor(96), isNull);
      // Nothing kept: nothing sent.
      await forum.repository().logout();
      expect(forum.of('admin', 'POST'), hasLength(1));
    });

    test('the last admin page left logs out; the token of another account is never logged out', () async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': [
          {'ok': 1, 'type': 'admin', 'op': 'logout'},
        ],
      });
      final repo = forum.repository();
      forum.session.keep(96, _token);
      forum.session
        ..acquire()
        ..acquire()
        ..release(repo.logout);
      await pumpEventQueue();
      expect(forum.of('admin', 'POST'), isEmpty);
      forum.session.release(repo.logout);
      await pumpEventQueue();
      expect(forum.of('admin', 'POST'), hasLength(1));
      expect(forum.session.tokenFor(96), isNull);

      forum.session
        ..keep(96, _token)
        ..acquire();
      forum.uid = 35;
      forum.session.release(repo.logout);
      await pumpEventQueue();
      expect(forum.of('admin', 'POST'), hasLength(1), reason: 'switched: dropped here, not sent with 35');
      expect(forum.session.holds(96), isFalse);
    });

    test('the app lock locking drops the token', () async {
      final session = AdminSession()..keep(96, _token);
      final lock = StreamController<bool>();
      final sub = session.dropOnLock(lock.stream);
      lock.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.holds(96), isTrue);
      lock.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.holds(96), isFalse);
      await sub.cancel();
      await lock.close();
    });
  });

  group('the logs', () {
    test('the password, the answer and the token are masked', () {
      for (final line in [
        'X-Tsdmapp-Admin: $_token',
        '{X-Tsdmapp-Admin: $_token, accept: */*}',
        'formhash=f1&op=login&password=secret-pass&questionid=3&answer=city',
        'admintoken=$_token&op=clear',
        '{"ok":1,"token":"$_token"}',
      ]) {
        final out = redactSensitive(line);
        expect(out, isNot(contains(_token)), reason: line);
        expect(out, isNot(contains('secret-pass')), reason: line);
        expect(out, isNot(contains('city')), reason: line);
      }
    });
  });

  group('the dialog', () {
    Future<(FakeAdminForum, Future<bool>)> open(
      WidgetTester tester,
      List<Object?> answers, {
      AdminLoginInfo? login,
    }) async {
      final forum = FakeAdminForum({
        'GET:admin': [adminFixture('admin_member_manager')],
        'POST:admin': answers,
      });
      late Future<bool> result;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                result = showAdminLoginDialog(context, forum.repository(), login ?? const AdminLoginInfo()),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (forum, result);
    }

    testWidgets('success closes it with the token kept', (tester) async {
      final (forum, result) = await open(tester, [adminLoginOk()]);
      expect(find.byKey(const ValueKey('admin-login-question')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('admin-login-password')), 'secret-pass');
      await tester.tap(find.byKey(const ValueKey('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(forum.session.tokenFor(96), _token);
      expect(find.byType(AdminLoginDialog), findsNothing);
    });

    testWidgets('a wrong password tells the tries left and clears the field', (tester) async {
      final (forum, _) = await open(tester, [
        adminError('admin_password', {
          'login': {'locked': 0, 'retry_after': 0, 'tries_left': 2, 'secques': 0},
        }),
      ]);
      await tester.enterText(find.byKey(const ValueKey('admin-login-password')), 'wrong');
      await tester.tap(find.byKey(const ValueKey('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(find.text(t.adminTools.wrongPassword(n: 2)), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('admin-login-password'))).controller!.text, isEmpty);
      expect(forum.session.tokenFor(96), isNull);
    });

    testWidgets('admin_secques shows the question and the answer; they are sent next time', (tester) async {
      final (forum, result) = await open(tester, [adminError('admin_secques'), adminLoginOk()]);
      await tester.enterText(find.byKey(const ValueKey('admin-login-password')), 'pw');
      await tester.tap(find.byKey(const ValueKey('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin-login-question')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('admin-login-password')), 'pw');
      await tester.enterText(find.byKey(const ValueKey('admin-login-answer')), 'city');
      await tester.tap(find.byKey(const ValueKey('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(forum.of('admin', 'POST').last.data, containsPair('questionid', '1'));
      expect(forum.of('admin', 'POST').last.data, containsPair('answer', 'city'));
    });

    testWidgets('secques 1 asks the question from the start', (tester) async {
      await open(tester, [adminLoginOk()], login: const AdminLoginInfo(secques: true));
      expect(find.byKey(const ValueKey('admin-login-question')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-login-answer')), findsOneWidget);
    });

    testWidgets('locked: the wait is shown and the button is off', (tester) async {
      final (forum, _) = await open(tester, [
        adminError('admin_locked', {
          'retry_after': 1800,
          'login': {'locked': 1, 'retry_after': 1800, 'tries_left': 0, 'secques': 0},
        }),
      ]);
      await tester.enterText(find.byKey(const ValueKey('admin-login-password')), 'wrong');
      await tester.tap(find.byKey(const ValueKey('admin-login-submit')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('30:00'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('admin-login-submit'))).onPressed, isNull);
      expect(forum.of('admin', 'POST'), hasLength(1));
      // Locked when opened.
      await tester.pumpWidget(const SizedBox());
      await open(tester, const [], login: const AdminLoginInfo(locked: true, retryAfter: 90, triesLeft: 0));
      expect(find.textContaining('1:30'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('admin-login-submit'))).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
