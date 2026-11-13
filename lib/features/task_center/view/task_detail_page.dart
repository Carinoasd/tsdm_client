import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/task_center/cubit/task_detail_cubit.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/task_center/models/task_detail.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// One task of the forum's task center: what it asks, what it gives, how far the account got, and its buttons.
///
/// Popped with `true` once something was sent from it: the task center's lists are stale then.
class TaskDetailPage extends StatefulWidget {
  /// An injected [controller] is owned by its caller.
  const TaskDetailPage({required this.taskId, super.key, this.controller, this.htmlBuilder, this.imageBuilder});

  /// The task.
  final int taskId;

  /// Optional controller for deterministic tests.
  final TaskDetailCubit? controller;

  /// Optional renderer of the forum's html; production reuses [MunchedHtml].
  final Widget Function(String html)? htmlBuilder;

  /// Optional image renderer; production reuses [CachedImage] and [HeroUserAvatar].
  final Widget Function(String? url, double size)? imageBuilder;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  late final TaskDetailCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = TaskDetailCubit(
        taskId: widget.taskId,
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => TaskCenterRepository.network(getIt.get<NetClientProvider>()),
      );
      _authSubscription = listenAccountChanges(
        auth,
        onLoggingIn: _cubit.invalidate,
        onChanged: () {
          _cubit.invalidate();
          unawaited(_cubit.load());
        },
      );
    }
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Widget _html(String html) => widget.htmlBuilder?.call(html) ?? MunchedHtml(html);

  Widget _icon(String? url) => SizedBox.square(
    dimension: 48,
    child:
        widget.imageBuilder?.call(url, 48) ??
        (url == null
            ? Icon(Icons.task_alt, color: Theme.of(context).colorScheme.outline)
            : CachedImage(url, width: 48, height: 48, fit: BoxFit.contain)),
  );

  Widget _avatar(TaskParter parter) =>
      widget.imageBuilder?.call(parter.avatarUrl, 32) ??
      HeroUserAvatar(username: parter.username, avatarUrl: parter.avatarUrl, maxRadius: 16, disableHero: true);

  String _time(DateTime? time) => time?.yyyyMMDDHHMM() ?? '';

  String _periodText(TaskPeriod period, TranslationsTaskCenterForumWordsEn words) => switch (period.kind) {
    TaskPeriodKind.hours => words.periodHour(period: period.value),
    TaskPeriodKind.days => words.periodDay(period: period.value),
    TaskPeriodKind.weekday => words.periodWeek(
      day: switch (period.value) {
        1 => words.weekday1,
        2 => words.weekday2,
        3 => words.weekday3,
        4 => words.weekday4,
        5 => words.weekday5,
        6 => words.weekday6,
        _ => words.weekday7,
      },
    ),
    TaskPeriodKind.monthDay => words.periodMonth(period: period.value),
  };

  Future<void> _confirmAndAct(TaskDetail detail, TaskActionKind kind, TranslationsTaskCenterEn tr) async {
    final name = context.displayText(detail.name);
    final (title, message) = switch (kind) {
      TaskActionKind.apply => (tr.apply, tr.confirmApply(name: name)),
      TaskActionKind.draw => (tr.claim, tr.confirmClaim(name: name)),
      TaskActionKind.giveUp => (tr.giveUp, tr.confirmGiveUp(name: name)),
    };
    final ok = await showQuestionDialog(context: context, title: title, message: message);
    if (ok != true || !mounted) return;
    await _cubit.act(kind);
  }

  Widget _result(TaskDetailState state, TaskDetail? detail, TranslationsTaskCenterEn tr) {
    final result = state.result!;
    final name = context.displayText(detail?.name ?? '');
    final (text, tone, icon) = switch (result.outcome) {
      TaskActionOutcome.applied => (tr.applied(name: name), AppNoticeTone.info, Icons.check_circle_outline),
      TaskActionOutcome.rewarded => (tr.rewarded(name: name), AppNoticeTone.info, Icons.redeem_outlined),
      TaskActionOutcome.gaveUp => (tr.gaveUp(name: name), AppNoticeTone.info, Icons.check_circle_outline),
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
        key: const ValueKey('task-detail-result'),
        tone: tone,
        icon: icon,
        title: message != null ? text : null,
        message: context.displayTextOr(message, text),
        selectable: message != null,
        actions: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const Icon(Icons.close),
            onPressed: _cubit.dismissResult,
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: appSurfaceGap),
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
            sizedBoxW8H8,
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _line(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(context.displayText(text), style: Theme.of(context).textTheme.bodyMedium),
  );

  Widget _taskLink(String label, TaskLink link) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('$label: ', style: Theme.of(context).textTheme.bodyMedium),
        TextButton(
          key: ValueKey('task-link-${link.id}'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () async {
            final acted = await context.pushNamed<bool>(
              ScreenPaths.taskDetail,
              pathParameters: {'taskId': '${link.id}'},
            );
            if ((acted ?? false) && mounted) await _cubit.otherActed();
          },
          child: Text(link.name.isEmpty ? '${link.id}' : context.displayText(link.name)),
        ),
      ],
    ),
  );

  Widget _header(TaskDetail detail, TranslationsTaskCenterForumWordsEn words) {
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return AppSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInsetBlock(padding: const EdgeInsets.all(8), child: _icon(detail.iconUrl)),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.displayText(detail.name),
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (detail.period case final period?) ...[
                  sizedBoxW4H4,
                  Text(_periodText(period, words), style: muted),
                ],
                if (detail.endTime case final end?) ...[
                  sizedBoxW4H4,
                  Text(words.endTime(time: _time(end)), style: muted),
                ],
                if (detail.descriptionHtml.trim().isNotEmpty) ...[sizedBoxW8H8, _html(detail.descriptionHtml)],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The account's standing with the task and its buttons, as the web page prints them for each `allowapply`.
  Widget _standing(TaskDetailState state, TaskDetail detail, TranslationsTaskCenterEn tr) {
    final words = tr.forumWords;
    final textTheme = Theme.of(context).textTheme;
    final at = _time(detail.time);
    final next = context.displayText(detail.next);
    final lines = <String>[
      ...switch (detail.state) {
        -4 => [if (at.isNotEmpty) words.failedOn(time: at)],
        -5 => [if (at.isNotEmpty) words.completedOn(time: at)],
        -6 => [
          if (at.isNotEmpty) words.completedOn(time: at),
          if (next.isNotEmpty) words.applyAgainAfter(time: next),
        ],
        -7 => [if (at.isNotEmpty) words.failedOn(time: at), if (next.isNotEmpty) words.reapplyAfter(time: next)],
        2 => [if (at.isNotEmpty) words.completedOn(time: at), words.applyAgainNow],
        3 => [if (at.isNotEmpty) words.failedOn(time: at), words.reapplyNow],
        _ => const <String>[],
      },
    ];
    final blocked = switch (detail.state) {
      -2 => words.noPermission,
      -3 => words.full,
      _ => null,
    };
    final busy = state.busy != null || state.loading;
    Widget button(TaskActionKind kind) {
      if (state.busy == kind) {
        return const Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      final onPressed = busy ? null : () => unawaited(_confirmAndAct(detail, kind, tr));
      return switch (kind) {
        TaskActionKind.apply => FilledButton.tonalIcon(
          key: const ValueKey('task-detail-apply'),
          onPressed: onPressed,
          icon: const Icon(Icons.add_task),
          label: Text(tr.apply),
        ),
        TaskActionKind.draw when (detail.progress ?? 0) >= 100 => FilledButton.icon(
          key: const ValueKey('task-detail-claim'),
          onPressed: onPressed,
          icon: const Icon(Icons.redeem_outlined),
          label: Text(tr.claim),
        ),
        TaskActionKind.draw => OutlinedButton.icon(
          key: const ValueKey('task-detail-claim'),
          onPressed: onPressed,
          icon: const Icon(Icons.redeem_outlined),
          label: Text(tr.claim),
        ),
        TaskActionKind.giveUp => TextButton.icon(
          key: const ValueKey('task-detail-give-up'),
          onPressed: onPressed,
          icon: const Icon(Icons.close),
          label: Text(tr.giveUp),
        ),
      };
    }

    final buttons = [
      if (detail.canGiveUp) button(TaskActionKind.giveUp),
      if (detail.canClaim) button(TaskActionKind.draw),
      if (detail.canApply) button(TaskActionKind.apply),
      if (blocked != null) FilledButton.tonal(onPressed: null, child: Text(blocked)),
    ];
    final progress = detail.progress;
    if (lines.isEmpty && buttons.isEmpty && progress == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: appSurfaceGap),
      child: AppSurface(
        key: const ValueKey('task-detail-standing'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (progress != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
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
              ),
            for (final line in lines) _line(line),
            if (buttons.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(spacing: 8, runSpacing: 8, children: buttons),
              ),
          ],
        ),
      ),
    );
  }

  Widget _parters(TaskDetailState state, TaskDetail detail, TranslationsTaskCenterEn tr) {
    final words = tr.forumWords;
    final textTheme = Theme.of(context).textTheme;
    return _section(words.applicants(count: detail.applicants), [
      for (final parter in state.parters)
        InkWell(
          key: ValueKey('task-parter-${parter.uid}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${parter.uid}'}),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox.square(dimension: 32, child: _avatar(parter)),
                sizedBoxW12H12,
                Expanded(child: Text(context.displayText(parter.username), style: textTheme.bodyMedium)),
                Text(switch (parter.status) {
                  TaskParterStatus.done => words.parterDone,
                  TaskParterStatus.failed => words.parterFailed,
                  TaskParterStatus.doing => tr.progress(
                    percent: parter.progress == parter.progress.roundToDouble()
                        ? parter.progress.toInt()
                        : parter.progress,
                  ),
                }, style: textTheme.labelLarge),
              ],
            ),
          ),
        ),
    ]);
  }

  Widget _content(TaskDetailState state, TaskDetail detail, TranslationsTaskCenterEn tr) {
    final words = tr.forumWords;
    return RefreshIndicator(
      onRefresh: _cubit.load,
      child: AppCenteredList(
        maxWidth: appFormMaxWidth,
        builder: (context, padding, _) => ListView(
          padding: padding.copyWith(top: 12, bottom: 12),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (state.result != null) _result(state, detail, tr),
            if (state.failed)
              Padding(
                padding: const EdgeInsets.only(bottom: appSurfaceGap),
                child: AppNoticeBanner(
                  tone: AppNoticeTone.error,
                  message: context.t.general.failedToLoad,
                  actions: [
                    TextButton(onPressed: () => unawaited(_cubit.load()), child: Text(context.t.general.retry)),
                  ],
                ),
              ),
            _header(detail, words),
            _standing(state, detail, tr),
            _section(words.reward, [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.card_giftcard_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                  ),
                  sizedBoxW4H4,
                  Expanded(child: Text(context.displayText(detail.reward.isEmpty ? words.rewardNone : detail.reward))),
                ],
              ),
            ]),
            _section(words.completeCondition, [
              if (detail.conditionHtml.isNotEmpty)
                _html(detail.conditionHtml)
              else if (detail.conditions.isNotEmpty)
                for (final v in detail.conditions) _line('${v.name}: ${v.value}')
              else
                _line(words.unlimited),
            ]),
            _section(words.applyCondition, [
              if (!detail.applyLimited) _line(words.unlimited),
              if (detail.groups.isNotEmpty)
                _line(words.usergroup(groups: detail.groups))
              else if (detail.perm == 'member')
                _line(words.generalUsers)
              else if (detail.perm == 'admin')
                _line(words.admins),
              if (detail.related case final link?) _taskLink(words.relatedTask, link),
              if (detail.exclusive case final link?) _taskLink(words.exclusiveTask, link),
              if (detail.limit > 0) _line(words.numLimit(limit: detail.limit)),
              for (final v in detail.applyVars) _line('${v.name}: ${v.value}'),
            ]),
            if (detail.applicants > 0) _parters(state, detail, tr),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<TaskDetailCubit, TaskDetailState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.taskCenter;
      final detail = state.detail;
      final Widget body;
      if (state.loginRequired) {
        body = AppStateView(
          icon: Icons.login,
          message: tr.loginRequired,
          action: FilledButton.tonalIcon(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load();
            },
            icon: const Icon(Icons.login),
            label: Text(context.t.loginPage.login),
          ),
        );
      } else if (state.message case final message?) {
        body = AppStateView(icon: Icons.task_alt, message: context.displayText(message));
      } else if (detail == null) {
        body = state.failed
            ? buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad)
            : const CenteredCircularIndicator();
      } else {
        body = _content(state, detail, tr);
      }
      return PopScope(
        // Sent something: the task center is told to load its lists again.
        canPop: !state.acted,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.pop(true);
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr.detailTitle),
            actions: [
              IconButton(
                tooltip: tr.refresh,
                icon: const Icon(Icons.refresh),
                onPressed: state.busy != null || state.loading ? null : _cubit.load,
              ),
              IconButton(
                tooltip: tr.openBrowser,
                icon: const Icon(Icons.open_in_browser_outlined),
                onPressed: () async => context.dispatchAsUrl(taskViewUrl(widget.taskId), external: true),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(4),
              child: SizedBox(
                height: 4,
                child: detail != null && (state.loading || state.busy != null) ? const LinearProgressIndicator() : null,
              ),
            ),
          ),
          body: SafeArea(child: body),
        ),
      );
    },
  );
}
