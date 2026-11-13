import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

final _space = RegExp(r'\s+');

String _line(Object? value) => tsdmAppText(value).replaceAll(_space, ' ').trim();

/// How often a periodic task may be applied for (`period` of plugin 4.0.0), as the web page words it.
enum TaskPeriodKind {
  /// Every [TaskPeriod.value] hours.
  hours,

  /// Every [TaskPeriod.value] days.
  days,

  /// On weekday [TaskPeriod.value] (1 Monday … 7 Sunday) of every week.
  weekday,

  /// On day [TaskPeriod.value] of every month.
  monthDay,
}

/// The period of a periodic task.
final class TaskPeriod {
  /// Constructor.
  const TaskPeriod(this.kind, this.value);

  /// What [value] counts.
  final TaskPeriodKind kind;

  /// The number of the period.
  final int value;
}

/// Another task a task names among its conditions to apply (`related`: to complete first, `exclusive`: not to have).
final class TaskLink {
  /// Constructor.
  const TaskLink({required this.id, required this.name});

  /// The task.
  final int id;

  /// Its name, empty when the forum gave none.
  final String name;
}

/// A line the forum prints as `name: value` (the conditions of a task script).
typedef TaskVar = ({String name, String value});

/// One task's page (`home.php?mod=task&do=view&id=N`) as the forum's app API answers it (plugin 4.0.0:
/// `type: task`, `schema` 66).
final class TaskDetail {
  /// Constructor.
  const TaskDetail({
    required this.id,
    required this.name,
    required this.descriptionHtml,
    required this.reward,
    required this.state,
    this.iconUrl,
    this.period,
    this.endTime,
    this.conditionHtml = '',
    this.conditions = const [],
    this.groups = '',
    this.perm = '',
    this.related,
    this.exclusive,
    this.limit = 0,
    this.applyVars = const [],
    this.applicants = 0,
    this.hasParters = false,
    this.progress,
    this.time,
    this.next = '',
    this.canApply = false,
    this.canClaim = false,
    this.canGiveUp = false,
  });

  /// Task id.
  final int id;

  /// Task name.
  final String name;

  /// The description as the forum stored it (`description_html`), for the app's renderer.
  final String descriptionHtml;

  /// The icon, absolute.
  final String? iconUrl;

  /// The reward as the forum words it, empty without one ([taskRewardTextOf]).
  final String reward;

  /// The period of a periodic task, null for a task applied for once.
  final TaskPeriod? period;

  /// When the task goes offline (the forum's wall clock), null when it does not.
  final DateTime? endTime;

  /// What completes the task as the task script words it (`condition_html`), empty when it gives [conditions]
  /// instead.
  final String conditionHtml;

  /// What completes the task line by line, when [conditionHtml] is empty.
  final List<TaskVar> conditions;

  /// The user groups the task is limited to (the forum's names, comma separated), empty when not limited by group.
  final String groups;

  /// Who may apply when not limited by group: `member` members, `admin` the staff, empty anyone.
  final String perm;

  /// The task to complete before applying.
  final TaskLink? related;

  /// The task not to have applied for.
  final TaskLink? exclusive;

  /// How many may be rewarded, 0 without a limit.
  final int limit;

  /// Other conditions to apply.
  final List<TaskVar> applyVars;

  /// How many applied.
  final int applicants;

  /// The forum names who applied (`parter_url`).
  final bool hasParters;

  /// The forum's `allowapply`: -1 in progress, -2 not for the group, -3 full, -4 failed, -5 completed, -6 completed
  /// and not yet available again, -7 failed and not yet available again, 1 available, 2 completed and available again,
  /// 3 failed and available again.
  final int state;

  /// Completion in percent (0–100) while in progress.
  final double? progress;

  /// When the task was completed or failed (the forum's wall clock).
  final DateTime? time;

  /// When it can be applied for again, as the forum words it (states -6, -7).
  final String next;

  /// The page has the apply button.
  final bool canApply;

  /// The page has the claim button.
  final bool canClaim;

  /// The page has the give-up button.
  final bool canGiveUp;

  /// The task is in progress.
  bool get inProgress => state == -1;

  /// The task failed (states -4, -7, 3).
  bool get failed => state == -4 || state == -7 || state == 3;

  /// Whether any condition to apply is set; the web page prints "unlimited" otherwise.
  bool get applyLimited =>
      groups.isNotEmpty || perm.isNotEmpty || related != null || exclusive != null || limit > 0 || applyVars.isNotEmpty;
}

