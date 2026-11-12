/// System notifications on iOS, macOS and Linux: off by default, behind a switch of the settings; the plugin is not
/// initialized (nothing asked, nothing posted) until the user turns the switch on, which asks the permission then; a
/// refusal (or no notification service on Linux) leaves the switch off. Android and Windows post as before, whatever
/// the switch says. The notifications themselves and what a tap opens are the ones of Android and Windows.
///
/// `debugDefaultTargetPlatformOverride` does not change `dart:io`'s `Platform`, which the app's platform checks read:
/// the platform is given to the gate instead.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/opt_in_notifications.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// What the gate asked of the plugin.
final class _FakeOptIn implements OptInNoticePlugin {
  _FakeOptIn({this.initializes = true, this.allows = true, this.stillAllowed = true, this.requestThrows = false});

  final bool initializes;
  final bool allows;
  final bool stillAllowed;
  final bool requestThrows;

  final calls = <String>[];

  @override
  Future<bool> initialize() async {
    calls.add('initialize');
    return initializes;
  }

  @override
  Future<bool> requestPermission() async {
    calls.add('requestPermission');
    if (requestThrows) {
      throw Exception('no notification service');
    }
    return allows;
  }

  @override
  Future<bool> permitted() async {
    calls.add('permitted');
    return stillAllowed;
  }
}

typedef _Shown = ({int id, String? title, String? body, NotificationDetails? details, String? payload});

/// The app's plugin, as far as these tests use it.
final class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];
  InitializationSettings? settings;
  DidReceiveNotificationResponseCallback? onResponse;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback? onDidReceiveBackgroundNotificationResponse,
  }) async {
    this.settings = settings;
    onResponse = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  T? resolvePlatformSpecificImplementation<T extends FlutterLocalNotificationsPlatform>() => null;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add((id: id, title: title, body: body, details: notificationDetails, payload: payload));
}

NotificationAutoSyncInfoNotice _reply() => const NotificationAutoSyncInfoNotice(
  msg: 'A 回复了您的帖子',
  notice: 1,
  personalMessage: 0,
  broadcastMessage: 0,
  timestamp: 1700000000,
  nid: 5,
  author: 'A',
  noticeType: 'post',
  fromIdType: 'post',
  threadTitle: 'T',
  tid: 1,
  pid: 2,
);

