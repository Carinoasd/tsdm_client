import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

/// What a check of one followed thread found, see [followedThreadStateOf].
sealed class FollowedThreadFetch {
  const FollowedThreadFetch();
}

/// The thread was read: its [replies] (the floors after the first), its [title] and the time of its newest floor
/// [lastReplyAt] (null when no floor told one); [viewerUid] is the account the forum served the page to, null for a
/// guest.
final class FollowedThreadFetched extends FollowedThreadFetch {
  /// Constructor.
  const FollowedThreadFetched({required this.replies, required this.title, this.lastReplyAt, this.viewerUid});

  /// Replies of the thread.
  final int replies;

  /// Title of the thread, null when the page did not tell.
  final String? title;

  /// Time of the newest floor on the page, null when not known.
  final DateTime? lastReplyAt;

  /// The account the page was served to.
  final int? viewerUid;
}

/// The thread could not be read this time ([reason]); [rateLimited] when the forum answered 429: the round stops.
final class FollowedThreadFetchFailed extends FollowedThreadFetch {
  /// Constructor.
  const FollowedThreadFetchFailed(this.reason, {this.rateLimited = false});

  /// Why, for the log.
  final String reason;

  /// The forum asked to slow down.
  final bool rateLimited;
}

/// The url a followed thread [tid] is checked with: its first page, newest floors first (`ordertype=1`, the first
/// floor stays on top), so the floors on it tell the time of the newest reply whatever the thread's own order is.
String followedThreadCheckUrl(int tid, {String base = baseUrl}) =>
    withTsdmAppJson('$base/forum.php?mod=viewthread&tid=$tid&ordertype=1');

/// What the answer [data] to [followedThreadCheckUrl] tells about the thread.
///
/// The structured answer of the forum's app API (plugin 2.1.0, [threadApiAnswerOf]) is read through
/// [threadPageFromApi], anything else as the web page ([parseThreadDocument]), as the thread page reads it: the
/// replies are the ones the floors are paginated by (`thread.replies`; the web page only tells the "回复: N" of its info
/// row), the newest floor is the latest time among the floors, hot replies left out (a copy of an older floor).
///
/// The forum's message (no permission, please log in, no such thread), a page without replies or without a page is a
/// failure: nothing is announced, the next round asks again.
FollowedThreadFetch followedThreadStateOf(Object? data) {
  final api = threadApiAnswerOf(data);
  final ThreadPageInfo page;
  final int? viewer;
  if (api != null) {
    if (api['ok'] != 1) {
      return FollowedThreadFetchFailed('forum message: ${api['message']}');
    }
    page = threadPageFromApi(api, 1);
    viewer = threadApiViewerUid(api);
  } else {
    if (tsdmAppAnswerWithoutPage(data)) {
      return const FollowedThreadFetchFailed('answer without page');
    }
    final document = tsdmAppPageDocument(data);
    page = parseThreadDocument(document, 1);
    viewer = parseLoggedUidFromDocument(document);
  }
  if (!page.havePermission || page.needLogin) {
    return const FollowedThreadFetchFailed('no permission');
  }
  final replies = page.paginationReplies ?? page.replyCount;
  if (replies == null || page.postList.isEmpty) {
    return const FollowedThreadFetchFailed('no thread on the page');
  }
  DateTime? newest;
  for (final post in page.postList) {
    final time = post.publishTime;
    if (!post.hot && time != null && (newest == null || time.isAfter(newest))) {
      newest = time;
    }
  }
  return FollowedThreadFetched(replies: replies, title: page.title, lastReplyAt: newest, viewerUid: viewer);
}

/// Check followed thread [tid] with [client] (bound to the account the thread is followed by), see
/// [followedThreadStateOf]. [base] is the forum's url.
Future<FollowedThreadFetch> fetchFollowedThread(NetClientProvider client, int tid, {String base = baseUrl}) async {
  final resp = await client.get(followedThreadCheckUrl(tid, base: base)).run();
  switch (resp) {
    case Left(:final value):
      final rateLimited = switch (value) {
        HttpHandshakeFailedException(statusCode: HttpStatus.tooManyRequests) => true,
        HttpRequestFailedException(statusCode: HttpStatus.tooManyRequests) => true,
        _ => false,
      };
      return FollowedThreadFetchFailed('request failed: $value', rateLimited: rateLimited);
    case Right(:final value):
      if (value.statusCode == HttpStatus.tooManyRequests) {
        return const FollowedThreadFetchFailed('429', rateLimited: true);
      }
      if (value.statusCode != HttpStatus.ok) {
        return FollowedThreadFetchFailed('status ${value.statusCode}');
      }
      try {
        return followedThreadStateOf(value.data);
      } on Object catch (e) {
        return FollowedThreadFetchFailed('not readable: $e');
      }
  }
}

/// The check of one followed thread of account [uid] ([fetchFollowedThread]) with a client of that account's own
/// cookie, read from the database ([CookieProvider.loadCookieFromDatabase]: the background service may have stored
/// one the forum renewed), never the global cookie of the account in use. The cookie is read once, on the first check;
/// without one every check fails. [clientFactory] builds the client from the cookie
/// ([NetClientProvider.buildNoCookie] by default).
Future<FollowedThreadFetch> Function(int tid) followedThreadFetcherOf(
  int uid, {
  NetClientProvider Function(CookieProvider cookie)? clientFactory,
}) {
  Future<NetClientProvider?>? client;
  Future<NetClientProvider?> build() async {
    final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
    if (!await cookie.loadCookieFromDatabase(UserLoginInfo(username: null, uid: uid))) {
      return null;
    }
    return (clientFactory ?? (c) => NetClientProvider.buildNoCookie(cookie: c))(cookie);
  }

  return (tid) async {
    final c = await (client ??= build());
    if (c == null) {
      return const FollowedThreadFetchFailed('no cookie of the account');
    }
    return fetchFollowedThread(c, tid);
  };
}
