/// The reports of the whole forum for an administrator (tsdmapp 3.9.0 `adminreport`, `schema` 29, spec §5.2 and §9):
/// the reports waiting and handled as two tabs, handled (`op=resolve`: ids indexed, each reporter's reward and message
/// only when the forum sets a reward) and deleted (`op=delete`) with the admin token and an `opid` kept while the same
/// write is sent again; `duplicate` is done; a read-only admin gets no picking. The page offers the whole forum first
/// beside the panel's one forum at a time, and a report whose thread or floor is not known shows its address and opens
/// it only once confirmed. A read-only admin of the reports gets the entry on the panel.
///
/// The lists are the test forum's (scrubbed); it had no report handled yet, so the handled list is the waiting one
/// shaped as the spec writes `op=resolved`; the write answers are shaped as the spec gives them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/report_handling/models/report_handling.dart';
import 'package:tsdm_client/features/report_handling/repository/admin_report_source.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/report_handling/view/admin_report_page.dart';
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

/// The test forum's administrator (uid 32) with the lists.
FakeAdminForum _forum([Map<String, List<Object?>> more = const {}]) => FakeAdminForum({
  'GET:admin': [adminFixture('admin_founder')],
  'GET:adminreport': [
    (AdminRequest r) => adminFixture(r.data['op'] == 'resolved' ? 'report_resolved' : 'report_new'),
  ],
  ...more,
})..uid = 32;

/// An admin error answered to the administrator (uid 32).
Map<String, dynamic> _error(String code, [Map<String, Object?> extra = const {}]) =>
    adminError(code, extra)..['uid'] = 32;

AdminReportList _list(String name, {bool writable = true}) =>
    adminReportFromApi(adminFixture(name), writable: writable, scopes: AdminReportSource.scopes)!;

/// A source of the panel answering one forum's empty list.
final class _PanelSource implements ReportSource {
  int loads = 0;

  @override
  Future<Either<AppException, ReportAnswer>> load({String scope = '', int page = 1}) async {
    loads++;
    return right(
      const ReportReady(
        ReportList(
          uid: 32,
          scopes: [(key: '2', label: 'forum 2')],
          scope: '2',
          scopeLabel: 'forum 2',
          needScope: false,
          page: 1,
          pages: 1,
          count: 0,
          items: [],
        ),
      ),
    );
  }

  @override
  Future<Either<AppException, ReportOutcome>> resolve(ReportList list, List<ReportDecision> decisions) async =>
      right(const ReportNotDone(''));

  @override
  Future<Either<AppException, ReportOutcome>> delete(ReportList list, List<ReportItem> items) async =>
      right(const ReportNotDone(''));

  @override
  Widget loginView(ReportNeedsLogin need, Future<void> Function() onLoggedIn) => const SizedBox.shrink();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(AdminAccessCache.reset);

  group('answer', () {
    test('the reports waiting of the whole forum: forums or none, addresses, the reward, the message limit', () {
      final list = _list('report_new');
      expect((list.uid, list.scope, list.page, list.pages, list.count), (32, 'new', 1, 1, 9));
      expect(list.items, hasLength(9));
      expect((list.canResolve, list.canDelete, list.scopeTabs, list.resolved), (true, true, true, false));
      expect(list.messageMax, 100);
      expect(list.reward!.options, [3, 2, 1, 0, -1, -2, -3]);

      final member = list.items.firstWhere((i) => i.id == 171);
      expect((member.tid, member.pid, member.fid, member.opensInApp), (0, 0, 0, false));
      expect(member.link.toString(), '$baseUrl/home.php?mod=space&uid=102');
      expect(member.linkIsForum, isTrue);
      final floor = list.items.firstWhere((i) => i.id == 168);
      expect(
        (floor.tid, floor.pid, floor.opensInApp, floor.excerpt),
        (9203112, 15265, true, 'tsdmapp390 spam reply a'),
      );
      expect(list.items.every((i) => i.resolution == null), isTrue);

      final outside = reportItemFromApi({'id': 1, 'url': 'https://example.com/x', 'tid': 0, 'pid': 0});
      expect((outside.opensInApp, outside.linkIsForum, outside.absoluteUrl), (false, false, null));
      expect(reportItemFromApi({'id': 2, 'url': 'javascript:alert(1)'}).link, isNull);
    });

    test('the reports handled: who, when, the reward; deleted only', () {
      final list = _list('report_resolved');
      expect((list.scope, list.resolved, list.canResolve, list.canDelete), ('resolved', true, false, true));
      final credit = list.items.first.resolution!;
      expect((credit.operator, credit.time, credit.value, credit.creditTitle), ('ag_admin', 1700000300, 2, '天使币'));
      expect(list.items.last.resolution!.value, 0);

      final readOnly = _list('report_new', writable: false);
      expect((readOnly.canResolve, readOnly.canDelete), (false, false));
      expect(adminReportFromApi(adminFixture('admin_login_needed'), writable: true, scopes: const []), isNull);
    });
  });

