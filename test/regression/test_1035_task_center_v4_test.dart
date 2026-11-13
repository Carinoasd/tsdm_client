/// The task center read from the forum's app API (plugin 4.0.0, `tsdmv=4`): the lists (`task_list`, schema 65) and the
/// apply and the claim, GETs that write (`do=apply`, `do=draw`).
///
/// * The lists are asked as pages only once `status` listed `task_list` in `task_pages`; otherwise the web page is read
///   as before and nothing carries `tsdmv`.
/// * The same list read either way gives the same tasks (the recorded answer and web page of the same account).
/// * The apply and the claim are sent once, without `inajax` (a claim with it is answered `progress|words`), and only
///   the forum's success keys count (`task_applied`, `task_completed`): `ok` alone never does.
///
/// Fixtures: the lists of the test forum (cleaned); the write results are the plugin's shape (spec 7.4), not sent to
/// the test forum (they write).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/parsing.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// A repository answering [api] to the pages of 4.0.0, [web] to the web pages, [write] to the writes of 4.0.0; what
/// it was asked in [pages], [writes] and [oldWrites].
final class _Harness {
  _Harness({this.api, this.web, this.write});

  final Object? api;
  final String? web;
  final Object? write;
  final pages = <String>[];
  final webPages = <String>[];
  final writes = <String>[];
  final oldWrites = <String>[];

  late final repository = TaskCenterRepository(
    getPage: (url) async {
      webPages.add(url);
      return web ?? '';
    },
    getWrite: (url) async {
      oldWrites.add(url);
      return (data: null, location: null);
    },
    getV4Page: (url) async {
      pages.add(url);
      return api;
    },
    getV4Write: (url) async {
      writes.add(url);
      return write;
    },
  );
}

Map<String, dynamic> _result(String key, {String message = '', int ok = 1, int login = 0, int uid = _uid}) => {
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
  'login': login,
  'alert': ok == 1 ? 'info' : 'error',
};

List<Object?> _rows(TaskList list) => [
  for (final task in list.tasks)
    (task.id, task.name, task.description, task.reward, task.action, task.blockedReason, task.progress, task.note),
];

