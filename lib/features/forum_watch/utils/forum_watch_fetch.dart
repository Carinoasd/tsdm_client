import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart' show fidOfForumUrl;
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

/// One thread of a list the check read.
@immutable
final class WatchRow {
  /// Constructor.
  const WatchRow({
    required this.tid,
    required this.fid,
    required this.title,
    this.author = '',
    this.authorUid = 0,
    this.forumName = '',
  });

  /// Thread id.
  final int tid;

  /// Forum of the thread, 0 when the list did not tell.
  final int fid;

  /// Title.
  final String title;

  /// Name of the author, empty for an anonymous one.
  final String author;

  /// Uid of the author, 0 for an anonymous one.
  final int authorUid;

  /// Name of the forum, empty when the list did not tell.
  final String forumName;

  @override
  String toString() => 'WatchRow($tid, fid $fid)';
}

/// What a reading of one source found.
sealed class ForumWatchFetch {
  const ForumWatchFetch();
}

/// The source was read: its [rows] in the list's order; [viewerUid] is the account the forum served the page to, null
/// for a guest.
final class ForumWatchFetched extends ForumWatchFetch {
  /// Constructor.
  const ForumWatchFetched(this.rows, {this.viewerUid});

  /// The threads listed.
  final List<WatchRow> rows;

  /// The account the page was served to.
  final int? viewerUid;
}

/// The source could not be read this time ([reason]); [rateLimited] when the forum answered 429: the round stops.
final class ForumWatchFetchFailed extends ForumWatchFetch {
  /// Constructor.
  const ForumWatchFetchFailed(this.reason, {this.rateLimited = false});

  /// Why, for the log.
  final String reason;

  /// The forum asked to slow down.
  final bool rateLimited;
}

/// The url forum [fid] is read with: its first page, the threads posted last first (`orderby=dateline`), in the JSON
/// mode without the page's blocks nor the previews of the rows. `forumdefstyle=yes` as the forum page asks it: a board
/// in picture mode lists its thread table then.
String forumWatchForumUrl(int fid, {String base = baseUrl}) =>
    withTsdmAppJson('$base/forum.php?mod=forumdisplay&fid=$fid&orderby=dateline&forumdefstyle=yes');

/// The url of the list of the latest threads (the forum guide's 最新发表), in the JSON mode.
String forumWatchLatestUrl({String base = baseUrl}) => withTsdmAppJson('$base/forum.php?mod=guide&view=newthread');

/// The url [source] is read with ([forumWatchForumSource], [forumWatchLatestSource]); null for anything else.
String? forumWatchUrlOf(String source, {String base = baseUrl}) {
  if (source == forumWatchLatestSource) {
    return forumWatchLatestUrl(base: base);
  }
  final fid = forumWatchFidOfSource(source);
  return fid == null ? null : forumWatchForumUrl(fid, base: base);
}

/// The row of a thread of a structured list answer (the forum `schema` 2 and the guide `schema` 7 share the fields);
/// null for a row without a thread or a subject, and for a moved thread's placeholder (`moved`): the thread itself is
/// older.
WatchRow? _rowOf(Map<String, dynamic> row, {String forumName = ''}) {
  if (!tsdmAppIsThreadRow(row) || tsdmAppInt(row['moved']) > 0) {
    return null;
  }
  final anonymous = tsdmAppInt(row['anonymous']) == 1;
  final name = tsdmAppText(row['forum']);
  return WatchRow(
    tid: tsdmAppInt(row['tid']),
    fid: tsdmAppInt(row['fid']),
    title: tsdmAppText(row['subject']),
    author: anonymous ? '' : tsdmAppText(row['author']),
    authorUid: anonymous ? 0 : tsdmAppInt(row['authorid']),
    forumName: name.isNotEmpty ? name : forumName,
  );
}

WatchRow? _rowOfThread(NormalThread thread, {required int fid, String forumName = ''}) {
  final tid = int.tryParse(thread.threadID);
  if (tid == null || tid <= 0 || thread.title.isEmpty) {
    return null;
  }
  return WatchRow(
    tid: tid,
    fid: fid,
    title: thread.title,
    author: thread.author.name,
    authorUid: int.tryParse(thread.author.uid ?? '') ?? 0,
    forumName: forumName,
  );
}

