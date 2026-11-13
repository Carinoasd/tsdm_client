/// The admin pages after the 1.55.0 check: cleaning up a spammer tells done only once the posts are cleared and its
/// progress never falls back to the member read before the clearing; a page that could not ask what the account may
/// use shows the failure and a retry instead of a form without a button; the moderator's panel offers its login where
/// the counts go while it asks the password; sending a background clears the members once the plugin says it sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_ban_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_group_page.dart';
import 'package:tsdm_client/features/background_grant/repository/background_grant_repository.dart';
import 'package:tsdm_client/features/background_grant/view/background_grant_page.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import 'admin_tools_fakes.dart';

Map<String, dynamic> _fixture390(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

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

Map<String, dynamic> _clearStep({required bool done, String cursor = '', int remaining = 0}) => {
  'ok': 1,
  'type': 'adminban',
  'schema': 30,
  'op': 'clear',
  'uid': 96,
  'target_uid': 99,
  'done': done ? 1 : 0,
  'cursor': cursor,
  'remaining': remaining,
  'posts': 2,
  'threads': 0,
};

/// A forum answering the GETs and POSTs of the admin actions through [get] and [post] (futures the test holds).
AdminRepository _repo({
  required Future<Map<String, dynamic>?> Function(String action, Map<String, String> query) get,
  required Future<Map<String, dynamic>?> Function(String action, Map<String, String> form) post,
}) => AdminRepository(
  get: (action, query, _) => get(action, query),
  post: (action, form, _) => post(action, form),
  currentUid: () => 96,
  session: AdminSession(),
  wait: (_) async {},
);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('cleaning up a spammer', () {
    testWidgets('a ban with the posts cleared tells done once they are, not while the clearing starts', (tester) async {
      final member = adminFixture('ban_member');
      (member['member'] as Map<String, dynamic>)['post_rows'] = 6;
      final clearing = Completer<Map<String, dynamic>?>();
      final repo = _repo(
        get: (action, _) async => action == 'admin' ? adminFixture('admin_member_manager') : member,
        post: (_, form) async => form['op'] == 'ban'
            ? {
                'ok': 1,
                'uid': 96,
                'type': 'adminban',
                'schema': 30,
                'op': 'ban',
                'member': member['member'],
                'cleared': <Object>[],
                'clear_posts': {'pending': 1, 'cursor': '0-0', 'remaining': 6, 'batch': 200},
              }
            : clearing.future,
      );
      await _pump(tester, AdminBanPage(repository: repo, initialMember: '99', writable: true));
      await tester.enterText(find.byKey(const ValueKey('admin-ban-reason')), 'spam');
      await tester.tap(find.byKey(const ValueKey('admin-ban-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.adminTools.confirm));
      await tester.pump();
      await tester.pump();
      // The ban went through, the clearing is on its way: 0 of 6, nothing told yet.
      expect(find.text(t.adminTools.clearProgress(done: 0, total: 6)), findsOneWidget);
      expect(find.text(t.adminTools.done), findsNothing);
      expect(find.text(t.adminTools.clearDone), findsNothing);

      clearing.complete(_clearStep(done: true));
      await tester.pumpAndSettle();
      expect(find.text(t.adminTools.clearDone), findsOneWidget);
      expect(find.text(t.adminTools.done), findsNothing);
    });

    testWidgets('a clearing gone on keeps its progress until the member is read again', (tester) async {
      final pending = adminFixture('ban_member');
      (pending['member'] as Map<String, dynamic>)
        ..['post_rows'] = 600
        ..['post_left'] = 300
        ..['clear_pending'] = 1;
      var reads = 0;
      final reread = Completer<Map<String, dynamic>?>();
      final repo = _repo(
        get: (action, _) async {
          if (action == 'admin') return adminFixture('admin_member_manager');
          reads++;
          return reads == 1 ? pending : reread.future;
        },
        post: (_, _) async => _clearStep(done: true),
      );
      await _pump(tester, AdminBanPage(repository: repo, initialMember: '99', writable: true));
      expect(find.text(t.adminTools.clearProgress(done: 300, total: 600)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('admin-ban-resume')));
      // Every frame until the member is read again: the progress done, never the member read before (300 of 600 and
      // the button to go on).
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('admin-ban-resume')), findsNothing, reason: 'frame $i');
        expect(find.text(t.adminTools.clearProgress(done: 300, total: 600)), findsNothing, reason: 'frame $i');
      }
      expect(reads, 2);
      expect(find.text(t.adminTools.clearProgress(done: 600, total: 600)), findsOneWidget);

      reread.complete(adminFixture('ban_member'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin-ban-progress')), findsNothing);
      expect(find.byKey(const ValueKey('admin-ban-resume')), findsNothing);
      expect(find.byKey(const ValueKey('admin-ban-submit')), findsOneWidget);
    });
  });

  group('access not told', () {
    testWidgets('each page from a profile shows the failure and asks again on retry', (tester) async {
      for (final (name, build) in <(String, Widget Function(AdminRepository, Future<AdminAccess?> Function()))>[
        (
          'credit',
          (repo, ask) => AdminCreditPage(key: UniqueKey(), repository: repo, initialMembers: '101', adminAccess: ask),
        ),
        (
          'group',
          (repo, ask) => AdminGroupPage(key: UniqueKey(), repository: repo, initialMember: '101', adminAccess: ask),
        ),
        (
          'ban',
          (repo, ask) => AdminBanPage(key: UniqueKey(), repository: repo, initialMember: '99', adminAccess: ask),
        ),
      ]) {
        final forum = FakeAdminForum({
          'GET:admincredit': [adminFixture('credit_members')],
          'GET:admingroup': [adminFixture('group_member')],
          'GET:adminban': [adminFixture('ban_member')],
        });
        final answers = <AdminAccess?>[null, AdminAccess.fromJson(adminFixture('admin_founder'))];
        var asked = 0;
        await _pump(
          tester,
          build(forum.repository(), () async {
            asked++;
            return answers.removeAt(0);
          }),
        );
        expect(find.byKey(const ValueKey('admin-access-failed')), findsOneWidget, reason: name);
        expect(find.text(t.general.failedToLoad), findsOneWidget, reason: name);
        expect(find.byKey(ValueKey('admin-$name-submit')), findsNothing, reason: name);

        await tester.tap(find.text(t.general.retry));
        await tester.pumpAndSettle();
        expect(asked, 2, reason: name);
        expect(find.byKey(const ValueKey('admin-access-failed')), findsNothing, reason: name);
        expect(find.byKey(ValueKey('admin-$name-submit')), findsOneWidget, reason: name);
      }
    });

    testWidgets('a read-only account still gets the form without the button, and no failure', (tester) async {
      final forum = FakeAdminForum({
        'GET:adminban': [adminFixture('ban_member')],
      });
      await _pump(
        tester,
        AdminBanPage(
          repository: forum.repository(),
          initialMember: '99',
          adminAccess: () async => AdminAccess.fromJson(adminFixture('admin_read_only')),
        ),
      );
      expect(find.byKey(const ValueKey('admin-access-failed')), findsNothing);
      expect(find.byKey(const ValueKey('admin-ban-reason')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-ban-submit')), findsNothing);
    });
  });

  group("the panel's counts", () {
    setUp(PanelToolsAccess.reset);

    testWidgets("asking the panel's password: its login where the counts go, then the counts", (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var loggedIn = false;
      final posted = <(String, Map<String, String>)>[];
      final login = jsonDecode(
        jsonEncode(
          _fixture390('modcp_report_login'),
        ).replaceAll('"uid":34', '"uid":33').replaceAll("discuz_uid = '34'", "discuz_uid = '33'"),
      );
      Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async => right((
        statusCode: 200,
        data: url.contains('tsdmapp=json')
            ? (loggedIn
                  ? {
                      ..._fixture390('modcp_home'),
                      'counts': {'moderate': 4, 'notes': 2, 'forums': 20},
                    }
                  : login)
            : "<script>var discuz_uid = '33';</script>",
      ));
      Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async {
        posted.add((url, body));
        loggedIn = true;
        return right((statusCode: 302, data: null));
      }

      final panel = ModcpRepository(get: get, post: post, currentUid: () => 33);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: ModeratorPanelPage(
              repository: panel,
              staffTools: () async => (grant: false, issue: false),
              panelTools: () async => (background: false, modcpReport: false),
              modcpPages: () async => {'home'},
              pagesRepository: ModcpPagesRepository(panel: panel, get: get, post: post, currentUid: () => 33),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-home-summary')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-home-login')), findsOneWidget);
      expect(find.text(t.modcpPages.unlock), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('modcp-home-login')));
      await tester.pumpAndSettle();
      expect(find.byType(ModeratePanelLoginView), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'secret');
      await tester.tap(find.widgetWithText(FilledButton, t.general.ok));
      await tester.pumpAndSettle();

      expect(posted.single.$2['cppwd'], 'secret');
      expect(find.byType(ModeratePanelLoginView), findsNothing);
      expect(find.byKey(const ValueKey('modcp-home-login')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-home-summary')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('modcp-count-moderate')), matching: find.text('4')),
        findsOne,
      );
    });
  });

  group('sending backgrounds', () {
    for (final (name, success) in [('bggrant_result_success', true), ('bggrant_result_noperm', false)]) {
      testWidgets('after $name the members are ${success ? 'cleared' : 'kept'}; the rest stays', (tester) async {
        final posted = <Map<String, String>>[];
        final repo = BackgroundGrantRepository(
          ask: (_) async {
            final json = _fixture390('bggrant_can');
            return {
              ...json,
              'backgrounds': [
                for (final b in json['backgrounds'] as List) {...(b as Map<String, dynamic>)}..remove('image'),
              ],
            };
          },
          post: (_, data) async {
            posted.add(data);
            return _fixture390(name);
          },
          currentUid: () => 31,
        );
        await _pump(tester, BackgroundGrantPage(repository: repo, initialMembers: '35'));
        TextEditingController field(String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;
        await tester.tap(find.byKey(const ValueKey('bggrant-item-2')));
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('bggrant-expiry')), '2026-12-31');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('bggrant-send')));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
        await tester.pumpAndSettle();

        expect(posted, hasLength(1));
        // The plugin's words shown as they are, either way.
        expect(find.textContaining(_fixture390(name)['message'] as String), findsOneWidget);
        expect(field('bggrant-members').text, success ? isEmpty : '35');
        expect(field('bggrant-image').text, '1209-2.jpg');
        expect(field('bggrant-expiry').text, '2026-12-31');
      });
    }
  });
}
