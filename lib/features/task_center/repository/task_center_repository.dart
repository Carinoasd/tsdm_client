import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/task_center/models/task_center.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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
  /// Injected transports allow the task center to be tested without a live account.
  TaskCenterRepository({required this.getPage, required this.getWrite});

  /// Uses the account-bound client.
  ///
  /// The lists are asked in the JSON mode of the forum's app API, which answers them as the web page (the plugin has
  /// no structured task list). The apply and the claim are AJAX GETs that write: asked for the plugin's write result
  /// (since plugin 2.6.0), sent once without following a redirect (an apply of a task that completes on applying redirects
  /// to its claim, never sent by itself), the redirect's target kept for the answer without the plugin.
  factory TaskCenterRepository.network(NetClientProvider client) => TaskCenterRepository(
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

  /// Fetch the list of [tab] served to [uid].
  Future<TaskList> fetchList(TaskCenterTab tab, int uid) async {
    if (uid <= 0) throw const TaskCenterIdentityException(guest: true);
    final document = parseHtmlDocument(await getPage(tab.url));
    final served = parseLoggedUidFromDocument(document);
    if (served != uid) throw TaskCenterIdentityException(guest: served == null || served == 0);
    return parseTaskList(document, tab);
  }

  /// Apply for task [id] once. The answer is the forum's verdict; the caller refreshes the lists by GET.
  Future<TaskActionResult> apply(int id) async {
    final answer = await getWrite(taskApplyUrl(id));
    return taskApplyResultOf(answer.data, id: id, location: answer.location);
  }

  /// Claim the reward of task [id] once. The answer is the forum's verdict; the caller refreshes the lists by GET.
  Future<TaskActionResult> draw(int id) async {
    final answer = await getWrite(taskDrawUrl(id));
    return taskDrawResultOf(answer.data, id: id);
  }
}
