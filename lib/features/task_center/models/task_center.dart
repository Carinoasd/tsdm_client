import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The lists of the forum's task center (`home.php?mod=task&item=…`) the app shows, in tab order.
enum TaskCenterTab {
  /// Tasks the account may apply for (`item=new`).
  available('new'),

  /// Tasks applied for and not yet rewarded (`item=doing`).
  doing('doing'),

  /// Tasks rewarded (`item=done`).
  done('done')
  ;

  const TaskCenterTab(this.item);

  /// The `item` query value of the list.
  final String item;

  /// The list page of this tab.
  String get url => '$baseUrl/home.php?mod=task&item=$item';
}

/// The AJAX url applying for task [id] (`do=apply`), a GET that writes.
String taskApplyUrl(int id) => '$baseUrl/home.php?mod=task&do=apply&id=$id&inajax=1';

/// The AJAX url claiming the reward of task [id] (`do=draw`), a GET that writes.
String taskDrawUrl(int id) => '$baseUrl/home.php?mod=task&do=draw&id=$id&inajax=1';

/// What a task card's button does.
enum TaskActionKind {
  /// Apply for the task (`do=apply`), also the "apply again" link of a periodic task.
  apply,

  /// Claim the reward (`do=draw`); the forum checks the progress and answers it when not complete.
  draw,
}

/// One task of a list, as the forum's page shows it.
final class ForumTask {
  /// Constructor.
  const ForumTask({
    required this.id,
    required this.name,
    required this.description,
    required this.reward,
    this.progress,
    this.action,
    this.blockedReason,
    this.note,
  });

  /// Task id.
  final int id;

  /// Task name.
  final String name;

  /// The description, plain text.
  final String description;

  /// The reward as the forum words it ("积分 天使币 5", "勋章 活跃会员"), empty when the task has none.
  final String reward;

  /// Completion in percent (0–100) of a task in progress, null for the other lists.
  final double? progress;

  /// The button of the card, null when there is none (a rewarded task).
  final TaskActionKind? action;

  /// Why the forum does not take an application now ("人数已满", no permission), shown in place of the button.
  final String? blockedReason;

  /// The forum's line beside a rewarded task (when it was completed, when it can be applied for again).
  final String? note;

  /// The reward can be claimed: the progress is complete.
  bool get claimable => action == TaskActionKind.draw && (progress ?? 0) >= 100;
}

/// One list of the task center.
final class TaskList {
  /// Constructor.
  const TaskList({required this.tab, required this.tasks, this.message});

  /// The list.
  final TaskCenterTab tab;

  /// Tasks in the forum's order.
  final List<ForumTask> tasks;

  /// The forum's message in place of the list (the task system is closed), null for a list.
  final String? message;
}

final _space = RegExp(r'\s+');
final _dialogText = RegExp(r"showDialog\('((?:[^'\\]|\\.)*)'");

/// The nearest ancestor of [e] (itself excluded) named [tag]; universal_html leaves `closest` unimplemented.
uh.Element? _ancestor(uh.Element e, String tag) {
  for (var node = e.parent; node != null; node = node.parent) {
    if (node.localName == tag) return node;
  }
  return null;
}

String _text(uh.Element? e) => (e?.text ?? '').replaceAll(_space, ' ').trim();

int? _taskIdOf(String? href, String action) {
  if (href == null) return null;
  final uri = Uri.tryParse(href.trim());
  if (uri == null) return null;
  final q = uri.queryParameters;
  if (q['mod'] != 'task' || q['do'] != action) return null;
  final id = int.tryParse(q['id'] ?? '');
  return id != null && id > 0 ? id : null;
}