/// What the answer [data] of [source] ([forumWatchUrlOf]) lists.
///
/// The structured answer of the forum's app API (the forum page, plugin 2.0.0; the guide, plugin 2.4.0) is read from
/// its fields; anything else as the web page, as the forum page and the latest thread page read it. The forum's
/// message (the guide switched off, no permission, please log in) or an answer without a page is a failure: nothing
/// is announced and the source keeps its mark.
ForumWatchFetch forumWatchRowsOf(String source, Object? data) {
  final fid = forumWatchFidOfSource(source);
  final json = tsdmAppAnswerJson(data);
  final schema = json?['schema'];
  final structured =
      json != null &&
      schema is num &&
      (fid != null ? schema >= 2 && json['type'] == 'forum' : schema >= 7 && json['type'] == 'guide');
  if (json != null && (structured || json['ok'] == 0)) {
    if (json['ok'] != 1) {
      return ForumWatchFetchFailed('forum message: ${json['message']}');
    }
    final forumName = fid == null ? '' : tsdmAppText(tsdmAppMap(json['forum'])['name']);
    final uid = tsdmAppInt(json['uid']);
    return ForumWatchFetched([
      for (final row in tsdmAppList(json['threads'])) ?_rowOf(row, forumName: forumName),
    ], viewerUid: uid > 0 ? uid : null);
  }
  if (tsdmAppAnswerWithoutPage(data)) {
    return const ForumWatchFetchFailed('answer without page');
  }
  final document = tsdmAppPageDocument(data);
  final viewer = parseLoggedUidFromDocument(document);
  if (fid != null) {
    final page = parseForumPage(document, '$fid');
    if (!page.havePermission || page.needLogin) {
      return const ForumWatchFetchFailed('no permission');
    }
    final name = page.title ?? '';
    return ForumWatchFetched([
      for (final t in [...page.stickThreadList, ...page.normalThreadList]) ?_rowOfThread(t, fid: fid, forumName: name),
    ], viewerUid: viewer);
  }
  final rows = document.querySelectorAll('tbody[id^="normalthread_"]');
  if (rows.isEmpty) {
    return const ForumWatchFetchFailed('no list on the page');
  }
  return ForumWatchFetched([
    for (final e in rows.map(LatestThread.fromTBody).where((e) => e.isValid))
      if (int.tryParse(e.threadID ?? '') case final tid? when tid > 0)
        WatchRow(
          tid: tid,
          fid: fidOfForumUrl(e.forumUrl) ?? 0,
          title: e.title ?? '',
          author: e.threadAuthor?.name ?? '',
          authorUid: int.tryParse(e.threadAuthor?.uid ?? '') ?? 0,
          forumName: e.forumName ?? '',
        ),
  ], viewerUid: viewer);
}

/// Read [source] with [client] (bound to the account the check is for), see [forumWatchRowsOf].
Future<ForumWatchFetch> fetchForumWatchSource(NetClientProvider client, String source, {String base = baseUrl}) async {
  final url = forumWatchUrlOf(source, base: base);
  if (url == null) {
    return ForumWatchFetchFailed('unknown source $source');
  }
  final resp = await client.get(url).run();
  switch (resp) {
    case Left(:final value):
      final rateLimited = switch (value) {
        HttpHandshakeFailedException(statusCode: HttpStatus.tooManyRequests) => true,
        HttpRequestFailedException(statusCode: HttpStatus.tooManyRequests) => true,
        _ => false,
      };
      return ForumWatchFetchFailed('request failed: $value', rateLimited: rateLimited);
    case Right(:final value):
      if (value.statusCode == HttpStatus.tooManyRequests) {
        return const ForumWatchFetchFailed('429', rateLimited: true);
      }
      if (value.statusCode != HttpStatus.ok) {
        return ForumWatchFetchFailed('status ${value.statusCode}');
      }
      try {
        return forumWatchRowsOf(source, value.data);
      } on Object catch (e) {
        return ForumWatchFetchFailed('not readable: $e');
      }
  }
}

/// The reading of the sources of account [uid] ([fetchForumWatchSource]) with a client of that account's own cookie,
/// read from the database once, on the first reading (as `followedThreadFetcherOf` does); without one every reading
/// fails. [clientFactory] builds the client from the cookie ([NetClientProvider.buildNoCookie] by default).
Future<ForumWatchFetch> Function(String source) forumWatchFetcherOf(
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

  return (source) async {
    final c = await (client ??= build());
    if (c == null) {
      return const ForumWatchFetchFailed('no cookie of the account');
    }
    return fetchForumWatchSource(c, source);
  };
}
