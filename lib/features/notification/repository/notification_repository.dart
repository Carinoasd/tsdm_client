import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:dio/dio.dart' show Response;
import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/fetch_bound.dart';
import 'package:tsdm_client/features/notification/utils/relative_time.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// One fetch of every notification kind, with the forum's clock when it was answered and the lower bound (seconds)
/// the fetch used, after the clamp to the last three days: `window`. `servedUid` is the account the forum answered
/// as (the `uid` of `notify`, or the user node of the notice page), null when it did not tell.
typedef FetchedNotification = ({NotificationV2 info, DateTime? serverTime, int window, int? servedUid});

/// The account a `notify` answer [json] was served to, null when it does not tell.
int? _servedUidOfNotify(Map<String, dynamic>? json) => switch (json?['uid']) {
  final num uid when uid > 0 => uid.toInt(),
  _ => null,
};

/// The thread page a notice points to ([NotificationRepository.fetchNoticeThread]): built from the structured answer
/// of the forum's app API (plugin 2.1.0, `schema: 3`), or the document of any other answer, parsed by the reader as
/// before.
sealed class NoticeThreadPage {
  const NoticeThreadPage();
}

/// The page built from the structured answer ([threadPageFromApi]); its page number is the page's own.
final class NoticeThreadPageBuilt extends NoticeThreadPage {
  /// Constructor.
  const NoticeThreadPageBuilt(this.page);

  /// The page, the floor of the notice among its posts when the forum still shows it.
  final ThreadPageInfo page;
}

/// The document of the answer (the web page, an older plugin's answer), with the page number the forum redirected to.
final class NoticeThreadPageDocument extends NoticeThreadPage {
  /// Constructor.
  const NoticeThreadPageDocument(this.document, this.page);

  /// The document.
  final uh.Document document;

  /// The `page` of the url the forum redirected to, null when it named none.
  final String? page;
}