/// Parse the task list [document] of [tab].
///
/// Rows are found by the link to the task's page (`do=view&id=N`) and their parts by what they link to or carry
/// (`span#csc_N`, `do=apply`, `do=draw`), not by layout: the forum's styles differ. A page without any row and with
/// the forum's message (`div#messagetext`: the task system closed) is that message; a page with neither is an empty
/// list.
TaskList parseTaskList(uh.Document document, TaskCenterTab tab) {
  final tasks = <ForumTask>[];
  final seen = <int>{};
  for (final link in document.querySelectorAll('a[href*="do=view"]')) {
    final id = _taskIdOf(link.attributes['href'], 'view');
    if (id == null || link.attributes['href']!.contains('#') || !seen.add(id)) continue;
    final row = _ancestor(link, 'tr');
    if (row == null) continue;
    final applyLink = row
        .querySelectorAll('a[href*="do=apply"]')
        .where((a) => _taskIdOf(a.attributes['href'], 'apply') == id)
        .firstOrNull;
    final drawLink = row
        .querySelectorAll('a[href*="do=draw"]')
        .where((a) => _taskIdOf(a.attributes['href'], 'draw') == id)
        .firstOrNull;
    String? blocked;
    if (applyLink == null && drawLink == null) {
      for (final a in row.querySelectorAll('a[onclick*="showDialog"]')) {
        if (_dialogText.firstMatch(a.attributes['onclick'] ?? '') case final match?) {
          blocked = match.group(1)!.replaceAll(r"\'", "'").trim();
          break;
        }
      }
    }
    final progressText = row.querySelector('span[id="csc_$id"]')?.text?.trim();
    final rewardCell = row.querySelector('td.xi1');
    final action = drawLink != null ? TaskActionKind.draw : (applyLink != null ? TaskActionKind.apply : null);
    String? note;
    if (tab != TaskCenterTab.available && action == null) {
      final last = row.querySelectorAll('td').lastOrNull;
      if (last != null && !identical(last, rewardCell)) {
        final text = _text(last);
        if (text.isNotEmpty) note = text;
      }
    } else if (tab == TaskCenterTab.done && action == TaskActionKind.apply) {
      final line = applyLink?.parent;
      if (line != null) {
        final text = _text(line).replaceAll(_text(applyLink), '').trim();
        if (text.isNotEmpty) note = text;
      }
    }
    tasks.add(
      ForumTask(
        id: id,
        name: _text(link),
        description: _text(_ancestor(link, 'td')?.querySelector('p.xg2')),
        reward: _text(rewardCell),
        progress: progressText == null ? null : (double.tryParse(progressText) ?? 0).clamp(0, 100).toDouble(),
        action: blocked != null ? null : action,
        blockedReason: blocked,
        note: note,
      ),
    );
  }
  String? message;
  if (tasks.isEmpty && document.querySelector('p.emp') == null) {
    final text = _text(document.querySelector('div#messagetext > p') ?? document.querySelector('div#messagetext'));
    if (text.isNotEmpty) message = text;
  }
  return TaskList(tab: tab, tasks: tasks, message: message);
}

/// How an apply or a claim ended, as the forum answered it.
enum TaskActionOutcome {
  /// The application was taken.
  applied,

  /// The reward was given.
  rewarded,

  /// The task is not complete yet; [TaskActionResult.progress] tells how far.
  inProgress,

  /// The task failed (its time ran out).
  failed,

  /// The forum refused with its message.
  refused,

  /// The forum asks to log in.
  loginRequired,

  /// The answer tells nothing; the refreshed lists do.
  unconfirmed,
}

/// The result of an apply or a claim of a task.
final class TaskActionResult {
  /// Constructor.
  const TaskActionResult({required this.taskId, required this.outcome, this.message, this.progress, this.uid});

  /// The task.
  final int taskId;

  /// What happened.
  final TaskActionOutcome outcome;

  /// The forum's own words, null when it gave none worth showing (a language key, an empty message).
  final String? message;

  /// The progress the forum answered a claim of an incomplete task with.
  final double? progress;

  /// The account the plugin's result says it was handled for (0 a guest), null without the plugin.
  final int? uid;
}

final _cdata = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');
final _succeed = RegExp(r"succeedhandle_\w*\('((?:[^'\\]|\\.)*)'\s*,\s*'((?:[^'\\]|\\.)*)'");
final _error = RegExp(r"errorhandle_\w*\('((?:[^'\\]|\\.)*)'");
final _drawAnswer = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\|([\s\S]*)$');
final _languageKey = RegExp(r'^\w+$');

String _unwrap(String body) => _cdata.firstMatch(body)?.group(1) ?? body;

String? _message(String? text) {
  final t = (text ?? '').replaceAll(_space, ' ').trim();
  return t.isEmpty || _languageKey.hasMatch(t) ? null : t;
}

bool _isTaskUrl(String url, String action, int id) => _taskIdOf(url, action) == id;

String _plain(String html) {
  if (html.trim().isEmpty) return '';
  return _text(parseHtmlDocument('<div>$html</div>').querySelector('div'));
}

