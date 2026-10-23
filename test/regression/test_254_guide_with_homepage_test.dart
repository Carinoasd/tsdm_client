/// The guide of the homepage is asked together with the homepage (cold start, UX audit item 5): its card was built,
/// and the guide asked, only once the homepage had arrived, so the two requests went one after the other.
///
/// 1. the request asked ahead is taken by the card, once, only for the session it was asked with and while fresh;
/// 2. the homepage asks for it as soon as it starts loading, before its own page arrives;
/// 3. the card shows the guide saved for the account at once and takes the request asked ahead, no second one; the
///    answer is saved for the account it was served to.
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
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/repository/guide_feed.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/saved_answer_store.dart';
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

/// The forum: the homepage (held while [holdHome] is pending) and the guide (held while [holdGuide] is pending).
final class _Forum implements HttpClientAdapter {
  Completer<void>? holdHome;
  Completer<void>? holdGuide;
  final requests = <Uri>[];

  Iterable<Uri> get guide => requests.where((e) => e.queryParameters['mod'] == 'guide');

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
    if (uri.path == '/forum.php' && uri.queryParameters['mod'] == 'guide') {
      await holdGuide?.future;
      body = _json('guide_v7_index.json');
    } else if (uri.path == '/forum.php') {
      await holdHome?.future;
      body = _json('index_v5_member.json')..remove('document');
    } else if (uri.path == '/home.php') {
      body = _json('profile_v4_self.json');
    } else {
      body = '';
    }
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [if (body is String) 'text/html' else 'application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
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
  late CookieProvider cookie;
  late _Forum forum;
  late Directory tmp;
  late SavedAnswerStore store;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });
  setUp(() async {
    TsdmAppApi.reset();
    tmp = Directory.systemTemp.createTempSync('tsdm_guide_feed_');
    store = SavedAnswerStore(directory: () async => tmp);
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    cookie = CookieProvider(_alice, {});
    forum = _Forum();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(cookie)
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
    await settings.init();
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
  });
  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  group('1. the request asked ahead', () {
    test('taken once by the card of the same session', () async {
      // A second ask while the first is fresh is the same request.
      final feed = GuideFeed(savedAnswers: store)
        ..prefetch()
        ..prefetch();
      final first = await feed.fetch().run();
      expect(first.toNullable(), isNotEmpty);
      expect(forum.guide, hasLength(1));
      // Taken: a card built later (a reload) asks again.
      await feed.fetch().run();
      expect(forum.guide, hasLength(2));
    });

    test('never for another session, nor once stale', () async {
      final feed = GuideFeed(savedAnswers: store)..prefetch();
      // Sent before the switch (a request still waiting to go out is dropped by the client of the session).
      for (var i = 0; i < 50 && forum.guide.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await cookie.updateUserInfo(const UserLoginInfo(uid: 4243, username: 'Bob'));
      await feed.fetch().run();
      expect(forum.guide, hasLength(2), reason: "Bob's card does not take Alice's request");

      final stale = GuideFeed(savedAnswers: store, freshFor: Duration.zero)..prefetch();
      await stale.fetch().run();
      expect(forum.guide, hasLength(4));
    });

    test('the answer is saved for the account it was served to, not after a switch', () async {
      await GuideFeed(savedAnswers: store).fetch().run();
      await store.pendingWrites;
      expect((await store.load(SavedAnswerKind.guide, uid: 4242))?.answer['uid'], 4242);
      expect(await store.load(SavedAnswerKind.guide, uid: 4243), isNull);

      forum.holdGuide = Completer<void>();
      final feed = GuideFeed(savedAnswers: store);
      final asked = feed.fetch().run();
      await pumpEventQueue();
      await cookie.updateUserInfo(const UserLoginInfo(uid: 4243, username: 'Bob'));
      store.forget(4242);
      forum.holdGuide!.complete();
      await asked;
      await store.pendingWrites;
      expect(await store.load(SavedAnswerKind.guide, uid: 4242), isNull, reason: 'the session changed meanwhile');
    });
  });

  test('3. the saved guide in memory goes with the account', () async {
    final feed = GuideFeed(savedAnswers: store);
    store.save(SavedAnswerKind.guide, _json('guide_v7_index.json'));
    await store.pendingWrites;
    await feed.loadSaved(4242);
    expect(feed.savedModules, isNotEmpty);
    store.forget(4242);
    expect(feed.savedModules, isNull, reason: 'logged out or removed meanwhile');
  });

  test('2. the homepage asks for the guide before its own page arrives', () async {
    final auth = _Auth();
    addTearDown(auth.close);
    final home = ForumHomeRepository(savedAnswers: store);
    addTearDown(home.dispose);
    final feed = GuideFeed(savedAnswers: store);
    forum.holdHome = Completer<void>();
    final bloc = HomepageBloc(
      forumHomeRepository: home,
      profileRepository: ProfileRepository(),
      authenticationRepository: auth,
      guideFeed: feed,
    )..add(HomepageLoadRequested());
    addTearDown(bloc.close);
    for (var i = 0; i < 50 && forum.guide.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(forum.guide, hasLength(1));
    expect(forum.homepage, hasLength(1));
    expect(forum.holdHome!.isCompleted, isFalse, reason: 'the homepage is still on its way');
    forum.holdHome!.complete();
    await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success);
    // The card built now takes that request.
    await feed.fetch().run();
    expect(forum.guide, hasLength(1));
  });

  testWidgets('3. the card shows the saved guide at once and takes the request asked ahead', (tester) async {
    final feed = GuideFeed(savedAnswers: store);
    await tester.runAsync(() async {
      store.save(SavedAnswerKind.guide, _json('guide_v7_index.json'));
      await store.pendingWrites;
      await feed.loadSaved(4242);
      forum.holdGuide = Completer<void>();
      feed.prefetch();
      for (var i = 0; i < 50 && forum.guide.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(feed.savedModules, isNotEmpty);
    expect(forum.guide, hasLength(1));
    tester.view
      ..physicalSize = const Size(1080, 4000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: RepositoryProvider<GuideFeed>.value(
            value: feed,
            child: const Scaffold(body: SingleChildScrollView(child: GuideSection())),
          ),
        ),
      ),
    );
    await tester.pump();
    final title = feed.savedModules!.first.items.first.title;
    expect(find.text(title), findsOneWidget, reason: 'the saved guide, while the guide is asked again');
    await tester.runAsync(() async {
      forum.holdGuide!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(forum.guide, hasLength(1), reason: 'the request asked ahead, no second one');
    expect(find.text(title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
