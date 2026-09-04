import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

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
final class NotificationRepository with LoggerMixin {
  /// Provide a stream of [NotificationInfoState] those are fetched from server.
  ///
  /// Carries fetch result and fetched info if any.
  final _controller = BehaviorSubject<NotificationInfoState>();

  /// Stream of fetched notification fetching status.
  Stream<NotificationInfoState> get status => _controller.asBroadcastStream();

  /// Fetch the html document of notice detail page.
  AsyncEither<(uh.Document, String? page)> fetchDocument(String url) => AsyncEither(
    () async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right((
        parseHtmlDocument(value.data as String),
        value.realUri.tryGetQueryParameters()?['page'],
      )),
    },
  );

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

  /// Fetch a html page as document.
  AsyncEither<uh.Document> _fetchPage(String url) =>
      getIt.get<NetClientProvider>().get(url).mapHttp((v) => parseHtmlDocument(v.data as String));

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

  /// Fetch all kinds of notification.
  ///
  /// [timestamp] is the last time call this api (in seconds). Only notifications since [timestamp] are returned.
  /// Notifications in recent 3 days are returned if [timestamp] is null or older than 3 days, same as the old API.
  /// [uid] is the user id of whom to do the fetch action.
  ///
  /// The name is kept for compatibility, see the class document for details.
  AsyncVoidEither fetchNotificationV2({required int uid, int? timestamp}) {
    _controller.add(const NotificationInfoStateLoading());
    return AsyncVoidEither(() async {
      final since = _buildSinceTimestamp(timestamp);
      final results = await Future.wait([
        _fetchPage(noticeUrl).run(),
        _fetchPage(personalMessageUrl).run(),
        _fetchPage(broadcastMessageUrl).run(),
      ]);
      for (final r in results) {
        if (r case Left(:final value)) {
          error('failed to fetch notification: $value');
          _controller.add(const NotificationInfoStateFailure());
          return left(value);
        }
      }
      final noticeDoc = results[0].getOrElse((_) => throw StateError('unreachable'));
      // Session expired: the server renders a guest page with the login form, not an empty notice list.
      if (noticeDoc.querySelector('form#lsform') != null && noticeDoc.querySelector('div#um') == null) {
        error('failed to fetch notification: not logged in');
        _controller.add(const NotificationInfoStateFailure());
        return left(NotificationUserNotFound());
      }
      final info = NotificationV2.fromDocuments(
        noticeDoc: noticeDoc,
        personalMessageDoc: results[1].getOrElse((_) => throw StateError('unreachable')),
        broadcastMessageDoc: results[2].getOrElse((_) => throw StateError('unreachable')),
        since: since,
      );
      debug(
        'fetched notification since $since: notice=${info.noticeList.length} '
        'pm=${info.personalMessageList.length} bm=${info.broadcastMessageList.length}',
      );
      _controller.add(NotificationInfoStateSuccess(uid, info));
      return rightVoid();
    });
  }

  /// Dispose the repo.
  Future<void> dispose() async {
    await _controller.close();
  }
}