/// The result of applying for task [id] from the answer [data] (the plugin's write result, or the forum's AJAX
/// fragment without the plugin) and, without the plugin, the [location] of a redirect the request did not follow.
///
/// The forum answers a refusal (`task_duplicate`, `task_grouplimit`…) as a note like a success, so only the
/// `task_applied` message, the success handler's link to the task's page, or the redirect to the claim of the same
/// task (a task that completes on applying) count as applied.
TaskActionResult taskApplyResultOf(Object? data, {required int id, String? location}) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    final uid = result.uid;
    if (result.login || result.messageKey == 'to_login') {
      return TaskActionResult(taskId: id, outcome: TaskActionOutcome.loginRequired, uid: uid);
    }
    final applied =
        result.messageKey == 'task_applied' ||
        (result.kind == TsdmAppWriteKind.redirect && _isTaskUrl(result.url, 'draw', id));
    if (applied) {
      return TaskActionResult(
        taskId: id,
        outcome: TaskActionOutcome.applied,
        message: _message(result.message),
        uid: uid,
      );
    }
    final message = _message(result.message);
    return TaskActionResult(
      taskId: id,
      outcome: message == null ? TaskActionOutcome.unconfirmed : TaskActionOutcome.refused,
      message: message,
      uid: uid,
    );
  }
  if (location != null) {
    if (_isTaskUrl(location, 'draw', id)) return TaskActionResult(taskId: id, outcome: TaskActionOutcome.applied);
    if (location.contains('mod=logging')) return TaskActionResult(taskId: id, outcome: TaskActionOutcome.loginRequired);
    return TaskActionResult(taskId: id, outcome: TaskActionOutcome.unconfirmed);
  }
  final body = _unwrap(tsdmAppAnswerText(data));
  if (_succeed.firstMatch(body) case final match?) {
    final message = _message(match.group(2));
    if (_isTaskUrl(match.group(1)!, 'view', id)) {
      return TaskActionResult(taskId: id, outcome: TaskActionOutcome.applied, message: message);
    }
    return TaskActionResult(
      taskId: id,
      outcome: message == null ? TaskActionOutcome.unconfirmed : TaskActionOutcome.refused,
      message: message,
    );
  }
  if (_error.firstMatch(body) case final match?) {
    final message = _message(match.group(1));
    return TaskActionResult(
      taskId: id,
      outcome: message == null ? TaskActionOutcome.unconfirmed : TaskActionOutcome.refused,
      message: message,
    );
  }
  if (body.contains('mod=logging')) return TaskActionResult(taskId: id, outcome: TaskActionOutcome.loginRequired);
  return TaskActionResult(taskId: id, outcome: TaskActionOutcome.unconfirmed);
}

/// The result of claiming the reward of task [id] from the answer [data].
///
/// The forum answers a claim it handled as `progress|message`: 100 is the reward given, -1 the task failed, any other
/// number the progress so far. The message of a reward is a language key the forum's packs lack
/// (`task_reward_credit`), never shown.
TaskActionResult taskDrawResultOf(Object? data, {required int id}) {
  final String body;
  int? uid;
  if (tsdmAppWriteResultOf(data) case final result?) {
    uid = result.uid;
    if (result.login || result.messageKey == 'to_login') {
      return TaskActionResult(taskId: id, outcome: TaskActionOutcome.loginRequired, uid: uid);
    }
    if (result.kind != TsdmAppWriteKind.page) {
      final message = _message(result.message);
      return TaskActionResult(
        taskId: id,
        outcome: message == null ? TaskActionOutcome.unconfirmed : TaskActionOutcome.refused,
        message: message,
        uid: uid,
      );
    }
    body = result.documentHtml;
  } else {
    body = _unwrap(tsdmAppAnswerText(data));
  }
  if (_drawAnswer.firstMatch(body) case final match?) {
    final progress = double.parse(match.group(1)!);
    final message = _message(_plain(match.group(2)!));
    final outcome = progress >= 100
        ? TaskActionOutcome.rewarded
        : progress < 0
        ? TaskActionOutcome.failed
        : TaskActionOutcome.inProgress;
    return TaskActionResult(
      taskId: id,
      outcome: outcome,
      message: message,
      progress: outcome == TaskActionOutcome.inProgress ? progress : null,
      uid: uid,
    );
  }
  if (_error.firstMatch(body) case final match?) {
    final message = _message(match.group(1));
    return TaskActionResult(
      taskId: id,
      outcome: message == null ? TaskActionOutcome.unconfirmed : TaskActionOutcome.refused,
      message: message,
      uid: uid,
    );
  }
  if (body.contains('mod=logging')) {
    return TaskActionResult(taskId: id, outcome: TaskActionOutcome.loginRequired, uid: uid);
  }
  return TaskActionResult(taskId: id, outcome: TaskActionOutcome.unconfirmed, uid: uid);
}
