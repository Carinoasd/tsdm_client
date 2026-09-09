import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Repository for the auto checkin feature.
final class AutoCheckinRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [clientFactory] builds the client of one account from its loaded cookie, replaceable in tests.
  AutoCheckinRepository({
    required StorageProvider storageProvider,
    NetClientProvider Function(CookieProvider cookie)? clientFactory,
    this.gap = const Duration(seconds: 2),
    this.retryDelays = const [Duration(seconds: 30), Duration(seconds: 60), Duration(seconds: 60)],
  }) : _storageProvider = storageProvider,
       _clientFactory = clientFactory ?? _defaultClient;

  static NetClientProvider _defaultClient(CookieProvider cookie) => NetClientProvider.buildNoCookie(cookie: cookie);

  final StorageProvider _storageProvider;
  final NetClientProvider Function(CookieProvider cookie) _clientFactory;

  /// Pause between two accounts.
  ///
  /// Accounts check in one after another: the forum answered 429 when four were sent at once, and every account left
  /// unsigned that way was tried again on the next app start only ("签了好几次才签完").
  final Duration gap;

  /// Waits before trying an account again after the server rate-limited it (429), one entry per retry. A longer
  /// `Retry-After` from the server wins, capped at five minutes.
  final List<Duration> retryDelays;

  /// Longest wait accepted from a `Retry-After` header.
  static const _maxRetryAfter = Duration(minutes: 5);

  /// Controller of stream providing current checkin info status.
  final _stream = BehaviorSubject<AutoCheckinInfo>();

  /// Stream of auto checkin progress.
  Stream<AutoCheckinInfo> get status => _stream.asBroadcastStream();

  /// Current status.
  var _currentInfo = AutoCheckinInfo.empty();

  /// Run checkin progress on all users in [waitingList], one at a time, [skippedList] are reported as skipped.
  AsyncVoidEither checkinAll({
    required List<UserLoginInfo> waitingList,
    required List<UserLoginInfo> skippedList,
    required CheckinFeeling feeling,
    required String message,
  }) => AsyncVoidEither(() async {
    // Initialize each run without retaining the previous batch results.
    _currentInfo = AutoCheckinInfo.empty();
    _updateSkipped(skippedList);
    _updateWaiting(waitingList);
    for (final (index, userInfo) in waitingList.indexed) {
      if (index > 0 && gap > Duration.zero) {
        await Future<void>.delayed(gap);
      }
      debug('run auto checkin for uid ${"${userInfo.uid}".obscured(4)}');
      _updateRunning([userInfo]);
      final result = await _checkinWithRetry(userInfo, feeling, message);
      if (result is CheckinResultSuccess) {
        await _updateSuccess(userInfo, result);
      } else {
        await _updateFailure(userInfo, result);
      }
    }
    return rightVoid();
  });

  /// Check in [userInfo], trying again after each 429 up to [retryDelays] times.
  Future<CheckinResult> _checkinWithRetry(UserLoginInfo userInfo, CheckinFeeling feeling, String message) async {
    final client = await _prepareCheckin(userInfo);
    if (client == null) {
      return const CheckinResultNotAuthorized();
    }
    for (var attempt = 0; ; attempt++) {
      final result = await doCheckin(client, feeling, message).run();
      if (result case CheckinResultWebRequestFailed(
        statusCode: HttpStatus.tooManyRequests,
        :final retryAfterSeconds,
      ) when attempt < retryDelays.length) {
        final wait = _retryWait(retryDelays[attempt], retryAfterSeconds);
        debug('check in rate limited, retry ${attempt + 1}/${retryDelays.length} in ${wait.inSeconds}s');
        await Future<void>.delayed(wait);
        continue;
      }
      return result;
    }
  }

  Duration _retryWait(Duration scheduled, int? retryAfterSeconds) {
    if (retryAfterSeconds == null || retryAfterSeconds <= 0) {
      return scheduled;
    }
    final told = Duration(seconds: retryAfterSeconds);
    if (told <= scheduled) {
      return scheduled;
    }
    return told > _maxRetryAfter ? _maxRetryAfter : told;
  }

  /// The client of [userInfo], null when its cookie is not stored any more.
  Future<NetClientProvider?> _prepareCheckin(UserLoginInfo userInfo) async {
    final cookieProvider = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
    final loaded = await cookieProvider.loadCookieFromStorage(userInfo);
    if (!loaded) {
      return null;
    }
    return _clientFactory(cookieProvider);
  }

  /// Update status: [userInfoList] is in unauthenticated state.
  void _updateSkipped(List<UserLoginInfo> userInfoList) {
    _currentInfo = _currentInfo.copyWith(skipped: [..._currentInfo.skipped, ...userInfoList]);
    _stream.add(_currentInfo);
  }

  /// Update status: [userInfoList] is in unauthenticated state.
  void _updateWaiting(List<UserLoginInfo> userInfoList) {
    _currentInfo = _currentInfo.copyWith(waiting: [..._currentInfo.waiting, ...userInfoList]);
    _stream.add(_currentInfo);
  }

  /// Update status: [userInfoList] started running.
  void _updateRunning(List<UserLoginInfo> userInfoList) {
    _currentInfo = _currentInfo.copyWith(
      waiting: _currentInfo.waiting.toList()..removeWhere((e) => userInfoList.contains(e)),
      running: [..._currentInfo.running, ...userInfoList],
    );
    _stream.add(_currentInfo);
  }

  /// Update status: [userInfo] ends up with failure in checkin progress.
  ///
  /// "Already checked in" still records the time: the account checked in from somewhere else today. "Not
  /// authorized" means the forum answered the guest page to this account's cookie: its session is recorded as
  /// expired (issue #25) so the manage accounts page can say so.
  Future<void> _updateFailure(UserLoginInfo userInfo, CheckinResult checkinResult) async {
    if (checkinResult is CheckinResultAlreadyChecked) {
      await _storageProvider.updateLastCheckinTime(userInfo.uid!, DateTime.now()).run();
    } else if (checkinResult is CheckinResultNotAuthorized) {
      await _storageProvider.markSessionExpired(userInfo.uid!);
    }
    _currentInfo = _currentInfo.copyWith(
      running: _currentInfo.running.where((e) => e != userInfo).toList(),
      failed: [..._currentInfo.failed, (userInfo, checkinResult)],
    );
    _stream.add(_currentInfo);
  }

  /// Update status: [userInfo] checked in successfully.
  ///
  /// The last check-in time is written right away (the task is run here; it used to be built and dropped) so the
  /// manage accounts page shows the account as checked in while the following accounts are still running. This is
  /// the only write: stamping the whole batch again when it finishes would move the time to the next day for a run
  /// that crosses midnight.
  Future<void> _updateSuccess(UserLoginInfo userInfo, CheckinResult checkinResult) async {
    await _storageProvider.updateLastCheckinTime(userInfo.uid!, DateTime.now()).run();
    _currentInfo = _currentInfo.copyWith(
      running: _currentInfo.running.where((e) => e != userInfo).toList(),
      succeeded: [..._currentInfo.succeeded, (userInfo, checkinResult)],
    );
    _stream.add(_currentInfo);
  }

  /// Dispose the repo.
  Future<void> dispose() async {
    await _stream.close();
  }
}
