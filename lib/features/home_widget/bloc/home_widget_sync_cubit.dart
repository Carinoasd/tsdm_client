import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/home_widget/repository/home_widget_channel.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What the home screen widget was last told.
@immutable
final class HomeWidgetSnapshot {
  /// Constructor.
  const HomeWidgetSnapshot({
    required this.uid,
    required this.notice,
    required this.personalMessage,
    required this.checkedInDay,
  });

  /// No account in use.
  static const empty = HomeWidgetSnapshot(uid: null, notice: 0, personalMessage: 0, checkedInDay: null);

  /// The account in use, null when none.
  final int? uid;

  /// Unread notices; null while the app has not counted them yet in this run (the widget keeps what it shows).
  final int? notice;

  /// Unread personal messages; null like [notice].
  final int? personalMessage;

  /// The day the account checked in, by the app's record, when that is today (ISO date, device-local); null when it
  /// has not checked in today.
  ///
  /// The day, not a flag: a check-in on the next day of an app that stayed open is a different snapshot, so it is
  /// pushed although "checked in" did not change.
  final String? checkedInDay;

  /// Whether the account checked in today.
  bool get checkedIn => checkedInDay != null;

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetSnapshot &&
      other.uid == uid &&
      other.notice == notice &&
      other.personalMessage == personalMessage &&
      other.checkedInDay == checkedInDay;

  @override
  int get hashCode => Object.hash(uid, notice, personalMessage, checkedInDay);

  @override
  String toString() =>
      'HomeWidgetSnapshot(uid: $uid, notice: $notice, pm: $personalMessage, checkedInDay: $checkedInDay)';
}

/// Keeps the Android home screen widget in step with the app (Android only, see [HomeWidgetChannel]).
///
/// The widget shows the unread counts and the check-in of the account in use. Every change the app sees is pushed
/// through the channel, deduplicated: the unread counts of `NotificationStateCubit` (the notice page read, a sync, the
/// background service's counts brought in by `BackgroundSyncBridgeCubit`), the check-in record in storage (a manual
/// check-in, the auto check-in, the shortcut; "already checked in" is recorded too) and the account (a login, a
/// switch, a logout: the widget is then cleared).
///
/// The counts are only sent once the app counted them in this run: at a start they are still the zeros of the cubit's
/// initial state while the widget may show what the background service brought, so the first push carries the account
/// and its check-in (from storage, once read) and leaves the counts as they are. The state is the snapshot pushed
/// last, for tests.
final class HomeWidgetSyncCubit extends Cubit<HomeWidgetSnapshot?> with LoggerMixin {
  /// Constructor.
  ///
  /// [unread] is the `NotificationStateCubit`'s stream; [accounts] is the storage's `allAccountsStream`; [auth] is the
  /// authentication status stream; [currentUid] tells the account in use (the stored one counts before its session is
  /// verified, like the shortcuts); [now] is the clock, for tests.
  HomeWidgetSyncCubit({
    required Stream<NotificationStateInfo> unread,
    required Stream<List<StoredAccount>> accounts,
    required Stream<AuthStatus> auth,
    required int? Function() currentUid,
    HomeWidgetChannel channel = const HomeWidgetChannel(),
    DateTime Function() now = DateTime.now,
  }) : _unreadStream = unread,
       _accountsStream = accounts,
       _authStream = auth,
       _currentUid = currentUid,
       _channel = channel,
       _now = now,
       super(null);

  final Stream<NotificationStateInfo> _unreadStream;
  final Stream<List<StoredAccount>> _accountsStream;
  final Stream<AuthStatus> _authStream;
  final int? Function() _currentUid;
  final HomeWidgetChannel _channel;
  final DateTime Function() _now;

  /// The unread counts, null until the app counted them in this run, and again after the account changed (the counts
  /// of the account before are not the new one's).
  NotificationStateInfo? _unread;

  /// The account the counts in [_unread] are of: the account in use when they came.
  ///
  /// Counts of the account before that arrive after the switch would be taken as the new account's: nothing in the
  /// counts tells their account. The sources check the account in use before they publish (`NotificationBloc` and
  /// `BackgroundSyncBridgeCubit` compare the uid, the notice page the lists' owner), so this is unlikely, and the new
  /// account's first sync corrects it.
  int? _unreadUid;

  /// The stored accounts, null until storage answered.
  List<StoredAccount>? _accounts;

  /// Whether the last authentication status said "no account": the stored account named by the settings is then not
  /// in use either, whatever [_currentUid] still answers while the logout clears them.
  var _loggedOut = false;

  final _subscriptions = <StreamSubscription<void>>[];

  /// Start listening. Nothing happens on platforms without the widget.
  void start() {
    if (!_channel.enabled || _subscriptions.isNotEmpty) {
      return;
    }
    _subscriptions.addAll([
      _unreadStream.listen((info) {
        _unread = info;
        _unreadUid = _loggedOut ? null : _currentUid();
        _push();
      }, onError: handleRaw),
      _accountsStream.listen((accounts) {
        _accounts = accounts;
        _push();
      }, onError: handleRaw),
      _authStream.listen((status) {
        switch (status) {
          case AuthStatusAuthed():
            _loggedOut = false;
            _push();
          case AuthStatusNotAuthed():
            _loggedOut = true;
            _push();
          case AuthStatusUnknown() || AuthStatusLoading():
            break;
        }
      }, onError: handleRaw),
    ]);
  }

  /// The state the widget should show now, null while storage has not told the accounts yet (nothing to say).
  HomeWidgetSnapshot? snapshot() {
    final uid = _loggedOut ? null : _currentUid();
    if (uid == null) {
      return HomeWidgetSnapshot.empty;
    }
    final accounts = _accounts;
    if (accounts == null) {
      return null;
    }
    DateTime? lastCheckin;
    for (final account in accounts) {
      if (account.user.uid == uid) {
        lastCheckin = account.lastCheckin;
        break;
      }
    }
    final unread = _unreadUid == uid ? _unread : null;
    return HomeWidgetSnapshot(
      uid: uid,
      notice: unread?.notice,
      personalMessage: unread?.personalMessage,
      checkedInDay: isCheckedInToday(lastCheckin, now: _now()) ? isoDay(lastCheckin!) : null,
    );
  }

  /// The device-local day of [time] as the native side writes it (`LocalDate.toString()`): `yyyy-MM-dd`.
  static String isoDay(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-'
      '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';

  void _push() {
    if (isClosed) {
      return;
    }
    final next = snapshot();
    if (next == null || next == state) {
      return;
    }
    emit(next);
    unawaited(
      next.uid == null
          ? _channel.clear()
          : _channel.update(
              uid: next.uid,
              notice: next.notice,
              personalMessage: next.personalMessage,
              checkedInDay: next.checkedInDay,
            ),
    );
  }

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    return super.close();
  }
}
