import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// The served page belongs to another account or to a guest.
final class MagicIdentityException implements Exception {
  /// Constructor.
  const MagicIdentityException({required this.guest});

  /// The page was served to a guest: the session expired.
  final bool guest;
}

/// Magic shop access bound to one network client's account. A buy or a use is posted once, never retried.
class MagicRepository {
  /// Injected transports allow the shop to be tested without a live account.
  MagicRepository({required this.getPage, required this.getWindow, required this.postForm});

  /// Uses the account-bound client.
  factory MagicRepository.network(NetClientProvider client) => MagicRepository(
    // The plugin answers these pages as the web page itself; an empty body fails the read.
    getPage: (url) => fetchTsdmAppPageHtml(client, url),
    // The window is an AJAX fragment: the plugin's `page` result (plugin 2.6.0) or the forum's xml.
    getWindow: (url) async => switch (await client.get(withTsdmAppJsonWrite(url)).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
    postForm: (url, body) async => switch (await client.postForm(url, data: body, singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// Reads list pages only.
  final Future<String> Function(String url) getPage;

  /// Reads a buy or use window.
  final Future<Object?> Function(String url) getWindow;

  /// Sends one explicitly confirmed buy or use.
  final Future<Object?> Function(String url, Map<String, String> body) postForm;

  /// Fetch a validated list page served to [uid].
  Future<MagicListPage> fetchList(String url, MagicList list, int uid) async {
    final safe = magicListPageUrl(url, list);
    if (safe == null || uid <= 0) throw const FormatException('Magic page refused');
    final document = parseHtmlDocument(await getPage(safe));
    final served = magicServedUid(document);
    if (served != uid) {
      // A message page served to a guest is the login prompt whatever it says.
      throw MagicIdentityException(guest: served == null);
    }
    return parseMagicList(document, list);
  }

  /// The buy window of the shop's magic [identifier].
  Future<MagicForm> buyWindow(String identifier) => _window(
    '${magicShopUrl.replaceFirst('action=shop', 'action=shop&operation=buy')}'
    '&mid=${Uri.encodeQueryComponent(identifier)}&infloat=yes&handlekey=$magicHandleKey&inajax=1',
  );

  /// The use window of the account's magic [magicId].
  Future<MagicForm> useWindow(int magicId) => _window(
    '$magicBoxUrl&operation=use&magicid=$magicId&infloat=yes&handlekey=$magicHandleKey&inajax=1',
  );

  Future<MagicForm> _window(String url) async => parseMagicForm(magicWindowHtml(await getWindow(url)));

  /// Post [form] once with the user's [values]. A failed request is [MagicResultKind.unknown]: the forum may have
  /// taken the credits or the card, the caller checks by GET and never sends it again.
  Future<MagicResult> submit(MagicForm form, Map<String, String> values) async {
    try {
      return parseMagicResult(await postForm(form.action, form.body(values)));
    } on Object {
      return const MagicResult(MagicResultKind.unknown);
    }
  }
}