TaskLink? _linkOf(Object? value) {
  final map = tsdmAppMap(value);
  final id = tsdmAppInt(map['taskid']);
  return id > 0 ? TaskLink(id: id, name: _line(map['name'])) : null;
}

List<TaskVar> _varsOf(Object? value) => [
  for (final row in tsdmAppList(value))
    if ((name: _line(row['name']), value: _line(row['value'])) case final v
        when v.name.isNotEmpty || v.value.isNotEmpty)
      v,
];

/// The task's page [json] of the forum's app API (plugin 4.0.0: `type: task`, `schema` 66).
///
/// Its buttons are read from the urls the page has (`apply_url`, `draw_url`, `delete_url`) as the web page shows them;
/// the urls themselves are not sent: the app builds its own from the task's id.
TaskDetail taskDetailFromApi(Map<String, dynamic> json) {
  final offset = tsdmAppTimeOffset(json);
  final state = tsdmAppInt(json['state']);
  final period = tsdmAppMap(json['period']);
  final periodKind = switch (period['type']) {
    0 => TaskPeriodKind.hours,
    1 => TaskPeriodKind.days,
    2 => TaskPeriodKind.weekday,
    3 => TaskPeriodKind.monthDay,
    _ => null,
  };
  final apply = tsdmAppMap(json['apply_condition']);
  final csc = json['csc'];
  final progress = csc is num ? csc.toDouble() : double.tryParse('${csc ?? ''}');
  final icon = _line(json['icon']);
  bool has(String key) => _line(json[key]).isNotEmpty;
  return TaskDetail(
    id: tsdmAppInt(json['taskid']),
    name: _line(json['name']),
    descriptionHtml: tsdmAppText(json['description_html']),
    iconUrl: icon.isEmpty ? null : spaceAbsoluteUrl(icon),
    reward: taskRewardTextOf(tsdmAppMap(json['reward'])),
    period: periodKind == null ? null : TaskPeriod(periodKind, tsdmAppInt(period['value'])),
    endTime: tsdmAppWallClockTime(json['endtime'], offset),
    conditionHtml: tsdmAppText(json['condition_html']).trim(),
    conditions: _varsOf(json['conditions']),
    groups: _line(apply['groups']),
    perm: _line(apply['perm']),
    related: _linkOf(apply['related']),
    exclusive: _linkOf(apply['exclusive']),
    limit: tsdmAppInt(apply['limit']),
    applyVars: _varsOf(apply['vars']),
    applicants: tsdmAppInt(json['applicants']),
    hasParters: has('parter_url'),
    state: state,
    progress: state == -1 ? (progress ?? 0).clamp(0, 100).toDouble() : null,
    time: tsdmAppWallClockTime(json['dateline'], offset),
    next: _line(json['next']),
    canApply: state > 0 && has('apply_url'),
    canClaim: state == -1 && has('draw_url'),
    canGiveUp: state == -1 && has('delete_url'),
  );
}

/// How far a member who applied got (`status` of plugin 4.0.0's `task_parter`).
enum TaskParterStatus {
  /// In progress, see [TaskParter.progress].
  doing,

  /// Completed.
  done,

  /// Failed.
  failed,
}

/// A member who applied for a task, among the latest eight the forum lists.
final class TaskParter {
  /// Constructor.
  const TaskParter({
    required this.uid,
    required this.username,
    required this.status,
    required this.progress,
    this.avatarUrl,
  });

  /// The member.
  final int uid;

  /// Their name.
  final String username;

  /// Their avatar, absolute.
  final String? avatarUrl;

  /// How far they got.
  final TaskParterStatus status;

  /// Completion in percent.
  final double progress;
}

/// The members who applied ([json]: plugin 4.0.0's `type: task_parter`, `schema` 67).
List<TaskParter> taskPartersFromApi(Map<String, dynamic> json) => [
  for (final row in tsdmAppList(json['list']))
    if (tsdmAppInt(row['uid']) case final uid when uid > 0 && _line(row['username']).isNotEmpty)
      TaskParter(
        uid: uid,
        username: _line(row['username']),
        avatarUrl: _line(row['avatar']).isEmpty ? null : spaceAbsoluteUrl(_line(row['avatar'])),
        status: switch (tsdmAppInt(row['status'])) {
          1 => TaskParterStatus.done,
          -1 => TaskParterStatus.failed,
          _ => TaskParterStatus.doing,
        },
        progress: (row['csc'] is num ? (row['csc'] as num).toDouble() : 0.0).clamp(0, 100).toDouble(),
      ),
];