const List<NoticePlatform> _optIn = [NoticePlatform.iOS, NoticePlatform.macOS, NoticePlatform.linux];
const List<NoticePlatform> _always = [NoticePlatform.android, NoticePlatform.windows];

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('which platforms always post and which only once turned on', () {
    for (final p in _always) {
      expect(p.alwaysPosts, isTrue, reason: p.name);
      expect(p.optIn, isFalse, reason: p.name);
    }
    for (final p in _optIn) {
      expect(p.alwaysPosts, isFalse, reason: p.name);
      expect(p.optIn, isTrue, reason: p.name);
    }
    expect(NoticePlatform.other.alwaysPosts || NoticePlatform.other.optIn, isFalse);
    expect(
      [
        for (final p in NoticePlatform.values)
          if (p.darwin) p,
      ],
      [NoticePlatform.iOS, NoticePlatform.macOS],
    );
  });

  group('iOS, macOS, Linux: off by default', () {
    for (final p in _optIn) {
      test('${p.name}: nothing initialized, asked nor posted while the switch is off', () async {
        final gate = SystemNotificationGate(platform: p, enabled: () => false);
        final plugin = _FakeOptIn();
        var turnedOff = false;
        await gate.boot(enabled: false, plugin: plugin, turnOff: () async => turnedOff = true);
        expect(plugin.calls, isEmpty, reason: 'the plugin is not even initialized');
        expect(gate.ready, isFalse);
        expect(gate.posts, isFalse);
        expect(gate.switchOn(enabled: false), isFalse);
        expect(turnedOff, isFalse);
      });
    }

    test('the setting is off unless set, and never synced across devices', () {
      expect(SettingsKeys.systemNotificationsOptIn.defaultValue, isFalse);
      expect({for (final s in syncedSettings) s.key.name}, isNot(contains(SettingsKeys.systemNotificationsOptIn.name)));
    });

    test('a setting left on without this run being ready (a backup restored) shows off and posts nothing', () {
      final gate = SystemNotificationGate(platform: NoticePlatform.iOS, enabled: () => true);
      expect(gate.posts, isFalse);
      expect(gate.switchOn(enabled: true), isFalse);
    });
  });

  group('turning the switch on', () {
    for (final p in _optIn) {
      test('${p.name}: initializes, asks the permission now, then posts', () async {
        var on = false;
        final gate = SystemNotificationGate(platform: p, enabled: () => on);
        final plugin = _FakeOptIn();
        final saved = <bool>[];
        final result = await turnOnSystemNotifications(
          gate: gate,
          plugin: plugin,
          save: ({required on}) async => saved.add(on),
        );
        on = saved.last;
        expect(result, OptInNoticeResult.granted);
        expect(plugin.calls, ['initialize', 'requestPermission']);
        expect(saved, [true]);
        expect(gate.ready, isTrue);
        expect(gate.posts, isTrue);
        expect(gate.switchOn(enabled: true), isTrue);

        // Turned off again: nothing posted, the switch off.
        on = false;
        expect(gate.posts, isFalse);
        expect(gate.switchOn(enabled: false), isFalse);
      });
    }

    for (final p in [NoticePlatform.iOS, NoticePlatform.macOS]) {
      test('${p.name}: refused, the switch flips back and says so', () async {
        final gate = SystemNotificationGate(platform: p, enabled: () => true);
        final saved = <bool>[];
        final result = await turnOnSystemNotifications(
          gate: gate,
          plugin: _FakeOptIn(allows: false),
          save: ({required on}) async => saved.add(on),
        );
        expect(result, OptInNoticeResult.denied);
        expect(saved, [false]);
        expect(gate.ready, isFalse);
        expect(gate.posts, isFalse);
        expect(gate.switchOn(enabled: false), isFalse);
      });
    }

    test('linux: no notification service answering, or no plugin, the switch flips back', () async {
      for (final plugin in [_FakeOptIn(requestThrows: true), _FakeOptIn(initializes: false)]) {
        final gate = SystemNotificationGate(platform: NoticePlatform.linux, enabled: () => true);
        final saved = <bool>[];
        final result = await turnOnSystemNotifications(
          gate: gate,
          plugin: plugin,
          save: ({required on}) async => saved.add(on),
        );
        expect(result, OptInNoticeResult.unavailable);
        expect(saved, [false]);
        expect(gate.posts, isFalse);
      }
    });

    test('the plugin is initialized without asking anything, with the tap handler of the other platforms', () async {
      for (final p in _optIn) {
        final plugin = _Plugin();
        await FlnpOptInNoticePlugin(platform: p, plugin: plugin).initialize();
        final darwin = [plugin.settings!.iOS!, plugin.settings!.macOS!];
        for (final d in darwin) {
          expect(d.requestAlertPermission, isFalse);
          expect(d.requestBadgePermission, isFalse);
          expect(d.requestSoundPermission, isFalse);
          expect(d.requestProvisionalPermission, isFalse);
        }
        expect(plugin.settings!.linux, isNotNull);
        expect(plugin.settings!.android, isNull);
        expect(plugin.settings!.windows, isNull);
        expect(plugin.onResponse, same(onLocalNotificationOpened));
      }
    });
  });

  group('at boot with the switch on', () {
    for (final p in _optIn) {
      test('${p.name}: initialized without asking, ready when still allowed', () async {
        final gate = SystemNotificationGate(platform: p, enabled: () => true);
        final plugin = _FakeOptIn();
        await gate.boot(enabled: true, plugin: plugin);
        expect(plugin.calls, ['initialize', 'permitted'], reason: 'no permission dialog at boot');
        expect(gate.posts, isTrue);
      });

      test(
        '${p.name}: not allowed any more, the setting is turned off (iOS, macOS) or this run only (Linux)',
        () async {
          final gate = SystemNotificationGate(platform: p, enabled: () => true);
          var turnedOff = false;
          await gate.boot(
            enabled: true,
            plugin: _FakeOptIn(stillAllowed: false),
            turnOff: () async => turnedOff = true,
          );
          // Linux: a notification service not answering yet (the desktop still starting) is tried again next boot.
          expect(turnedOff, p.darwin, reason: p.name);
          expect(gate.posts, isFalse);
          expect(gate.switchOn(enabled: true), isFalse);
        },
      );

      test('${p.name}: the plugin is initialized once per run, whatever the switch does after', () async {
        var on = true;
        final gate = SystemNotificationGate(platform: p, enabled: () => on);
        final plugin = _FakeOptIn();
        await gate.boot(enabled: true, plugin: plugin);
        on = false;
        expect(await gate.enable(plugin), OptInNoticeResult.granted);
        on = true;
        expect(await gate.enable(plugin), OptInNoticeResult.granted);
        expect(plugin.calls.where((c) => c == 'initialize'), hasLength(1));
        expect(gate.posts, isTrue);
      });
    }
  });

  group('Android and Windows unchanged', () {
    for (final p in _always) {
      test('${p.name}: always posts, the switch neither shown nor used', () async {
        for (final enabled in [false, true]) {
          final gate = SystemNotificationGate(platform: p, enabled: () => enabled);
          final plugin = _FakeOptIn();
          await gate.boot(enabled: enabled, plugin: plugin);
          expect(await gate.enable(plugin), OptInNoticeResult.unavailable);
          expect(plugin.calls, isEmpty, reason: 'the boot of these platforms initializes the plugin as before');
          expect(gate.posts, isTrue);
          expect(gate.ready, isFalse);
          expect(gate.switchOn(enabled: enabled), isFalse);
        }
      });
    }

    test('the other accounts are polled and announced where they always were only', () {
      final saved = systemNotificationGate;
      addTearDown(() => systemNotificationGate = saved);
      for (final p in NoticePlatform.values) {
        systemNotificationGate = SystemNotificationGate(platform: p, enabled: () => true);
        expect(alwaysPostsNotifications, p.alwaysPosts, reason: p.name);
      }
    });
  });

  group('the auto sync results reach the notifications', () {
    late SystemNotificationGate saved;
    setUp(() => saved = systemNotificationGate);
    tearDown(() => systemNotificationGate = saved);

    Future<int> resultsPassed(NotificationInfoRepository repo) async {
      final got = <NotificationAutoSyncInfo>[];
      final sub = repo.autoSyncStatus.listen(got.add);
      // The stream replays the latest result to a new listener: only what this update adds counts.
      await Future<void>.delayed(Duration.zero);
      final before = got.length;
      repo.updateAutoSyncInfo(_reply());
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      return got.length - before;
    }

    test('iOS: only once turned on, without rebuilding the repository', () async {
      var on = false;
      systemNotificationGate = SystemNotificationGate(platform: NoticePlatform.iOS, enabled: () => on);
      final repo = NotificationInfoRepository();
      addTearDown(repo.dispose);
      expect(autoSyncPostsNotifications, isFalse);
      expect(await resultsPassed(repo), 0);

      await systemNotificationGate.enable(_FakeOptIn());
      on = true;
      expect(autoSyncPostsNotifications, isTrue);
      expect(await resultsPassed(repo), 1);

      on = false;
      expect(await resultsPassed(repo), 0);
    });

    test('Android and Windows: always, as before', () async {
      for (final p in _always) {
        systemNotificationGate = SystemNotificationGate(platform: p, enabled: () => false);
        final repo = NotificationInfoRepository();
        expect(await resultsPassed(repo), 1, reason: p.name);
        await repo.dispose();
      }
    });

    test('the flag the tests give still decides', () async {
      systemNotificationGate = SystemNotificationGate(platform: NoticePlatform.linux, enabled: () => false);
      final repo = NotificationInfoRepository(localNotifications: true);
      addTearDown(repo.dispose);
      expect(await resultsPassed(repo), 1);
    });
  });

  test(
    'the same notification and tap payload as on Android and Windows, with the details of the other platforms',
    () async {
      final tr = await AppLocale.zhCn.build();
      final plugin = _Plugin();
      const account = LocalNoticeAccount(uid: 31, username: 'u');
      await showLocalNotificationWith(
        plugin: plugin,
        translations: tr,
        info: _reply(),
        account: account,
        directReply: false,
        android: false,
      );
      final expected = localNotificationContentOf(tr, _reply(), account: account);
      expect(plugin.shown, hasLength(1));
      final n = plugin.shown.single;
      expect(n.id, expected.id);
      expect(n.title, expected.title);
      expect(n.body, expected.body);
      expect(n.payload, expected.payload);
      // A tap opens what it opens on Android and Windows: the floor of the notice, as that account.
      expect(LocalNoticeKeys.parseTarget(n.payload), isNotNull);
      expect(n.details!.android, isNotNull);
      expect(n.details!.windows, isNotNull);
      expect(n.details!.iOS, isNotNull);
      expect(n.details!.macOS, isNotNull);
      expect(n.details!.linux, isNotNull);
      expect(n.details!.iOS!.threadIdentifier, NoticeCategory.reply.channelId);
    },
  );
}
