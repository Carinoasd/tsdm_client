import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/utils/auto_sync_info.dart';
import 'package:tsdm_client/features/notification/utils/fetch_bound.dart';
import 'package:tsdm_client/features/notification/utils/poll_slot.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
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
    this.cookiesFromDatabase = false,
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

  /// Whether each account's cookie is read from the database rather than the cache of the storage provider: for the
  /// in-app round of the other accounts, which must see the cookies the background service renewed, without
  /// reloading the app's whole cache every round.
  final bool cookiesFromDatabase;

  /// Longest wait accepted from a `Retry-After` header before the one retry of a rate-limited account.
  ///
  /// A 429 without `Retry-After` is reported as rate limited right away, the next account still runs.
  final Duration maxRetryAfter;

  final _stream = BehaviorSubject<NotificationSyncAllInfo>();

  /// Stream of the progress.
  Stream<NotificationSyncAllInfo> get status => _stream.asBroadcastStream();

  var _currentInfo = NotificationSyncAllInfo.empty();

  /// Sync the notifications of every account in [accounts], one at a time, and return the final progress.
  ///
  /// The returned `finished` holds this run's results only: the progress stream is shared, and a run given up by
  /// the background service may still be writing to it while the next one runs (GitHub #173).
  ///
  /// With [pollInterval] (the auto sync interval, for the sync of all accounts the user asks for) each account takes
  /// its poll first ([NotificationPollSlot.takeForManualSync], shared with the in-app auto sync and the background
  /// message service), at [now] (the current time by default): an account one of them polled within half the
  /// interval, at most 30 seconds ago, is not asked again (the plugin answers a second call within its interval with
  /// 429), its result is what is stored now ([NotificationSyncResultSuccess.recent]); a poll that brought nothing is
  /// given back. Without it (the background tick and the in-app round of the other accounts, which take the poll
  /// themselves) every account is fetched. The pause between accounts ([gap]) is this run's own, see
  /// [NotificationPollSlot].
  AsyncEither<NotificationSyncAllInfo> syncAll({
    required List<UserLoginInfo> accounts,
    Duration? pollInterval,
    DateTime? now,
  }) => AsyncEither(() async {
    // Initialize each run without retaining the previous batch results.
    _currentInfo = NotificationSyncAllInfo.empty();
    _updateWaiting(accounts);
    final finished = <(UserLoginInfo, NotificationSyncResult)>[];
    var previousAsked = false;
    for (final (index, user) in accounts.indexed) {
      if (index > 0 && gap > Duration.zero && previousAsked) {
        await Future<void>.delayed(gap);
      }
      debug('sync notification for uid ${"${user.uid}".obscured(4)}');
      _updateRunning(user);
      final result = await _syncPolled(user, pollInterval, now);
      previousAsked = result is! NotificationSyncResultSuccess || !result.recent;
      finished.add((user, result));
      _updateFinished(user, result);
    }
    return right(NotificationSyncAllInfo(waiting: const [], running: const [], finished: finished));
  });

  /// [_syncOne] behind the poll of [user] when [interval] is given, see [syncAll].
  Future<NotificationSyncResult> _syncPolled(UserLoginInfo user, Duration? interval, DateTime? now) async {
    final uid = user.uid;
    if (interval == null || uid == null) {
      return _syncOne(user);
    }
    final int? slot;
    try {
      slot = await NotificationPollSlot.takeForManualSync(_storageProvider, uid, interval, now: now);
      if (slot == null) {
        debug('uid ${"$uid".obscured(4)} was polled moments ago, using what is stored');
        final unread = await countUnreadNotification(storage: _storageProvider, uid: uid);
        return NotificationSyncResultSuccess(
          newNotice: 0,
          newPersonalMessage: 0,
          newBroadcastMessage: 0,
          unreadNotice: unread.notice,
          unreadPersonalMessage: unread.personalMessage,
          unreadBroadcastMessage: unread.broadcastMessage,
          recent: true,
        );
      }
      // Anything thrown here must be reported, not escape the run.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      error('poll of uid ${"$uid".obscured(4)} threw: $e', e, st);
      return NotificationSyncResultFailed('$e');
    }
    final result = await _syncOne(user);
    if (result is! NotificationSyncResultSuccess) {
      // Nothing came of this poll: the auto sync may take the interval after all.
      await NotificationPollSlot.release(_storageProvider, uid, slot);
    }
    return result;
  }

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
    final loaded = cookiesFromDatabase
        ? await cookie.loadCookieFromDatabase(user)
        : await cookie.loadCookieFromStorage(user);
    if (!loaded) {
      return const NotificationSyncResultNotAuthorized();
    }
    final client = _clientFactory(cookie);
    final started = DateTime.now();
    final timestamp = await _lastFetchTimestamp(uid);

    for (var attempt = 0; ; attempt++) {
      final result = await _notificationRepository
          .fetchNotificationWith(client, timestamp: timestamp, retry: true)
          .run();
      switch (result) {
        case Left(value: NotificationUserNotFound()):
          // The forum answered the guest page to this account's cookie: remember the session is dead (issue #25).
          // Not when another session of the account was stored meanwhile (a login with the password, here or in the
          // app while the background service polls): the guest page says nothing of it.
          await _storageProvider.markSessionExpiredIfHeld(uid, session: cookie.session);
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
          if (!await _storageProvider.hasCookieOfUid(uid)) {
            // The account was removed from this device while its pages were fetched: do not bring rows back. Read
            // from the database: the removal may have happened in another isolate (#80).
            info('account ${"$uid".obscured(4)} was removed during the sync, result dropped');
            return const NotificationSyncResultNotAuthorized();
          }
          final persisted = await persistFetchedNotification(
            storage: _storageProvider,
            uid: uid,
            fetched: value.info,
            since: timestamp,
            window: value.window,
          );
          // Same rule as AutoNotificationCubit: the forum's clock when it answered, the device clock otherwise.
          await _storageProvider
              .updateLastFetchNoticeTime(uid, nextFetchBound(startedAt: started, serverTime: value.serverTime))
              .run();
          return NotificationSyncResultSuccess(
            newNotice: persisted.fresh.noticeList.length,
            newPersonalMessage: persisted.fresh.personalMessageList.length,
            newBroadcastMessage: persisted.fresh.broadcastMessageList.length,
            unreadNotice: persisted.unread.notice,
            unreadPersonalMessage: persisted.unread.personalMessage,
            unreadBroadcastMessage: persisted.unread.broadcastMessage,
            latest: autoSyncInfoOf(persisted.fresh, rules: await NotificationPushRules.read(_storageProvider)),
            servedUid: value.servedUid,
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
