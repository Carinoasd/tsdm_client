import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// The served page or result belongs to another account or to a guest.
final class TaskCenterIdentityException implements Exception {
  /// Constructor.
  const TaskCenterIdentityException({required this.guest});

  /// The page was served to a guest: the session expired.
  final bool guest;
}

/// The answer of a GET that writes: its body and, for a redirect it did not follow, the target.
typedef TaskWriteAnswer = ({Object? data, String? location});

/// Task center access bound to one network client's account. An apply or a claim is sent once, never retried.
class TaskCenterRepository {
  /// Injected transports allow the task center to be tested without a live account; without [getV4Page] and
  /// [getV4Write] only the web pages and the old writes are used.
  TaskCenterRepository({
    required this.getPage,
    required this.getWrite,
    this.getV4Page,
    this.getV4Write,
    this.ensureStatus,
  });

  /// Uses the account-bound client.
  ///
  /// The lists are asked in the JSON mode of the forum's app API, which answers them as the web page (the plugin has
  /// no structured task list). The apply and the claim are AJAX GETs that write: asked for the plugin's write result
  /// (since plugin 2.6.0), sent once without following a redirect (an apply of a task that completes on applying redirects
  /// to its claim, never sent by itself), the redirect's target kept for the answer without the plugin.
  ///
  /// Once the forum's plugin answers the task pages as fields (plugin 4.0.0: `status` lists `task_list` in
  /// `task_pages`), the lists are asked as its pages (`tsdmv=4`) and the apply and the claim are its GETs that write
  /// ([getTsdmAppV4Write]: sent once, only when the user pressed the button).
  factory TaskCenterRepository.network(NetClientProvider client) => TaskCenterRepository(
    ensureStatus: () => TsdmAppApi.ensureStatus(client),
    getV4Page: (url) async => switch (await client.get(withTsdmAppV4Page(url)).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
    getV4Write: (url) async => switch (await getTsdmAppV4Write(client, url).run()) {
      Right(:final value) => value,
      Left(:final value) => throw value,
    },
    getPage: (url) => fetchTsdmAppPageHtml(client, url),
    getWrite: (url) async {
      final resp = await client
          .get(
            withTsdmAppJsonWrite(url),
            singleAttempt: true,
            options: Options(validateStatus: (code) => code != null && code < 400),
          )
          .run();
      return switch (resp) {
        Right(:final value) => (
          data: value.data,
          location: (value.statusCode ?? 200) >= 300 ? value.headers.value('location') : null,
        ),
        Left(:final value) => throw value,
      };
    },
  );

  /// Reads a task list page.
  final Future<String> Function(String url) getPage;

  /// Sends one apply or claim.
  final Future<TaskWriteAnswer> Function(String url) getWrite;

  /// Reads a page of plugin 4.0.0 (the url as it is, `tsdmv=4` added by the transport); its answer as it came.
  final Future<Object?> Function(String url)? getV4Page;

  /// Sends one apply or claim of plugin 4.0.0 (`tsdmv=4` added by the transport); its answer as it came.
  final Future<Object?> Function(String url)? getV4Write;

  /// Asks the plugin's `status` when this run has none yet.
  final Future<void> Function()? ensureStatus;

  /// The task pages are answered as fields (plugin 4.0.0).
  Future<bool> _v4() async {
    if (getV4Page == null) return false;
    await ensureStatus?.call();
    return TsdmAppV4.has(TsdmAppV4Group.taskPages, 'task_list');
  }

  /// Fetch the list of [tab] served to [uid].
  ///
  /// The page of plugin 4.0.0 when the plugin answers it ([taskListFromApi]): another account's is refused, the login
  /// prompt is the login, the forum's message (the task system closed) is the list's message; anything else (a
  /// message without words, not the page) reads the web page as before.
  Future<TaskList> fetchList(TaskCenterTab tab, int uid) async {
    if (uid <= 0) throw const TaskCenterIdentityException(guest: true);
    if (await _v4()) {
      final answer = tsdmAppV4AnswerOf(await getV4Page!(tab.url), type: 'task_list', schema: 65);
      if (answer != null && answer.uid != uid) {
        throw TaskCenterIdentityException(guest: answer.uid == 0);
      }
      switch (answer) {
        case TsdmAppV4Page(:final json):
          return taskListFromApi(json, tab);
        case TsdmAppV4Message(:final login) when login:
          throw const TaskCenterIdentityException(guest: true);
        case TsdmAppV4Message(:final message) when message.trim().isNotEmpty:
          return TaskList(tab: tab, tasks: const [], message: message.trim());
        case TsdmAppV4Message() || TsdmAppV4Refused() || null:
          break;
      }
    }
    final document = parseHtmlDocument(await getPage(tab.url));
    final served = parseLoggedUidFromDocument(document);
    if (served != uid) throw TaskCenterIdentityException(guest: served == null || served == 0);
    return parseTaskList(document, tab);
  }

  /// Apply for task [id] once. The answer is the forum's verdict; the caller refreshes the lists by GET.
  Future<TaskActionResult> apply(int id) async {
    if (await _v4() && getV4Write != null) {
      final data = await getV4Write!(taskV4ApplyUrl(id));
      return taskV4ActionResultOf(data, id: id, kind: TaskActionKind.apply) ?? taskApplyResultOf(data, id: id);
    }
    final answer = await getWrite(taskApplyUrl(id));
    return taskApplyResultOf(answer.data, id: id, location: answer.location);
  }

  /// Claim the reward of task [id] once. The answer is the forum's verdict; the caller refreshes the lists by GET.
  Future<TaskActionResult> draw(int id) async {
    if (await _v4() && getV4Write != null) {
      final data = await getV4Write!(taskV4DrawUrl(id));
      return taskV4ActionResultOf(data, id: id, kind: TaskActionKind.draw) ?? taskDrawResultOf(data, id: id);
    }
    final answer = await getWrite(taskDrawUrl(id));
    return taskDrawResultOf(answer.data, id: id);
  }
}
