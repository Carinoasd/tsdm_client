/// The Android home screen widget shows the unread notice and personal message counts of the account in use and
/// whether it checked in today; the native side draws it from what Dart tells over `HomeWidgetChannel`.
///
/// 1. the channel sends the whole state in one `update` call, does nothing on a platform without the widget and never
///    throws when the native side is missing or fails;
/// 2. `HomeWidgetSyncCubit` tells the widget the account and its check-in once storage answered, with the counts left
///    as they are until the app counted them in this run, then every change: the unread counts, a check-in recorded in
///    storage today (another account's or yesterday's does not count), a logout (cleared at once) and a login, an
///    account switch (the counts of the account before are not sent as the new one's); the same state is not sent
///    twice, and nothing is sent where the widget does not exist;
/// 3. the check-in goes as its day, not a flag: an app open across midnight that checks in again sends the new day
///    although "checked in" did not change, and the widget never takes the day from its own clock.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/home_widget/bloc/home_widget_sync_cubit.dart';
import 'package:tsdm_client/features/home_widget/repository/home_widget_channel.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const channel = MethodChannel(HomeWidgetChannel.name);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  /// Let the native side answer every call, or throw [failure].
  void nativeSide({Exception? failure}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (failure != null) {
        throw failure;
      }
      return true;
    });
  }

  /// The arguments of the calls so far.
  List<Map<Object?, Object?>> sent() => calls.map((c) => c.arguments as Map<Object?, Object?>).toList();

  setUp(() {
    calls = [];
    nativeSide();
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('channel', () {
    test('the whole state goes in one update call', () async {
      const widget = HomeWidgetChannel(enabled: true);
      await widget.update(uid: 7, notice: 3, personalMessage: 1, checkedInDay: '2026-11-05');
      await widget.update(uid: 7, notice: null, personalMessage: null, checkedInDay: null);
      await widget.clear();
      expect(calls.map((c) => c.method), everyElement(HomeWidgetChannel.updateMethod));
      expect(sent(), [
        {'uid': 7, 'notice': 3, 'personalMessage': 1, 'checkedInDay': '2026-11-05'},
        {'uid': 7, 'notice': null, 'personalMessage': null, 'checkedInDay': null},
        {'uid': null, 'notice': 0, 'personalMessage': 0, 'checkedInDay': null},
      ]);
    });

    test('nothing on a platform without the widget', () async {
      const widget = HomeWidgetChannel(enabled: false);
      await widget.update(uid: 7, notice: 3, personalMessage: 1, checkedInDay: '2026-11-05');
      await widget.clear();
      expect(calls, isEmpty);
      // The app's channel decides by the platform: the tests run on none of the mobile ones.
      expect(const HomeWidgetChannel().enabled, isFalse);
    });

    test('a missing or failing native side never throws', () async {
      const widget = HomeWidgetChannel(enabled: true);
      messenger.setMockMethodCallHandler(channel, null);
      await widget.update(uid: 7, notice: 3, personalMessage: 1, checkedInDay: '2026-11-05');
      nativeSide(failure: PlatformException(code: 'boom'));
      await widget.update(uid: 7, notice: 3, personalMessage: 1, checkedInDay: '2026-11-05');
      expect(calls, hasLength(1));
    });
  });

  group('sync', () {
    late StreamController<NotificationStateInfo> unread;
    late StreamController<List<StoredAccount>> accounts;
    late StreamController<AuthStatus> auth;
    int? uid;
    var now = DateTime(2026, 11, 5, 9);
    const today = '2026-11-05';
    const user = UserLoginInfo(username: 'a', uid: 7);
    const other = UserLoginInfo(username: 'b', uid: 8);
    const counts = NotificationStateInfo(notice: 2, personalMessage: 1, broadcastMessage: 5);

    StoredAccount stored(UserLoginInfo user, DateTime? lastCheckin) =>
        (user: user, lastCheckin: lastCheckin, sessionExpiredAt: null);

    HomeWidgetSyncCubit build({bool enabled = true}) => HomeWidgetSyncCubit(
      unread: unread.stream,
      accounts: accounts.stream,
      auth: auth.stream,
      currentUid: () => uid,
      channel: HomeWidgetChannel(enabled: enabled),
      now: () => now,
    );

    setUp(() {
      unread = StreamController.broadcast();
      accounts = StreamController.broadcast();
      auth = StreamController.broadcast();
      uid = 7;
      now = DateTime(2026, 11, 5, 9);
    });
    tearDown(() async {
      await unread.close();
      await accounts.close();
      await auth.close();
    });

    test('the account and its check-in once storage answered, the counts once the app counted', () async {
      final cubit = build()..start();
      addTearDown(cubit.close);
      await pumpEventQueue();
      // Nothing to say yet: the widget may show what the background service brought.
      expect(cubit.state, isNull);
      expect(calls, isEmpty);

      accounts.add([stored(user, null)]);
      await pumpEventQueue();
      expect(cubit.state, const HomeWidgetSnapshot(uid: 7, notice: null, personalMessage: null, checkedInDay: null));
      expect(sent(), [
        {'uid': 7, 'notice': null, 'personalMessage': null, 'checkedInDay': null},
      ]);

      unread.add(counts);
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': null});

      // The notice page read a notice; the broadcast messages are not on the widget.
      unread.add(const NotificationStateInfo(notice: 1, personalMessage: 1, broadcastMessage: 0));
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 1, 'personalMessage': 1, 'checkedInDay': null});

      // The same counts again (another sync found nothing new): not sent twice.
      unread.add(const NotificationStateInfo(notice: 1, personalMessage: 1, broadcastMessage: 3));
      await pumpEventQueue();
      expect(calls, hasLength(3));

      // Starting twice listens once.
      cubit.start();
      unread.add(NotificationStateInfo.empty);
      await pumpEventQueue();
      expect(calls, hasLength(4));
    });

    test('the check-in recorded today, of this account', () async {
      final cubit = build()..start();
      addTearDown(cubit.close);
      unread.add(counts);
      // Yesterday's check-in and another account's today do not count.
      accounts.add([stored(user, now.subtract(const Duration(days: 1))), stored(other, now)]);
      await pumpEventQueue();
      expect(sent(), [
        {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': null},
      ]);

      // A check-in of this account succeeded (or answered "already checked in"): recorded in storage.
      accounts.add([stored(user, now.subtract(const Duration(minutes: 1))), stored(other, now)]);
      await pumpEventQueue();
      expect(cubit.state, const HomeWidgetSnapshot(uid: 7, notice: 2, personalMessage: 1, checkedInDay: today));
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': today});

      // Switched to the other account, which checked in as well: the counts in hand are the first account's, the new
      // one's come with its sync.
      uid = 8;
      auth.add(const AuthStatusAuthed(other));
      await pumpEventQueue();
      expect(sent().last, {'uid': 8, 'notice': null, 'personalMessage': null, 'checkedInDay': today});
      unread.add(const NotificationStateInfo(notice: 4, personalMessage: 0, broadcastMessage: 0));
      await pumpEventQueue();
      expect(sent().last, {'uid': 8, 'notice': 4, 'personalMessage': 0, 'checkedInDay': today});
    });

    test('the next day: the check-in of the day before is over, the new one is sent as its own day', () async {
      final cubit = build()..start();
      addTearDown(cubit.close);
      unread.add(counts);
      accounts.add([stored(user, now)]);
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': today});

      // Past midnight, the app still open: the day watcher asks the check-in state again, storage answers the same
      // rows (nothing changed in them), the widget is told yesterday's check-in is over.
      now = DateTime(2026, 11, 6, 0, 0, 5);
      accounts.add([stored(user, DateTime(2026, 11, 5, 9))]);
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': null});

      // The auto check-in of the new day: "checked in" again, a different day than the one sent before, so it goes.
      now = DateTime(2026, 11, 6, 1, 1);
      accounts.add([stored(user, DateTime(2026, 11, 6, 1, 0, 40))]);
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': '2026-11-06'});
      expect(HomeWidgetSyncCubit.isoDay(DateTime(2026, 1, 9, 23, 59)), '2026-01-09');
    });

    test('a logout clears the widget, a login fills it again', () async {
      final cubit = build()..start();
      addTearDown(cubit.close);
      unread.add(counts);
      accounts.add([stored(user, now)]);
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': today});

      // The settings still name the account while the logout clears them: the status decides.
      auth.add(const AuthStatusNotAuthed());
      await pumpEventQueue();
      expect(cubit.state, HomeWidgetSnapshot.empty);
      expect(sent().last, {'uid': null, 'notice': 0, 'personalMessage': 0, 'checkedInDay': null});

      // Counts of nobody change nothing on the widget.
      unread.add(const NotificationStateInfo(notice: 9, personalMessage: 9, broadcastMessage: 9));
      await pumpEventQueue();
      expect(calls, hasLength(2));

      auth.add(const AuthStatusLoading());
      await pumpEventQueue();
      expect(calls, hasLength(2));

      // Logged in again: the check-in of the day is still recorded, the counts are counted again.
      auth.add(const AuthStatusAuthed(user));
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': null, 'personalMessage': null, 'checkedInDay': today});
      unread.add(counts);
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': 2, 'personalMessage': 1, 'checkedInDay': today});
    });

    test('no account at start: cleared once storage answered, until a login', () async {
      uid = null;
      final cubit = build()..start();
      addTearDown(cubit.close);
      accounts.add([]);
      await pumpEventQueue();
      expect(sent(), [
        {'uid': null, 'notice': 0, 'personalMessage': 0, 'checkedInDay': null},
      ]);
      uid = 7;
      auth.add(const AuthStatusAuthed(user));
      await pumpEventQueue();
      expect(sent().last, {'uid': 7, 'notice': null, 'personalMessage': null, 'checkedInDay': null});
    });

    test('nothing where the widget does not exist', () async {
      final cubit = build(enabled: false)..start();
      addTearDown(cubit.close);
      unread.add(counts);
      accounts.add([stored(user, now)]);
      auth.add(const AuthStatusNotAuthed());
      await pumpEventQueue();
      expect(cubit.state, isNull);
      expect(calls, isEmpty);
    });
  });
}
