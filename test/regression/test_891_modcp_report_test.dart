/// Handling reports on the moderation panel (tsdmapp 3.9.0 `modcp_report`, `schema` 28): the forums to choose from, a
/// forum's reports (each opens the floor reported, `tid` may be 0), the panel's own form posted back as the answer
/// describes it (the ids indexed, each reporter as listed, the reward and the message only when the forum sets a
/// reward), done only on `modcp_report_success`, the panel's login asked and its refusals in its words.
///
/// The answers are the test forum's (scrubbed); the write results are shaped as the spec gives them (handling is left
/// to the emulator check).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/features/report_handling/models/report_handling.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/report_handling/view/report_handling_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The fid 25 page served to [uid] with a second report of two reporters.
Map<String, dynamic> _twoReports({int uid = 33}) {
  final json = _fixture('modcp_report_fid25');
  final first = (json['reports'] as List).first as Map<String, dynamic>;
  return {
    ...json,
    'uid': uid,
    'count': 2,
    'reports': [
      first,
      {
        ...first,
        'id': 13,
        'url': 'forum.php?mod=viewthread&tid=9203005',
        'tid': 9203005,
        'pid': 0,
        'message': 'ag_t01 : 广告\nag_t02 : 灌水',
        'uid': 37,
        'username': 'ag_t01',
        'num': 2,
      },
    ],
  };
}

/// A source answering [answer] for each url asked and [reply] for a post, recording both.
ModcpReportSource _source({
  Object? Function(String url)? answer,
  Object? reply,
  List<String>? asked,
  List<(String, Map<String, String>)>? posted,
  int Function()? uid,
}) {
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async {
    asked?.add(url);
    return right((statusCode: 200, data: answer == null ? _twoReports() : answer(url)));
  }

  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async {
    posted?.add((url, body));
    return right((statusCode: 200, data: reply ?? _fixture('modcp_report_result_success')));
  }

  return ModcpReportSource(
    panel: ModcpRepository(get: get, post: post, currentUid: uid ?? () => 33),
    get: get,
    post: post,
    currentUid: uid ?? () => 33,
  );
}

