/// The task center: the forum's task lists and the answers of an apply and a claim, as the test forum served them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/task/$name').readAsStringSync();

TaskList _list(String name, TaskCenterTab tab) => parseTaskList(parseHtmlDocument(_data(name)), tab);

void main() {
  group('lists', () {
    test('available tasks: name, description, reward, apply button and a full task blocked with its reason', () {
      final list = _list('list_new_x5.html', TaskCenterTab.available);
      expect(list.message, isNull);
      expect(list.tasks.map((t) => t.id), [4, 3, 2, 1]);
      final reply = list.tasks[2];
      expect(reply.name, '回复三次');
      expect(reply.description, '在任意版块回复 3 次即可完成。');
      expect(reply.reward, '勋章 活跃会员');
      expect(reply.action, TaskActionKind.apply);
      expect(reply.progress, isNull);
      expect(list.tasks[1].reward, '积分 威望 2');
      final full = list.tasks[3];
      expect(full.name, '新人红包');
      expect(full.action, isNull, reason: 'the forum answers this button with a dialog, not an apply');
      expect(full.blockedReason, '人数已满');
    });

    test('a task in progress has its progress and a claim that is not yet complete', () {
      final task = _list('list_doing_x5.html', TaskCenterTab.doing).tasks.single;
      expect(task.id, 2);
      expect(task.progress, closeTo(66.67, 0.001));
      expect(task.action, TaskActionKind.draw);
      expect(task.claimable, isFalse);
      expect(task.note, isNull);
    });

    test('a complete task can be claimed', () {
      final task = _list('list_doing_complete_x5.html', TaskCenterTab.doing).tasks.single;
      expect(task.progress, 100);
      expect(task.claimable, isTrue);
    });

    test('completed tasks carry the forum line of when, and no button', () {
      final list = _list('list_done_x5.html', TaskCenterTab.done);
      expect(list.tasks.map((t) => t.name), ['上传头像', '回复三次', '新人红包']);
      for (final task in list.tasks) {
        expect(task.action, isNull);
        expect(task.note, startsWith('完成于'));
      }
      expect(list.tasks[1].reward, '勋章 活跃会员');
      expect(list.tasks.last.reward, '积分 天使币 5');
    });

    test('an empty list is empty, not a message', () {
      final list = _list('list_doing_empty_x5.html', TaskCenterTab.doing);
      expect(list.tasks, isEmpty);
      expect(list.message, isNull);
    });

    test('the forum message in place of the list (task system closed) is kept', () {
      final list = parseTaskList(
        parseHtmlDocument(
          '<html><head><script>var discuz_uid = \'31\';</script></head><body><div id="wp"> '
          '<div id="messagetext" class="alert_error"><p>抱歉，站点任务关闭</p></div></div></body></html>',
        ),
        TaskCenterTab.available,
      );
      expect(list.tasks, isEmpty);
      expect(list.message, '抱歉，站点任务关闭');
    });

    test('a periodic task done may be applied for again', () {
      final list = parseTaskList(
        parseHtmlDocument('''
<table><tr>
<td class="bbda"><h3><a href="home.php?mod=task&amp;do=view&amp;id=7">每日签到</a></h3><p class="xg2">每天一次</p></td>
<td class="xi1 bbda hm">积分 天使币 1 </td>
<td class="bbda"><p>完成于 2023-11-15 06:13<br /><a href="home.php?mod=task&amp;do=apply&amp;id=7">立即重新申请</a></p></td>
</tr></table>'''),
        TaskCenterTab.done,
      );
      final task = list.tasks.single;
      expect(task.action, TaskActionKind.apply);
      expect(task.note, '完成于 2023-11-15 06:13');
    });
  });

  group('apply', () {
    test('the plugin result: applied, and a task that completes on applying redirects to its claim', () {
      final applied = taskApplyResultOf(_data('apply_applied.json'), id: 3);
      expect(applied.outcome, TaskActionOutcome.applied);
      expect(applied.uid, 31);
      final gift = taskApplyResultOf(jsonDecode(_data('apply_gift_redirect.json')), id: 1);
      expect(gift.outcome, TaskActionOutcome.applied);
      final other = taskApplyResultOf(_data('apply_gift_redirect.json'), id: 9);
      expect(other.outcome, TaskActionOutcome.unconfirmed, reason: 'a redirect to another task proves nothing');
    });

    test('the forum answers refusals as notes like a success: only the message key tells them apart', () {
      final duplicate = taskApplyResultOf(_data('apply_duplicate.json'), id: 2);
      expect(duplicate.outcome, TaskActionOutcome.refused);
      expect(duplicate.message, '抱歉，您已申请过此任务，请不要重复申请');
      final group = taskApplyResultOf(_data('apply_grouplimit.json'), id: 4);
      expect(group.outcome, TaskActionOutcome.refused);
      expect(group.message, '抱歉，您所在的用户组不允许申请此任务');
    });

    test('a guest is asked to log in', () {
      final guest = taskApplyResultOf(_data('apply_guest.json'), id: 1);
      expect(guest.outcome, TaskActionOutcome.loginRequired);
      expect(guest.uid, 0);
    });

    test('without the plugin: the success handler links to the task page, a refusal elsewhere', () {
      final applied = taskApplyResultOf(_data('apply_applied_x5.xml'), id: 2);
      expect(applied.outcome, TaskActionOutcome.applied);
      expect(applied.message, '任务申请成功');
      expect(applied.uid, isNull);
      final duplicate = taskApplyResultOf(_data('apply_duplicate_x5.xml'), id: 2);
      expect(duplicate.outcome, TaskActionOutcome.refused);
      expect(duplicate.message, '抱歉，您已申请过此任务，请不要重复申请');
      expect(
        taskApplyResultOf(_data('apply_applied_x5.xml'), id: 5).outcome,
        isNot(TaskActionOutcome.applied),
        reason: 'the link names another task',
      );
    });

    test('without the plugin: the redirect not followed to the claim of the task is an application', () {
      expect(
        taskApplyResultOf('', id: 1, location: 'home.php?mod=task&do=draw&id=1').outcome,
        TaskActionOutcome.applied,
      );
      expect(
        taskApplyResultOf('', id: 1, location: 'member.php?mod=logging&action=login').outcome,
        TaskActionOutcome.loginRequired,
      );
      expect(taskApplyResultOf('', id: 1).outcome, TaskActionOutcome.unconfirmed);
    });
  });

  group('claim', () {
    test('a reward given: its language key is never shown', () {
      for (final name in ['draw_reward.json', 'draw_reward_x5.xml']) {
        final result = taskDrawResultOf(_data(name), id: 1);
        expect(result.outcome, TaskActionOutcome.rewarded, reason: name);
        expect(result.message, isNull, reason: name);
      }
    });

    test('an incomplete task answers its progress with the forum words', () {
      final result = taskDrawResultOf(_data('draw_progress.json'), id: 2);
      expect(result.outcome, TaskActionOutcome.inProgress);
      expect(result.progress, closeTo(33.33, 0.001));
      expect(result.message, '您已完成该任务的 33.33%，加油啊！');
    });

    test('a failed task', () {
      final result = taskDrawResultOf('<?xml version="1.0"?><root><![CDATA[-1|task_failed]]></root>', id: 2);
      expect(result.outcome, TaskActionOutcome.failed);
      expect(result.message, isNull);
    });

    test('a task not in progress is refused with the forum message, with and without the plugin', () {
      for (final name in ['draw_not_underway.json', 'draw_not_underway_x5.xml']) {
        final result = taskDrawResultOf(_data(name), id: 2);
        expect(result.outcome, TaskActionOutcome.refused, reason: name);
        expect(result.message, '不是进行中的任务', reason: name);
      }
    });
  });
}
