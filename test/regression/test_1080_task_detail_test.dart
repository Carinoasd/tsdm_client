/// A task's page from the forum's app API (plugin 4.0.0: `type: task`, schema 66; `task_parter`, schema 67) and its
/// give-up (`do=delete`, a GET that writes).
///
/// * The page is only asked once `status` lists `task` in `task_pages`; without it the cards open nothing and nothing
///   is asked (the app has no web parser for the page).
/// * The buttons follow the page's `state` and urls; the urls sent are built from the task's id, never the answer's.
/// * The give-up is sent once, only after the confirmation, without `inajax`; only `task_deleted` counts.
/// * Another account's answers are dropped.
///
/// Fixtures: the test forum's pages (cleaned); the write results are the plugin's shape (spec 7.4), not sent to the
/// test forum (they write).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/task_center/cubit/task_center_cubit.dart';
import 'package:tsdm_client/features/task_center/cubit/task_detail_cubit.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/models/task_detail.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/features/task_center/view/task_detail_page.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// The task being done: the recorded completed page turned into the spec's in-progress one.
Map<String, dynamic> _doing({num csc = 40}) => v4Json('task_view_v66_done.json')
  ..['state'] = -1
  ..['csc'] = csc
  ..['dateline'] = 0
  ..['draw_url'] = 'home.php?mod=task&do=draw&id=2'
  ..['delete_url'] = csc < 100 ? 'home.php?mod=task&do=delete&id=2' : '';

Map<String, dynamic> _result(String key, {String message = '', int ok = 1, int uid = _uid}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': uid,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'message',
  'message': message,
  'message_key': key,
  'url': 'home.php?mod=task&do=view&id=2',
  'handlekey': '',
  'values': <String, Object>{},
  'login': 0,
  'alert': ok == 1 ? 'info' : 'error',
};

final class _Harness {
  _Harness({Object? page, this.parter, this.write}) : page = page ?? _doing();

  Object? page;
  Object? parter;
  Object? write;
  final pages = <String>[];
  final writes = <String>[];
  final webPages = <String>[];

  TaskCenterRepository repository() => TaskCenterRepository(
    getPage: (url) async {
      webPages.add(url);
      return '';
    },
    getWrite: (url) async {
      webPages.add(url);
      return (data: null, location: null);
    },
    getV4Page: (url) async {
      pages.add(url);
      if (url.contains('do=parter')) return parter;
      if (url.contains('do=view')) return page;
      return v4Json('task_list_v65_new.json');
    },
    getV4Write: (url) async {
      writes.add(url);
      return write;
    },
  );
}

