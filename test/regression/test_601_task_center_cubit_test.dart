/// The task center state: one request per tap, the lists reloaded after it, and nothing of another account.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/task_center/cubit/task_center_cubit.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/instance.dart';

String _data(String name) => File('test/data/task/$name').readAsStringSync();

/// A forum serving the fixtures of uid 31: the pages by `item`, the writes from [writes] in order.
final class _Forum {
  _Forum({this.writes = const []});

  final List<FutureOr<TaskWriteAnswer> Function()> writes;
  final pages = <String>[];
  final sent = <String>[];
  String doing = 'list_doing_x5.html';
  int? Function() uid = () => 31;

  late final cubit = TaskCenterCubit(
    currentUid: () => uid(),
    repository: () => TaskCenterRepository(
      getPage: (url) async {
        pages.add(url);
        final item = Uri.parse(url).queryParameters['item'];
        return _data(switch (item) {
          'new' => 'list_new_x5.html',
          'doing' => doing,
          _ => 'list_done_x5.html',
        });
      },
      getWrite: (url) async {
        sent.add(url);
        return writes[sent.length - 1]();
      },
    ),
  );
}

TaskWriteAnswer _answer(String name) => (data: _data(name), location: null);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('a tab loads its list for the account', () async {
    final forum = _Forum();
    await forum.cubit.load(TaskCenterTab.available);
    expect(forum.cubit.state.uid, 31);
    expect(forum.cubit.state.tab(TaskCenterTab.available).list?.tasks, hasLength(4));
    expect(forum.cubit.state.tab(TaskCenterTab.doing).list, isNull, reason: 'other tabs load when opened');
    await forum.cubit.close();
  });

  test('a page of another account or a guest is never shown', () async {
    final other = _Forum()..uid = () => 32;
    await other.cubit.load(TaskCenterTab.available);
    expect(other.cubit.state.tab(TaskCenterTab.available).failed, isTrue);
    expect(other.cubit.state.tab(TaskCenterTab.available).list, isNull);
    await other.cubit.close();
    final guest = _Forum()..uid = () => null;
    await guest.cubit.load(TaskCenterTab.available);
    expect(guest.cubit.state.loginRequired, isTrue);
    expect(guest.pages, isEmpty);
    await guest.cubit.close();
  });

  test('apply sends once, reports, and reloads its list; the in-progress list is loaded again when opened', () async {
    final forum = _Forum(writes: [() => _answer('apply_applied.json')]);
    await forum.cubit.load(TaskCenterTab.available);
    await forum.cubit.load(TaskCenterTab.doing);
    final task = forum.cubit.state.tab(TaskCenterTab.available).list!.tasks[1];
    final act = forum.cubit.act(TaskCenterTab.available, task);
    expect(forum.cubit.state.busyTaskId, task.id);
    await forum.cubit.act(TaskCenterTab.available, task);
    await act;
    expect(forum.sent, ['https://www.tsdm39.com/home.php?mod=task&do=apply&id=3&inajax=1']);
    expect(forum.cubit.state.result?.outcome, TaskActionOutcome.applied);
    expect(forum.cubit.state.resultName, '上传头像');
    expect(forum.cubit.state.busyTaskId, isNull);
    expect(forum.cubit.state.tab(TaskCenterTab.doing).list, isNull, reason: 'the in-progress list changed');
    expect(forum.pages.where((u) => u.contains('item=new')), hasLength(2));
    await forum.cubit.ensureLoaded(TaskCenterTab.doing);
    expect(forum.cubit.state.tab(TaskCenterTab.doing).list, isNotNull);
    await forum.cubit.close();
  });

  test('a claim of a complete task reloads the in-progress list', () async {
    final forum = _Forum(writes: [() => _answer('draw_reward.json')])..doing = 'list_doing_complete_x5.html';
    await forum.cubit.load(TaskCenterTab.doing);
    final task = forum.cubit.state.tab(TaskCenterTab.doing).list!.tasks.single;
    forum.doing = 'list_doing_empty_x5.html';
    await forum.cubit.act(TaskCenterTab.doing, task);
    expect(forum.sent.single, endsWith('do=draw&id=2&inajax=1'));
    expect(forum.cubit.state.result?.outcome, TaskActionOutcome.rewarded);
    expect(forum.cubit.state.tab(TaskCenterTab.doing).list?.tasks, isEmpty);
    await forum.cubit.close();
  });

  test('a failed request is not repeated and tells nothing', () async {
    final forum = _Forum(writes: [() => throw const SocketException('reset')]);
    await forum.cubit.load(TaskCenterTab.doing);
    await forum.cubit.act(TaskCenterTab.doing, forum.cubit.state.tab(TaskCenterTab.doing).list!.tasks.single);
    expect(forum.sent, hasLength(1));
    expect(forum.cubit.state.result?.outcome, TaskActionOutcome.unconfirmed);
    await forum.cubit.close();
  });

  test('a result served to another account is not taken as this one', () async {
    final forum = _Forum(
      writes: [() => (data: _data('apply_applied.json').replaceAll('"uid":31', '"uid":32'), location: null)],
    );
    await forum.cubit.load(TaskCenterTab.available);
    await forum.cubit.act(TaskCenterTab.available, forum.cubit.state.tab(TaskCenterTab.available).list!.tasks[1]);
    expect(forum.cubit.state.result?.outcome, TaskActionOutcome.unconfirmed);
    await forum.cubit.close();
  });

  test('switching accounts while a request is pending drops its completion', () async {
    final answer = Completer<TaskWriteAnswer>();
    final forum = _Forum(writes: [() => answer.future]);
    await forum.cubit.load(TaskCenterTab.available);
    final pending = forum.cubit.act(
      TaskCenterTab.available,
      forum.cubit.state.tab(TaskCenterTab.available).list!.tasks[1],
    );
    forum.uid = () => 32;
    forum.cubit.invalidate();
    answer.complete(_answer('apply_applied.json'));
    await pending;
    expect(forum.cubit.state.result, isNull);
    expect(forum.cubit.state.tabs, isEmpty);
    await forum.cubit.close();
  });
}
