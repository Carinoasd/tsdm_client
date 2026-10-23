import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:dio/dio.dart' show DioException, Options;
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/offline_thread/utils/thread_refusal.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The first page of a thread asked to learn who started it ([ThreadRepository.fetchThreadFirstPage]): the page, and
/// whether its first floor names no user (an anonymous or guest post: nobody on a block list can be its author).
typedef ThreadFirstPage = ({ThreadPageInfo page, bool firstFloorNamesNoUser});

/// A thread page answer read: the page built, and the account the forum served it to (null for a guest, or when the
/// answer does not tell).
typedef _ThreadAnswer = ({ThreadPageInfo page, int? viewerUid});

/// Repository of thread page of the app.
class ThreadRepository {
  /// Constructor.
  ///
  /// With [offline], [fetchThreadPage] saves the pages it loads while the setting is on and reads them back when the
  /// forum can not be reached ([fetchThreadFirstPage] only reads them back); without it nothing is saved or read.
  ThreadRepository({OfflineThreadRepository? offline}) : _offline = offline;

  final OfflineThreadRepository? _offline;

  String? _threadUrl;

  /// Getter to get the thread url.
  String? get threadUrl => _threadUrl;

  int? _pageNumber;

  /// getter of current thread page number.
  int? get pageNumber => _pageNumber;

  String _buildOperationUrl(String tid) =>
      '$baseUrl/forum.php?mod=misc&action=viewthreadmod&tid=$tid'
      '&infloat=yes&handlekey=viewthreadmod&inajax=1&ajaxtarget=fwin_content_viewthreadmod';