  group('source', () {
    test('the lists are asked with the token, by op and page', () async {
      final forum = _forum();
      forum.session.keep(32, 'tok-0000');
      final source = AdminReportSource(repository: forum.repository(), writable: true);
      await source.load();
      await source.load(scope: 'resolved', page: 2);
      expect(forum.of('adminreport').map((r) => r.data), [
        {'op': 'new'},
        {'op': 'resolved', 'page': '2'},
      ]);
      expect(forum.of('adminreport').first.headers, {adminTokenHeader: 'tok-0000'});
      final refused = AdminReportSource.answerOf(
        AdminReply(adminError('admin_noperm', {'why': 'perm'})),
        writable: true,
      );
      expect(refused.getRight().toNullable(), isA<ReportRefused>());
    });

    test('handling: ids indexed, reward and message when set, one opid while sent again', () async {
      final forum = _forum({
        'POST:adminreport': [
          null,
          _error('busy', {'retry_after': 3}),
          {
            'ok': 1,
            'uid': 32,
            'type': 'adminreport',
            'schema': 29,
            'op': 'resolve',
            'resolved': [168],
            'skipped': [167],
          },
          {
            'ok': 1,
            'uid': 32,
            'type': 'adminreport',
            'schema': 29,
            'op': 'resolve',
            'resolved': [168],
            'skipped': <int>[],
          },
          _error('duplicate'),
        ],
      });
      final source = AdminReportSource(repository: forum.repository(), writable: true);
      final list = _list('report_new');
      ReportItem item(int id) => list.items.firstWhere((i) => i.id == id);
      final decisions = <ReportDecision>[
        (item: item(168), credit: 2, message: ' 谢谢 '),
        (item: item(167), credit: 0, message: ''),
      ];
      expect((await source.resolve(list, decisions)).getRight().toNullable(), isA<ReportUnknown>());
      expect((await source.resolve(list, decisions)).getRight().toNullable(), isA<ReportNotDone>());
      final done = (await source.resolve(list, decisions)).getRight().toNullable();
      expect(done, isA<ReportDone>());
      final posts = forum.of('adminreport', 'POST');
      expect(posts.first.data, {
        'op': 'resolve',
        'ids[0]': '168',
        'credits[168]': '2',
        'msg[168]': '谢谢',
        'ids[1]': '167',
        'opid': posts.first.data['opid'],
        'formhash': 'f1f2f3f4',
      });
      expect(posts.map((r) => r.data['opid']).toSet(), hasLength(1), reason: 'failed, busy: the same write');
      expect(posts.first.data['opid'], matches(RegExp(r'^[0-9a-f-]{36}$')));

      await source.resolve(list, decisions);
      final again = forum.of('adminreport', 'POST').last.data['opid'];
      expect(again, isNot(posts.first.data['opid']), reason: 'answered: the next one is another write');
      // The same write the forum did already.
      expect((await source.resolve(list, decisions)).getRight().toNullable(), isA<ReportDone>());

      // No reward set: no reward sent, the message still (the admin API takes it alone).
      expect(AdminReportSource.resolveForm(decisions, withReward: false), {
        'op': 'resolve',
        'ids[0]': '168',
        'msg[168]': '谢谢',
        'ids[1]': '167',
      });
      // An answer without the ids is done all the same.
      expect(
        AdminReportSource.outcomeOf(const AdminReply({'ok': 1, 'uid': 32}), op: 'delete', count: 2),
        isA<ReportDone>(),
      );
      // Read-only: nothing sent.
      final readOnly = AdminReportSource(repository: forum.repository(), writable: false);
      final sent = forum.requests.length;
      expect(
        (await readOnly.resolve(_list('report_new', writable: false), decisions)).getRight().toNullable(),
        isA<ReportNotDone>(),
      );
      expect(forum.requests, hasLength(sent));
    });

    test('deleting: op=delete with the ids; another account is never sent', () async {
      final forum = _forum({
        'POST:adminreport': [
          {
            'ok': 1,
            'uid': 32,
            'type': 'adminreport',
            'op': 'delete',
            'deleted': [171, 170],
          },
        ],
      });
      final source = AdminReportSource(repository: forum.repository(), writable: true);
      final list = _list('report_resolved');
      final outcome = await source.delete(list, list.items);
      expect(outcome.getRight().toNullable(), isA<ReportDone>());
      expect(forum.of('adminreport', 'POST').single.data, {
        'op': 'delete',
        'ids[0]': '${list.items[0].id}',
        'ids[1]': '${list.items[1].id}',
        'opid': forum.of('adminreport', 'POST').single.data['opid'],
        'formhash': 'f1f2f3f4',
      });
      forum.uid = 35;
      expect((await source.delete(list, list.items)).getLeft().toNullable(), isA<IdentityChangedException>());
      expect(forum.of('adminreport', 'POST'), hasLength(1));
    });
  });