/// Repository of notification.
///
/// ## Note on API versions
///
/// The v2 JSON API (`plugin.php?mobile=yes&tsdmapp=1&id=Kahrpba:usernotify`) is GONE since the server upgraded to
/// Discuz X5, the server responds a normal html page on it now. The "v2" fetching here reads the forum's app API
/// ([TsdmAppApi], the `tsdmapp` plugin) and three html pages instead:
///
/// * `home.php?mod=space&do=notice` for notices.
/// * `home.php?mod=space&do=pm&filter=privatepm` for personal messages.
/// * `home.php?mod=space&do=pm&filter=announcepm` for broadcast messages.
///
/// and converts the result into the same [NotificationV2] model so the whole notification stack (bloc, storage and
/// widgets) keeps working.
///
/// Every fetch asks the API's `notify` first. Since plugin 1.9.0 its answer carries the notices and the unread
/// broadcast messages, and `pmlist` the conversation list of the private message page: the notice page and the
/// private message page are not fetched any more, and the broadcast message page only when the read ones are wanted
/// too (the first fetch, a refresh the user asked for). Opening the two pages on the web is also what marks the
/// notices read and clears the forum's "new" prompts, so the fetch posts `seen` for that instead. With an older
/// plugin `notify` only tells whether anything arrived (a poll with nothing new fetches no page), and without the
/// plugin, or when an answer is missing, the three pages are read as before.
///
/// The pages are asked in the JSON mode of the forum's app API ([withTsdmAppJson], roadmap item 3): the private
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
  ///
  /// [seenTimeout] is how long a fetch waits for its `seen` ([TsdmAppApi.post]) before it goes on without it.
  NotificationRepository({
    StorageProvider? storageProvider,
    Duration retryDelay = const Duration(seconds: 5),
    Duration seenTimeout = const Duration(seconds: 8),
  }) : _storageProvider = storageProvider,
       _retryDelay = retryDelay,
       _seenTimeout = seenTimeout;

  final StorageProvider? _storageProvider;
  final Duration _retryDelay;
  final Duration _seenTimeout;

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
      Right(:final value) when value.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(value.data) => left(
        HttpRequestFailedException(value.statusCode),
      ),
      Right(:final value) => right((
        tsdmAppPageDocument(value.data),
        value.realUri.tryGetQueryParameters()?['page'],
      )),
    },
  );

  /// Fetch the thread page a notice points to ([url], the `findpost` redirect of the notice), see [NoticeThreadPage].
  ///
  /// Asked as [fetchDocument] asks it. An answer of plugin 2.1.0 or later carries the page as structured fields
  /// (`schema: 3`, or the forum's message with `login`): the page is built from them, its `document` never read
  /// ([threadApiAnswerOf]); any other answer is given as its document with the page number of the redirect, for the
  /// reader to parse as before.
  AsyncEither<NoticeThreadPage> fetchNoticeThread(String url) => AsyncEither(() async {
    final Response<dynamic> resp;
    switch (await getIt.get<NetClientProvider>().get(jsonModeDetailUrl(url)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        resp = value;
    }
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }
    final api = threadApiAnswerOf(resp.data);
    if (api != null) {
      return right(NoticeThreadPageBuilt(threadPageFromApi(api, 1)));
    }
    if (tsdmAppAnswerWithoutPage(resp.data)) {
      return left(HttpRequestFailedException(resp.statusCode));
    }
    return right(
      NoticeThreadPageDocument(tsdmAppPageDocument(resp.data), resp.realUri.tryGetQueryParameters()?['page']),
    );
  });

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

  /// How far ahead of the device clock a stored fetch bound may lie and still be used: a device clock a little
  /// behind the forum's (the bound comes from the forum's clock, GitHub #71).
  static const boundAheadTolerance = Duration(minutes: 10);

  /// Build the timestamp (in seconds) to filter notifications, same rule as the old v2 API:
  ///
  /// Use [timestamp] if it is in recent 3 days, otherwise 3 days ago. A [timestamp] more than
  /// [boundAheadTolerance] ahead of the device clock is no bound either: older builds recorded the time of the newest
  /// item fetched, which on a device in another zone than the member's forum offset lies hours in the future (see
  /// `apiTimeOf`), and such a bound made every poll find nothing new.
  static int _buildSinceTimestamp(int? timestamp) {
    final now = DateTime.now();
    final time = timestamp != null ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000) : now;
    if (timestamp != null && !time.isAfter(now.add(boundAheadTolerance)) && now.difference(time).inDays <= 3) {
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
  /// The returned `serverTime` is the earliest `Date` header of the pages fetched (and the clock of `notify` when its
  /// lists are read, see below), null when the server sent none: the caller stores the lower bound of its next fetch
  /// from that clock (GitHub #71).
  ///
  /// Every fetch asks the forum's app API first when it has one ([TsdmAppApi], `notify`); an answer that the session
  /// expired gives [NotificationUserNotFound] at once. For a polling fetch (with [timestamp]) with nothing arrived
  /// since then, nothing else is fetched and an empty result with the forum's clock is returned; with plugin 1.9.0 a
  /// `seen` for the notices it still lists as unread is posted first (see below).
  ///
  /// Plugin 1.9.0 answers the lists themselves ([notifyCarriesLists]): the notices come from `notify`, the
  /// conversations from `pmlist` (only when one changed, for a poll; the private message page when `pmlist` does not
  /// answer) and the broadcast messages from `notify` (unread ones only, for a poll) or the broadcast message page.
  /// The fetch then posts `seen` ([TsdmAppApi.post]) for what reading the notice page and the private message page
  /// does on the forum: the notices marked read when `notify` listed one unread (unless one arrived or was flagged
  /// again since it answered, see [notifyListsUnreadNotice]), the "new" prompts cleared. A failed `seen` is only
  /// logged; the next fetch posts it again while `notify` still lists unread notices, a poll with nothing new too
  /// (the prompt of the private messages only after the next `pmlist`: `notify` does not tell it); nothing is marked
  /// with a bound ahead of the forum's clock. The lists are kept by the bound taken in their own time representation
  /// ([apiTimeOf]: the member's wall clock as the device's local time), and the returned `window` is in it too; the
  /// three pages are still compared with the real bound, as they always were. `serverTime` is the earliest of the
  /// `notify` clock and the `Date` headers of the pages read. With an older plugin, or without
  /// one, the three pages are the source of every notification shown: fetching the notice page is also what marks
  /// the notices read on the forum, as it always did.
  ///
  /// With [bypassGate] the answer of `notify` never skips the fetch and every conversation of the private message
  /// list is kept whatever its time: for a refresh the user asked for (the notification page) and the one after
  /// sending a private message (GitHub #193). `notify` lists the unread received conversations only, so a
  /// conversation last sent to, or read on the web, never made a poll fetch the list and never reached it.
  ///
  /// With [retry], a polling fetch that could not reach the forum at all (no answer: name resolution, connection or
  /// timeout) is tried once more after a few seconds: the network often comes back a moment after the device wakes
  /// up (GitHub #173). An answer with an error status is not retried. The in-app auto sync does not ask for it: the
  /// wait would hold its "fetching" state, which the login and account switch flows wait on.
  AsyncEither<FetchedNotification> fetchNotificationWith(
    NetClientProvider client, {
    int? timestamp,
    bool retry = false,
    bool bypassGate = false,
  }) => AsyncEither(() async {
    final first = await _fetchNotificationOnce(client, timestamp: timestamp, bypassGate: bypassGate).run();
    if (first case Left(
      value: HttpHandshakeFailedException(statusCode: null) && final e,
    ) when retry && timestamp != null) {
      debug('forum not reached, trying again in ${_retryDelay.inSeconds}s: ${e.message}');
      await Future<void>.delayed(_retryDelay);
      return _fetchNotificationOnce(client, timestamp: timestamp, bypassGate: bypassGate).run();
    }
    return first;
  });

  AsyncEither<FetchedNotification> _fetchNotificationOnce(
    NetClientProvider client, {
    int? timestamp,
    bool bypassGate = false,
  }) => AsyncEither(() async {
    final since = _buildSinceTimestamp(timestamp);
    // A poll inside a known window; the first fetch and a refresh the user asked for read everything there is.
    final polling = timestamp != null && !bypassGate;
    final notify = await TsdmAppApi.ask(client, 'notify', {'since': '$since'});
    switch (notifyGateOf(notify, since: since)) {
      case TsdmAppNotLoggedIn():
        // Every plugin version answers it before reading the action: the pages would be the guest page.
        error('failed to fetch notification: not logged in (app api)');
        return left(NotificationUserNotFound());
      case TsdmAppNothingNew(:final serverTime) when polling:
        debug('nothing new since $since by the app api, pages skipped');
        // A successful `seen` leaves no unread notice on the forum: one still listed means an earlier `seen` failed
        // (or something else left it unread), and the web keeps its red dot until the next new event otherwise.
        // The "new private message" prompt is not retried: `notify` does not tell it. Nor is anything marked with a
        // bound ahead of the forum's clock: the notices since then were not fetched by this poll.
        if (notifyCarriesLists(notify) && notifyListsUnreadNotice(notify!) && since <= (notify['time'] as int)) {
          await _markSeen(client, notify['formhash'] as String, notice: notify['time'] as int, pm: false);
        }
        return right((
          info: NotificationV2.empty,
          serverTime: serverTime,
          window: since,
          servedUid: _servedUidOfNotify(notify),
        ));
      case TsdmAppNothingNew() || TsdmAppFetchPages():
        break;
    }
    if (notifyCarriesLists(notify)) {
      return _fetchWithApiLists(client, notify!, since: since, polling: polling, bypassGate: bypassGate);
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
      allPersonalMessages: bypassGate,
    );
    debug(
      'fetched notification since $since${bypassGate ? ' (gate bypassed, every conversation)' : ''}: notice=${info.noticeList.length} '
      'pm=${info.personalMessageList.length} bm=${info.broadcastMessageList.length} '
      'serverTime=${serverTime?.toIso8601String() ?? 'unknown'}',
    );
    return right((
      info: info,
      serverTime: serverTime,
      window: since,
      servedUid: _servedUidOfNotify(notify) ?? parseLoggedUidFromDocument(noticeDoc),
    ));
  });

  /// The rest of a fetch since [since] whose `notify` answer [notify] carries the lists ([notifyCarriesLists], plugin
  /// 1.9.0), see [fetchNotificationWith]. [polling] is a poll inside a known window, [bypassGate] a refresh that keeps
  /// every conversation.
  Future<Either<AppException, FetchedNotification>> _fetchWithApiLists(
    NetClientProvider client,
    Map<String, dynamic> notify, {
    required int since,
    required bool polling,
    required bool bypassGate,
  }) async {
    final timeOffset = notify['timeoffset'] as num;
    // The relative times of the notification page read "now" in the member's offset too.
    // Never fails the sync: without it the times read with the offset remembered before (8 by default).
    if (_servedUidOfNotify(notify) case final uid?) {
      try {
        await NotificationTimeOffsets.remember(_storage, uid, timeOffset);
      } on Object catch (e, st) {
        error('failed to remember the time offset of the account: $e');
        handleRaw(e, st);
      }
    }
    final notices = (notify['notices'] as List)
        .whereType<Map<String, dynamic>>()
        .map((e) => Notice.toV2FromApi(e, timeOffset: timeOffset))
        .whereType<NoticeV2>()
        .toList();
    // The first fetch and a refresh list every conversation; a poll only when one changed since its window began.
    final personalMessages = !polling || notifyPmSignalOf(notify, since: since) ? _personalMessagesWith(client) : null;
    // `notify` holds the unread broadcast messages only, which is all a poll keeps (GitHub #154).
    final broadcastPage = polling ? null : _fetchPageWithTime(client, broadcastMessageUrl).run();

    final pageTimes = <DateTime?>[];
    var pmListRead = false;
    var seenPm = false;
    var pmList = const <PersonalMessageV2>[];
    num? pmTimeOffset;
    if (personalMessages != null) {
      switch (await personalMessages) {
        case Left(:final value):
          await broadcastPage;
          error('failed to fetch notification: $value');
          return left(value);
        case Right(:final value):
          pmList = value.list;
          pmListRead = value.fromApi;
          seenPm = value.seenPm;
          pmTimeOffset = value.timeOffset;
          pageTimes.add(value.serverTime);
      }
    }
    final List<BroadcastMessageV2> broadcasts;
    if (broadcastPage == null) {
      broadcasts = (notify['announces'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => BroadcastMessage.toV2FromApi(e, timeOffset: timeOffset))
          .whereType<BroadcastMessageV2>()
          .toList();
    } else {
      switch (await broadcastPage) {
        case Left(:final value):
          error('failed to fetch notification: $value');
          return left(value);
        case Right(:final value):
          broadcasts = NotificationV2.broadcastMessagesOf(value.$1);
          pageTimes.add(value.$2);
      }
    }

    // The times of the lists are what the page path reads ([apiTimeOf]): compared with the bound in that same
    // representation, or a device in another zone than the member's offset keeps notices of hours before the window
    // (west of it) or drops the new ones (east of it), which `seen` then marks read on the forum. The page path below
    // still compares its times with the real bound, as it always did.
    final listSince = apiTimeOf(since, timeOffset);
    final pmSince = pmTimeOffset == null ? listSince : apiTimeOf(since, pmTimeOffset);
    final info = NotificationV2.within(
      notices: notices,
      personalMessages: pmList,
      broadcastMessages: broadcasts,
      since: listSince,
      personalMessagesSince: pmSince,
      allPersonalMessages: bypassGate,
    );
    final serverTime = earliestOf([
      DateTime.fromMillisecondsSinceEpoch((notify['time'] as int) * 1000, isUtc: true),
      ...pageTimes,
    ]);
    debug(
      'fetched notification by the app api since $since${bypassGate ? ' (gate bypassed, every conversation)' : ''}: '
      'notice=${info.noticeList.length} pm=${info.personalMessageList.length} '
      '(${personalMessages == null ? 'not asked' : (pmListRead ? 'pmlist' : 'page')}) '
      'bm=${info.broadcastMessageList.length} (${broadcastPage == null ? 'notify' : 'page'}) '
      'serverTime=${serverTime?.toIso8601String() ?? 'unknown'}',
    );

    // Not with a bound ahead of the forum's clock either, see the poll with nothing new above.
    final time = notify['time'] as int;
    final seenNotice = notifyListsUnreadNotice(notify) && since <= time ? time : null;
    if (seenNotice != null || seenPm) {
      await _markSeen(client, notify['formhash'] as String, notice: seenNotice, pm: seenPm);
    }
    // The window the conversations were kept by, in their representation: what decides that one is news.
    return right((info: info, serverTime: serverTime, window: pmSince, servedUid: _servedUidOfNotify(notify)));
  }

  /// The conversation list asked of `pmlist` with [client] (plugin 1.9.0), `fromApi` true; the private message page
  /// when the API does not answer it (refused as too soon, not understood), `fromApi` false and the page's clock in
  /// `serverTime`. [NotificationUserNotFound] when the API answered that the session expired.
  ///
  /// `seenPm` tells that `seen` has to clear the forum's "new private message" prompt for the list read, as reading
  /// the page does: not when the page was read, and not when the forum has private messages switched off (`closed`,
  /// no conversation listed, as on the page then). `timeOffset` is the offset `pmlist` gave the times with, null for
  /// the page (the member's offset of `notify`).
  Future<
    Either<
      AppException,
      ({List<PersonalMessageV2> list, bool fromApi, bool seenPm, num? timeOffset, DateTime? serverTime})
    >
  >
  _personalMessagesWith(NetClientProvider client) async {
    final json = await TsdmAppApi.ask(client, 'pmlist');
    if (json case {'ok': 0, 'error': 'login'}) {
      error('failed to fetch notification: not logged in (app api pmlist)');
      return left(NotificationUserNotFound());
    }
    if (PersonalMessage.listFromApi(json) case final list?) {
      return right((
        list: list,
        fromApi: true,
        seenPm: json!['closed'] != 1,
        timeOffset: json['timeoffset'] as num,
        serverTime: null,
      ));
    }
    debug('pmlist not answered (${json?['error'] ?? 'no answer'}), reading the private message page');
    return switch (await _fetchPageWithTime(client, personalMessageUrl).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((
        list: NotificationV2.personalMessagesOf(value.$1),
        fromApi: false,
        seenPm: false,
        timeOffset: null,
        serverTime: value.$2,
      )),
    };
  }

  /// Post `seen` with [client] and the [formhash] of its `notify` answer: the unread notices marked read when [notice]
  /// (the clock of that answer, seconds) is given and none is unread with a time at or after it, and the forum's "new
  /// private message" prompt cleared when [pm]. Only logged when it fails.
  ///
  /// Waited for, so a background sync does not end before it is sent, but not longer than [_seenTimeout]: the fetch
  /// holds the sync's "fetching" state (which the login and account switch flows wait on) until it returns, and the
  /// request alone may take its whole connect and receive timeouts. The request is not cancelled then; its answer is
  /// only not read.
  Future<void> _markSeen(NetClientProvider client, String formhash, {required int? notice, required bool pm}) async {
    var timedOut = false;
    final answer =
        await TsdmAppApi.post(client, 'seen', {
          'formhash': formhash,
          if (notice != null) 'notice': '$notice',
          if (pm) 'pm': '1',
        }).timeout(
          _seenTimeout,
          onTimeout: () {
            timedOut = true;
            return null;
          },
        );
    if (timedOut) {
      warning('marking notifications seen on the forum (notice=$notice pm=$pm) did not answer in time, going on');
      return;
    }
    if (answer == null || answer['ok'] != 1) {
      warning(
        'failed to mark notifications seen on the forum (notice=$notice pm=$pm): ${answer?['error'] ?? 'no answer'}',
      );
      return;
    }
    debug(
      'marked seen on the forum: notice=${answer['notice']}${answer['newer'] == 1 ? ' (a newer one arrived)' : ''} '
      'pm=${answer['pm']}',
    );
  }

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
  ///
  /// [bypassGate] is passed on to [fetchNotificationWith]: the refresh the user asked for.
  AsyncEither<DateTime?> fetchNotificationV2({required int uid, int? timestamp, bool bypassGate = false}) {
    _controller.add(const NotificationInfoStateLoading());
    return AsyncEither(() async {
      final startedAt = DateTime.now();
      // The session the default client is bound to: the one the guest page below is about.
      final cookie = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>() : null;
      final asked = (uid: cookie?.userLoginInfo.uid, generation: cookie?.generation);
      final result = await fetchNotificationWith(
        getIt.get<NetClientProvider>(),
        timestamp: timestamp,
        bypassGate: bypassGate,
      ).run();
      switch (result) {
        case Left(:final value):
          if (value is NotificationUserNotFound) {
            if (cookie == null || (asked.uid == uid && cookie.generation == asked.generation)) {
              // The forum answered the guest page to the current account's cookie: its session is dead (issue #25).
              await _storage?.markSessionExpired(uid);
            } else {
              // Asked as another account, or another session was loaded since (a login with the password, of this
              // account too): the guest page says nothing of the session in use now.
              info('guest page of a previous session of uid ${"$uid".obscured(4)}, nothing marked');
            }
          }
          _controller.add(const NotificationInfoStateFailure());
          return left(value);
        case Right(:final value):
          _controller.add(
            NotificationInfoStateSuccess(
              uid,
              value.info,
              since: timestamp,
              window: value.window,
              serverTime: value.serverTime,
              startedAt: startedAt,
            ),
          );
          return right(value.serverTime);
      }
    });
  }

  /// Dispose the repo.
  Future<void> dispose() async {
    await _controller.close();
  }
}