void main() {
  setUpAll(() async {
    registerV4TestServices();
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('page (task, schema 66)', () {
    test('a completed task: when, no buttons, the members who applied', () {
      final detail = taskDetailFromApi(v4Json('task_view_v66_done.json'));
      expect(detail.id, 2);
      expect(detail.name, '回复三次');
      expect(detail.descriptionHtml, isNotEmpty);
      expect(detail.reward, '勋章 活跃会员');
      expect(detail.conditionHtml, contains('3'));
      expect(detail.state, -5);
      expect(detail.time, isNotNull);
      expect(detail.progress, isNull);
      expect(detail.canApply || detail.canClaim || detail.canGiveUp, isFalse);
      expect(detail.hasParters, isTrue);
      expect(detail.applyLimited, isFalse);
      expect(detail.iconUrl, startsWith('https://forum.test/'));
    });

    test('in progress: the claim and the give-up while not complete', () {
      final doing = taskDetailFromApi(_doing());
      expect(doing.inProgress, isTrue);
      expect(doing.progress, 40);
      expect(doing.canClaim, isTrue);
      expect(doing.canGiveUp, isTrue);
      expect(doing.canApply, isFalse);
      final complete = taskDetailFromApi(_doing(csc: 100));
      expect(complete.canClaim, isTrue);
      expect(complete.canGiveUp, isFalse);
    });

    test('the conditions: group limit, staff, linked tasks, periods', () {
      final staff = taskDetailFromApi(v4Json('task_view_v66_grouplimit.json'));
      expect(staff.state, -2);
      expect(staff.perm, 'admin');
      expect(staff.applyLimited, isTrue);
      expect(staff.canApply, isFalse);
      final available = taskDetailFromApi(v4Json('task_view_v66_apply.json'));
      expect(available.state, 1);
      expect(available.canApply, isTrue);
      final linked = taskDetailFromApi(
        v4Json('task_view_v66_apply.json')
          ..['period'] = {'type': 2, 'value': 7}
          ..['endtime'] = 1700003600
          ..['condition_html'] = ''
          ..['conditions'] = [
            {'name': '回复次数', 'value': '3'},
          ]
          ..['apply_condition'] = {
            'groups': '字幕组',
            'perm': '',
            'related': {'taskid': 1, 'name': '新人红包', 'url': 'home.php?mod=task&do=view&id=1'},
            'exclusive': null,
            'limit': 5,
            'vars': <Object>[],
          },
      );
      expect(linked.period?.kind, TaskPeriodKind.weekday);
      expect(linked.period?.value, 7);
      expect(linked.endTime, isNotNull);
      expect(linked.conditions.single, (name: '回复次数', value: '3'));
      expect(linked.groups, '字幕组');
      expect(linked.related?.id, 1);
      expect(linked.limit, 5);
    });

    test('members who applied (task_parter, schema 67)', () {
      final parters = taskPartersFromApi(v4Json('task_parter_v67.json'));
      expect(parters.single.uid, 31);
      expect(parters.single.status, TaskParterStatus.done);
      expect(parters.single.avatarUrl, startsWith('https://forum.test/'));
    });
  });

  group('repository', () {
    test('without task in task_pages nothing is asked and the cards open nothing', () async {
      knowV4Status(
        v4Status({
          'task_pages': <String>['task_list'],
        }),
      );
      final h = _Harness();
      final repo = h.repository();
      expect(await repo.detailAvailable(), isFalse);
      await expectLater(repo.fetchDetail(2, _uid), throwsStateError);
      expect(h.pages, isEmpty);
      final cubit = TaskCenterCubit(currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load(TaskCenterTab.available);
      expect(cubit.state.detailAvailable, isFalse);
    });

    test('an old plugin: no task page', () async {
      knowV4Status(v4Status({'v4': null, 'task_pages': null}));
      final h = _Harness();
      expect(await h.repository().detailAvailable(), isFalse);
      final cubit = TaskCenterCubit(currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load(TaskCenterTab.available);
      expect(cubit.state.detailAvailable, isFalse);
      expect(h.pages.where((u) => u.contains('do=view')), isEmpty);
    });

    test('with it: the page and its members, asked as pages of 4.0.0', () async {
      knowV4Status();
      final h = _Harness(page: v4Json('task_view_v66_done.json'), parter: v4Json('task_parter_v67.json'));
      final cubit = TaskCenterCubit(currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load(TaskCenterTab.available);
      expect(cubit.state.detailAvailable, isTrue);
      final repo = h.repository();
      final detail = await repo.fetchDetail(2, _uid);
      expect(detail.id, 2);
      expect(h.pages.last, '$baseUrl/home.php?mod=task&do=view&id=2');
      expect((await repo.fetchParters(2, _uid)).single.username, 'ag_low2');
      expect(h.pages.last, '$baseUrl/home.php?mod=task&do=parter&id=2');
      expect(h.webPages, isEmpty);
    });

    test("the forum's message, another account, the login", () async {
      knowV4Status();
      final missing = _Harness(page: v4Json('task_view_nonexistence.json'));
      await expectLater(
        missing.repository().fetchDetail(99, _uid),
        throwsA(isA<TaskDetailMessage>().having((e) => e.message, 'message', '抱歉，该任务不存在或已被删除')),
      );
      final other = _Harness(page: v4Json('task_view_v66_done.json')..['uid'] = 77);
      await expectLater(
        other.repository().fetchDetail(2, _uid),
        throwsA(isA<TaskCenterIdentityException>().having((e) => e.guest, 'guest', isFalse)),
      );
      final guest = _Harness(
        page: {
          'ok': 0,
          'error': 'message',
          'message': '您需要先登录才能继续本操作',
          'login': 1,
          'uid': 0,
          'message_key': 'to_login',
        },
      );
      await expectLater(
        guest.repository().fetchDetail(2, _uid),
        throwsA(isA<TaskCenterIdentityException>().having((e) => e.guest, 'guest', isTrue)),
      );
      final otherTask = _Harness(page: v4Json('task_view_v66_done.json'));
      await expectLater(otherTask.repository().fetchDetail(3, _uid), throwsFormatException);
    });

    test('members of another account are refused; without task_parter none are asked', () async {
      knowV4Status(
        v4Status({
          'task_pages': <String>['task_list', 'task'],
        }),
      );
      final h = _Harness(parter: v4Json('task_parter_v67.json'));
      expect(await h.repository().fetchParters(2, _uid), isEmpty);
      expect(h.pages, isEmpty);
      knowV4Status();
      final other = _Harness(parter: v4Json('task_parter_v67.json')..['uid'] = 77);
      await expectLater(other.repository().fetchParters(2, _uid), throwsA(isA<TaskCenterIdentityException>()));
    });

    test('the give-up: its own url, only task_deleted counts', () async {
      knowV4Status();
      Future<TaskActionOutcome> giveUp(Object? answer) async {
        final h = _Harness(write: answer);
        final result = await h.repository().giveUp(2);
        expect(h.writes.single, '$baseUrl/home.php?mod=task&do=delete&id=2');
        expect(h.writes.single, isNot(contains('inajax')));
        return result.outcome;
      }

      expect(await giveUp(_result('task_deleted', message: '任务已放弃')), TaskActionOutcome.gaveUp);
      expect(
        await giveUp(_result('task_nonexistence', message: '抱歉，该任务不存在或已被删除', ok: 0)),
        TaskActionOutcome.refused,
      );
      // `ok` alone is not a give-up.
      expect(await giveUp(_result('task_applied', message: '申请成功')), TaskActionOutcome.refused);
      expect(await giveUp(_result('')), TaskActionOutcome.unconfirmed);
      expect(await giveUp(null), TaskActionOutcome.unconfirmed);
    });
  });

  group('cubit', () {
    test('acts once, only what the page offers, then loads the page again', () async {
      knowV4Status();
      final h = _Harness(write: _result('task_deleted', message: '任务已放弃'));
      final cubit = TaskDetailCubit(taskId: 2, currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.detail?.canGiveUp, isTrue);
      expect(cubit.canAct(TaskActionKind.apply), isFalse);
      await cubit.act(TaskActionKind.apply);
      expect(h.writes, isEmpty);
      h.page = v4Json('task_view_v66_apply.json')..['uid'] = _uid;
      final first = cubit.act(TaskActionKind.giveUp);
      // A second tap while the first is in flight sends nothing.
      await cubit.act(TaskActionKind.giveUp);
      await first;
      expect(h.writes, ['$baseUrl/home.php?mod=task&do=delete&id=2']);
      expect(cubit.state.result?.outcome, TaskActionOutcome.gaveUp);
      expect(cubit.state.acted, isTrue);
      expect(cubit.state.detail?.state, 1);
    });

    test('a failed request is not sent again', () async {
      knowV4Status();
      final h = _Harness();
      final cubit = TaskDetailCubit(
        taskId: 2,
        currentUid: () => _uid,
        repository: () => TaskCenterRepository(
          getPage: (_) async => '',
          getWrite: (_) async => (data: null, location: null),
          getV4Page: (url) async => h.page,
          getV4Write: (url) async {
            h.writes.add(url);
            throw StateError('offline');
          },
        ),
      );
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.act(TaskActionKind.giveUp);
      expect(h.writes, hasLength(1));
      expect(cubit.state.result?.outcome, TaskActionOutcome.unconfirmed);
    });

    test('a reload while a write is in flight waits for it; the result and the next write still go', () async {
      knowV4Status();
      final h = _Harness();
      final hold = Completer<Object?>();
      final cubit = TaskDetailCubit(
        taskId: 2,
        currentUid: () => _uid,
        repository: () => TaskCenterRepository(
          getPage: (_) async => '',
          getWrite: (_) async => (data: null, location: null),
          getV4Page: (url) async {
            h.pages.add(url);
            return h.page;
          },
          getV4Write: (url) async {
            h.writes.add(url);
            if (h.writes.length == 1) return hold.future;
            return _result('task_completed');
          },
        ),
      );
      addTearDown(cubit.close);
      await cubit.load();
      final pagesBefore = h.pages.length;
      final giving = cubit.act(TaskActionKind.giveUp);
      await cubit.load();
      expect(h.pages, hasLength(pagesBefore));
      expect(cubit.state.busy, TaskActionKind.giveUp);
      hold.complete(_result('task_nonexistence', message: '抱歉，该任务不存在或已被删除', ok: 0));
      await giving;
      expect(cubit.state.result?.outcome, TaskActionOutcome.refused);
      expect(cubit.state.acted, isTrue);
      expect(cubit.canAct(TaskActionKind.draw), isTrue);
      await cubit.act(TaskActionKind.draw);
      expect(h.writes, hasLength(2));
    });

    test('a write on a task opened from this one marks this one changed and loads it again', () async {
      knowV4Status();
      final h = _Harness();
      final cubit = TaskDetailCubit(taskId: 2, currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.acted, isFalse);
      final before = h.pages.length;
      await cubit.otherActed();
      expect(cubit.state.acted, isTrue);
      expect(h.pages.length, greaterThan(before));
    });

    test('no task id: nothing is asked', () async {
      knowV4Status();
      final h = _Harness();
      final cubit = TaskDetailCubit(taskId: 0, currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load();
      expect(h.pages, isEmpty);
      expect(cubit.state.failed, isTrue);
    });

    test("another account's completion is dropped", () async {
      knowV4Status();
      var uid = _uid;
      final h = _Harness();
      final cubit = TaskDetailCubit(taskId: 2, currentUid: () => uid, repository: h.repository);
      addTearDown(cubit.close);
      final loading = cubit.load();
      uid = 77;
      await loading;
      expect(cubit.state.detail, isNull);
    });
  });

  group('screen', () {
    Future<TaskDetailCubit> pump(WidgetTester tester, _Harness h) async {
      await LocaleSettings.setLocale(AppLocale.en);
      knowV4Status();
      final cubit = TaskDetailCubit(taskId: 2, currentUid: () => _uid, repository: h.repository);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: TaskDetailPage(
              taskId: 2,
              controller: cubit,
              htmlBuilder: Text.new,
              imageBuilder: (_, size) => SizedBox.square(dimension: size),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return cubit;
    }

    testWidgets('the give-up asks first and is sent only on yes', (tester) async {
      final h = _Harness(write: _result('task_deleted', message: '任务已放弃'));
      await pump(tester, h);
      expect(find.byKey(const ValueKey('task-detail-claim')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('task-detail-give-up')));
      await tester.pumpAndSettle();
      expect(h.writes, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, t.general.cancel));
      await tester.pumpAndSettle();
      expect(h.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('task-detail-give-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(h.writes, hasLength(1));
      expect(find.byKey(const ValueKey('task-detail-result')), findsOneWidget);
    });

    testWidgets('a completed task: no buttons, its members', (tester) async {
      final h = _Harness(page: v4Json('task_view_v66_done.json'), parter: v4Json('task_parter_v67.json'));
      await pump(tester, h);
      expect(find.byKey(const ValueKey('task-detail-give-up')), findsNothing);
      expect(find.byKey(const ValueKey('task-detail-apply')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('task-parter-31')), 200);
      expect(find.text('ag_low2'), findsOneWidget);
    });
  });
}
