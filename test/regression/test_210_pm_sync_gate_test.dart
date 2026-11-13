import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// GitHub #193: a private conversation never showed in the app's list.
///
/// Before polling the pages, the app asks the forum's app API (`notify`) whether anything arrived. Its `pms` lists the
/// unread received conversations only, so a conversation the user wrote to last (or read on the web) never made a
/// poll fetch the private message page, and it never reached the stored list. Now:
///
/// * Plugin 1.8.0 answers `pm_last`, the latest change of any conversation (forum clock): newer than the poll's
///   `since`, the pages are fetched. An older plugin leaves it out and the gate decides as before.
/// * A refresh the user asks for on the notification page skips the API and keeps every conversation of the page.
/// * A private message sent in the app refreshes the list once, the same way.
///
/// Review of the fix:
///
/// * (e) A conversation deleted in the app (local only) came back on every refresh that bypassed the gate.
/// * (f) Without a stored fetch time, the first refresh announced old conversations the peer wrote last as news.
/// * (g) With a stored bound days ahead of the clock, no new conversation was ever announced by such a refresh.
/// * (h) The refresh after sending ran for the account switched to meanwhile.
///
/// Synthetic pages and names, no real account or forum.
const _alice = UserLoginInfo(username: 'Alice', uid: 3000);
const _bob = UserLoginInfo(username: 'Bob', uid: 3002);
const _peer = 3001;

/// The current account can change in the middle of a test.
final class _SwitchableAuth extends Fake implements AuthenticationRepository {
  _SwitchableAuth(this.currentUser);

  @override
  UserLoginInfo? currentUser;
}

Map<String, String> _jar(String token) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=$token; Path=/;_crt=1"}}',
};

/// The forum clock: now, since the repository clamps `since` to three days ago.
int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A `notify` answer with nothing unread, without the lists of 1.9.0; [pmLast] as plugin 1.8.0 adds it. Named 3.5.0:
/// an older plugin's answer is not used.
Map<String, Object?> _notify({int? pmLast}) => {
  'ok': 1,
  'api': 1,
  'version': '3.5.0',
  'time': _now,
  'uid': _alice.uid,
  'counts': {'notice': 0, 'pm': 0, 'announce': 0},
  'notices': <Object?>[],
  'pms': <Object?>[],
  'announces': <Object?>[],
  'pm_last': ?pmLast,
};

String _timeTextOf(DateTime t) =>
    '${t.year}-${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The private message page holding one conversation whose last message Alice sent at [at].
String _sentPmPage(DateTime at, String text) =>
    '<html><body><div id="um"></div><form id="deletepmform"><div>\n'
    '<dl id="pmlist_$_peer" class="cl">\n'
    '<dd class="m avt"><a href="home.php?mod=space&amp;uid=$_peer"><img src="a.jpg"></a></dd> '
    '<dd class="ptm pm_c"><div class="o"></div><span class="xi2 xw1">您</span> 对 '
    '<a href="home.php?mod=space&uid=$_peer" class="xw1">Peer</a> 说 :<br />$text &nbsp; <br /> '
    '<span class="xg1"><span title="${_timeTextOf(at)}">1 小时前</span></span></dd>\n'
    '</dl></div></form></body></html>';

/// The private message page holding one unread conversation whose last message the peer sent at [at].
String _receivedPmPage(DateTime at, String text) =>
    '<html><body><div id="um"></div><form id="deletepmform"><div>\n'
    '<dl id="pmlist_$_peer" class="cl newpm">\n'
    '<dd class="m avt"><a href="home.php?mod=space&amp;uid=$_peer"><img src="a.jpg"></a><div class="newpm_avt"></div></dd> '
    '<dd class="ptm pm_c"><div class="o"></div><a href="home.php?mod=space&uid=$_peer" class="xw1">Peer</a> 对 '
    '<span class="xi2">您</span> 说 :<br />$text &nbsp; <br /> '
    '<span class="xg1"><span title="${_timeTextOf(at)}">1 小时前</span></span></dd>\n'
    '</dl></div></form></body></html>';

const _emptyPage = '<html><body><div id="um"></div><div class="nts"></div></body></html>';

