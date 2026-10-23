/// The daily login visit and the automatic daily red packet run after the homepage showed (cold start, UX audit item
/// 5): the page used to wait for the visit, the claim and a reload of the page (three more requests) before anything
/// showed.
///
/// 1. the page is answered as soon as it is fetched, the rewards follow in the background;
/// 2. the page asked once more after them replaces the cached page and the page the homepage shows (the claimed packet
///    gone), and only that page: a page the homepage does not show, or of another account, changes nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
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
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';

/// A fixture answer, its member renamed ([_neutral]).
Map<String, dynamic> _json(String name) =>
    _neutral(jsonDecode(File('test/data/tsdmapp/$name').readAsStringSync()))! as Map<String, dynamic>;

/// The member the fixtures were recorded as (read from them, never named here), renamed by [_neutral]: the tests
/// speak of a neutral account.
final _fixtureMember =
    (jsonDecode(File('test/data/tsdmapp/index_v5_member.json').readAsStringSync()) as Map<String, dynamic>)['user']
        as Map<String, dynamic>;
final _fixtureUid = _fixtureMember['uid'] as int;
final _fixtureName = _fixtureMember['username'] as String;

/// [value] with the member of the fixtures replaced by Alice (uid 4242).
Object? _neutral(Object? value) => switch (value) {
  final Map<String, dynamic> m => {
    for (final MapEntry(:key, value: v) in m.entries)
      key: (key == 'uid' || key == 'authorid') && '$v' == '$_fixtureUid' ? (v is String ? '4242' : 4242) : _neutral(v),
  },
  final List<dynamic> l => [for (final e in l) _neutral(e)],
  final String s => s.replaceAll(_fixtureName, 'alice').replaceAll(RegExp('uid=$_fixtureUid\\b'), 'uid=4242'),
  _ => value,
};

const _alice = UserLoginInfo(uid: 4242, username: 'alice');
const _checknewpm = 'home.php?mod=spacecp&ac=pm&op=checknewpm&rand=123';

/// The forum: the member's homepage with the daily visit and today's packet until it is claimed; the visit held while
/// [holdVisit] is pending.
final class _Forum implements HttpClientAdapter {
  bool claimed = false;
  Completer<void>? holdVisit;
  final requests = <Uri>[];

  Iterable<Uri> get homepage => requests.where((e) => e.path == '/forum.php' && e.queryParameters['mod'] == null);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    final Object body;
    if (uri.path == '/forum.php' && uri.queryParameters['mod'] == null) {
      body = {
        ...(_json('index_v5_member.json')..remove('document')),
        'checknewpm': _checknewpm,
        if (claimed) 'red_packet': null,
      };
    } else if (uri.path == '/home.php' && uri.queryParameters['op'] == 'checknewpm') {
      await holdVisit?.future;
      body = '';
    } else if (uri.path == '/home.php') {
      body = _json('profile_v4_self.json');
    } else {
      claimed = true;
      body = {'ok': true, 'amount': 5};
    }
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [if (body is String) 'text/javascript' else 'application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Authentication with the current account the test sets: a page served to an account verifies it.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  AuthStatus? get latestStatus => null;

  @override
  int get identityEpoch => 0;

  @override
  AsyncVoidEither loginWithServedUser(UserLoginInfo? user, {required bool guest, int? fetchedAs, int? epoch}) =>
      AsyncVoidEither(() async {
        currentUser = guest ? null : user;
        return rightVoid();
      });

  Future<void> close() => _controller.close();
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late _Forum forum;
  late ForumHomeRepository home;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider(_alice, {}))
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
    await settings.init();
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
    home = ForumHomeRepository();
  });
  tearDown(() async {
    await home.dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  test('1. the page is answered before the daily visit and the claim', () async {
    forum.holdVisit = Completer<void>();
    final page = (await home.fetchHomePage().run()).toNullable();
    expect(page?.servedUid, 4242);
    expect(page?.dailyRedPacket, isNotNull, reason: 'the page as fetched');
    expect(forum.holdVisit!.isCompleted, isFalse, reason: 'answered while the visit is held');
    expect(forum.homepage, hasLength(1));
    forum.holdVisit!.complete();
    await home.dailyRewardsDone;
    expect(forum.requests.map((e) => e.path), ['/forum.php', '/home.php', '/plugin.php', '/forum.php']);
    expect(home.getCache()?.dailyRedPacket, isNull, reason: 'replaced by the page after the claim');
  });

  group('2. the homepage', () {
    late _Auth auth;

    setUp(() => auth = _Auth(null));
    tearDown(() => auth.close());

    HomepageBloc homepage() {
      final bloc = HomepageBloc(
        forumHomeRepository: home,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(bloc.close);
      return bloc;
    }

    test('shows the page at once, then the page after the claim', () async {
      forum.holdVisit = Completer<void>();
      final bloc = homepage()..add(HomepageLoadRequested());
      final first = await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success);
      expect(first.dailyRedPacket?.dateFlag, '20261001', reason: 'shown before the rewards ran');
      forum.holdVisit!.complete();
      final after = await bloc.stream.firstWhere((s) => s.dailyRedPacket == null);
      expect(after.status, HomepageStatus.success);
      expect(after.loggedUserInfo?.username, 'alice');
    });

    test('a page it does not show, or of another account, changes nothing', () async {
      forum.holdVisit = Completer<void>();
      final bloc = homepage()..add(HomepageLoadRequested());
      final shown = await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success);
      final other = ForumHomeApiPage({...(_json('index_v5_member.json')..remove('document')), 'red_packet': null});
      bloc.add(HomepagePageReplaced(previous: other, page: other));
      await pumpEventQueue();
      expect(bloc.state, shown, reason: 'not the page shown');

      // The rewards replace the page shown, but the account changed meanwhile.
      auth.currentUser = const UserLoginInfo(uid: 4243, username: 'Bob');
      forum.holdVisit!.complete();
      await home.dailyRewardsDone;
      await pumpEventQueue();
      expect(bloc.state.dailyRedPacket, isNotNull, reason: "Alice's reloaded page is not shown to Bob");
    });
  });
}
