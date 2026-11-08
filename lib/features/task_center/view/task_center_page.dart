import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/task_center/cubit/task_center_cubit.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The forum's task center: the tasks to apply for, in progress and completed.
class TaskCenterPage extends StatefulWidget {
  /// An injected [controller] is owned by its caller.
  const TaskCenterPage({super.key, this.controller});

  /// Optional controller for deterministic tests.
  final TaskCenterCubit? controller;

  @override
  State<TaskCenterPage> createState() => _TaskCenterPageState();
}

class _TaskCenterPageState extends State<TaskCenterPage> with SingleTickerProviderStateMixin {
  late final TaskCenterCubit _cubit;
  late final TabController _tabs;
  StreamSubscription<AuthStatus>? _authSubscription;

  TaskCenterTab get _tab => TaskCenterTab.values[_tabs.index];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: TaskCenterTab.values.length, vsync: this)
      ..addListener(() {
        if (!_tabs.indexIsChanging) unawaited(_cubit.ensureLoaded(_tab));
      });
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = TaskCenterCubit(
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => TaskCenterRepository.network(getIt.get<NetClientProvider>()),
      );
      _authSubscription = listenAccountChanges(
        auth,
        onLoggingIn: _cubit.invalidate,
        onChanged: () {
          _cubit.invalidate();
          unawaited(_cubit.load(_tab));
        },
      );
    }
    unawaited(_cubit.load(_tab));
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _tabs.dispose();
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Widget _result(TaskCenterState state, TranslationsTaskCenterEn tr) {
    final result = state.result!;
    final name = state.resultName;
    final (text, tone, icon) = switch (result.outcome) {
      TaskActionOutcome.applied => (tr.applied(name: name), AppNoticeTone.info, Icons.check_circle_outline),
      TaskActionOutcome.rewarded => (tr.rewarded(name: name), AppNoticeTone.info, Icons.redeem_outlined),
      TaskActionOutcome.inProgress => (tr.inProgress(name: name), AppNoticeTone.warning, Icons.timelapse),
      TaskActionOutcome.failed => (tr.failed(name: name), AppNoticeTone.error, Icons.error_outline),
      TaskActionOutcome.refused => (tr.refused(name: name), AppNoticeTone.error, Icons.block_outlined),
      TaskActionOutcome.loginRequired => (context.t.general.needLogin, AppNoticeTone.warning, Icons.login),
      TaskActionOutcome.unconfirmed => (tr.unconfirmed(name: name), AppNoticeTone.warning, Icons.help_outline),
    };
    final message = result.message;
    return Padding(
      padding: const EdgeInsets.only(bottom: appSurfaceGap),
      child: AppNoticeBanner(
        key: const ValueKey('task-center-result'),
        tone: tone,
        icon: icon,
        title: message != null ? text : null,
        message: message ?? text,
        selectable: message != null,
      ),
    );
  }

  Widget _button(TaskCenterState state, TaskCenterTab tab, ForumTask task, TranslationsTaskCenterEn tr) {
    if (state.busyTaskId == task.id) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final onPressed = state.busyTaskId != null ? null : () => unawaited(_cubit.act(tab, task));
    return switch (task.action!) {
      TaskActionKind.apply => FilledButton.tonalIcon(
        key: ValueKey('task-apply-${task.id}'),
        onPressed: onPressed,
        icon: const Icon(Icons.add_task),
        label: Text(tr.apply),
      ),
      TaskActionKind.draw when task.claimable => FilledButton.icon(
        key: ValueKey('task-claim-${task.id}'),
        onPressed: onPressed,
        icon: const Icon(Icons.redeem_outlined),
        label: Text(tr.claim),
      ),
      TaskActionKind.draw => OutlinedButton.icon(
        key: ValueKey('task-claim-${task.id}'),
        onPressed: onPressed,
        icon: const Icon(Icons.redeem_outlined),
        label: Text(tr.claim),
      ),
    };
  }

  Widget _card(TaskCenterState state, TaskCenterTab tab, ForumTask task, TranslationsTaskCenterEn tr) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final muted = textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    final progress = task.progress;
    return AppSurface(
      key: ValueKey('task-${tab.item}-${task.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.name, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          if (task.description.isNotEmpty) ...[sizedBoxW4H4, Text(task.description, style: muted)],
          if (task.reward.isNotEmpty) ...[
            sizedBoxW8H8,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.card_giftcard_outlined, size: 16, color: colorScheme.primary),
                ),
                sizedBoxW4H4,
                Expanded(child: Text(task.reward, style: textTheme.bodyMedium)),
              ],
            ),
          ],
          if (progress != null) ...[
            sizedBoxW12H12,
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: progress / 100, minHeight: 8),
                  ),
                ),
                sizedBoxW8H8,
                Text(
                  tr.progress(percent: progress == progress.roundToDouble() ? progress.toInt() : progress),
                  style: textTheme.labelLarge,
                ),
              ],
            ),
          ],
          if (task.note case final note?) ...[sizedBoxW8H8, Text(note, style: muted)],
          if (task.action != null || task.blockedReason != null) ...[
            sizedBoxW12H12,
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: task.action != null
                  ? _button(state, tab, task, tr)
                  : FilledButton.tonal(onPressed: null, child: Text(task.blockedReason!)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _list(TaskCenterState state, TaskCenterTab tab, TranslationsTaskCenterEn tr) {
    final tabState = state.tab(tab);
    final list = tabState.list;
    final result = state.result;
    if (list == null) {
      if (tabState.failed) {
        return buildRetryButton(context, () => unawaited(_cubit.load(tab)), message: context.t.general.failedToLoad);
      }
      return const CenteredCircularIndicator();
    }
    return RefreshIndicator(
      onRefresh: () => _cubit.load(tab),
      child: AppCenteredList(
        builder: (context, padding, width) {
          final columns = appColumnsFor(width);
          final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
          final tasks = list.tasks;
          return ListView(
            padding: padding.copyWith(top: 12, bottom: 12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (result != null) _result(state, tr),
              if (list.message case final message?)
                AppStateView(icon: Icons.task_alt, message: message, scrollable: false)
              else if (tasks.isEmpty)
                AppStateView(icon: Icons.task_alt, message: tr.empty, scrollable: false),
              for (var row = 0; row < appRowCount(tasks.length, columns); row++)
                Padding(
                  padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                  child: AppColumnsRow(
                    row: row,
                    columns: columns,
                    count: tasks.length,
                    gap: gap,
                    itemBuilder: (context, index) => _card(state, tab, tasks[index], tr),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<TaskCenterCubit, TaskCenterState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.taskCenter;
      final Widget body;
      if (state.loginRequired) {
        body = AppStateView(
          icon: Icons.login,
          message: tr.loginRequired,
          action: FilledButton.tonalIcon(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load(_tab);
            },
            icon: const Icon(Icons.login),
            label: Text(context.t.loginPage.login),
          ),
        );
      } else {
        body = TabBarView(
          controller: _tabs,
          children: [for (final tab in TaskCenterTab.values) _list(state, tab, tr)],
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          actions: [
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: state.busyTaskId != null || state.tab(_tab).loading ? null : () => _cubit.load(_tab),
            ),
            IconButton(
              tooltip: tr.openBrowser,
              icon: const Icon(Icons.open_in_browser_outlined),
              onPressed: () async => context.dispatchAsUrl(_tab.url, external: true),
            ),
          ],
          bottom: state.loginRequired
              ? null
              : TabBar(
                  controller: _tabs,
                  tabs: [
                    Tab(text: tr.tabAvailable),
                    Tab(text: tr.tabDoing),
                    Tab(text: tr.tabDone),
                  ],
                ),
        ),
        body: SafeArea(child: body),
      );
    },
  );
}
