/// GitHub #173 and #172.
///
/// #173: on Android the in-app auto sync and the background message service each polled every interval, so the
/// forum got two polls a minute and the app API answered the second one with HTTP 429. They now share the poll: the
/// time of the last one is in the shared database and whoever comes within half an interval skips. A polling fetch
/// that did not reach the forum at all (name resolution, timeout, as when the device wakes up) is tried once more.
///
/// #172: a Windows in-app update closed the app and nothing came back. The update script now logs as soon as it
/// starts and once the app exited, waits longer for the exit, and the app copies the script's log into its own log
/// at the next start, so the next report tells where it stopped. Closing the storage can no longer keep the app from
/// exiting.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/poll_slot.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/features/update/repository/windows_update_installer.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The time of a poll that just happened, in seconds.
///
/// The repository only keeps a polling time that is inside the last three days and falls back to three days ago
/// otherwise (`_buildSinceTimestamp`). The fixed time these tests used (2026-10-07) went out of that window a few days
/// later and the tests quietly stopped covering the in-window branch, so the polls below are relative to the real
/// clock.
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Answers `notify` with "nothing new" after failing [offline] times without an answer (or with [status]).
final class _Forum implements HttpClientAdapter {
  _Forum({this.offline = 0, this.status});

  int offline;
  final int? status;
  final requests = <RequestOptions>[];