  group('page', () {
    testWidgets('waiting and handled as tabs; handled ones show how, may be deleted, not handled again', (
      tester,
    ) async {
      final forum = _forum({
        'POST:adminreport': [
          {
            'ok': 1,
            'uid': 32,
            'type': 'adminreport',
            'op': 'delete',
            'deleted': [169],
          },
        ],
      });
      await _pump(tester, AdminReportPage(repository: forum.repository(), writable: true));
      expect(find.byKey(const ValueKey('report-tabs')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-source')), findsNothing);
      expect(find.byKey(const ValueKey('report-171')), findsOneWidget);
      await tester.tap(find.text(t.reportHandling.handled));
      await tester.pumpAndSettle();
      expect(forum.of('adminreport', 'GET').last.data, {'op': 'resolved'});
      expect(find.byKey(const ValueKey('report-resolution-169')), findsOneWidget);
      expect(find.textContaining('ag_admin'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('report-pick-169')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-resolve')), findsNothing);
      expect(find.byKey(const ValueKey('report-credit-169')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('report-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.reportHandling.delete(n: 1)));
      await tester.pumpAndSettle();
      expect(forum.of('adminreport', 'POST').single.data['op'], 'delete');
      expect(forum.of('adminreport', 'POST').single.data['ids[0]'], '169');
      expect(find.text(t.reportHandling.deleted(n: 1)), findsOneWidget);
      expect(forum.of('adminreport', 'GET').last.data, {'op': 'resolved'}, reason: 'the handled list read again');
    });

    testWidgets('handling a waiting one: reward and message, the forum range told on refusal', (tester) async {
      final forum = _forum({
        'POST:adminreport': [
          _error('credits', {'min': -3, 'max': 3}),
        ],
      });
      await _pump(tester, AdminReportPage(repository: forum.repository(), writable: true));
      await tester.tap(find.byKey(const ValueKey('report-pick-168')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-credit-168')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('report-message-168')), 'x' * 150);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('report-message-168'))).controller!.text,
        hasLength(100),
      );
      await tester.tap(find.byKey(const ValueKey('report-resolve')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.reportHandling.resolve(n: 1)).last);
      await tester.pumpAndSettle();
      expect(forum.of('adminreport', 'POST').single.data['ids[0]'], '168');
      expect(find.text(t.reportHandling.errorCredits(min: -3, max: 3)), findsOneWidget);
    });

    testWidgets('no reward set: a message alone to a waiting one, shown in the confirmation; none when handled', (
      tester,
    ) async {
      Map<String, dynamic> noReward(String name) =>
          adminFixture(name)..['reward'] = {'enabled': 0, 'credit': null, 'min': 0, 'max': 0, 'options': <int>[]};
      final forum = _forum({
        'GET:adminreport': [
          (AdminRequest r) => noReward(r.data['op'] == 'resolved' ? 'report_resolved' : 'report_new'),
        ],
        'POST:adminreport': [
          {
            'ok': 1,
            'uid': 32,
            'type': 'adminreport',
            'op': 'resolve',
            'resolved': [168],
            'skipped': <int>[],
          },
        ],
      });
      await _pump(tester, AdminReportPage(repository: forum.repository(), writable: true));
      await tester.tap(find.byKey(const ValueKey('report-pick-168')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-credit-168')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('report-message-168')), '已处理');
      await tester.tap(find.byKey(const ValueKey('report-resolve')));
      await tester.pumpAndSettle();
      expect(find.text('ag_t01 · 已处理'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, t.reportHandling.resolve(n: 1)).last);
      await tester.pumpAndSettle();
      final sent = forum.of('adminreport', 'POST').single.data;
      expect((sent['ids[0]'], sent['msg[168]'], sent.containsKey('credits[168]')), ('168', '已处理', false));

      await tester.tap(find.text(t.reportHandling.handled));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-pick-169')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-message-169')), findsNothing);
    });

    testWidgets('read-only: listed, nothing to pick', (tester) async {
      final forum = _forum();
      await _pump(tester, AdminReportPage(repository: forum.repository(), writable: false));
      expect(find.byKey(const ValueKey('report-171')), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('report-pick-171'))).onChanged, isNull);
    });

    testWidgets('an address the reporter wrote is shown and opened only once confirmed', (tester) async {
      final forum = _forum();
      await _pump(tester, AdminReportPage(repository: forum.repository(), writable: true));
      expect(find.byKey(const ValueKey('report-link-171')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-link-168')), findsNothing, reason: 'a floor opens in the app');
      await tester.tap(find.byKey(const ValueKey('report-171')));
      await tester.pumpAndSettle();
      expect(find.text(t.reportHandling.openLink), findsOneWidget);
      expect(find.text('$baseUrl/home.php?mod=space&uid=102'), findsWidgets);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(find.text(t.reportHandling.openLink), findsNothing);
    });

    testWidgets('the whole forum first, the panel beside it', (tester) async {
      final forum = _forum();
      final panel = _PanelSource();
      await _pump(tester, AdminReportPage(repository: forum.repository(), writable: true, panel: panel));
      expect(find.byKey(const ValueKey('report-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-171')), findsOneWidget);
      expect(panel.loads, 0);
      await tester.tap(find.text(t.reportHandling.byForum));
      await tester.pumpAndSettle();
      expect(panel.loads, 1);
      expect(find.byKey(const ValueKey('report-171')), findsNothing);
      expect(find.byKey(const ValueKey('report-tabs')), findsNothing);
      await tester.tap(find.text(t.reportHandling.wholeForum));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-171')), findsOneWidget);
      expect(forum.of('adminreport', 'GET'), hasLength(2));
    });

    testWidgets('the panel offers it to a read-only admin of the reports', (tester) async {
      final forum = _forum();
      await _pump(
        tester,
        ModeratorPanelPage(
          staffTools: () async => null,
          panelTools: () async => null,
          adminAccess: () async => AdminAccess.fromJson(adminFixture('admin_report_only')),
          adminRepository: forum.repository(),
        ),
      );
      expect(find.byKey(const ValueKey('modcp-admin-ban')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('modcp-report')));
      await tester.pumpAndSettle();
      expect(find.byType(AdminReportPage), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('report-pick-171'))).onChanged, isNull);
    });
  });
}
