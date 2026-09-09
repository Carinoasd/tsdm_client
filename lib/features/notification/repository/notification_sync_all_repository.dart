import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Repository syncing the notifications of every account saved on this device, one account after another.
///
/// Each account gets its own client built from its stored cookie (an empty [CookieProvider] loaded with that row,
/// see [ServiceKeys.empty] and [NetClientProvider.buildNoCookie]), so the global cookie and the current account are
/// untouched: nothing here switches accounts. Fetched copies are stored per uid through [persistFetchedNotification],
/// the same helper the current-user sync uses, and the account's `lastFetchNotice` is moved to the minute the fetch
/// started in (same rule as the auto sync). Unread counts of other accounts never reach the badge: the caller
/// publishes the current user's recount, nothing else.
///
/// Mirrors `AutoCheckinRepository`: sequential with [gap] between accounts, progress on [status].
final class NotificationSyncAllRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [clientFactory] builds the client of one account from its loaded cookie, replaceable in tests.
  NotificationSyncAllRepository({
    required StorageProvider storageProvider,
    required NotificationRepository notificationRepository,
    NetClientProvider Function(CookieProvider cookie)? clientFactory,
    this.gap = const Duration(seconds: 2),
    this.maxRetryAfter = const Duration(seconds: 60),
  }) : _storageProvider = storageProvider,
       _notificationRepository = notificationRepository,
       _clientFactory = clientFactory ?? _defaultClient;

  static NetClientProvider _defaultClient(CookieProvider cookie) => NetClientProvider.buildNoCookie(cookie: cookie);

  final StorageProvider _storageProvider;
  final NotificationRepository _notificationRepository;
  final NetClientProvider Function(CookieProvider cookie) _clientFactory;

  /// Pause between two accounts.
  ///
  /// Three pages are fetched per account; the forum answered 429 when four accounts checked in at once.
  final Duration gap;

  /// Longest wait accepted from a `Retry-After` header before the one retry of a rate-limited account.
  ///
  /// A 429 without `Retry-After` is reported as rate limited right away, the next account still runs.
  final Duration maxRetryAfter;

  final _stream = BehaviorSubject<NotificationSyncAllInfo>();

  /// Stream of the progress.
  Stream<NotificationSyncAllInfo> get status => _stream.asBroadcastStream();

  var _currentInfo = NotificationSyncAllInfo.empty();

  /// Sync the notifications of every account in [accounts], one at a time, and return the final progress.
  AsyncEither<NotificationSyncAllInfo> syncAll({required List<UserLoginInfo> accounts}) => AsyncEither(() async {
    // Initialize each run without retaining the previous batch results.
    _currentInfo = NotificationSyncAllInfo.empty();
    _updateWaiting(accounts);
    for (final (index, user) in accounts.indexed) {
      if (index > 0 && gap > Duration.zero) {
        await Future<void>.delayed(gap);
      }
      debug('sync notification for uid ${"${user.uid}".obscured(4)}');
      _updateRunning(user);
      final result = await _syncOne(user);
      _updateFinished(user, result);
    }
    return right(_currentInfo);
  });

  /// Fetch and store the notifications of [user] with its own client.
  ///
  /// Anything thrown on the way (cookie load, page decoding, the database writes) is reported as
  /// [NotificationSyncResultFailed] for this account only: the batch goes on with the next one.
  Future<NotificationSyncResult> _syncOne(UserLoginInfo user) async {
    final uid = user.uid;
    if (uid == null) {
      return const NotificationSyncResultNotAuthorized();
    }
    try {
      return await _syncOneUnguarded(uid, user);
      // Anything thrown here must be reported, not escape the run.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      error('sync notification for uid ${"$uid".obscured(4)} threw: $e', e, st);
      return NotificationSyncResultFailed('$e');
    }
  }

  Future<NotificationSyncResult> _syncOneUnguarded(int uid, UserLoginInfo user) async {
    final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
    if (!await cookie.loadCookieFromStorage(user)) {
      return const NotificationSyncResultNotAuthorized();
    }
    final client = _clientFactory(cookie);
    final started = DateTime.now();
    final timestamp = await _lastFetchTimestamp(uid);

    for (var attempt = 0; ; attempt++) {
      final result = await _notificationRepository.fetchNotificationWith(client, timestamp: timestamp).run();
      switch (result) {
        case Left(value: NotificationUserNotFound()):
          return const NotificationSyncResultNotAuthorized();
        case Left(:final value) when _isRateLimited(value):
          final retryAfter = _retryAfter(value);
          if (attempt == 0 && retryAfter != null) {
            final wait = retryAfter > maxRetryAfter ? maxRetryAfter : retryAfter;
            debug('sync notification rate limited, retry once in ${wait.inSeconds}s');
            await Future<void>.delayed(wait);
            continue;
          }
          warning('sync notification rate limited by the server');
          return const NotificationSyncResultRateLimited();
        case Left(:final value):
          return NotificationSyncResultFailed(value.message ?? '${value.runtimeType}');
        case Right(:final value):
          if (_storageProvider.getCookieByUidSync(uid) == null) {
            // The account was removed from this device while its pages were fetched: do not bring rows back.
            info('account ${"$uid".obscured(4)} was removed during the sync, result dropped');
            return const NotificationSyncResultNotAuthorized();
          }
          final persisted = await persistFetchedNotification(storage: _storageProvider, uid: uid, fetched: value);
          // Whole minute only, see AutoNotificationCubit: notification times have minute precision.
          await _storageProvider.updateLastFetchNoticeTime(uid, started.truncateToMinute()).run();
          return NotificationSyncResultSuccess(
            newNotice: persisted.fresh.noticeList.length,
            newPersonalMessage: persisted.fresh.personalMessageList.length,
            newBroadcastMessage: persisted.fresh.broadcastMessageList.length,
            unreadNotice: persisted.unread.notice,
            unreadPersonalMessage: persisted.unread.personalMessage,
            unreadBroadcastMessage: persisted.unread.broadcastMessage,
          );
      }
    }
  }

  /// The inclusive lower bound of the fetch (seconds), same rule as `NotificationBloc`.
  Future<int?> _lastFetchTimestamp(int uid) async {
    final lastFetchTimeEither = await _storageProvider.fetchLastFetchNoticeTime(uid).run();
    if (lastFetchTimeEither case Right(value: final DateTime datetime)) {
      return datetime.millisecondsSinceEpoch ~/ 1000;
    }
    return null;
  }

  static bool _isRateLimited(AppException e) => switch (e) {
    HttpHandshakeFailedException(statusCode: HttpStatus.tooManyRequests) => true,
    HttpRequestFailedException(statusCode: HttpStatus.tooManyRequests) => true,
    _ => false,
  };

  /// The `Retry-After` of a 429 answer, null when the server did not say.
  static Duration? _retryAfter(AppException e) {
    if (e case HttpHandshakeFailedException(:final headers)) {
      final seconds = int.tryParse(headers?.value('retry-after') ?? '');
      if (seconds != null && seconds > 0) {
        return Duration(seconds: seconds);
      }
    }
    return null;
  }

  void _updateWaiting(List<UserLoginInfo> users) {
    _currentInfo = _currentInfo.copyWith(waiting: [..._currentInfo.waiting, ...users]);
    _stream.add(_currentInfo);
  }

  void _updateRunning(UserLoginInfo user) {
    _currentInfo = _currentInfo.copyWith(
      waiting: _currentInfo.waiting.where((e) => e != user).toList(),
      running: [..._currentInfo.running, user],
    );
    _stream.add(_currentInfo);
  }

  void _updateFinished(UserLoginInfo user, NotificationSyncResult result) {
    _currentInfo = _currentInfo.copyWith(
      running: _currentInfo.running.where((e) => e != user).toList(),
      finished: [..._currentInfo.finished, (user, result)],
    );
    _stream.add(_currentInfo);
  }

  /// Dispose the repo.
  Future<void> dispose() async {
    await _stream.close();
  }
}
