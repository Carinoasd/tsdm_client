/// The devices an account logged in on (plugin 3.6.0, `plugin.php?id=tsdmapp:api&action=device`).
///
/// The app makes one id for its installation ([LoginDeviceIdentity]) and, once `status` said the forum keeps devices
/// (`device: 1`, [TsdmAppApi.knowsDevice]), sends it in `X-Tsdmapp-Device` with every request to the forum
/// ([LoginDeviceHeader]). Each account is registered after its login. A device logged out from another device
/// gets `error: device_revoked` (HTTP 200) for its next request: the request fails, the id is replaced, the login of
/// that account is dropped from this device and the user is told; the account is not registered again (a register
/// with the cookie still valid on the forum would undo the logout) until it is logged in again. The settings page
/// offers the devices page only once `status` named it; the page lists the devices with this one marked, logs another
/// one out (after a question) and takes those logged out off the list. The id never goes with a backup.
///
/// The answers are the test forum's (tsdmapp 3.6.0), scrubbed (`test/data/tsdmapp/README.md`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/login_device/cubit/login_devices_cubit.dart';
import 'package:tsdm_client/features/login_device/login_device_coordinator.dart';
import 'package:tsdm_client/features/login_device/login_device_identity.dart';
import 'package:tsdm_client/features/login_device/models/login_device.dart';
import 'package:tsdm_client/features/login_device/repository/login_device_repository.dart';
import 'package:tsdm_client/features/login_device/view/login_devices_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) => jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, dynamic>;

Translations get tr => LocaleSettings.instance.currentTranslations;

/// The id of this device in the fixtures, and the one of the other device.
const _thisId = '0f8e6a52-3c1d-4b7e-9a10-5d2c7e4b1a01';
const _otherId = '7c2b9d14-8e5f-4a63-b2c7-1e9f0a3d6c02';

/// One answer of the fake forum: its body and status.
typedef _Answer = ({Object body, int status});

_Answer _ok(Object body) => (body: body, status: 200);

