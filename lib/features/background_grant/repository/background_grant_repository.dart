import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/background_grant/models/background_grant.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Reads `bggrant` of the forum's app API and posts the background plugin's sending form, bound to the account logged
/// in: an answer served to another account is dropped and a sending is never made once the account changed
/// ([IdentityChangedException]).
class BackgroundGrantRepository {
  /// Transports are injected so the page is tested without a forum.
  BackgroundGrantRepository({required this.ask, required this.post, int Function()? currentUid})
    : _currentUid = currentUid ?? currentLoginUid;

  /// Uses the account-bound [client].
  factory BackgroundGrantRepository.network(NetClientProvider client) => BackgroundGrantRepository(
    ask: (query) => TsdmAppApi.askWaiting(client, 'bggrant', query),
    // One attempt: a sending is never made twice (the plugin does not refuse a second one). The write result of the
    // forum's app API (`tsdmapp=json`, added by `NetClientProvider.postForm`) carries the plugin's message.
    post: (url, data) async => switch (await client.postForm(url, data: data, singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// Ask `bggrant` with the query given; null when it can not answer.
  final Future<Map<String, dynamic>?> Function(Map<String, String> query) ask;

  /// POST a form once; the answer as it came.
  final Future<Object?> Function(String url, Map<String, String> data) post;

  final int Function() _currentUid;

  /// The catalogue's page [page], filtered by [keyword] when not empty; null when the forum can not answer.
  Future<BackgroundGrantInfo?> load({String keyword = '', int page = 1}) async {
    final uid = _currentUid();
    final json = await ask({if (keyword.isNotEmpty) 'kw': keyword, if (page > 1) 'page': '$page'});
    final info = BackgroundGrantInfo.fromJson(json);
    if (info != null && (info.uid != uid || _currentUid() != uid)) {
      throw IdentityChangedException();
    }
    return info;
  }

  /// Send [image] to [uids] until [expiry] with [info]'s form, a notice when [notify]; once.
  Future<BackgroundGrantResult> submit(
    BackgroundGrantInfo info, {
    required String image,
    required List<int> uids,
    required String expiry,
    required bool notify,
  }) async {
    final form = info.form;
    if (form == null) {
      return (success: false, message: '');
    }
    if (info.uid <= 0 || _currentUid() != info.uid) {
      throw IdentityChangedException();
    }
    final data = await post(form.url, form.body(image: image, uids: uids, expiry: expiry, notify: notify));
    final result = tsdmAppWriteResultOf(data);
    if (result != null && result.uid != info.uid) {
      throw IdentityChangedException();
    }
    // The plugin's 提示信息 is plain text; a forum answering its own page (no write result) is read as that page.
    final message = result?.message ?? parseFormResult(tsdmAppWriteAnswerHtml(data)).message;
    return backgroundGrantResultOf(message, form.successPrefix);
  }
}
