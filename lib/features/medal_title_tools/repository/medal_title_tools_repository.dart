import 'dart:convert';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// What the forum answered to a form: the message of its 提示信息 page.
final class FormResult {
  /// Constructor.
  const FormResult({required this.success, required this.message});

  /// The forum's answer is not an error. A success page is not proof that anything changed; the page is read again.
  final bool success;

  /// The message as served.
  final String message;
}

/// The message of a 提示信息 page in [html]: `alert_error` is a refusal, `alert_right` and `alert_info` are not.
FormResult parseFormResult(String html) {
  final document = parseHtmlDocument(html);
  String text(uh.Element? node) {
    if (node == null) return '';
    final clone = node.clone(true) as uh.Element;
    for (final e in clone.querySelectorAll('script, style')) {
      e.remove();
    }
    for (final br in clone.querySelectorAll('br')) {
      br.replaceWith(uh.Text('\n'));
    }
    return (clone.text ?? '')
        .split('\n')
        .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
  }

  final box = document.querySelector('#messagetext');
  final message = text(box?.querySelector('p') ?? box);
  if (document.querySelector('.alert_error') != null) {
    return FormResult(success: false, message: message);
  }
  return FormResult(success: message.isNotEmpty, message: message);
}

/// Reads the medal and title pages of the forum's app API and posts the plugins' forms; bound to one account's client.
class MedalTitleToolsRepository {
  /// Transports are injected so the pages can be tested without a forum.
  MedalTitleToolsRepository({required this.ask, required this.getJson, required this.post});

  /// Uses the account-bound [client].
  factory MedalTitleToolsRepository.network(NetClientProvider client) => MedalTitleToolsRepository(
    ask: (action, query) => TsdmAppApi.askWaiting(client, action, query),
    getJson: (url) async => switch (await client.get(url).run()) {
      Right(:final value) => value.data is String ? jsonDecode(value.data as String) : value.data,
      Left(:final value) => throw value,
    },
    // One attempt: a write is never sent twice.
    post: (url, data) async => switch (await client.postForm(url, data: data, singleAttempt: true).run()) {
      Right(:final value) => '${value.data}',
      Left(:final value) => throw value,
    },
  );

  /// Ask an action of the app API; null when it can not answer.
  final Future<Map<String, dynamic>?> Function(String action, Map<String, String> query) ask;

  /// GET a JSON endpoint of a plugin.
  final Future<Object?> Function(String url) getJson;

  /// POST a form once; the answer page.
  final Future<String> Function(String url, Map<String, String> data) post;

  /// The title exchange page.
  Future<ExchangePage?> exchange({String filter = 'all', String q = '', int page = 1}) async => ExchangePage.fromJson(
    await ask('titleexchange', {'filter': filter, 'q': ?(q.isEmpty ? null : q), 'page': '$page'}),
  );

  /// My medals with a page of the record.
  Future<MyMedalsData?> myMedals({int page = 1}) async =>
      MyMedalsData.fromJson(await ask('mymedals', {'page': '$page'}));

  /// The send medals page with a page of sendings.
  Future<GrantInfo?> grant({int page = 1}) async => GrantInfo.fromJson(await ask('medalgrant', {'page': '$page'}));

  /// The issue titles page.
  Future<IssueInfo?> issue() async => IssueInfo.fromJson(await ask('titleissue', const {}));

  /// Post [form] with [extra] fields.
  Future<FormResult> submit(ApiForm form, Map<String, String> extra) async =>
      parseFormResult(await post(form.url, form.body(extra)));

  /// Look up the members [uids] and which of [medals] they have.
  Future<({List<GrantPerson> users, List<String> missing})?> lookup(
    String url,
    List<int> uids,
    List<int> medals,
  ) async => grantLookupFromJson(await getJson('$url&uids=${uids.join(',')}&mids=${medals.join(',')}'));

  /// The repliers of thread [tid] (floors [from] to [to], 0 for no bound), without the thread author when [noOwner].
  Future<({List<int> uids, int total, String subject, String? error})> threadRepliers(
    String url, {
    required int tid,
    int from = 0,
    int to = 0,
    bool noOwner = true,
  }) async {
    final json = await getJson('$url&tid=$tid&from=$from&to=$to&noowner=${noOwner ? 1 : 0}');
    if (json is! Map) return (uids: const <int>[], total: 0, subject: '', error: '');
    if (json['ok'] != 1) return (uids: const <int>[], total: 0, subject: '', error: '${json['error'] ?? ''}');
    return (
      uids: [for (final u in (json['uids'] as List? ?? const [])) (u as num).toInt()],
      total: (json['total'] as num?)?.toInt() ?? 0,
      subject: '${json['subject'] ?? ''}',
      error: null,
    );
  }
}