/// A forum answering every request with [answer] and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  /// The requests to the `device` action.
  List<RequestOptions> get deviceCalls =>
      requests.where((r) => r.uri.queryParameters['action'] == LoginDeviceRepository.action).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    final body = a.body;
    final json = body is Map || (body is String && body.startsWith('{'));
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      a.status,
      headers: {
        Headers.contentTypeHeader: [if (json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A client of [forum], with the interceptors of the app.
NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

/// The plugin's `status`: 3.6.0 with `device` [device], or an older plugin without the key.
Map<String, Object?> _status({int? device = 1, String version = '3.6.0'}) => {
  'ok': 1,
  'api': 1,
  'version': version,
  'time': 1700000000,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'actions': ['status', 'notify', if (device != null) 'device'],
  'nodoc': 1,
  'preview': 1,
  'device': ?device,
};

/// The form of a POST as the forum reads it.
Map<String, String> _form(RequestOptions r) => switch (r.data) {
  final Map<dynamic, dynamic> m => {for (final e in m.entries) '${e.key}': '${e.value}'},
  final String s => Uri.splitQueryString(s),
  _ => const {},
};

String? _header(RequestOptions r) => r.headers[LoginDeviceIdentity.header] as String?;

String _action(RequestOptions r) => r.uri.queryParameters['action'] ?? '';

/// Real time for the database and the forum, a few frames in between.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(() {
    TsdmAppApi.reset();
    LoginDeviceIdentity.reset();
    LoginDeviceIdentity.id = _thisId;
    LoginDeviceIdentity.onRevoked = null;
  });
  tearDown(() {
    LoginDeviceIdentity.reset();
    LoginDeviceIdentity.onRevoked = null;
  });

  group('A. status tells whether the forum keeps devices', () {
    test('device 1, device 0, an older plugin; another action changes nothing; reset forgets', () async {
      final answers = <String, Object>{};
      final client = _client(_Forum((o) => _ok(answers[_action(o)]!)));
      expect(TsdmAppApi.knowsDevice, isFalse, reason: 'nothing told yet');

      answers['status'] = _status();
      await TsdmAppApi.ask(client, 'status');
      expect(TsdmAppApi.knowsDevice, isTrue);
      expect(TsdmAppApi.pluginInfo.value!.device, isTrue);

      // notify names the version, not `device`: what status said holds.
      answers['notify'] = {'ok': 1, 'version': '3.6.0', 'time': 1700000000, 'uid': 31, 'notices': <Object?>[]};
      await TsdmAppApi.ask(client, 'notify', {'since': '0'});
      expect(TsdmAppApi.knowsDevice, isTrue);

      // The forum switched it off.
      answers['status'] = _status(device: 0);
      await TsdmAppApi.ask(client, 'status');
      expect(TsdmAppApi.knowsDevice, isFalse);

      // An older plugin: no key at all.
      answers['status'] = _status(device: null, version: '3.5.0');
      await TsdmAppApi.ask(client, 'status');
      expect(TsdmAppApi.knowsDevice, isFalse);
      expect(TsdmAppApi.pluginInfo.value!.device, isNull);

      answers['status'] = _status();
      await TsdmAppApi.ask(client, 'status');
      expect(TsdmAppApi.knowsDevice, isTrue);
      TsdmAppApi.reset();
      expect(TsdmAppApi.knowsDevice, isFalse);
    });

    test('the device_revoked answer is no plugin info (its device is the id)', () {
      expect(TsdmAppPluginInfo.fromAnswer(_json('device_v20_revoked.json')), isNull);
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': '3.6.0', 'device': _thisId})!.device, isNull);
    });
  });

  group('B. the header', () {
    test('only to the forum, only once status named it, only with an id; a header set by the caller stays', () async {
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : <String, Object?>{'ok': 1}));
      final client = _client(forum);

      await TsdmAppApi.ask(client, 'status');
      expect(_header(forum.requests.last), isNull, reason: 'status not answered yet when it was sent');

      await TsdmAppApi.ask(client, 'notify');
      expect(_header(forum.requests.last), _thisId);

      // A page of the forum, a write of the forum, the alternative host: all of them.
      await client.get('$baseUrl/forum.php?mod=forumdisplay&fid=2&tsdmapp=json&nodoc=1').run();
      expect(_header(forum.requests.last), _thisId);
      await client.postForm('$baseUrl/forum.php?mod=post&action=reply&tid=1', data: {'message': 'x'}).run();
      expect(_header(forum.requests.last), _thisId);
      await client.get('https://$baseHostAlt/forum.php').run();
      expect(_header(forum.requests.last), _thisId);

      // Anywhere else: never.
      await client.get('https://example.com/image.png').run();
      expect(_header(forum.requests.last), isNull);

      // Set by the caller: kept.
      await client.get('$baseUrl/forum.php', options: Options(headers: {LoginDeviceIdentity.header: _otherId})).run();
      expect(_header(forum.requests.last), _otherId);

      // No id (an isolate that never loaded it): nothing.
      LoginDeviceIdentity.id = null;
      await TsdmAppApi.ask(client, 'notify');
      expect(_header(forum.requests.last), isNull);

      // The forum switched it off.
      LoginDeviceIdentity.id = _thisId;
      final off = _Forum((o) => _ok(_status(device: 0)));
      await TsdmAppApi.ask(_client(off), 'status');
      await TsdmAppApi.ask(_client(off), 'status');
      expect(_header(off.requests.last), isNull);
    });
  });

  group('C. device_revoked', () {
    test('of a JSON object or text, nothing else', () {
      final revoked = _json('device_v20_revoked.json');
      expect(loginDeviceRevokedOf(revoked), (uid: 31, device: _otherId));
      expect(loginDeviceRevokedOf(jsonEncode(revoked)), (uid: 31, device: _otherId));
      expect(loginDeviceRevokedOf('  ${jsonEncode(revoked)}'), (uid: 31, device: _otherId));
      expect(loginDeviceRevokedOf({'ok': 0, 'error': 'login'}), isNull);
      expect(loginDeviceRevokedOf(_json('device_v20_list.json')), isNull);
      expect(loginDeviceRevokedOf('<p>"device_revoked"</p>'), isNull, reason: 'a page that names it');
      expect(loginDeviceRevokedOf('{"device_revoked": broken'), isNull);
      expect(loginDeviceRevokedOf(null), isNull);
      expect(loginDeviceRevokedOf(Uint8List(3)), isNull);
    });

    test('fails the request; every answer naming an account is told, the coordinator decides', () async {
      final told = <(int, String)>[];
      LoginDeviceIdentity.onRevoked = (uid, device) => told.add((uid, device));
      LoginDeviceIdentity.id = _otherId;
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : _json('device_v20_revoked.json')));
      final client = _client(forum);
      await TsdmAppApi.ask(client, 'status');

      // A page in the JSON mode: the answer is no page, the request failed with the reason.
      final page = await client.get('$baseUrl/forum.php?mod=forumdisplay&fid=2&tsdmapp=json&nodoc=1').run();
      expect(page.getLeft().toNullable(), isA<LoginDeviceRevokedException>().having((e) => e.uid, 'uid', 31));
      expect(told, [(31, _otherId)]);

      // The API: no answer.
      expect(await TsdmAppApi.ask(client, 'notify'), isNull);
      expect(await TsdmAppApi.post(client, 'seen', {'formhash': 'f1f2f3f4'}), isNull);
      expect(told, hasLength(3));

      // An answer naming no account fails without being told.
      final nobody = _Forum(
        (o) => _ok(_action(o) == 'status' ? _status() : {..._json('device_v20_revoked.json'), 'uid': 0}),
      );
      expect(await TsdmAppApi.ask(_client(nobody), 'notify'), isNull);
      expect(told, hasLength(3));
    });
  });

  group('D. the repository', () {
    test('the list: every device, this one marked, the logged out ones too', () async {
      final forum = _Forum((o) => _ok(_json('device_v20_list.json')));
      final result = await LoginDeviceRepository(buildClient: (_) => _client(forum)).list(31);
      final list = (result as LoginDeviceDone<LoginDeviceList>).value;
      expect(list.uid, 31);
      expect(list.formHash, 'f1f2f3f4');
      expect(list.devices.map((e) => e.id), [_otherId, _thisId]);
      final other = list.devices.first;
      expect(other.platform, 'windows');
      expect(other.appVersion, '1.52.1+164');
      expect(other.name, 'Work PC');
      expect(other.revoked, isTrue);
      expect(other.current, isFalse);
      expect(other.lastSeen, DateTime.fromMillisecondsSinceEpoch(1700000053 * 1000));
      final mine = list.devices.last;
      expect(mine.current, isTrue);
      expect(mine.revoked, isFalse);
      expect(mine.name, 'Pixel 7');
    });

    test('unsupported: supported 0, an older plugin; failed: login, no JSON', () async {
      Future<LoginDeviceResult<LoginDeviceList>> listOf(Object body) =>
          LoginDeviceRepository(buildClient: (_) => _client(_Forum((_) => _ok(body)))).list(31);
      expect(
        await listOf({'ok': 1, 'uid': 31, 'type': 'devices', 'schema': 20, 'supported': 0}),
        isA<LoginDeviceUnsupported<LoginDeviceList>>(),
      );
      expect(await listOf({'ok': 0, 'error': 'action'}), isA<LoginDeviceUnsupported<LoginDeviceList>>());
      expect(
        await listOf({'ok': 0, 'error': 'login'}),
        isA<LoginDeviceFailed<LoginDeviceList>>().having((e) => e.error, 'error', 'login'),
      );
    });

    test('register: the form hash of status, the fields; nothing when status does not name it', () async {
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : _json('device_v20_register.json')));
      final repo = LoginDeviceRepository(buildClient: (_) => _client(forum));
      final result = await repo.register(
        31,
        device: _thisId,
        platform: 'android',
        appVersion: '1.52.1+164',
        name: 'Pixel 7',
      );
      expect((result as LoginDeviceDone<LoginDevice>).value.current, isTrue);
      final post = forum.deviceCalls.single;
      expect(post.method, 'POST');
      expect(_form(post), {
        'formhash': 'f1f2f3f4',
        'op': 'register',
        'device': _thisId,
        'platform': 'android',
        'app_version': '1.52.1+164',
        'name': 'Pixel 7',
      });
      expect(_header(post), _thisId);

      // An empty name is left out: the plugin keeps the one it has.
      await repo.register(31, device: _thisId, platform: 'ios', appVersion: '1.52.1+164', name: '');
      expect(_form(forum.deviceCalls.last).containsKey('name'), isFalse);

      // The id replaced while status was asked: nothing sent.
      final before = forum.deviceCalls.length;
      final replaced = await repo.register(
        31,
        device: _thisId,
        platform: 'android',
        appVersion: '1.52.1+164',
        name: '',
        stillCurrent: () => false,
      );
      expect(replaced, isA<LoginDeviceFailed<LoginDevice>>());
      expect(forum.deviceCalls, hasLength(before));

      for (final device in [0, null]) {
        final off = _Forum((o) => _ok(_status(device: device)));
        final r = await LoginDeviceRepository(
          buildClient: (_) => _client(off),
        ).register(31, device: _thisId, platform: 'android', appVersion: '1.52.1+164', name: '');
        expect(r, isA<LoginDeviceUnsupported<LoginDevice>>());
        expect(off.deviceCalls, isEmpty);
      }
    });

    test('revoke and remove; "too soon" waited for once; remove of a device gone is done', () async {
      var busy = 1;
      final forum = _Forum((o) {
        final op = _form(o)['op'];
        if (busy > 0) {
          busy--;
          return (body: {'ok': 0, 'error': 'busy', 'retry_after': 0}, status: 429);
        }
        return _ok(switch (op) {
          'revoke' => _json('device_v20_revoke.json'),
          'remove' => _json('device_v20_remove.json'),
          _ => {'ok': 0, 'error': 'op'},
        });
      });
      final repo = LoginDeviceRepository(buildClient: (_) => _client(forum));

      final revoked = await repo.revoke(31, formHash: 'f1f2f3f4', device: _otherId);
      expect((revoked as LoginDeviceDone<LoginDevice>).value.revoked, isTrue);
      expect(forum.deviceCalls, hasLength(2), reason: 'sent again after the "too soon"');
      expect(_form(forum.deviceCalls.last), {'formhash': 'f1f2f3f4', 'op': 'revoke', 'device': _otherId});

      expect(await repo.remove(31, formHash: 'f1f2f3f4', device: _otherId), isA<LoginDeviceDone<void>>());

      // Busy twice: given up, the plugin's error.
      busy = 2;
      expect(
        await repo.revoke(31, formHash: 'f1f2f3f4', device: _otherId),
        isA<LoginDeviceFailed<LoginDevice>>().having((e) => e.error, 'error', 'busy'),
      );

      final gone = LoginDeviceRepository(
        buildClient: (_) => _client(_Forum((_) => _ok({'ok': 0, 'error': 'nodevice'}))),
      );
      expect(await gone.remove(31, formHash: 'f1f2f3f4', device: _otherId), isA<LoginDeviceDone<void>>());
      expect(
        await LoginDeviceRepository(
          buildClient: (_) => _client(_Forum((_) => _ok({'ok': 0, 'error': 'notrevoked'}))),
        ).remove(31, formHash: 'f1f2f3f4', device: _thisId),
        isA<LoginDeviceFailed<void>>().having((e) => e.error, 'error', 'notrevoked'),
      );
    });
  });

  group('E. the coordinator', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty());
      await settings.init();
    });

    tearDown(() async {
      await settings.dispose();
      await db.close();
    });

    test('the id: made once, kept, renewed', () async {
      LoginDeviceIdentity.id = null;
      await LoginDeviceIdentity.load(storage);
      final made = LoginDeviceIdentity.id!;
      expect(LoginDeviceIdentity.isValid(made), isTrue);
      expect(await storage.getString(LoginDeviceIdentity.storageKey), made);
      LoginDeviceIdentity.id = null;
      await LoginDeviceIdentity.load(storage);
      expect(LoginDeviceIdentity.id, made);
      final next = await LoginDeviceIdentity.renew(storage);
      expect(next, isNot(made));
      expect(await storage.getString(LoginDeviceIdentity.storageKey), next);
    });

    test('a register answered device_revoked: new id, the login dropped once, told, not registered again', () async {
      await storage.saveString(LoginDeviceIdentity.storageKey, _otherId);
      await storage.saveCookie(username: 'alice', uid: 31, cookie: {'${cookiePrefix}_auth': 'a1'});
      expect(await storage.hasCookieOfUid(31), isTrue);

      final forum = _Forum((o) {
        if (_action(o) == 'status') {
          return _ok(_status());
        }
        // The old id is logged out for the account; a new one would be registered.
        return _ok(_header(o) == _otherId ? _json('device_v20_revoked.json') : _json('device_v20_register.json'));
      });
      final coordinator = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(),
        storage: storage,
        repository: LoginDeviceRepository(buildClient: (_) => _client(forum), buildStoredClient: (_) async => null),
        deviceName: () async => 'Work PC',
      );
      addTearDown(coordinator.dispose);
      final told = <LoginDeviceRevocation>[];
      coordinator.revocations.listen(told.add);
      await coordinator.start();
      expect(LoginDeviceIdentity.id, _otherId, reason: 'the stored id');

      await coordinator.register(31);
      await pumpEventQueue();
      final renewed = LoginDeviceIdentity.id;
      expect(renewed, isNot(_otherId));
      expect(LoginDeviceIdentity.isValid(renewed!), isTrue);
      expect(await storage.getString(LoginDeviceIdentity.storageKey), renewed);
      expect(await storage.hasCookieOfUid(31), isFalse, reason: 'the saved login of the account is gone');
      expect(told, [(uid: 31, username: 'alice')]);

      // An answer of a request sent with the old id arrives late: not told again.
      LoginDeviceIdentity.onRevoked!(31, _otherId);
      await pumpEventQueue();
      expect(told, hasLength(1));

      // Not registered again with the new id while it is not logged in again.
      final sent = forum.requests.length;
      await coordinator.register(31);
      expect(forum.requests, hasLength(sent));
    });

    test('two accounts logged out with the same id, one after the other: both dropped, the id renewed once', () async {
      await storage.saveCookie(username: 'alice', uid: 31, cookie: {'${cookiePrefix}_auth': 'a1'});
      await storage.saveCookie(username: 'bob', uid: 35, cookie: {'${cookiePrefix}_auth': 'b1'});
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : _json('device_v20_register.json')));
      final coordinator = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(),
        storage: storage,
        repository: LoginDeviceRepository(buildClient: (_) => _client(forum), buildStoredClient: (_) async => null),
        deviceName: () async => '',
      );
      addTearDown(coordinator.dispose);
      final told = <LoginDeviceRevocation>[];
      coordinator.revocations.listen(told.add);
      await coordinator.start();
      final old = LoginDeviceIdentity.id!;

      LoginDeviceIdentity.onRevoked!(31, old);
      await pumpEventQueue();
      final renewed = LoginDeviceIdentity.id!;
      expect(renewed, isNot(old));
      // The answer for 35 to a request sent with the old id arrives after the renewal.
      LoginDeviceIdentity.onRevoked!(35, old);
      LoginDeviceIdentity.onRevoked!(35, old);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(LoginDeviceIdentity.id, renewed, reason: 'renewed once');
      expect(told, [(uid: 31, username: 'alice'), (uid: 35, username: 'bob')]);
      expect(await storage.hasCookieOfUid(31), isFalse);
      expect(await storage.hasCookieOfUid(35), isFalse);

      // Neither is registered with the new id until it is logged in again; an id this device never had is no answer.
      await coordinator.register(31);
      await coordinator.register(35);
      LoginDeviceIdentity.onRevoked!(40, '11111111-2222-4333-8444-555555555555');
      await pumpEventQueue();
      expect(forum.deviceCalls, isEmpty);
      expect(told, hasLength(2));
    });

    test(
      'the id in use logged out: every other stored account asked once with it, dropped when logged out too',
      () async {
        await storage.saveCookie(username: 'alice', uid: 31, cookie: {'${cookiePrefix}_auth': 'a1'});
        await storage.saveCookie(username: 'bob', uid: 35, cookie: {'${cookiePrefix}_auth': 'b1'});
        await storage.saveCookie(username: 'carol', uid: 40, cookie: {'${cookiePrefix}_auth': 'c1'});
        // The stored clients name their account in a query parameter here; the forum answers by it.
        var busyOnce = true;
        final forum = _Forum((o) {
          final who = o.uri.queryParameters['who'];
          if (who != null && _action(o) == 'status') {
            if (busyOnce) {
              busyOnce = false;
              return (body: {'ok': 0, 'error': 'busy', 'retry_after': 0}, status: 429);
            }
            // Bob was logged out with the old id as well, Carol was not.
            return who == '35'
                ? _ok({..._json('device_v20_revoked.json'), 'uid': 35, 'device': _header(o)})
                : _ok(_status());
          }
          return _ok(_action(o) == 'status' ? _status() : _json('device_v20_register.json'));
        });
        final coordinator = LoginDeviceCoordinator(
          authentication: AuthenticationRepository(user: const UserLoginInfo(username: 'carol', uid: 40)),
          storage: storage,
          repository: LoginDeviceRepository(
            buildClient: (_) => _client(forum),
            buildStoredClient: (user) async => NetClientProvider.buildNoCookie(
              dio: Dio(BaseOptions(baseUrl: baseUrl, queryParameters: {'who': '${user.uid}'}))
                ..httpClientAdapter = forum,
            ),
          ),
          deviceName: () async => '',
        );
        addTearDown(coordinator.dispose);
        final told = <LoginDeviceRevocation>[];
        coordinator.revocations.listen(told.add);
        await coordinator.start();
        final old = LoginDeviceIdentity.id!;

        LoginDeviceIdentity.onRevoked!(31, old);
        for (var i = 0; i < 20 && forum.deviceCalls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final renewed = LoginDeviceIdentity.id!;
        expect(renewed, isNot(old));
        final probes = forum.requests.where((r) => r.uri.queryParameters['who'] != null).toList();
        expect(probes.map(_header).toSet(), {old}, reason: 'asked with the old id');
        expect(probes.map((r) => r.uri.queryParameters['who']).toSet(), {'35', '40'}, reason: 'not the one logged out');
        expect(told, [(uid: 31, username: 'alice'), (uid: 35, username: 'bob')]);
        expect(await storage.hasCookieOfUid(31), isFalse);
        expect(await storage.hasCookieOfUid(35), isFalse);
        expect(await storage.hasCookieOfUid(40), isTrue);
        // The account in use registered with the new id after the check; neither of the others.
        final registers = forum.deviceCalls.map(_form).toList();
        expect(registers, hasLength(1));
        expect(registers.single['device'], renewed);
      },
    );

    test('a login while the other accounts are checked waits for the check', () async {
      await storage.saveCookie(username: 'alice', uid: 31, cookie: {'${cookiePrefix}_auth': 'a1'});
      await storage.saveCookie(username: 'bob', uid: 35, cookie: {'${cookiePrefix}_auth': 'b1'});
      final answer = Completer<void>();
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : _json('device_v20_register.json')));
      final auth = AuthenticationRepository(user: const UserLoginInfo(username: 'bob', uid: 35));
      final coordinator = LoginDeviceCoordinator(
        authentication: auth,
        storage: storage,
        repository: LoginDeviceRepository(
          buildClient: (_) => _client(forum),
          // Bob's check answers late: logged out with the old id too.
          buildStoredClient: (user) async {
            await answer.future;
            return _client(
              _Forum((o) => _ok({..._json('device_v20_revoked.json'), 'uid': user.uid, 'device': _header(o)})),
            );
          },
        ),
        deviceName: () async => '',
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      final old = LoginDeviceIdentity.id!;

      LoginDeviceIdentity.onRevoked!(31, old);
      await pumpEventQueue();
      // The homepage tells Bob authenticated meanwhile.
      final waiting = coordinator.register(35);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forum.requests, isEmpty, reason: 'nothing before the check is done');
      answer.complete();
      await waiting;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forum.deviceCalls, isEmpty, reason: 'Bob was logged out with the old id: never registered');
      expect(await storage.hasCookieOfUid(35), isFalse);
    });

    test('a check that throws leaves the next registers working', () async {
      await storage.saveCookie(username: 'alice', uid: 31, cookie: {'${cookiePrefix}_auth': 'a1'});
      await storage.saveCookie(username: 'bob', uid: 35, cookie: {'${cookiePrefix}_auth': 'b1'});
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : _json('device_v20_register.json')));
      final coordinator = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(user: const UserLoginInfo(username: 'bob', uid: 35)),
        storage: storage,
        repository: LoginDeviceRepository(
          buildClient: (_) => _client(forum),
          buildStoredClient: (_) async => throw StateError('no database'),
        ),
        deviceName: () async => '',
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      LoginDeviceIdentity.onRevoked!(31, LoginDeviceIdentity.id!);
      for (var i = 0; i < 20 && forum.deviceCalls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(forum.deviceCalls, hasLength(1), reason: 'the account in use registered after the check');
      await coordinator.register(40);
      expect(forum.deviceCalls, hasLength(2));
    });

    test('another stored account logged out: the account in use registered with the new id, that one not', () async {
      await storage.saveCookie(username: 'alice', uid: 31, cookie: {'${cookiePrefix}_auth': 'a1'});
      final forum = _Forum((o) => _ok(_action(o) == 'status' ? _status() : _json('device_v20_register.json')));
      final coordinator = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(user: const UserLoginInfo(username: 'bob', uid: 35)),
        storage: storage,
        repository: LoginDeviceRepository(buildClient: (uid) => _client(forum)),
        deviceName: () async => '',
      );
      addTearDown(coordinator.dispose);
      final told = <LoginDeviceRevocation>[];
      coordinator.revocations.listen(told.add);
      await coordinator.start();
      final old = LoginDeviceIdentity.id!;

      // The poll of every account got `device_revoked` for 31.
      LoginDeviceIdentity.onRevoked!(31, old);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final renewed = LoginDeviceIdentity.id!;
      expect(renewed, isNot(old));
      expect(told, [(uid: 31, username: 'alice')]);
      expect(await storage.hasCookieOfUid(31), isFalse);
      final registers = forum.deviceCalls.map(_form).toList();
      expect(registers, hasLength(1));
      expect(registers.single['device'], renewed);
    });

    test('the homepage telling the account again asks a forum without devices once', () async {
      final forum = _Forum((o) => _ok(_status(device: 0)));
      final auth = AuthenticationRepository();
      final coordinator = LoginDeviceCoordinator(
        authentication: auth,
        storage: storage,
        repository: LoginDeviceRepository(buildClient: (_) => _client(forum), buildStoredClient: (_) async => null),
        deviceName: () async => '',
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      for (var i = 0; i < 3; i++) {
        await auth.loginWithServedUser(const UserLoginInfo(username: 'alice', uid: 31), guest: false).run();
        await pumpEventQueue();
      }
      expect(forum.requests.where((r) => _action(r) == 'status'), hasLength(1));
      expect(forum.deviceCalls, isEmpty);
    });

    test('registered once per run and id; a failed request is asked again, a refusal not', () async {
      var fail = true;
      final forum = _Forum(
        (o) => _action(o) == 'status'
            ? _ok(_status())
            : (fail ? (body: '<html>Bad Gateway</html>', status: 502) : _ok(_json('device_v20_register.json'))),
      );
      final coordinator = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(),
        storage: storage,
        repository: LoginDeviceRepository(buildClient: (_) => _client(forum), buildStoredClient: (_) async => null),
        deviceName: () async => '',
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      await coordinator.register(31);
      fail = false;
      await coordinator.register(31);
      await coordinator.register(31);
      expect(forum.deviceCalls, hasLength(2));
      expect(_form(forum.deviceCalls.last)['platform'], loginDevicePlatform);

      final refusing = _Forum((o) => _ok(_action(o) == 'status' ? _status() : {'ok': 0, 'error': 'limit', 'max': 50}));
      final other = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(),
        storage: storage,
        repository: LoginDeviceRepository(buildClient: (_) => _client(refusing)),
        deviceName: () async => '',
      );
      addTearDown(other.dispose);
      await other.register(35);
      await other.register(35);
      expect(refusing.deviceCalls, hasLength(1));
    });
  });

  group('F. the backup', () {
    test('an export carries no id; an import keeps the one in use', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db
        ..execute('CREATE TABLE settings (name TEXT PRIMARY KEY, int_value INTEGER, string_value TEXT)')
        ..execute("INSERT INTO settings (name, string_value) VALUES ('${LoginDeviceIdentity.storageKey}', ?)", [
          _otherId,
        ])
        ..execute("INSERT INTO settings (name, string_value) VALUES ('dioUserAgent', 'ua')");
      BackupRepository.stripCredentials(db);
      expect(db.select('SELECT name FROM settings').map((r) => r['name']), ['dioUserAgent']);
      expect(BackupRepository.readCredentials(db).loginSettings, isEmpty);

      BackupRepository.keepDeviceSettings(db, deviceId: _thisId);
      expect(
        db.select('SELECT string_value FROM settings WHERE name = ?', [
          LoginDeviceIdentity.storageKey,
        ]).single['string_value'],
        _thisId,
      );
      BackupRepository.keepDeviceSettings(db, deviceId: null);
      expect(db.select('SELECT name FROM settings'), hasLength(2));
    });
  });

  group('G. the pages', () {
    testWidgets('the devices: this one marked, another logged out after the question, one logged out removed', (
      tester,
    ) async {
      final list = _json('device_v20_list.json');
      final third = {
        ...(list['devices'] as List).first as Map<String, dynamic>,
        'device': '5a6b7c8d-1e2f-4a3b-8c4d-5e6f7a8b9c03',
        'platform': 'macos',
        'name': '',
        'revoked': 0,
        'revoked_at': 0,
        'notified': 0,
      };
      list['devices'] = [third, ...list['devices'] as List];
      final forum = _Forum((o) {
        if (o.method == 'GET') {
          return _ok(list);
        }
        return _ok(switch (_form(o)['op']) {
          'revoke' => {
            ..._json('device_v20_revoke.json'),
            'device': {...third, 'revoked': 1, 'revoked_at': 1700000100},
          },
          'remove' => _json('device_v20_remove.json'),
          _ => {'ok': 0, 'error': 'op'},
        });
      });
      final repository = LoginDeviceRepository(buildClient: (_) => _client(forum));
      final coordinator = LoginDeviceCoordinator(
        authentication: AuthenticationRepository(),
        storage: StorageProvider(AppDatabase(NativeDatabase.memory()), {}, {}),
        repository: repository,
      );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(
              value: AuthenticationRepository(user: const UserLoginInfo(username: 'alice', uid: 31)),
            ),
            RepositoryProvider<LoginDeviceCoordinator>.value(value: coordinator),
          ],
          child: TranslationProvider(child: const MaterialApp(home: LoginDevicesPage())),
        ),
      );
      await _settle(tester);
      final t = tr.loginDevicesPage;

      // This one first, marked, nothing to do; the other active one with "log out"; the logged out one apart.
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles, hasLength(3));
      expect(find.text('Pixel 7'), findsOneWidget);
      expect(find.text(t.current), findsOneWidget);
      expect(
        find.descendant(of: find.byType(ListTile).first, matching: find.text(t.current)),
        findsOneWidget,
        reason: 'this device first',
      );
      expect(find.text('macOS'), findsOneWidget, reason: 'no name: the platform');
      expect(find.text(t.loggedOut), findsOneWidget);
      expect(find.text(t.logOut), findsOneWidget);
      expect(find.text(t.remove), findsOneWidget);
      expect(find.textContaining('Windows · 1.52.1+164'), findsOneWidget);

      // Log out the other one: asked first; cancelled sends nothing.
      await tester.tap(find.text(t.logOut));
      await tester.pumpAndSettle();
      expect(find.text(t.logOutTitle), findsOneWidget);
      await tester.tap(find.text(tr.general.cancel));
      await tester.pumpAndSettle();
      expect(forum.requests.where((r) => r.method == 'POST'), isEmpty);
      await tester.tap(find.text(t.logOut));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.general.ok));
      await _settle(tester);
      expect(_form(forum.requests.last), containsPair('op', 'revoke'));
      expect(find.text(t.logOut), findsNothing);
      expect(find.text(t.remove), findsNWidgets(2), reason: 'it moved to the logged out ones');

      // Remove the first logged out one: off the list.
      await tester.tap(find.text(t.remove).last);
      await _settle(tester);
      expect(_form(forum.requests.last), containsPair('op', 'remove'));
      expect(find.text('Work PC'), findsNothing);
      expect(find.byType(ListTile), findsNWidgets(2));
    });

    test('a failed write, or reading again, tells it and keeps the list', () async {
      final forum = _Forum(
        (o) => o.method == 'GET' ? _ok(_json('device_v20_list.json')) : _ok({'ok': 0, 'error': 'nodevice'}),
      );
      final cubit = LoginDevicesCubit(
        repository: LoginDeviceRepository(buildClient: (_) => _client(forum), buildStoredClient: (_) async => null),
        uid: 31,
      );
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.status, LoginDevicesStatus.ready);
      expect(cubit.state.devices.first.current, isTrue, reason: 'this one first');
      final other = cubit.state.devices.last;
      // A revoke answered `nodevice`: removed meanwhile, off the list.
      await cubit.revoke(other);
      expect(cubit.state.devices, hasLength(1));
      // A remove the forum refuses otherwise: the list as before, a hint.
      final refusing = LoginDevicesCubit(
        repository: LoginDeviceRepository(
          buildClient: (_) => _client(
            _Forum(
              (o) => o.method == 'GET' ? _ok(_json('device_v20_list.json')) : _ok({'ok': 0, 'error': 'notrevoked'}),
            ),
          ),
        ),
        uid: 31,
      );
      addTearDown(refusing.close);
      await refusing.load();
      await refusing.remove(refusing.state.devices.last);
      expect(refusing.state.devices, hasLength(2));
      expect(refusing.state.writeSeq, 1);

      // Read again and failed: the list stays, with a hint.
      var down = false;
      final flaky = LoginDevicesCubit(
        repository: LoginDeviceRepository(
          buildClient: (_) => _client(
            _Forum((o) => _ok(down ? {'ok': 0, 'error': 'login'} : _json('device_v20_list.json'))),
          ),
        ),
        uid: 31,
      );
      addTearDown(flaky.close);
      await flaky.load();
      down = true;
      final states = <LoginDevicesStatus>[];
      final sub = flaky.stream.listen((e) => states.add(e.status));
      await flaky.load();
      await sub.cancel();
      expect(states, isNot(contains(LoginDevicesStatus.loading)));
      expect(flaky.state.status, LoginDevicesStatus.ready);
      expect(flaky.state.devices, hasLength(2));
      expect(flaky.state.writeSeq, 1);
    });
  });

  group('H. the settings entry', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum((_) => _ok('')))),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await settings.dispose();
      await db.close();
    });

    testWidgets('only once status named it, for an account in use', (tester) async {
      tester.view
        ..physicalSize = const Size(384, 792)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = ThemeCubit();
      addTearDown(theme.close);
      Future<void> pump(AuthenticationRepository auth) async {
        await tester.pumpWidget(
          RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<ThemeCubit>.value(value: theme),
              ],
              child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
            ),
          ),
        );
        await _settle(tester);
      }

      final entry = find.byKey(const ValueKey('settings-login-devices'));
      await pump(AuthenticationRepository(user: const UserLoginInfo(username: 'alice', uid: 31)));
      expect(entry, findsNothing, reason: 'nothing told yet');

      TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo.fromAnswer(_status(device: null, version: '3.5.0'));
      await tester.pumpAndSettle();
      expect(entry, findsNothing, reason: 'an older plugin');

      TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo.fromAnswer(_status(device: 0));
      await tester.pumpAndSettle();
      expect(entry, findsNothing, reason: 'switched off on the forum');

      TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo.fromAnswer(_status());
      await tester.pumpAndSettle();
      expect(entry, findsOneWidget);
      expect(
        find.descendant(of: entry, matching: find.text(tr.settingsPage.accountSection.loginDevices)),
        findsOneWidget,
      );

      // No account in use: nothing to list.
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(AuthenticationRepository());
      expect(entry, findsNothing);
    });
  });
}