void main() {
  setUpAll(() async {
    registerV4TestServices();
    // The forum's own words are Chinese: the app's words for them are compared in the same language.
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('lists (task_list, schema 65)', () {
    test('the answer and the web page of the same list give the same tasks', () async {
      knowV4Status();
      final api = _Harness(api: v4Json('task_list_v65_new.json'));
      final fromApi = await api.repository.fetchList(TaskCenterTab.available, _uid);
      expect(api.webPages, isEmpty);
      expect(api.pages.single, TaskCenterTab.available.url);
      final fromWeb = parseTaskList(parseHtmlDocument(v4Raw('task_list_new_web.html')), TaskCenterTab.available);
      expect(fromApi.tasks, hasLength(4));
      expect(_rows(fromApi), _rows(fromWeb));
      final full = fromApi.tasks.firstWhere((task) => task.id == 1);
      expect(full.action, isNull);
      expect(full.blockedReason, '人数已满');
    });

    test("the group may not: the forum's reason in place of the button", () {
      final json = v4Json('task_list_v65_new.json');
      final rows = (json['tasks'] as List).cast<Map<String, dynamic>>();
      json['tasks'] = [
        {...rows.first, 'noperm': 1, 'apply_url': ''},
      ];
      final task = taskListFromApi(json, TaskCenterTab.available).tasks.single;
      expect(task.action, isNull);
      expect(task.blockedReason, t.taskCenter.forumWords.noPermission);
    });

    test('in progress: the progress and the claim; done: when, and when again', () async {
      final doing = v4Json('task_list_v65_new.json')
        ..['item'] = 'doing'
        ..['tasks'] = [
          {
            ...((v4Json('task_list_v65_new.json')['tasks'] as List).first as Map<String, dynamic>),
            'csc': 34.5,
            'draw_url': 'home.php?mod=task&do=draw&id=4',
          },
        ];
      final task = taskListFromApi(doing, TaskCenterTab.doing).tasks.single;
      expect(task.progress, 34.5);
      expect(task.action, TaskActionKind.draw);
      expect(task.claimable, isFalse);
      final done = taskListFromApi(v4Json('task_list_v65_done.json'), TaskCenterTab.done).tasks;
      expect(done, isNotEmpty);
      expect(done.first.action, isNull);
      expect(done.first.note, startsWith('完成于 '));
      final again = v4Json('task_list_v65_done.json');
      final rows = (again['tasks'] as List).cast<Map<String, dynamic>>();
      again['tasks'] = [
        {...rows.first, 'period': 1, 'reapply': 0, 'next': '3 小时'},
        {...rows.first, 'taskid': 9, 'period': 1, 'reapply': 1, 'reapply_url': 'home.php?mod=task&do=apply&id=9'},
      ];
      final periodic = taskListFromApi(again, TaskCenterTab.done).tasks;
      expect(periodic.first.note, endsWith('3 小时 后可以再次申请'));
      expect(periodic.last.action, TaskActionKind.apply);
      expect(taskListFromApi(v4Json('task_list_v65_doing.json'), TaskCenterTab.doing).tasks, isEmpty);
    });

    test('not listed in task_pages, or no status: the web page, nothing with tsdmv', () async {
      knowV4Status(v4Status({'task_pages': <String>[]}));
      final off = _Harness(web: v4Raw('task_list_new_web.html'));
      expect((await off.repository.fetchList(TaskCenterTab.available, _uid)).tasks, hasLength(4));
      expect(off.pages, isEmpty);
      expect(off.webPages, hasLength(1));
      TsdmAppApi.reset();
      final none = _Harness(web: v4Raw('task_list_new_web.html'));
      expect((await none.repository.fetchList(TaskCenterTab.available, _uid)).tasks, hasLength(4));
      expect(none.pages, isEmpty);
    });

    test("another account refused, the login prompt the login, the forum's message the list's", () async {
      knowV4Status();
      await expectLater(
        _Harness(api: v4Json('task_list_v65_new.json')).repository.fetchList(TaskCenterTab.available, 32),
        throwsA(isA<TaskCenterIdentityException>().having((e) => e.guest, 'guest', isFalse)),
      );
      await expectLater(
        _Harness(
          api: const {'ok': 0, 'error': 'message', 'message': '请先登录', 'message_key': 'to_login', 'login': 1, 'uid': 0},
        ).repository.fetchList(TaskCenterTab.available, _uid),
        throwsA(isA<TaskCenterIdentityException>().having((e) => e.guest, 'guest', isTrue)),
      );
      final closed = await _Harness(
        api: const {
          'ok': 0,
          'error': 'message',
          'message': '任务功能已关闭',
          'message_key': 'task_close',
          'login': 0,
          'uid': _uid,
        },
      ).repository.fetchList(TaskCenterTab.available, _uid);
      expect(closed.tasks, isEmpty);
      expect(closed.message, '任务功能已关闭');
    });
  });

  group('apply and claim (GETs that write, schema 13)', () {
    test("sent once, without inajax, to the task's own url", () async {
      knowV4Status();
      final h = _Harness(write: _result('task_applied', message: '任务申请成功'));
      final result = await h.repository.apply(2);
      expect(result.outcome, TaskActionOutcome.applied);
      expect(h.writes, ['$baseUrl/home.php?mod=task&do=apply&id=2']);
      expect(h.oldWrites, isEmpty);
      final d = _Harness(write: _result('task_completed', message: 'task_reward_credit'));
      expect((await d.repository.draw(2)).outcome, TaskActionOutcome.rewarded);
      expect(d.writes, ['$baseUrl/home.php?mod=task&do=draw&id=2']);
      expect(d.writes.single, isNot(contains('inajax')));
    });

    test('only the success keys count; ok alone never does', () {
      TaskActionOutcome apply(Map<String, dynamic> r) =>
          taskV4ActionResultOf(r, id: 2, kind: TaskActionKind.apply)!.outcome;
      TaskActionOutcome draw(Map<String, dynamic> r) =>
          taskV4ActionResultOf(r, id: 2, kind: TaskActionKind.draw)!.outcome;
      // The forum words its refusals as notes ("info"): ok 1 in the plugin's classification.
      expect(apply(_result('task_duplicate', message: '您已申请过此任务')), TaskActionOutcome.refused);
      expect(apply(_result('task_grouplimit', message: '您所在的用户组无法申请此任务')), TaskActionOutcome.refused);
      expect(
        apply(_result('task_completed', message: '任务已完成')),
        TaskActionOutcome.refused,
        reason: "not the apply's key",
      );
      expect(apply(_result('')), TaskActionOutcome.unconfirmed);
      // A task completing on applying is sent on to its own claim (task_gift): applied; to another task's: not.
      expect(
        apply({..._result(''), 'ok': 0, 'kind': 'redirect', 'url': 'home.php?mod=task&do=draw&id=2'}),
        TaskActionOutcome.applied,
      );
      expect(
        apply({..._result(''), 'ok': 0, 'kind': 'redirect', 'url': 'home.php?mod=task&do=draw&id=3'}),
        TaskActionOutcome.unconfirmed,
      );
      expect(draw(_result('task_reward_credit')), TaskActionOutcome.rewarded);
      expect(draw(_result('task_doing', message: '您已完成该任务的 34%')), TaskActionOutcome.inProgress);
      expect(draw(_result('task_waiting_rt', message: '等待中')), TaskActionOutcome.inProgress);
      expect(draw(_result('task_failed', message: '任务已失败', ok: 0)), TaskActionOutcome.failed);
      expect(draw(_result('task_not_found', message: '任务不存在')), TaskActionOutcome.refused);
      expect(draw(_result('task_applied', message: '任务已完成')), TaskActionOutcome.refused);
      expect(draw(_result('to_login', login: 1, uid: 0)), TaskActionOutcome.loginRequired);
      final progress = taskV4ActionResultOf(
        _result('task_doing', message: '您已完成该任务的 34%'),
        id: 2,
        kind: TaskActionKind.draw,
      )!;
      expect(progress.message, '您已完成该任务的 34%');
      expect(
        taskV4ActionResultOf(
          _result('task_completed', message: 'task_reward_credit'),
          id: 2,
          kind: TaskActionKind.draw,
        )!.message,
        isNull,
      );
    });

    test('without the flag the old AJAX write is sent, as before', () async {
      knowV4Status(v4Status({'task_pages': <String>[]}));
      final h = _Harness();
      await h.repository.apply(2);
      expect(h.writes, isEmpty);
      expect(h.oldWrites.single, contains('inajax=1'));
    });
  });
}