  /// Fetch the thread page with [tid] on page [pageNumber] as a document, for the readers that parse the page
  /// themselves (`parseThreadDocument`).
  ///
  /// The page is asked in the JSON mode of the forum's app API; whatever the answer is (the web page, or a JSON
  /// answer whose `document` holds the blocks of the page: the structured answer of plugin 2.1.0 carries them too),
  /// it is given as the document of the page. The thread page shown to the user is fetched with [fetchThreadPage],
  /// which reads the structured fields of such an answer instead.
  ///
  /// # Exception
  ///
  /// * **HttpRequestedFailedException** when http request failed.
  AsyncEither<uh.Document> fetchThread({
    String? tid,
    String? pid,
    int pageNumber = 1,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) =>
      _fetchAnswer(
        tid: tid,
        pid: pid,
        pageNumber: pageNumber,
        onlyVisibleUid: onlyVisibleUid,
        reverseOrder: reverseOrder,
        exactOrder: exactOrder,
      ).flatMap(
        (data) => AsyncEither(() async {
          // The antitheft interceptor asked the web page again for an answer without a page; what is still one here
          // is a failed request, not a thread without posts (see tsdmAppAnswerWithoutPage).
          if (tsdmAppAnswerWithoutPage(data)) {
            return left(HttpRequestFailedException(HttpStatus.ok));
          }
          // A structured answer without its blocks (lean, plugin 2.3.0) has no document to give: the thread page
          // shown to the user is built from its fields by fetchThreadPage instead. The forum's message is rebuilt
          // as the page (tsdmAppPageDocument).
          final json = tsdmAppAnswerJson(data);
          if (json != null && json['schema'] is num && json['document'] is! String) {
            return left(HttpRequestFailedException(HttpStatus.ok));
          }
          return right(tsdmAppPageDocument(data));
        }),
      );

  /// Fetch the thread page with [tid] on page [pageNumber], built.
  ///
  /// The page is asked in the JSON mode of the forum's app API. An answer of plugin 2.1.0 or later carries the page
  /// as structured fields (`schema: 3`), or is the forum's own message with `login` (no permission, please log in):
  /// the page is built from them ([threadPageFromApi]), its `document` never read. Any other answer (a web page from
  /// a forum without the plugin, an older plugin's answer, the antitheft challenge or the thread cache a guest is
  /// served, whose `document` holds the blocks of the page) is parsed as the web page ([parseThreadDocument]), with
  /// [pageFallback] (or [pageNumber]) as the page when the page does not tell: a page without a pager is page 1 of
  /// 1 whatever page was asked for (the author-only view asks the page the thread was on, the filtered thread may
  /// have fewer pages). A structured answer always tells its page.
  ///
  /// # Offline copies
  ///
  /// With the offline repository given to the constructor and its setting on, for a logged in account:
  ///
  /// * a page with floors the forum served to that account is saved as it came, under the account, the thread, the
  ///   page asked for and the filters (`ordertype`, `authorid`); the `findpost` redirect under the page it landed on,
  ///   without filters, as that request has none;
  /// * the forum's message refusing the thread to the account ([forumRefusesThread]: no such thread, no permission;
  ///   not the login prompt of an expired session, not a request refused for being too frequent) deletes every page of
  ///   the thread saved for that account;
  /// * when the forum could not be reached at all ([isNoNetworkFailure]), the page saved for the same account and the
  ///   same request is built instead, marked with the time it was loaded ([ThreadPageInfo.offlineSavedAt]) and without
  ///   its reply form; any other failure, or no saved page, is the failure as before.
  ///
  /// # Exception
  ///
  /// * **HttpRequestedFailedException** when http request failed.
  AsyncEither<ThreadPageInfo> fetchThreadPage({
    String? tid,
    String? pid,
    int pageNumber = 1,
    int? pageFallback,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) => AsyncEither(() async {
    final offline = _offline != null && _offline.enabled ? _offline : null;
    // The account the request goes out as: the client is bound to it, and drops the answer once another one is in use.
    final uid = offline?.currentUid();
    final orderType = tid == null ? 0 : (_orderTypeOf(exactOrder: exactOrder, reverseOrder: reverseOrder) ?? 0);
    final authorId = tid == null ? 0 : (int.tryParse(onlyVisibleUid ?? '') ?? 0);
    final askedTid = int.tryParse(tid ?? '');

    final answer = await _fetchAnswer(
      tid: tid,
      pid: pid,
      pageNumber: pageNumber,
      onlyVisibleUid: onlyVisibleUid,
      reverseOrder: reverseOrder,
      exactOrder: exactOrder,
      // A deleted thread comes with 404: its message may still be a refusal that deletes the copies.
      onNotFound: offline != null && uid != null && askedTid != null
          ? (body) {
              try {
                final read = _readThreadPage(body, pageNumber: pageNumber, readViewer: true).toNullable();
                if (read != null && read.viewerUid == uid && forumRefusesThread(read.page)) {
                  offline.forgetThread(uid: uid, tid: askedTid);
                }
              } on Object catch (_) {
                // Not a page: nothing refused.
              }
            }
          : null,
    ).run();

    switch (answer) {
      case Left(value: final e):
        // Never another account's copy: the account in use may have changed while the request was out.
        if (offline != null &&
            uid != null &&
            askedTid != null &&
            isNoNetworkFailure(e) &&
            offline.currentUid() == uid) {
          final key = OfflineThreadKey(
            uid: uid,
            tid: askedTid,
            page: pageNumber,
            orderType: orderType,
            authorId: authorId,
          );
          final saved = await offline.load(key);
          if (saved != null) {
            ThreadPageInfo? page;
            try {
              page = _readThreadPage(
                saved.body,
                pageNumber: pageNumber,
                pageFallback: pageFallback,
              ).toNullable()?.page;
            } on Object catch (_) {
              // A copy that can not be built is no page: the failure stays.
              page = null;
            }
            if (page != null && page.havePermission && !page.needLogin && page.postList.isNotEmpty) {
              return right(page.asOffline(saved.savedAt));
            }
          }
        }
        return left(e);
      case Right(value: final data):
        final read = _readThreadPage(
          data,
          pageNumber: pageNumber,
          pageFallback: pageFallback,
          readViewer: offline != null && uid != null,
        );
        if (read case Right(value: final v) when askedTid != null && v.page.currentPage != pageNumber) {
          // The url to copy, share or open names the page the forum answered (its last page for a page past it).
          _threadUrl = _threadUrl?.replaceFirst(RegExp(r'&page=\d+$'), '&page=${v.page.currentPage}');
        }
        if (read case Right(value: final v) when offline != null && uid != null) {
          final page = v.page;
          final pageTid = askedTid ?? int.tryParse(page.tid ?? '');
          // Refused to the account the copies are of (the answer names it; plugin 2.2.0 and the web page do).
          if (pageTid != null && v.viewerUid == uid && forumRefusesThread(page)) {
            offline.forgetThread(uid: uid, tid: pageTid);
          } else if (pageTid != null && page.havePermission && !page.needLogin && page.postList.isNotEmpty) {
            // Only what the forum served to this account: not the guest page of a session that expired.
            if (v.viewerUid == uid) {
              offline.save(
                OfflineThreadKey(
                  uid: uid,
                  tid: pageTid,
                  // Asked past the last page on purpose (`goto=lastpost`, with a fallback page), the forum answered
                  // its last page: kept as that page.
                  page: askedTid != null && (pageFallback == null || pageNumber <= page.totalPages)
                      ? pageNumber
                      : page.currentPage,
                  orderType: orderType,
                  authorId: authorId,
                ),
                data,
              );
            }
          }
        }
        return read.map((v) => v.page);
    }
  });

  /// The page of the thread page answer [data] asked for page [pageNumber] (see [fetchThreadPage]), with the account it
  /// was served to (read from a web page only with [readViewer]).
  Either<AppException, _ThreadAnswer> _readThreadPage(
    Object? data, {
    required int pageNumber,
    int? pageFallback,
    bool readViewer = false,
  }) {
    final api = threadApiAnswerOf(data);
    if (api != null) {
      // A message answer tells no page: the fallback, not a page asked past the last one on purpose.
      return right((page: threadPageFromApi(api, pageFallback ?? pageNumber), viewerUid: threadApiViewerUid(api)));
    }
    // An answer without a page is a failed request, not a thread without posts (see tsdmAppAnswerWithoutPage); the
    // antitheft interceptor asked the web page again for one already.
    if (tsdmAppAnswerWithoutPage(data)) {
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    final document = tsdmAppPageDocument(data);
    return right((
      page: parseThreadDocument(document, pageFallback ?? pageNumber),
      viewerUid: readViewer ? parseLoggedUidFromDocument(document) : null,
    ));
  }

  /// Fetch the first page of thread [tid], oldest floor first, to learn who started it (the thread page does, when the
  /// thread was opened on a later page and the current account blocks somebody).
  ///
  /// The page is [fetchThreadPage]'s: built from a structured answer, parsed from the document otherwise. The first
  /// floor is on it whatever the thread's own order is; it names no user when it is an anonymous or guest post
  /// (`firstFloorNamesNoUser`): built, such a floor is in the list without a uid; parsed, the post parser skips it
  /// and the page is asked.
  ///
  /// With the offline repository on, the copy of the same page saved for the account in use is read when the forum
  /// can not be reached; this lookup never saves one itself.
  AsyncEither<ThreadFirstPage> fetchThreadFirstPage({required String tid}) => AsyncEither(() async {
    final offline = _offline != null && _offline.enabled ? _offline : null;
    final uid = offline?.currentUid();
    final answer = await _fetchAnswer(
      tid: tid,
      pid: null,
      pageNumber: 1,
      onlyVisibleUid: null,
      reverseOrder: false,
      exactOrder: null,
    ).run();
    final Object? data;
    switch (answer) {
      case Left(value: final e):
        final askedTid = int.tryParse(tid);
        if (offline == null ||
            uid == null ||
            askedTid == null ||
            !isNoNetworkFailure(e) ||
            offline.currentUid() != uid) {
          return left(e);
        }
        final saved = await offline.load(
          OfflineThreadKey(
            uid: uid,
            tid: askedTid,
            page: 1,
            orderType: _orderTypeOf(exactOrder: null, reverseOrder: false) ?? 0,
            authorId: 0,
          ),
        );
        if (saved == null) {
          return left(e);
        }
        data = saved.body;
      case Right(:final value):
        data = value;
    }
    final api = threadApiAnswerOf(data);
    if (api != null) {
      final page = threadPageFromApi(api, 1);
      return right((
        page: page,
        firstFloorNamesNoUser: page.postList.any((e) => e.postFloor == 1 && e.author.uid == null),
      ));
    }
    if (tsdmAppAnswerWithoutPage(data)) {
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    final document = tsdmAppPageDocument(data);
    return right((
      page: parseThreadDocument(document, 1),
      firstFloorNamesNoUser: firstFloorNamesNoUser(document),
    ));
  });

  /// The `ordertype` asked with [exactOrder] and [reverseOrder] (see [_fetchAnswer]), null when none is asked.
  static int? _orderTypeOf({required int? exactOrder, required bool? reverseOrder}) => switch ((
    exactOrder,
    reverseOrder,
  )) {
    (final int i, _) => i,
    (null, true) => 1,
    (null, false) => 2,
    (null, null) => null,
  };

  /// The body of the thread page answer: the web page, or the JSON answer of the forum's app API (which may be one
  /// without a page, see [tsdmAppAnswerWithoutPage]: the callers tell).
  AsyncEither<Object?> _fetchAnswer({
    required String? tid,
    required String? pid,
    required int pageNumber,
    required String? onlyVisibleUid,
    required bool? reverseOrder,
    required int? exactOrder,
    void Function(Object? body)? onNotFound,
  }) => AsyncEither(() async {
    assert(tid != null || pid != null, 'tid and pid MUST not be null at the same time');

    /// Only visible uid.
    final visibleUid = onlyVisibleUid == null ? '' : '&authorid=$onlyVisibleUid';
    // ordertype: Control sort of post floors.
    // 1: desc (latest post first)
    // 2: asc (oldest post first)
    //
    // Some threads defined reverse order (latest post first) as default
    // post order, it's hard to detect the default order of a thread.
    //
    // Instead, always set `ordertype` query parameter to ensure all threads
    // are in the same default order.
    //
    // And in some situation, do NOT force reverse order, like user is going
    // to find a post in a certain page number, in this use case a manually
    // other override may going into different page that does NOT contain
    // the target post.
    final orderType = switch (_orderTypeOf(exactOrder: exactOrder, reverseOrder: reverseOrder)) {
      final int i => '&ordertype=$i',
      null => '',
    };

    _pageNumber = pageNumber;
    if (tid != null) {
      _threadUrl =
          '$baseUrl/forum.php?mod=viewthread&tid=$tid&extra=page%3D1'
          '$orderType$visibleUid'
          '&page=$pageNumber';
    } else {
      // The page came from where we redirect by finding a post.
      _threadUrl = '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=$pid';
    }

    // With the forum's app API the page comes back as JSON without header, footer and sidebar (see TsdmAppApi);
    // the url kept for sharing and reloading stays the plain one.
    //
    // Discuz answers a thread that does not exist (deleted, or waiting for moderation) with HTTP 404 and its message:
    // with [onNotFound] that answer is read too and handed to it; the load fails all the same.
    final respEither = await getIt
        .get<NetClientProvider>()
        .get(
          withTsdmAppJson(_threadUrl!),
          options: onNotFound == null
              ? null
              : Options(validateStatus: (s) => s != null && ((s >= 200 && s < 300) || s == HttpStatus.notFound)),
        )
        .run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp = respEither.unwrap();
    if (resp.statusCode == HttpStatus.notFound && onNotFound != null) {
      onNotFound(resp.data);
      // The very failure of a 404 without [onNotFound]: dio's bad response, mapped the same way, kept for the error
      // card and logged as the error handler of the client does.
      final refused = DioException.badResponse(
        statusCode: HttpStatus.notFound,
        requestOptions: resp.requestOptions,
        response: resp,
      );
      talker.error('${refused.requestOptions.uri} ${refused.type}: error: ${refused.error}, status code: 404');
      getIt.get<NetErrorSaver>().save(refused.message);
      return left(mapException(refused, StackTrace.current));
    }
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    return right(resp.data);
  });

  /// Fetch the operation log for thread [tid].
  AsyncEither<List<OperationLogItem>> fetchOperationLog(String tid) =>
      getIt.get<NetClientProvider>().get(_buildOperationUrl(tid)).mapHttp((resp) {
        final htmlData = parseXmlDocument(resp.data as String).documentElement?.nodes.firstOrNull?.text;
        if (htmlData == null) {
          // Safe to throw because we use it in a future builder.
          throw Exception('html data not found');
        }

        // The log table is `<table class="list">` with a `<thead>` row of `<td>` headers and one `<tr>` per action.
        //
        // When no operation log is available the server responds with a notice `<div class="alert_error">`, in
        // which case an empty list is returned.
        final doc = parseHtmlDocument(htmlData);
        final items = doc
            .querySelectorAll('table tr')
            .map(OperationLogItem.fromTr)
            .whereType<OperationLogItem>()
            .toList();
        return items;
      });
}
