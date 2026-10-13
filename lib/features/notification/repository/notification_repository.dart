import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/fetch_bound.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// One fetch of every notification kind, with the forum's clock when it was answered.
typedef FetchedNotification = ({NotificationV2 info, DateTime? serverTime});

/// Repository of notification.
///
/// ## Note on API versions
///
/// The v2 JSON API (`plugin.php?mobile=yes&tsdmapp=1&id=Kahrpba:usernotify`) is GONE since the server upgraded to
/// Discuz X5, the server responds a normal html page on it now. So the "v2" fetching here is implemented by scraping
/// the three html pages:
///
/// * `home.php?mod=space&do=notice` for notices.
/// * `home.php?mod=space&do=pm&filter=privatepm` for personal messages.
/// * `home.php?mod=space&do=pm&filter=announcepm` for broadcast messages.
///
/// and converting the result into the same [NotificationV2] model so the whole notification stack (bloc, storage and
/// widgets) keeps working.
///
/// The three pages are asked in the JSON mode of the forum's app API ([withTsdmAppJson], roadmap item 3): the private
/// message pages are answered by plugin 1.3.0 and later, the notice page by 1.6.0. The forum still renders the whole
/// page, so reading the notice page marks the notices read as before; an older plugin, or a forum without it, answers
/// the web page, which parses the same ([tsdmAppPageDocument]).
final class NotificationRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [storageProvider] records the session expiry of the current account (issue #25); the global one is used when
  /// not given and registered.
  ///
  /// [retryDelay] is the wait before the one retry of a polling fetch that could not reach the forum.
  NotificationRepository({StorageProvider? storageProvider, Duration retryDelay = const Duration(seconds: 5)})
    : _storageProvider = storageProvider,
      _retryDelay = retryDelay;

  final StorageProvider? _storageProvider;
  final Duration _retryDelay;

  StorageProvider? get _storage =>
      _storageProvider ?? (getIt.isRegistered<StorageProvider>() ? getIt.get<StorageProvider>() : null);

  /// Provide a stream of [NotificationInfoState] those are fetched from server.
  ///
  /// Carries fetch result and fetched info if any.
  final _controller = BehaviorSubject<NotificationInfoState>();

  /// Stream of fetched notification fetching status.
  Stream<NotificationInfoState> get status => _controller.asBroadcastStream();

  /// Fetch the html document of notice detail page.
  ///
  /// A thread page (the `findpost` redirect of a notice, carried to the thread page by the plugin) or a private
  /// message page (a broadcast message) is asked in JSON mode, see [jsonModeDetailUrl]; the page number still comes
  /// from where the forum redirected to.
  AsyncEither<(uh.Document, String? page)> fetchDocument(String url) => AsyncEither(
    () async => switch (await getIt.get<NetClientProvider>().get(jsonModeDetailUrl(url)).run()) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right((
        tsdmAppPageDocument(value.data),
        value.realUri.tryGetQueryParameters()?['page'],
      )),
    },
  );

  /// [url] of a notice or broadcast message detail, in the JSON mode of the forum's app API when the plugin answers
  /// that page: forum thread pages and their `findpost` redirect, and the private message pages (`home.php`
  /// `do=pm`). Any other page a notice links to is fetched as it is.
  ///
  /// Marked as public for testing.
  static String jsonModeDetailUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isForumOrRelative) {
      return url;
    }
    final query = uri.queryParameters;
    final answered = switch (uri.pathSegments.lastOrNull) {
      'forum.php' => query['mod'] == 'viewthread' || query['mod'] == 'redirect',
      'home.php' => query['mod'] == 'space' && query['do'] == 'pm',
      _ => false,
    };
    return answered ? withTsdmAppJson(url) : url;
  }

  /// Build the timestamp (in seconds) to filter notifications, same rule as the old v2 API:
  ///
  /// Use [timestamp] if it is in recent 3 days, otherwise 3 days ago.
  static int _buildSinceTimestamp(int? timestamp) {
    final now = DateTime.now();
    final time = timestamp != null ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000) : now;
    if (timestamp != null && 0 <= now.difference(time).inDays && now.difference(time).inDays <= 3) {
      return timestamp;
    }
    return now.add(const Duration(days: -3)).millisecondsSinceEpoch ~/ 1000;
  }

  /// Fetch a html page as document with the current user's client.
  AsyncEither<uh.Document> _fetchPage(String url) => _fetchPageWith(getIt.get<NetClientProvider>(), url);

  /// Fetch a notification page as document with [client], in JSON mode (see the class document).
  static AsyncEither<uh.Document> _fetchPageWith(NetClientProvider client, String url) =>
      _fetchPageWithTime(client, url).map((v) => v.$1);

  /// Same as [_fetchPageWith], plus the forum's clock from the answer's `Date` header (null when absent); a JSON
  /// answer carries it too.
  ///
  /// A JSON answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or an empty body) fails
  /// like a bad answer, so the poll does not take it for an empty list and move its window past what it did not read.
  static AsyncEither<(uh.Document, DateTime?)> _fetchPageWithTime(NetClientProvider client, String url) => AsyncEither(
    () async => switch (await client.get(withTsdmAppJson(url)).run()) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(value.data) => left(
        HttpRequestFailedException(value.statusCode),
      ),
      Right(:final value) => right((tsdmAppPageDocument(value.data), serverTimeOf(value.headers))),
    },
  );

  /// Fetch all notices from server page.
  AsyncEither<List<Notice>> fetchNotice() => _fetchPage(
    noticeUrl,
  ).map((doc) => NotificationV2.noticeNodes(doc).map(Notice.fromClNode).whereType<Notice>().toList());

  /// Fetch all personal messages from server page.
  AsyncEither<List<PersonalMessage>> fetchPersonalMessage() =>
      _fetchPage(
        personalMessageUrl,
      ).map(
        (doc) =>
            NotificationV2.personalMessageNodes(doc).map(PersonalMessage.fromDl).whereType<PersonalMessage>().toList(),
      );

  /// Fetch all broadcast messages from server page.
  AsyncEither<List<BroadcastMessage>> fetchBroadMessage() =>
      _fetchPage(
        broadcastMessageUrl,
      ).map(
        (doc) => NotificationV2.broadcastMessageNodes(
          doc,
        ).map(BroadcastMessage.fromDl).whereType<BroadcastMessage>().toList(),
      );

  /// Fetch all kinds of notification with [client], without touching the [status] stream.
  ///
  /// [timestamp] is the last time call this api (in seconds). Only notifications since [timestamp] are returned.
  /// Notifications in recent 3 days are returned if [timestamp] is null or older than 3 days, same as the old API.
  ///
  /// The account is whatever [client] carries: the current-user fetch ([fetchNotificationV2]) passes the default
  /// client, the sync of all accounts passes one client per stored account. Returns [NotificationUserNotFound] when
  /// the server answered the guest page (session expired), the request error otherwise.
  ///
  /// The returned `serverTime` is the earliest `Date` header of the three answers, null when
  /// the server sent none: the caller stores the lower bound of its next fetch from that clock (GitHub #71).
  ///
  /// A polling fetch (with [timestamp]) asks the forum's app API first when it has one ([TsdmAppApi]): when nothing
  /// arrived since then, the three pages are not fetched and an empty result with the forum's clock is returned. The
  /// pages stay the source of every notification shown: fetching the notice page is also what marks the notices read
  /// on the forum, as it always did.
  ///
  /// With [retry], a polling fetch that could not reach the forum at all (no answer: name resolution, connection or
  /// timeout) is tried once more after a few seconds: the network often comes back a moment after the device wakes
  /// up (GitHub #173). An answer with an error status is not retried. The in-app auto sync does not ask for it: the
  /// wait would hold its "fetching" state, which the login and account switch flows wait on.
  AsyncEither<FetchedNotification> fetchNotificationWith(
    NetClientProvider client, {
    int? timestamp,
    bool retry = false,
  }) => AsyncEither(() async {
    final first = await _fetchNotificationOnce(client, timestamp: timestamp).run();
    if (first case Left(
      value: HttpHandshakeFailedException(statusCode: null) && final e,
    ) when retry && timestamp != null) {
      debug('forum not reached, trying again in ${_retryDelay.inSeconds}s: ${e.message}');
      await Future<void>.delayed(_retryDelay);
      return _fetchNotificationOnce(client, timestamp: timestamp).run();
    }
    return first;
  });

  AsyncEither<FetchedNotification> _fetchNotificationOnce(NetClientProvider client, {int? timestamp}) =>
      AsyncEither(() async {
        final since = _buildSinceTimestamp(timestamp);
        if (timestamp != null) {
          switch (notifyGateOf(await TsdmAppApi.ask(client, 'notify', {'since': '$since'}), since: since)) {
            case TsdmAppNothingNew(:final serverTime):
              debug('nothing new since $since by the app api, pages skipped');
              return right((info: NotificationV2.empty, serverTime: serverTime));
            case TsdmAppNotLoggedIn():
              error('failed to fetch notification: not logged in (app api)');
              return left(NotificationUserNotFound());
            case TsdmAppFetchPages():
              break;
          }
        }
        final results = await Future.wait([
          _fetchPageWithTime(client, noticeUrl).run(),
          _fetchPageWithTime(client, personalMessageUrl).run(),
          _fetchPageWithTime(client, broadcastMessageUrl).run(),
        ]);
        for (final r in results) {
          if (r case Left(:final value)) {
            error('failed to fetch notification: $value');
            return left(value);
          }
        }
        final pages = results.map((r) => r.getOrElse((_) => throw StateError('unreachable'))).toList();
        final serverTime = earliestOf(pages.map((page) => page.$2));
        final noticeDoc = pages[0].$1;
        // Session expired: the server renders a guest page with the login form, not an empty notice list.
        if (noticeDoc.querySelector('form#lsform') != null && noticeDoc.querySelector('div#um') == null) {
          error('failed to fetch notification: not logged in');
          return left(NotificationUserNotFound());
        }
        final info = NotificationV2.fromDocuments(
          noticeDoc: noticeDoc,
          personalMessageDoc: pages[1].$1,
          broadcastMessageDoc: pages[2].$1,
          since: since,
        );
        debug(
          'fetched notification since $since: notice=${info.noticeList.length} '
          'pm=${info.personalMessageList.length} bm=${info.broadcastMessageList.length} '
          'serverTime=${serverTime?.toIso8601String() ?? 'unknown'}',
        );
        return right((info: info, serverTime: serverTime));
      });

  /// Fetch all kinds of notification of the current user.
  ///
  /// [timestamp] is the last time call this api (in seconds). Only notifications since [timestamp] are returned.
  /// Notifications in recent 3 days are returned if [timestamp] is null or older than 3 days, same as the old API.
  /// [uid] is the user id of whom to do the fetch action.
  ///
  /// The result is delivered on [status]: [NotificationInfoStateLoading] first, then [NotificationInfoStateFailure]
  /// or [NotificationInfoStateSuccess]. The fetch itself is [fetchNotificationWith] on the default client.
  ///
  /// The name is kept for compatibility, see the class document for details.
  ///
  /// Resolves to the forum's clock of the fetch (see [fetchNotificationWith]), null when the server did not say.
  AsyncEither<DateTime?> fetchNotificationV2({required int uid, int? timestamp}) {
    _controller.add(const NotificationInfoStateLoading());
    return AsyncEither(() async {
      final result = await fetchNotificationWith(getIt.get<NetClientProvider>(), timestamp: timestamp).run();
      switch (result) {
        case Left(:final value):
          if (value is NotificationUserNotFound) {
            // The forum answered the guest page to the current account's cookie: its session is dead (issue #25).
            await _storage?.markSessionExpired(uid);
          }
          _controller.add(const NotificationInfoStateFailure());
          return left(value);
        case Right(:final value):
          _controller.add(NotificationInfoStateSuccess(uid, value.info, since: timestamp));
          return right(value.serverTime);
      }
    });
  }

  /// Dispose the repo.
  Future<void> dispose() async {
    await _controller.close();
  }
}
