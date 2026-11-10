import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/chat/utils/chat_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Repository to fetch chat related source.
final class ChatRepository {
  /// Constructor.
  ///
  /// [client] asks the chat dialog ([fetchChat]) as another account than the one of the global cookie (`getIt`): the
  /// reply typed in a notification, sent in the background as the account of the notification.
  const ChatRepository({NetClientProvider? client}) : _client = client;

  final NetClientProvider? _client;

  /// Fetch the chat history with user [uid], page [page] (the forum serves the last page without one).
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the conversation page (`do=pm&subop=view`) since
  /// plugin 1.3.0. Plugin 2.5.0 answers it as structured fields (`schema: 11`, [chatApiAnswerOf]), kept as a
  /// [TsdmAppStructuredPage] for `chatHistoryFromApi`; an older plugin answers the web page ([TsdmAppWebPage]), which
  /// parses as before. An answer without a page is a failed request, not a history without messages
  /// ([TsdmAppPageHttpExt.mapHttpPageAnswer]).
  AsyncEither<TsdmAppPageAnswer> fetchChatHistory(String uid, {int? page}) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson(formatChatFullHistoryUrl(uid, page: page)))
      .mapHttpPageAnswer(chatApiAnswerOf);

  /// Fetch the chat dialog with user [uid]: an AJAX answer (the html inside the xml), not a page of the JSON mode.
  AsyncEither<uh.Document> fetchChat(String uid) => AsyncEither(() async {
    final respEither = await (_client ?? getIt.get<NetClientProvider>()).get(formatChatUrl(uid)).run();

    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }
    final xmlDoc = parseXmlDocument(resp.data as String);
    final htmlBodyData = xmlDoc.documentElement?.nodes.firstOrNull?.text;
    if (htmlBodyData == null) {
      return left(ChatDataDocumentNotFoundException());
    }
    final document = parseHtmlDocument(htmlBodyData);
    return right(document);
  });
}