ModcpReportList _list(Map<String, dynamic> json) => modcpReportFromApi(json)!;

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: home),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('answer', () {
    test('without a forum: the forums to choose from, nothing listed', () {
      final list = _list(_fixture('modcp_report_need_forum'));
      expect(list.uid, 70);
      expect(list.needScope, isTrue);
      expect(list.scopes, [(key: '2', label: '公告与新手报到'), (key: '9', label: '手游情报站'), (key: '25', label: '周边交易区')]);
      expect(list.items, isEmpty);
      expect(list.reward, isNull);
      expect(list.form, isNull);
      expect(list.canResolve, isFalse);
    });

    test("a forum's reports, the reward and the form", () {
      final list = _list(_fixture('modcp_report_fid25'));
      expect(list.needScope, isFalse);
      expect((list.fid, list.scope, list.scopeLabel), (25, '25', '周邊交易區'));
      expect((list.page, list.pages, list.count), (1, 1, 1));
      final item = list.items.single;
      expect((item.id, item.tid, item.pid, item.uid, item.username, item.count), (1, 0, 3138, 35, 'ag_low2', 1));
      expect(item.lines, ['ag_low2 : notify 檢舉理由（rep_1789171425534）']);
      expect(item.absoluteUrl, '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=0&pid=3138');
      final reward = list.reward!;
      expect((reward.creditTitle, reward.min, reward.max), ('天使币', -3, 3));
      expect(reward.options, [3, 2, 1, 0, -1, -2, -3]);
      expect(list.form!.url, '$baseUrl/forum.php?mod=modcp&action=report&fid=25');
      expect(list.form!.fields, {'formhash': 'f1f2f3f4', 'reportsubmit': 'true'});
      expect(list.canResolve, isTrue);
      expect(_list(_fixture('modcp_report_empty')).items, isEmpty);
    });

    test('several reporters one a line', () {
      final item = _list(_twoReports()).items.last;
      expect(item.lines, ['ag_t01 : 广告', 'ag_t02 : 灌水']);
      expect((item.tid, item.pid, item.count), (9203005, 0, 2));
    });

    test('no reward when the forum sets none', () {
      expect(ReportReward.fromJson({'enabled': 0, 'min': 0, 'max': 0}), isNull);
      expect(ReportReward.fromJson({'enabled': 1, 'min': 2, 'max': 2}), isNull);
      expect(ReportReward.fromJson(null), isNull);
      expect(ReportReward.fromJson({'enabled': 1, 'min': -1, 'max': 2})!.options, [2, 1, 0, -1]);
      // A wide range without options is stepped as the forum's select, about ten values.
      expect(
        ReportReward.fromJson({'enabled': 1, 'min': -100, 'max': 100})!.options,
        [100, 80, 60, 40, 20, 0, -20, -40, -60, -80, -100],
      );
      expect(ReportReward.fromJson({'enabled': 1, 'min': -10, 'max': 15})!.options.last, -10);
    });

    test('a form posting anywhere else, or of another shape, is never used', () {
      final submit = _fixture('modcp_report_fid25')['submit'] as Map<String, dynamic>;
      expect(ModcpReportForm.parse(submit, fid: 25), isNotNull);
      expect(ModcpReportForm.parse(submit, fid: 2), isNull);
      for (final bad in [
        {'url': 'https://evil.test/forum.php?mod=modcp&action=report&fid=25'},
        {'url': 'forum.php?mod=modcp&action=moderate&fid=25'},
        {'url': 'forum.php?mod=modcp&action=report&fid=25&op=delete'},
        {'url': 'plugin.php?mod=modcp&action=report&fid=25'},
        {'ids_field': 'reportids'},
        {'uid_field': 'reportuids[]'},
        {'credit_field': 'creditsvalue[{id}][x]'},
        {'fields': 'formhash'},
      ]) {
        expect(ModcpReportForm.parse({...submit, ...bad}, fid: 25), isNull, reason: '$bad');
      }
    });

    test('the fixed fields never carry the ones the app fills', () {
      final submit = _fixture('modcp_report_fid25')['submit'] as Map<String, dynamic>;
      final form = ModcpReportForm.parse({
        ...submit,
        'fields': {
          ...submit['fields'] as Map<String, dynamic>,
          'creditsvalue[1]': '3',
          'msg[1]': 'x',
          'reportids[]': '9',
          'reportuids[9]': '1',
        },
      }, fid: 25)!;
      expect(form.fields, {'formhash': 'f1f2f3f4', 'reportsubmit': 'true'});
    });

    test('the body: ids indexed, each reporter as listed, reward and message only when set', () {
      final list = _list(_twoReports());
      final [a, b] = list.items;
      final decisions = <ReportDecision>[(item: a, credit: 2, message: ' 谢谢 '), (item: b, credit: 0, message: '')];
      expect(list.form!.body(decisions, withReward: true), {
        'formhash': 'f1f2f3f4',
        'reportsubmit': 'true',
        'reportids[0]': '1',
        'reportuids[1]': '35',
        'creditsvalue[1]': '2',
        'msg[1]': '谢谢',
        'reportids[1]': '13',
        'reportuids[13]': '37',
      });
      expect(list.form!.body(decisions, withReward: false), {
        'formhash': 'f1f2f3f4',
        'reportsubmit': 'true',
        'reportids[0]': '1',
        'reportuids[1]': '35',
        'reportids[1]': '13',
        'reportuids[13]': '37',
      });
    });
  });

  group('source', () {
    test('asks the panel page in the JSON mode, the forum and the page when given', () async {
      final asked = <String>[];
      final source = _source(asked: asked);
      await source.load();
      await source.load(scope: '25', page: 2);
      expect(asked, [
        '$baseUrl/forum.php?mod=modcp&action=report&tsdmapp=json&nodoc=1',
        '$baseUrl/forum.php?mod=modcp&action=report&fid=25&page=2&tsdmapp=json&nodoc=1',
      ]);
    });

    test("the panel's login, its refusals, another account", () {
      expect(
        ModcpReportSource.answerOf(_fixture('modcp_report_login'), uid: 34),
        isA<Right<AppException, ReportAnswer>>().having(
          (r) => r.value,
          'value',
          isA<ReportNeedsLogin>().having((n) => n.token, 'token', 'f1f2f3f4'),
        ),
      );
      expect(
        ModcpReportSource.answerOf(_fixture('modcp_report_noaccess'), uid: 31).getRight().toNullable(),
        isA<ReportRefused>().having((r) => r.message, 'message', '抱歉，您没有权限访问管理面板，请重新登录站点，然后重试'),
      );
      expect(
        ModcpReportSource.answerOf(_fixture('modcp_report_guest'), uid: 0).getRight().toNullable(),
        isA<ReportRefused>().having((r) => r.message, 'message', '您需要先登录才能继续本操作'),
      );
      expect(
        ModcpReportSource.answerOf(_fixture('modcp_report_fid25'), uid: 70).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
      expect(
        ModcpReportSource.answerOf(_fixture('modcp_report_login'), uid: 33).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
      expect(ModcpReportSource.answerOf('<html></html>', uid: 33).isLeft(), isTrue);
      // The forum's login ended under the same account: its prompt, not "account changed".
      expect(
        ModcpReportSource.answerOf(_fixture('modcp_report_guest'), uid: 33).getRight().toNullable(),
        isA<ReportRefused>().having((r) => r.message, 'message', '您需要先登录才能继续本操作'),
      );
    });

    test('done only on modcp_report_success; a reward out of range, the session ended', () {
      expect(
        ModcpReportSource.outcomeOf(_fixture('modcp_report_result_success'), uid: 33).getRight().toNullable(),
        isA<ReportDone>().having((d) => d.message, 'message', '处理成功，现在返回管理面板'),
      );
      expect(
        ModcpReportSource.outcomeOf(_fixture('modcp_report_result_range'), uid: 33).getRight().toNullable(),
        isA<ReportNotDone>().having((d) => d.message, 'message', '您没有权限进行此操作'),
      );
      expect(
        ModcpReportSource.outcomeOf(_fixture('modcp_report_result_session'), uid: 33).getRight().toNullable(),
        isA<ReportSessionEnded>(),
      );
      final alike = {..._fixture('modcp_report_result_success'), 'message_key': 'modcp_report_other'};
      expect(ModcpReportSource.outcomeOf(alike, uid: 33).getRight().toNullable(), isA<ReportNotDone>());
      expect(
        ModcpReportSource.outcomeOf(_fixture('modcp_report_result_success'), uid: 34).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
      expect(ModcpReportSource.outcomeOf('<html></html>', uid: 33).getRight().toNullable(), isA<ReportUnknown>());
      final loggedOut = {
        ..._fixture('modcp_report_result_range'),
        'uid': 0,
        'login': 1,
        'message': '您需要先登录才能继续本操作',
        'message_key': 'to_login',
      };
      expect(
        ModcpReportSource.outcomeOf(loggedOut, uid: 33).getRight().toNullable(),
        isA<ReportNotDone>().having((d) => d.message, 'message', '您需要先登录才能继续本操作'),
      );
    });

    test('posts the form once; never once the account changed', () async {
      final posted = <(String, Map<String, String>)>[];
      final list = _list(_twoReports());
      final decision = <ReportDecision>[(item: list.items.first, credit: 1, message: '')];
      final done = await _source(posted: posted).resolve(list, decision);
      expect(done.getRight().toNullable(), isA<ReportDone>());
      expect(posted.single.$1, list.form!.url);
      expect(posted.single.$2['creditsvalue[1]'], '1');

      final changed = await _source(posted: posted, uid: () => 34).resolve(list, decision);
      expect(changed.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(posted.length, 1);
    });
  });

  group('page', () {
    testWidgets('choose a forum, pick reports with reward and message, confirm, handle', (tester) async {
      final asked = <String>[];
      final posted = <(String, Map<String, String>)>[];
      await _pump(
        tester,
        ReportHandlingPage(
          source: _source(
            asked: asked,
            posted: posted,
            answer: (url) =>
                url.contains('fid=25') ? _twoReports() : {..._fixture('modcp_report_need_forum'), 'uid': 33},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('report-scope-25')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('report-scope-25')));
      await tester.pumpAndSettle();
      expect(asked.last, contains('fid=25'));
      expect(find.byKey(const ValueKey('report-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-13')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-switch-scope')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-resolve')), findsNothing);
      expect(find.byKey(const ValueKey('report-credit-1')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('report-pick-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-pick-13')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-credit-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('report-credit-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('天使币 -2').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('report-message-1')), '已核实');

      await tester.tap(find.byKey(const ValueKey('report-resolve')));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('ag_low2 · 天使币 -2')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('ag_t01')), findsOneWidget);
      await tester.tap(find.descendant(of: dialog, matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();

      expect(posted.single.$1, '$baseUrl/forum.php?mod=modcp&action=report&fid=25');
      expect(posted.single.$2, {
        'formhash': 'f1f2f3f4',
        'reportsubmit': 'true',
        'reportids[0]': '1',
        'reportuids[1]': '35',
        'creditsvalue[1]': '-2',
        'msg[1]': '已核实',
        'reportids[1]': '13',
        'reportuids[13]': '37',
      });
      expect(find.text('处理成功，现在返回管理面板'), findsOneWidget);
      // Read again after handling; the choices are cleared.
      expect(asked.last, contains('fid=25'));
      expect(find.byKey(const ValueKey('report-resolve')), findsNothing);
    });

    testWidgets('the only forum is chosen right away; no reward fields when none is set', (tester) async {
      final noReward = {
        ..._twoReports(),
        'reward': {'enabled': 0, 'credit': null, 'min': 0, 'max': 0, 'options': <int>[]},
        'forums': [
          {'fid': 25, 'name': '周边交易区'},
        ],
      };
      final asked = <String>[];
      await _pump(
        tester,
        ReportHandlingPage(
          source: _source(
            asked: asked,
            answer: (url) => url.contains('fid=25')
                ? noReward
                : {
                    ..._fixture('modcp_report_need_forum'),
                    'uid': 33,
                    'forums': [
                      {'fid': 25, 'name': '周边交易区'},
                    ],
                  },
          ),
        ),
      );
      expect(asked.length, 2);
      expect(find.byKey(const ValueKey('report-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-switch-scope')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('report-pick-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-resolve')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-credit-1')), findsNothing);
      expect(find.byKey(const ValueKey('report-message-1')), findsNothing);
    });

    testWidgets("the panel's login is asked; a refusal in its words", (tester) async {
      await _pump(
        tester,
        ReportHandlingPage(
          source: _source(uid: () => 34, answer: (_) => _fixture('modcp_report_login')),
        ),
      );
      expect(find.byType(ModeratePanelLoginView), findsOneWidget);
      await _pump(
        tester,
        ReportHandlingPage(
          key: UniqueKey(),
          source: _source(uid: () => 31, answer: (_) => _fixture('modcp_report_noaccess')),
        ),
      );
      expect(find.text('抱歉，您没有权限访问管理面板，请重新登录站点，然后重试'), findsOneWidget);
    });

    testWidgets('a report opens the floor reported, or the thread', (tester) async {
      final opened = <Map<String, String>>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => ReportHandlingPage(source: _source()),
          ),
          GoRoute(
            path: '/thread/v1',
            name: ScreenPaths.threadV1,
            builder: (_, s) {
              opened.add(s.uri.queryParameters);
              return const Scaffold(body: Text('thread'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();
      // The test page lists fid 25 straight away (the source answers it for any url).
      await tester.tap(find.text('ag_low2 : notify 檢舉理由（rep_1789171425534）'));
      await tester.pumpAndSettle();
      expect(opened.last, {'pid': '3138', 'overrideReverseOrder': 'false'});
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('ag_t02 : 灌水'));
      await tester.pumpAndSettle();
      expect(opened.last, {'tid': '9203005'});
    });
  });
}
