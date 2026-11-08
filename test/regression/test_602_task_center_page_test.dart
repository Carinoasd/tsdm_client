/// The task center screen: three tabs of cards, the claim of a complete task, narrow and large-text layouts.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/task_center/cubit/task_center_cubit.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/features/task_center/view/task_center_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

final _files = <String, String>{
  for (final name in [
    'list_new_x5.html',
    'list_doing_complete_x5.html',
    'list_doing_empty_x5.html',
    'list_done_x5.html',
    'draw_reward.json',
  ])
    name: File('test/data/task/$name').readAsStringSync(),
};

final class _Harness {
  _Harness({this.answer});

  final Completer<TaskWriteAnswer>? answer;
  final sent = <String>[];
  String doing = 'list_doing_complete_x5.html';
  Completer<void>? holdAvailable;

  late final cubit = TaskCenterCubit(
    currentUid: () => 31,
    repository: () => TaskCenterRepository(
      getPage: (url) async {
        final item = Uri.parse(url).queryParameters['item'];
        if (item == 'new') await holdAvailable?.future;
        return _files[switch (item) {
          'new' => 'list_new_x5.html',
          'doing' => doing,
          _ => 'list_done_x5.html',
        }]!;
      },
      getWrite: (url) async {
        sent.add(url);
        final pending = answer;
        final result = pending == null ? (data: _files['draw_reward.json'], location: null) : await pending.future;
        doing = 'list_doing_empty_x5.html';
        return result;
      },
    ),
  );
}

Future<void> _pump(WidgetTester tester, TaskCenterCubit cubit, {double width = 400, double scale = 1}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: TaskCenterPage(controller: cubit),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('available tasks show name, description, reward and apply; a full task shows its reason', (
    tester,
  ) async {
    final h = _Harness();
    await _pump(tester, h.cubit, width: 320);
    expect(find.text(t.taskCenter.tabAvailable), findsOneWidget);
    expect(find.text('管理员专属'), findsOneWidget);
    expect(find.text('仅限管理人员申请。'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-apply-4')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('人数已满'),
      300,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    expect(find.byKey(const ValueKey('task-apply-1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });

  testWidgets('claiming a complete task sends once, locks the buttons and reports the reward', (tester) async {
    final answer = Completer<TaskWriteAnswer>();
    final h = _Harness(answer: answer);
    await _pump(tester, h.cubit);
    await tester.tap(find.text(t.taskCenter.tabDoing));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('task-claim-2')));
    await tester.pump();
    expect(h.sent, hasLength(1));
    expect(find.byKey(const ValueKey('task-claim-2')), findsNothing, reason: 'a progress indicator in its place');
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh)).onPressed, isNull);
    answer.complete((data: _files['draw_reward.json'], location: null));
    await tester.pumpAndSettle();
    expect(find.text(t.taskCenter.rewarded(name: '回复三次')), findsOneWidget);
    expect(find.text(t.taskCenter.empty), findsOneWidget);
    expect(h.sent, hasLength(1));
    await tester.tap(find.text(t.taskCenter.tabDone));
    await tester.pumpAndSettle();
    expect(find.text('上传头像'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-center-result')), findsNothing, reason: 'shown on its own tab only');
    await tester.tap(find.text(t.taskCenter.tabDoing));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-center-result-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-center-result')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });

  testWidgets('the refresh button follows the tab shown, not a load in another tab', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit);
    await tester.tap(find.text(t.taskCenter.tabDoing));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.taskCenter.tabAvailable));
    await tester.pumpAndSettle();
    final hold = h.holdAvailable = Completer<void>();
    Finder refresh() => find.widgetWithIcon(IconButton, Icons.refresh);
    await tester.tap(refresh());
    await tester.pump();
    expect(tester.widget<IconButton>(refresh()).onPressed, isNull, reason: 'this tab is loading');
    await tester.tap(find.text(t.taskCenter.tabDoing));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<IconButton>(refresh()).onPressed, isNotNull, reason: 'the in-progress list is loaded');
    hold.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });

  testWidgets('large text on a narrow screen lays out every tab', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit, width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    for (final tab in [t.taskCenter.tabDoing, t.taskCenter.tabDone]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });
}