const _sendSucceeded =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[succeedhandle_pmsend(\'\', \'\');]]></root>';

/// Answers the app API from [api] (given the `since` it was asked), the private message page from [pmPage], the other
/// two pages with nothing and a send with the forum's success marker; records every request.
final class _Forum implements HttpClientAdapter {
  _Forum({required this.api});

  Map<String, Object?> Function(int since) api;
  String pmPage = _emptyPage;
  final requests = <RequestOptions>[];

  Iterable<RequestOptions> get apiRequests => requests.where((e) => e.uri.queryParameters['id'] == 'tsdmapp:api');

  Iterable<RequestOptions> get pmPageRequests => requests.where((e) => e.uri.queryParameters['filter'] == 'privatepm');

  Iterable<RequestOptions> get sends => requests.where((e) => e.method == 'POST');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    final q = options.uri.queryParameters;
    final (body, type) = switch (q) {
      {'id': 'tsdmapp:api', 'since': final since} => (jsonEncode(api(int.parse(since))), 'application/json'),
      {'op': 'send'} when options.method == 'POST' => (_sendSucceeded, 'text/xml'),
      {'filter': 'privatepm'} => (pmPage, 'text/html'),
      {'do': 'notice'} || {'filter': 'announcepm'} => (_emptyPage, 'text/html'),
      _ => fail('unexpected request: ${options.method} ${options.uri}'),
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['$type; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('(a) the gate reads pm_last', () {
    final since = _now - 600;
    test('a conversation changed after since: fetch the pages', () {
      expect(notifyGateOf(_notify(pmLast: since + 1), since: since), isA<TsdmAppFetchPages>());
      expect(notifyGateOf(_notify(pmLast: _now), since: since), isA<TsdmAppFetchPages>());
    });

    test('changed at or before since, or never: nothing new', () {
      expect(notifyGateOf(_notify(pmLast: since), since: since), isA<TsdmAppNothingNew>());
      expect(notifyGateOf(_notify(pmLast: since - 3600), since: since), isA<TsdmAppNothingNew>());
      expect(notifyGateOf(_notify(pmLast: 0), since: since), isA<TsdmAppNothingNew>());
    });

    test('an older plugin without pm_last decides as before', () {
      final gate = notifyGateOf(_notify(), since: since);
      expect(gate, isA<TsdmAppNothingNew>());
      expect((gate as TsdmAppNothingNew).serverTime.millisecondsSinceEpoch ~/ 1000, closeTo(_now, 2));
      expect(
        notifyGateOf(
          _notify()
            ..['pms'] = [
              {'plid': 1, 'lastdateline': since + 5},
            ],
          since: since,
        ),
        isA<TsdmAppFetchPages>(),
      );
      // Not a number: not understood, ignored.
      expect(notifyGateOf(_notify()..['pm_last'] = 'x', since: since), isA<TsdmAppNothingNew>());
    });

    test('compared with the since the poll asked, after the three day clamp', () async {
      TsdmAppApi.reset();
      getIt
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      addTearDown(getIt.reset);
      // Last fetch five days ago: the window is clamped to three days, and that is the since the API is asked.
      final fiveDaysAgo = _now - 5 * 24 * 3600;
      final skipped = _Forum(api: (since) => _notify(pmLast: since));
      await NotificationRepository().fetchNotificationWith(_client(skipped), timestamp: fiveDaysAgo).run();
      final asked = int.parse(skipped.apiRequests.single.uri.queryParameters['since']!);
      expect(asked, closeTo(_now - 3 * 24 * 3600, 5), reason: 'the clamped window');
      expect(skipped.pmPageRequests, isEmpty, reason: 'pm_last equal to since is not new');

      // A change four days ago is before the window as well.
      final older = _Forum(api: (since) => _notify(pmLast: _now - 4 * 24 * 3600));
      await NotificationRepository().fetchNotificationWith(_client(older), timestamp: fiveDaysAgo).run();
      expect(older.pmPageRequests, isEmpty);

      final fetched = _Forum(api: (since) => _notify(pmLast: since + 1));
      final result = await NotificationRepository()
          .fetchNotificationWith(_client(fetched), timestamp: fiveDaysAgo)
          .run();
      expect(result.isRight(), isTrue);
      expect(fetched.pmPageRequests, hasLength(1), reason: 'a conversation changed inside the window');
    });
  });

  group('the stored conversation list', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _Forum forum;
    late _SwitchableAuth auth;
    late NotificationInfoRepository infoRepository;
    late List<NotificationAutoSyncInfo> announced;
    late bool switching;
    late NotificationBloc bloc;

    /// Ten minutes ago: the bound a poll stored a moment ago.
    final bound = DateTime.now().subtract(const Duration(minutes: 10));

    setUp(() async {
      TsdmAppApi.reset();
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      forum = _Forum(api: (_) => _notify());
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        )
        ..registerSingleton<CookieProvider>(CookieProvider(_alice, _jar('alice')));
      await settings.init();
      await storage.saveCookie(username: _alice.username!, uid: _alice.uid!, cookie: _jar('alice'));
      await storage.updateLastFetchNoticeTime(_alice.uid!, bound).run();
      auth = _SwitchableAuth(_alice);
      // What the auto sync would show as a system notification ("N 则新私信"), whatever the test platform.
      infoRepository = NotificationInfoRepository(localNotifications: true);
      announced = [];
      final announcements = infoRepository.autoSyncStatus.listen(announced.add);
      addTearDown(announcements.cancel);
      switching = false;
      bloc = NotificationBloc(
        notificationRepository: NotificationRepository(storageProvider: storage),
        infoRepository: infoRepository,
        authRepo: auth,
        storageProvider: storage,
        sentRefreshDelay: const Duration(milliseconds: 300),
        switchingAccount: () => switching,
      );
    });

    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<List<PersonalMessageEntity>> stored({int? uid}) async =>
        (await storage.fetchNotificationSince(uid: uid ?? _alice.uid!, timestamp: 0).run()).personalMessageList;

    const form = {'formhash': 'XXXXXXXX', 'message': 'hi', 'pmsubmit': 'true'};

    /// Send a private message as the account of the global cookie (Alice) to another peer.
    Future<void> send() async =>
        expect((await const ReplyRepository().replyPersonalMessage('4000', form).run()).isRight(), isTrue);

    Future<void> sync(NotificationUpdateAllRequested event) async {
      final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
      bloc.add(event);
      await done.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
    }

    test('(d) an automatic sync with nothing new and no pm_last still skips the pages', () async {
      forum.pmPage = _sentPmPage(DateTime.now(), 'sent on the web');
      await sync(const NotificationUpdateAllRequested());
      expect(forum.apiRequests, hasLength(1));
      expect(forum.pmPageRequests, isEmpty);
      expect(await stored(), isEmpty);
    });

    test('an automatic sync fetches the conversation pm_last tells about (plugin 1.8.0)', () async {
      final at = DateTime.now();
      forum
        ..pmPage = _sentPmPage(at, 'sent on the web')
        ..api = (_) => _notify(pmLast: _now);
      await sync(const NotificationUpdateAllRequested());
      expect(forum.pmPageRequests, hasLength(1));
      expect((await stored()).map((e) => (e.peerUid, e.sender, e.data)), [(_peer, true, 'sent on the web')]);
    });

    test('(b) a refresh on the notification page fetches the pages although notify tells nothing new', () async {
      // Alice wrote to the peer an hour ago, before the stored bound: the polls since then skipped the pages.
      forum.pmPage = _sentPmPage(DateTime.now().subtract(const Duration(hours: 1)), 'hello');
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      // Asked since the lists of plugin 1.9.0 (test 211); the answer of an older plugin gates no refresh.
      expect(forum.apiRequests, hasLength(1), reason: 'asked, its "nothing new" ignored');
      expect(forum.pmPageRequests, hasLength(1));
      final rows = await stored();
      expect(rows.map((e) => (e.peerUid, e.sender, e.alreadyRead)), [(_peer, true, true)]);
      expect(bloc.state.personalMessageList.map((e) => e.peerUid), [_peer], reason: 'listed on the page');
    });

    test('(c) sending a private message refreshes the list once, bypassing the gate', () async {
      forum.pmPage = _sentPmPage(DateTime.now(), 'just sent');
      final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
      // Two messages in a row: one refresh.
      expect((await const ReplyRepository().replyPersonalMessage('$_peer', form).run()).isRight(), isTrue);
      expect((await const ReplyRepository().replyPersonalMessage('$_peer', form).run()).isRight(), isTrue);
      await done.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(forum.sends, hasLength(2));
      expect(forum.apiRequests, hasLength(1), reason: 'the refresh is not gated by the answer of an older plugin');
      expect(forum.pmPageRequests, hasLength(1), reason: 'once for the two messages');
      expect((await stored()).map((e) => (e.peerUid, e.sender, e.data)), [(_peer, true, 'just sent')]);
    });

    test('(e) a conversation deleted in the app stays deleted on refresh and after sending', () async {
      final at = DateTime.now().subtract(const Duration(hours: 1));
      forum.pmPage = _receivedPmPage(at, 'old');
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      expect((await stored()).map((e) => (e.peerUid, e.alreadyRead)), [(_peer, false)]);

      bloc.add(const NotificationDeletePersonalMessageRequested(uid: 3000, peerUid: _peer));
      for (var i = 0; i < 50 && (await stored()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await stored(), isEmpty);

      // The forum still lists it: the delete is local only.
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      expect(forum.pmPageRequests, hasLength(2));
      expect(await stored(), isEmpty, reason: 'not stored again by the pull-to-refresh');
      expect(bloc.state.personalMessageList, isEmpty, reason: 'not listed');
      expect((await countUnreadNotification(storage: storage, uid: _alice.uid!)).personalMessage, 0);

      // A message sent to someone else refreshes the same page once more.
      final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
      await send();
      await done.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(forum.pmPageRequests, hasLength(3));
      expect(await stored(), isEmpty, reason: 'not stored again after sending');
      expect(announced, isEmpty, reason: 'never announced again');

      // A newer message of the peer brings it back, as news.
      forum.pmPage = _receivedPmPage(DateTime.now(), 'new');
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      expect((await stored()).map((e) => (e.peerUid, e.data, e.alreadyRead)), [(_peer, 'new', false)]);
      expect(announced.map((e) => e.personalMessage), [1]);
    });

    test('(e) the deletion survives a new bloc, and an unchanged copy from the automatic sync', () async {
      final at = DateTime.now().subtract(const Duration(minutes: 5));
      forum
        ..pmPage = _receivedPmPage(at, 'hello')
        ..api = (_) => _notify(pmLast: _now);
      await sync(const NotificationUpdateAllRequested());
      expect(await stored(), hasLength(1));
      bloc.add(const NotificationDeletePersonalMessageRequested(uid: 3000, peerUid: _peer));
      for (var i = 0; i < 50 && (await stored()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await stored(), isEmpty);
      await bloc.close();
      bloc = NotificationBloc(
        notificationRepository: NotificationRepository(storageProvider: storage),
        infoRepository: infoRepository,
        authRepo: auth,
        storageProvider: storage,
      );
      // The poll inside the window gets the same copy again.
      await sync(const NotificationUpdateAllRequested());
      expect(await stored(), isEmpty);
      expect(announced.map((e) => e.personalMessage), [1], reason: 'announced once, before the delete');
    });

    test('(f) without a stored fetch time, old conversations are listed but not announced', () async {
      // Bob has no fetch time stored on this device yet.
      auth.currentUser = _bob;
      forum.pmPage = _receivedPmPage(DateTime.now().subtract(const Duration(days: 5)), 'long ago');
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      expect((await stored(uid: _bob.uid)).map((e) => e.peerUid), [_peer], reason: 'stored and listed');
      expect(bloc.state.personalMessageList.map((e) => e.peerUid), [_peer]);
      expect(announced, isEmpty, reason: 'older than the three days fetched: no news');

      // A message from inside the three days is news on that first fetch, as for the automatic sync.
      await storage.deletePersonalMessage(uid: _bob.uid!, peerUid: _peer).run();
      forum.pmPage = _receivedPmPage(DateTime.now().subtract(const Duration(hours: 2)), 'recent');
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      expect(announced.map((e) => e.personalMessage), [1]);
    });

    test('(g) a stored bound days ahead of the clock does not hide new conversations', () async {
      // The device clock was fast (GitHub #71): the stored bound lies two days ahead.
      await storage.updateLastFetchNoticeTime(_alice.uid!, DateTime.now().add(const Duration(days: 2))).run();
      forum.pmPage = _receivedPmPage(DateTime.now(), 'right now');
      await sync(const NotificationUpdateAllRequested(bypassGate: true));
      expect((await stored()).map((e) => e.data), ['right now']);
      expect(announced.map((e) => e.personalMessage), [1], reason: 'announced with the clamped window');
    });

    test('(h) the refresh after sending is skipped once another account is current', () async {
      forum.pmPage = _receivedPmPage(DateTime.now(), 'for Bob');
      await send();
      // Alice switches to Bob before the refresh runs.
      auth.currentUser = _bob;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(forum.pmPageRequests, isEmpty, reason: 'nothing fetched for Bob');
      expect(await stored(uid: _bob.uid), isEmpty);
    });

    test('(h) the refresh after sending is skipped while an account switch runs', () async {
      forum.pmPage = _receivedPmPage(DateTime.now(), 'during the switch');
      await send();
      switching = true;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(forum.pmPageRequests, isEmpty);

      // Still Alice and no switch: the refresh runs for her.
      switching = false;
      final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
      await send();
      await done.timeout(const Duration(seconds: 5));
      expect(forum.pmPageRequests, hasLength(1));
    });
  });
}
