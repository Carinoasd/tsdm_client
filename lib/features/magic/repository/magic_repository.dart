import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
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
  MagicRepository({
    required this.getPage,
    required this.getWindow,
    required this.postForm,
    this.getV4,
    this.postV4,
    this.ensureStatus,
  });

  /// Uses the account-bound client.
  ///
  /// Once the forum's plugin answers the magic pages and windows as fields (plugin 4.0.0: `status` lists
  /// `magic_shop`, `magic_mybox` in `magic_pages` and `magicbuy`, `magicuse` in `forms`), they are asked with `tsdmv=4`
  /// (the windows as small forms) and a form of them is posted back once with `tsdmv=4` ([postTsdmAppV4]).
  factory MagicRepository.network(NetClientProvider client) => MagicRepository(
    ensureStatus: () => TsdmAppApi.ensureStatus(client),
    getV4: (url) async => switch (await client.get(url).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
    postV4: (url, body) async => switch (await postTsdmAppV4(client, url, body).run()) {
      Right(:final value) => value,
      Left(:final value) => throw value,
    },
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

  /// Reads a page or a window of plugin 4.0.0 (the url as asked, its parameters added by the caller).
  final Future<Object?> Function(String url)? getV4;

  /// Sends one buy or use of a form of plugin 4.0.0 (`tsdmapp=json&tsdmv=4` added by the transport).
  final Future<Object?> Function(String url, Map<String, String> body)? postV4;

  /// Asks the plugin's `status` when this run has none yet.
  final Future<void> Function()? ensureStatus;

  Future<bool> _has(TsdmAppV4Group group, String name) async {
    if (getV4 == null) return false;
    await ensureStatus?.call();
    return TsdmAppV4.has(group, name);
  }

  /// Fetch a validated list page served to [uid].
  ///
  /// The page of plugin 4.0.0 when the plugin answers it ([magicListPageFromApi]): another account's is refused, the
  /// forum's message (magics closed, no permission, the login prompt) is [MagicForumMessage]; anything else (a
  /// message without words, not the page) reads the web page as before.
  Future<MagicListPage> fetchList(String url, MagicList list, int uid) async {
    final safe = magicListPageUrl(url, list);
    if (safe == null || uid <= 0) throw const FormatException('Magic page refused');
    final (type, schema, name) = list == MagicList.shop
        ? ('magic_shop', 69, 'magic_shop')
        : ('magic_mybox', 70, 'magic_mybox');
    if (await _has(TsdmAppV4Group.magicPages, name)) {
      final answer = tsdmAppV4AnswerOf(await getV4!(withTsdmAppV4Page(safe)), type: type, schema: schema);
      if (answer != null && answer.uid != uid) {
        if (answer case TsdmAppV4Message(:final login, :final reason) when login && answer.uid == 0) {
          throw MagicForumMessage(reason, login: true);
        }
        throw MagicIdentityException(guest: answer.uid == 0);
      }
      switch (answer) {
        case TsdmAppV4Page(:final json):
          return magicListPageFromApi(json, list, safe);
        case TsdmAppV4Message(:final reason, :final login) when login || reason.trim().isNotEmpty:
          throw MagicForumMessage(reason.trim(), login: login);
        case TsdmAppV4Message() || TsdmAppV4Refused() || null:
          break;
      }
    }
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

  Future<MagicForm> _window(String url) async {
    final kind = url.contains('operation=buy') ? SmallFormKind.magicbuy : SmallFormKind.magicuse;
    if (await _has(TsdmAppV4Group.forms, kind.name)) {
      // The plugin answers the window as its small form only with `tsdmv=4` (the test forum, though spec 7.9 and 7.10
      // write the urls without it).
      if (magicFormFromApi(await getV4!(withTsdmAppV4Form(url)), kind) case final form?) {
        return form;
      }
    }
    return parseMagicForm(magicWindowHtml(await getWindow(url)));
  }

  /// Post [form] once with the user's [values]. A failed request is [MagicResultKind.unknown]: the forum may have
  /// taken the credits or the card, the caller checks by GET and never sends it again.
  Future<MagicResult> submit(MagicForm form, Map<String, String> values) async {
    try {
      if (form.api && postV4 != null) {
        return magicV4ResultOf(await postV4!(form.action, form.body(values)), buy: form.hidden['operation'] == 'buy');
      }
      return parseMagicResult(await postForm(form.action, form.body(values)));
    } on Object {
      return const MagicResult(MagicResultKind.unknown);
    }
  }
}
