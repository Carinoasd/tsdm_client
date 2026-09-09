import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A repository that fetches the homepage html data from website.
///
/// One instance serves the whole app: the homepage tab and the topics tab share the same `forum.php` document, so
/// every fetch is published on [documentStream] and both tabs can re-parse it (issue #1: a favorite forum added on
/// the web only showed up after a refresh on the topics tab itself).
///
/// **Need to call dispose.**
final class ForumHomeRepository with LoggerMixin {
  /// Cached document of forum homepage.
  uh.Document? _document;

  /// Every document fetched from the server, the latest one replayed to new listeners.
  final _documentSubject = BehaviorSubject<uh.Document>();

  /// Stream of every `forum.php` document fetched from the server, in order; a new listener gets the latest one
  /// first when there is any.
  Stream<uh.Document> get documentStream => _documentSubject.stream;

  /// Check has cached html [_document] or not.
  bool hasCache() => _document != null;

  /// Get the cached [_document].
  uh.Document? getCache() => _document;

  /// Drop the cached document so the next fetch goes to the server.
  void invalidate() => _document = null;

  /// Release the stream.
  Future<void> dispose() async {
    await _documentSubject.close();
  }

  /// Fetch the home page of app from server.
  AsyncEither<uh.Document> fetchHomePage({bool force = false}) => AsyncEither(() async {
    debug('fetch home page');
    if (!force && _document != null) {
      debug('use cached home page');
      return right(_document!);
    }

    final docEither = await _fetchForumHome().run();
    if (docEither.isLeft()) {
      return left(docEither.unwrapErr());
    }

    final document = docEither.unwrap();
    _document = document;
    if (!_documentSubject.isClosed) {
      _documentSubject.add(document);
    }
    debug('use fetched home page');
    return right(document);
  });

  /// Fetch the topic page of app from server.
  ///
  /// The topics tab shows the same `forum.php` as the homepage, so this is the same cache and the same fetch.
  AsyncEither<uh.Document> fetchTopicPage({bool force = false}) => fetchHomePage(force: force);

  /// Fetch the [homePage] of forum.
  ///
  /// # Exception
  ///
  /// * [HttpHandshakeFailedException] if GET request failed.
  AsyncEither<uh.Document> _fetchForumHome() =>
      getIt.get<NetClientProvider>().get(homePage).mapHttp((v) => parseHtmlDocument(v.data as String));
}