  /// The `since` of every request to the app API, in the order asked.
  List<String?> get apiSinces => [
    for (final r in requests)
      if (r.uri.queryParameters['id'] == 'tsdmapp:api') r.uri.queryParameters['since'],
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (offline > 0) {
      offline--;
      throw DioException.connectionError(requestOptions: options, reason: 'Unable to resolve host');
    }
    if (status != null) {
      return ResponseBody.fromString(
        '<html></html>',
        status!,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return ResponseBody.fromString(
      jsonEncode({
        'ok': 1,
        'api': 1,
        'version': '3.5.0',
        'time': now,
        'notices': <Object>[],
        'pms': <Object>[],
        'announces': <Object>[],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Never answers: a request the system holds while the device sleeps.
final class _Silent implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options.uri);
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

const _noticePage = '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=7">alice</a></div></body></html>';
const _emptyPage = '<html><body></body></html>';

/// A forum on a first poll (no time stored: the three pages are fetched, the api is not asked). The n-th notice
/// page request waits for `holds[n]`: answered when it completes with true, failed when with false; a notice page
/// request without a hold fails at once. The other pages answer at once.
final class _Held implements HttpClientAdapter {
  _Held(this.holds);

  final Map<int, Completer<bool>> holds;
  final requests = <Uri>[];
  var _notices = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final String page;
    if (options.uri.queryParameters['do'] == 'notice') {
      final hold = holds[_notices++];
      if (hold == null || !await hold.future) {
        throw DioException.connectionError(requestOptions: options, reason: 'offline');
      }
      page = _noticePage;
    } else {
      page = _emptyPage;
    }
    return ResponseBody.fromString(
      page,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void main() {
  late AppDatabase db;
  late StorageProvider storage;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
  });

  setUp(() {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });

  tearDown(() async {
    await getIt.reset();
    await db.close();
  });

  group('#173 one poll per interval', () {
    const minute = Duration(minutes: 1);
    final t0 = DateTime(2026, 10, 7, 12);

    test('the second poller within half an interval skips, the next interval is polled again', () async {
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0), isNotNull);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 2))), isNull);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 29))), isNull);
      // Exactly half an interval apart is still the same interval: both polling every time otherwise.
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 30))), isNull);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 31))), isNotNull);
    });

    test('whatever the phase of the two timers, each interval is polled once', () async {
      // The app polls at :00 of every minute, the service at :xx; count the polls that went out over ten minutes.
      for (final offset in [0, 1, 17, 29, 31, 45, 59]) {
        final uid = 100 + offset;
        var polls = 0;
        for (var minuteIndex = 0; minuteIndex < 10; minuteIndex++) {
          final app = t0.add(Duration(minutes: minuteIndex));
          if (await NotificationPollSlot.take(storage, uid, minute, now: app) != null) {
            polls++;
          }
          if (await NotificationPollSlot.take(storage, uid, minute, now: app.add(Duration(seconds: offset))) != null) {
            polls++;
          }
        }
        expect(polls, inInclusiveRange(10, 11), reason: 'offset $offset');
      }
    });

    test('accounts are separate, and a clock turned back does not block', () async {
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0), isNotNull);
      expect(await NotificationPollSlot.take(storage, 2, minute, now: t0), isNotNull);
      expect(
        await NotificationPollSlot.take(storage, 1, minute, now: t0.subtract(const Duration(hours: 1))),
        isNotNull,
      );
    });

    test('a poll that brought nothing is given back; a poll taken since is left alone', () async {
      final s1 = (await NotificationPollSlot.take(storage, 1, minute, now: t0))!;
      await NotificationPollSlot.release(storage, 1, s1);
      final s2 = await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 1)));
      expect(s2, isNotNull, reason: 'the interval is free again');
      // A stale release does not free the newer poll.
      await NotificationPollSlot.release(storage, 1, s1);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 2))), isNull);
    });

    test('the background service gives the interval back when the forum was not reached', () async {
      final settings = SettingsRepository(storage);
      getIt.registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, 7);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      await storage.saveCookie(
        username: 'alice',
        uid: 7,
        cookie: {
          '.index': '["$baseHost"]',
          baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=alice; Path=/;_crt=1"}}',
        },
      );
      final forum = _Forum(offline: 99);
      final outcome = await backgroundSyncTick(
        storage: storage,
        repository: NotificationSyncAllRepository(
          storageProvider: storage,
          notificationRepository: NotificationRepository(storageProvider: storage, retryDelay: Duration.zero),
          clientFactory: (cookie) => _client(forum),
          gap: Duration.zero,
        ),
      );
      expect(
        outcome,
        isA<BackgroundSyncDone>().having((e) => e.result, 'result', isA<NotificationSyncResultFailed>()),
      );
      expect(forum.requests, isNotEmpty);
      // The app's sync may poll right away.
      expect(await NotificationPollSlot.take(storage, 7, minute), isNotNull);
      await settings.dispose();
    });

    /// Alice (uid 7) logged in with the service on, every minute.
    Future<SettingsRepository> loggedIn() async {
      final settings = SettingsRepository(storage);
      getIt.registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, 7);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      await storage.saveCookie(
        username: 'alice',
        uid: 7,
        cookie: {
          '.index': '["$baseHost"]',
          baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=alice; Path=/;_crt=1"}}',
        },
      );
      return settings;
    }

    NotificationSyncAllRepository syncing(HttpClientAdapter adapter) => NotificationSyncAllRepository(
      storageProvider: storage,
      notificationRepository: NotificationRepository(storageProvider: storage, retryDelay: Duration.zero),
      clientFactory: (cookie) =>
          NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      gap: Duration.zero,
    );

    test('a tick that could not get its network settings leaves the interval to the app', () async {
      final settings = await loggedIn();
      final silent = _Silent();
      final outcome = await backgroundSyncTick(
        storage: storage,
        repository: syncing(silent),
        prepareNetwork: () async => throw StateError('no platform'),
      );
      expect(outcome, isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', contains('network settings')));
      expect(silent.requests, isEmpty);
      expect(await NotificationPollSlot.take(storage, 7, minute), isNotNull);
      await settings.dispose();
    });

    test('a tick given up reports what it fetched later, and the next tick reports its own fetch', () async {
      final settings = await loggedIn();
      final first = Completer<bool>();
      final second = Completer<bool>();
      final held = _Held({0: first, 1: second});
      final repository = syncing(held);
      final late = <BackgroundSyncOutcome>[];

      final given = await backgroundSyncTick(
        storage: storage,
        repository: repository,
        deadline: const Duration(milliseconds: 200),
        onLate: late.add,
      );
      expect(given, isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', contains('no answer')));
      expect(late, isEmpty);

      // The next tick is in flight when the first fetch fails after all (the device woke up); its retry fails too.
      final next = backgroundSyncTick(storage: storage, repository: repository, now: DateTime.now());
      while (held.requests.length < 6) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      first.complete(false);
      while (late.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        late.single,
        isA<BackgroundSyncDone>().having((e) => e.result, 'result', isA<NotificationSyncResultFailed>()),
      );
      second.complete(true);
      final outcome = await next;
      expect(
        outcome,
        isA<BackgroundSyncDone>().having((e) => e.result, 'result', isA<NotificationSyncResultSuccess>()),
        reason: 'the result of the fetch given up must not pass for this one',
      );
      await settings.dispose();
    });

    test('a fetch answered after the deadline is reported as the outcome it would have been', () async {
      final settings = await loggedIn();
      final first = Completer<bool>();
      final late = <BackgroundSyncOutcome>[];
      final given = await backgroundSyncTick(
        storage: storage,
        repository: syncing(_Held({0: first})),
        deadline: const Duration(milliseconds: 200),
        onLate: late.add,
      );
      expect(given, isA<BackgroundSyncSkipped>());
      first.complete(true);
      while (late.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        late.single,
        isA<BackgroundSyncDone>()
            .having((e) => e.uid, 'uid', 7)
            .having((e) => e.result, 'result', isA<NotificationSyncResultSuccess>()),
      );
      await settings.dispose();
    });

    test('the in-app auto sync does not stay pending while nobody is logged in', () async {
      final cubit = AutoNotificationCubit(
        authenticationRepository: AuthenticationRepository(),
        notificationRepository: NotificationRepository(storageProvider: storage),
        storageProvider: storage,
      )..start(const Duration(seconds: 1));
      addTearDown(cubit.close);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      // A pending state here would never end: the timer only counts while ticking, and a login waits for it.
      expect(cubit.state, isA<AutoNoticeStateTicking>());
    });

    test('a tick the forum never answers ends at the deadline and gives the interval back', () async {
      final settings = SettingsRepository(storage);
      getIt.registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, 7);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      await storage.saveCookie(
        username: 'alice',
        uid: 7,
        cookie: {
          '.index': '["$baseHost"]',
          baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=alice; Path=/;_crt=1"}}',
        },
      );
      final silent = _Silent();
      final outcome = await backgroundSyncTick(
        storage: storage,
        repository: NotificationSyncAllRepository(
          storageProvider: storage,
          notificationRepository: NotificationRepository(storageProvider: storage, retryDelay: Duration.zero),
          clientFactory: (cookie) =>
              NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = silent),
          gap: Duration.zero,
        ),
        deadline: const Duration(milliseconds: 300),
      ).timeout(const Duration(seconds: 5));
      expect(outcome, isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', contains('no answer')));
      expect(silent.requests, isNotEmpty);
      expect(await NotificationPollSlot.take(storage, 7, minute), isNotNull);
      await settings.dispose();
    });

    test('the background service skips a tick right after the app polled', () async {
      final settings = SettingsRepository(storage);
      getIt.registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, 7);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      // The app's auto sync took the poll a moment ago.
      expect(await NotificationPollSlot.take(storage, 7, minute), isNotNull);
      final forum = _Forum();
      final outcome = await backgroundSyncTick(
        storage: storage,
        repository: NotificationSyncAllRepository(
          storageProvider: storage,
          notificationRepository: NotificationRepository(storageProvider: storage),
          clientFactory: (cookie) => _client(forum),
          gap: Duration.zero,
        ),
      );
      expect(outcome, isA<BackgroundSyncSkipped>());
      expect((outcome as BackgroundSyncSkipped).reason, contains('polled by the app'));
      expect(forum.requests, isEmpty);
      await settings.dispose();
    });

    test('a poll that did not reach the forum is tried once more', () async {
      // The first attempt reaches nothing: the API and the three pages fail.
      final forum = _Forum(offline: 4);
      // Relative to now (see [_now]): the last poll is inside the three day window, so both attempts ask the app API
      // from that very time. A fixed time would be clamped to three days ago once it gets old.
      final polled = _now - 60;
      final result = await NotificationRepository(
        storageProvider: storage,
        retryDelay: Duration.zero,
      ).fetchNotificationWith(_client(forum), timestamp: polled, retry: true).run();
      expect(result.isRight(), isTrue);
      expect(forum.requests, hasLength(5));
      expect(forum.apiSinces, ['$polled', '$polled']);
    });

    test('only once: still offline is a failure', () async {
      final forum = _Forum(offline: 9);
      // Relative to now, same reason as above.
      final polled = _now - 60;
      final result = await NotificationRepository(
        storageProvider: storage,
        retryDelay: Duration.zero,
      ).fetchNotificationWith(_client(forum), timestamp: polled, retry: true).run();
      expect(result.isLeft(), isTrue);
      // Each attempt asks the API, then the three pages.
      expect(forum.requests, hasLength(8));
      expect(forum.apiSinces, ['$polled', '$polled']);
    });

    test('an answer with an error status is not retried', () async {
      TsdmAppApi.markUnavailable();
      final forum = _Forum(status: 502);
      // Relative to now like the two above, for consistency only: any time makes this a polling fetch and the fetch
      // fails on the status before `since` matters, so this test does not depend on the window.
      final result = await NotificationRepository(
        storageProvider: storage,
        retryDelay: Duration.zero,
      ).fetchNotificationWith(_client(forum), timestamp: _now - 60, retry: true).run();
      expect(result.isLeft(), isTrue);
      expect(forum.requests, hasLength(3));
    });
  });

  group('#172 Windows update diagnosis', () {
    test('the script logs its start and the exit of the app, and waits up to ten minutes', () {
      const script = WindowsUpdateInstaller.updateScript;
      expect(script, contains("Write-Log ('started, waiting for the app"));
      expect(script, contains("Write-Log 'the app exited'"));
      expect(script, contains('WaitForExit(600000)'));
      expect(script.codeUnits.every((c) => c < 128), isTrue);
      // The log is only written after the marker that lets the app exit.
      expect(script.indexOf(r'Set-Content -LiteralPath $Marker'), lessThan(script.indexOf("Write-Log ('started")));
    });

    test('a script that never reports in leaves what was found in the app log', () async {
      final dir = await Directory.systemTemp.createTemp('tsdm_update_');
      addTearDown(() => dir.delete(recursive: true));
      final app = await Directory(p.join(dir.path, 'app')).create();
      File(p.join(app.path, 'tsdm_client.exe')).writeAsStringSync('old exe');
      File(p.join(app.path, 'flutter_windows.dll')).writeAsStringSync('old engine');
      final updates = (await Directory(p.join(dir.path, 'updates')).create()).path;
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('tsdm_client/tsdm_client.exe', utf8.encode('new exe')))
        ..addFile(ArchiveFile.bytes('tsdm_client/flutter_windows.dll', utf8.encode('new engine')));
      final zip = File(p.join(updates, 'update-125-1.zip'))..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      final logs = <String>[];
      final subscription = talker.stream.listen((e) => logs.add(e.message ?? ''));
      addTearDown(subscription.cancel);
      String? launched;
      final installer = WindowsUpdateInstaller(
        updateDirectory: updates,
        executable: p.join(app.path, 'tsdm_client.exe'),
        startTimeout: const Duration(milliseconds: 300),
        launch: (executable, arguments) async => launched = executable,
        quit: () async => fail('must not quit'),
      );

      await expectLater(
        installer.install(DownloadedUpdate(path: zip.path, version: '1.33.0', versionCode: 125)),
        throwsA(isA<UpdateDownloadException>()),
      );
      await pumpEventQueue();
      // The full path on a Windows machine, the name where it does not exist.
      expect(launched, anyOf('powershell.exe', endsWith(r'\WindowsPowerShell\v1.0\powershell.exe')));
      expect(logs.any((e) => e.contains('install 125 from $updates')), isTrue);
      expect(
        logs.any((e) => e.contains('did not report in') && e.contains('script present, marker missing, log missing')),
        isTrue,
      );
    });

    test('a script that reports in too late is told to stand down', () async {
      final dir = await Directory.systemTemp.createTemp('tsdm_update_');
      addTearDown(() => dir.delete(recursive: true));
      final app = await Directory(p.join(dir.path, 'app')).create();
      File(p.join(app.path, 'tsdm_client.exe')).writeAsStringSync('old exe');
      File(p.join(app.path, 'flutter_windows.dll')).writeAsStringSync('old engine');
      final updates = (await Directory(p.join(dir.path, 'updates')).create()).path;
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('tsdm_client/tsdm_client.exe', utf8.encode('new exe')))
        ..addFile(ArchiveFile.bytes('tsdm_client/flutter_windows.dll', utf8.encode('new engine')));
      final zip = File(p.join(updates, 'update-125-1.zip'))..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      String? nonce;
      final installer = WindowsUpdateInstaller(
        updateDirectory: updates,
        executable: p.join(app.path, 'tsdm_client.exe'),
        startTimeout: const Duration(milliseconds: 200),
        // PowerShell held up by an antivirus: the script reports in only after the app gave up.
        launch: (executable, arguments) async {
          nonce = arguments[arguments.indexOf('-Nonce') + 1];
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 400), () {
              File(arguments[arguments.indexOf('-Marker') + 1]).writeAsStringSync('$nonce\r\n');
            }),
          );
        },
        quit: () async => fail('must not quit'),
      );
      await expectLater(
        installer.install(DownloadedUpdate(path: zip.path, version: '1.33.0', versionCode: 125)),
        throwsA(isA<UpdateDownloadException>()),
      );
      final cancelled = File(p.join(updates, WindowsUpdateInstaller.cancelledMarkerName(nonce!)));
      expect(cancelled.existsSync(), isTrue);
      expect(cancelled.readAsStringSync(), nonce);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // The script: after the app exited and before touching a file, a cancelled attempt ends there.
      const script = WindowsUpdateInstaller.updateScript;
      final exited = script.indexOf("Write-Log 'the app exited'");
      final standDown = script.indexOf(r"($Marker + '.' + $Nonce + '.cancelled')");
      final firstFile = script.indexOf('Get-ChildItem');
      expect(exited, greaterThan(0));
      expect(standDown, inExclusiveRange(exited, firstFile));
      expect(script.substring(standDown, firstFile), contains('exit'));
      // Only an exit the script saw counts; the cmdlets that read [ ] as wildcards are not used on user paths.
      expect(script, contains(r'$exited = $false'));
      expect(script, contains(r'[System.IO.File]::Copy($From, $To, $true)'));
      expect(script, contains('[System.IO.Directory]::CreateDirectory'));
      expect(script, contains('System.Diagnostics.ProcessStartInfo'));
      expect(script, isNot(contains('Start-Process')));
      expect(script, isNot(contains('Copy-Item')));
      expect(script, isNot(contains('New-Item')));
      expect(script.codeUnits.every((c) => c < 128), isTrue);

      // Cancel markers are cleaned after an hour, not before.
      final old = File(p.join(updates, WindowsUpdateInstaller.cancelledMarkerName('abcd')))
        ..writeAsStringSync('abcd')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      await ReleaseUpdateRepository(installer: installer).cleanup(keepVersionCode: 125);
      expect(old.existsSync(), isFalse);
      expect(cancelled.existsSync(), isTrue);
      expect(zip.existsSync(), isTrue);
    });

    test('the last attempt is copied into the app log once', () async {
      final dir = await Directory.systemTemp.createTemp('tsdm_update_');
      addTearDown(() => dir.delete(recursive: true));
      final logs = <String>[];
      final subscription = talker.stream.listen((e) => logs.add(e.message ?? ''));
      addTearDown(subscription.cancel);
      final installer = WindowsUpdateInstaller(updateDirectory: dir.path);

      await installer.reportLastAttempt();
      await pumpEventQueue();
      expect(logs.where((e) => e.contains('last update attempt')), isEmpty);

      File(p.join(dir.path, WindowsUpdateInstaller.startedMarkerName)).writeAsStringSync('nonce');
      File(p.join(dir.path, WindowsUpdateInstaller.logName)).writeAsStringSync('x started, waiting for the app\n');
      await installer.reportLastAttempt();
      await pumpEventQueue();
      expect(logs.where((e) => e.contains('last update attempt') && e.contains('waiting for the app')), hasLength(1));
      expect(File(p.join(dir.path, WindowsUpdateInstaller.startedMarkerName)).existsSync(), isFalse);

      await installer.reportLastAttempt();
      await pumpEventQueue();
      expect(logs.where((e) => e.contains('last update attempt')), hasLength(1));
    });
  });
}
