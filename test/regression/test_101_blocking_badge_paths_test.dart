import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:universal_html/html.dart' as uh;

/// Every path that publishes the unread badge on screen leaves out what the local block list hides or mutes, on the
/// real widgets: the homepage merging the forum header (a notice total and a personal message flag that name nobody),
/// the notification page counting what it lists, and a muted conversation deleted from its card.
///
/// The pages below are synthetic, no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Blocked by Alice in these tests.
const _bob = 1001;

/// Not blocked.
const _carol = 1002;

/// Authentication with a fixed current account; the homepage checks a fetched page with it.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  @override
  AsyncVoidEither loginWithDocument(uh.Document document) => AsyncVoidEither(() async => rightVoid());

  Future<void> close() => _controller.close();
}

/// Notification bloc whose state the test sets; events are recorded, never handled.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this._state);

  NotificationState _state;
  final _controller = StreamController<NotificationState>.broadcast(sync: true);
  final events = <NotificationEvent>[];

  @override
  NotificationState get state => _state;

  @override
  Stream<NotificationState> get stream => _controller.stream;

  /// Emit [next] like the real bloc does after a sync.
  void push(NotificationState next) {
    _state = next;
    _controller.add(next);
  }

  @override
  void add(NotificationEvent event) => events.add(event);

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => _controller.close();
}

/// Storage whose block list rows can not be read.
final class _UnreadableBlocks extends StorageProvider {
  _UnreadableBlocks(AppDatabase db) : super(db, {}, {});

  @override
  Future<List<String>?> getStringList(String key) async {
    if (key.startsWith(UserBlockRepository.keyPrefix)) {
      throw StateError('database is locked');
    }
    return super.getStringList(key);
  }
}

/// Header of `forum.php` for Alice: 3 unread notices and the "new message" flag, like Discuz! X5 renders it.
const _forumHome = '''
<html><body>
<ul id="myprompt_menu" class="p_pop"><li><a href="home.php?mod=space&amp;do=pm" id="pm_ntc"><em class="prompt_news"></em>消息</a></li></ul>
<div id="um">
<div class="avt y"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg" class="_avt user_avatar"></a></div>
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong>
<span class="pipe">|</span><a href="home.php?mod=space&amp;do=pm" id="pm_ntc" class="new">消息</a>
<span class="pipe">|</span><a href="home.php?mod=space&amp;do=notice" id="myprompt" class="a showmenu new">提醒(3)</a></p>
</div>
<form><input type="hidden" name="formhash" value="XXXXXXXX" /></form>
</body></html>''';

/// Alice's own profile page, read by the homepage for her avatar.
const _profile = '''
<html><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="uhd"><div class="icn avt"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg"></a></div></div>
</body></html>''';

/// Answers `forum.php` and the profile page, an empty page for anything else (the guide index); images are not
/// served.
final class _ForumAdapter implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    if (uri.path.endsWith('.jpg')) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final q = uri.queryParameters;
    final body = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == null => _forumHome,
      'home.php' when q['mod'] == 'space' && q['uid'] == '${_alice.uid}' => _profile,
      _ => '<html><body></body></html>',
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late _Auth auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;
  late List<NotificationStateInfo> published;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    getIt.registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _ForumAdapter())),
    );
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = _Auth(_alice);
    info = NotificationInfoRepository();
    counts = NotificationStateCubit(info);
    published = <NotificationStateInfo>[];
    info.status.listen(published.add);
  });

  tearDown(() async {
    await info.dispose();
    await counts.close();
    await settingsBloc.close();
    await blocks.dispose();
    await auth.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// Pump [child] under the providers of the app; the block cubit reads the list of Alice from [repository]
  /// (default: [blocks]).
  Future<UserBlockCubit> pump(
    WidgetTester tester,
    Widget child, {
    required _Notifications notifications,
    UserBlockRepository? repository,
    List<RepositoryProvider<Object>> repositories = const [],
    List<BlocProvider> blocs = const [],
  }) async {
    final cubit = UserBlockCubit(
      repository: repository ?? blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      // No automatic read again: no timer outlives a test.
      retryDelays: const [],
    );
    addTearDown(cubit.close);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => child)],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<NotificationInfoRepository>.value(value: info),
            ...repositories,
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: cubit),
              BlocProvider<NotificationBloc>.value(value: notifications),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              ...blocs,
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await settle(tester);
    return cubit;
  }

  Future<void> blockBob() => blocks.block(ownerUid: _alice.uid, uid: _bob, username: 'Bob');

  group('homepage header hint', () {
    late _ForumAdapter adapter;

    setUp(() async {
      adapter = _ForumAdapter();
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
      // The profile page of the logged in account is read for the avatar.
      await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    });

    /// Open the homepage after a sync published [synced], the block list read from [repository]; returns the
    /// notification bloc it talks to.
    Future<_Notifications> openHomepage(
      WidgetTester tester,
      NotificationStateInfo synced, {
      UserBlockRepository? repository,
    }) async {
      info.updateInfo(
        unreadNoticeCount: synced.notice,
        unreadPersonalMessageCount: synced.personalMessage,
        unreadBroadcastMessageCount: synced.broadcastMessage,
      );
      final notifications = _Notifications(const NotificationState(status: NotificationStatus.success));
      final home = HomeCubit();
      final checkin = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
      final forumHome = ForumHomeRepository();
      addTearDown(() async {
        await home.close();
        await checkin.close();
        await forumHome.dispose();
      });
      await pump(
        tester,
        const HomepagePage(),
        notifications: notifications,
        repository: repository,
        repositories: [
          RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
          RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
        ],
        blocs: [
          BlocProvider<HomeCubit>.value(value: home),
          BlocProvider<CheckinBloc>.value(value: checkin),
        ],
      );
      await settle(tester);
      // The page loaded: the listener merging the header ran.
      expect(tester.element(find.byType(Scaffold).first).read<HomepageBloc>().state.status, HomepageStatus.success);
      expect(adapter.requests.where((e) => e.path.endsWith('forum.php')), isNotEmpty);
      expect(notifications.events.whereType<NotificationUpdateAllRequested>(), isNotEmpty);
      return notifications;
    }

    NotificationStateInfo badge() => published.last;

    testWidgets('without blocks the forum header raises the badge as before', (tester) async {
      await openHomepage(tester, NotificationStateInfo.empty);
      expect((badge().notice, badge().personalMessage), (3, 1));
    });

    testWidgets('with a block neither the notice total nor the message flag of the header reach the badge', (
      tester,
    ) async {
      await tester.runAsync(blockBob);
      // The last sync counted what is not hidden or muted: nothing. The header still says 3 notices and a message,
      // possibly all from Bob.
      await openHomepage(tester, NotificationStateInfo.empty);
      expect((badge().notice, badge().personalMessage), (0, 0));
    });

    testWidgets('with a block the filtered counts of the last sync are kept as they are', (tester) async {
      await tester.runAsync(blockBob);
      await openHomepage(tester, const NotificationStateInfo(notice: 1, personalMessage: 0, broadcastMessage: 2));
      expect((badge().notice, badge().personalMessage, badge().broadcastMessage), (1, 0, 2));
    });

    testWidgets('a block list that can not be read withholds both hints as well', (tester) async {
      final unreadable = UserBlockRepository(_UnreadableBlocks(db));
      addTearDown(unreadable.dispose);
      await openHomepage(tester, NotificationStateInfo.empty, repository: unreadable);
      expect(
        tester.element(find.byType(Scaffold).first).read<UserBlockCubit>().state.status,
        UserBlockListStatus.failed,
      );
      expect((badge().notice, badge().personalMessage), (0, 0));
    });
  });

  group('notification page', () {
    late AutoNotificationCubit auto;

    setUp(() {
      auto = AutoNotificationCubit(
        authenticationRepository: auth,
        notificationRepository: NotificationRepository(storageProvider: storage),
        storageProvider: storage,
      );
    });

    tearDown(() => auto.close());

    NoticeV2 notice(int id, {int? author}) => NoticeV2(
      id: id,
      timestamp: 1788000000 + id,
      data: 'notice $id',
      ignoreType: author == null ? null : 'post',
      authorId: author,
    );

    PersonalMessageV2 pm(int peer, String name) => PersonalMessageV2(
      timestamp: 1788000000 + peer,
      data: 'hello from $name',
      peerUid: peer,
      peerUsername: name,
      sender: false,
      alreadyRead: false,
    );

    /// A sync result: unread notices of Bob, Carol and one without author; unread conversations with Bob and Carol.
    final synced = NotificationState(
      status: NotificationStatus.success,
      noticeList: [
        notice(1, author: _bob),
        notice(2, author: _carol),
        notice(3),
      ],
      personalMessageList: [pm(_bob, 'Bob'), pm(_carol, 'Carol')],
    );

    Future<_Notifications> open(WidgetTester tester) async {
      final notifications = _Notifications(const NotificationState(status: NotificationStatus.loading));
      await pump(
        tester,
        const NotificationPage(),
        notifications: notifications,
        blocs: [BlocProvider<AutoNotificationCubit>.value(value: auto)],
      );
      notifications.push(synced);
      await settle(tester);
      return notifications;
    }

    testWidgets('a sync result counts everything when nobody is blocked', (tester) async {
      await open(tester);
      expect((counts.state.notice, counts.state.personalMessage, counts.state.broadcastMessage), (3, 2, 0));
    });

    testWidgets('a sync result leaves the hidden notice and the muted conversation out of the badge', (tester) async {
      await tester.runAsync(blockBob);
      await open(tester);
      expect((counts.state.notice, counts.state.personalMessage, counts.state.broadcastMessage), (2, 1, 0));

      // Muted, not hidden: the conversation with Bob is still listed.
      await tester.tap(find.text(tr.noticePage.privateMessageTab.title));
      await settle(tester);
      expect(find.textContaining('hello from Bob', findRichText: true), findsOneWidget);
      expect(find.textContaining('hello from Carol', findRichText: true), findsOneWidget);
    });
  });

  group('muted conversation deleted from its card', () {
    Future<_Notifications> openCard(WidgetTester tester, int peer, String name) async {
      final notifications = _Notifications(const NotificationState(status: NotificationStatus.success));
      await pump(
        tester,
        Scaffold(
          body: PersonalMessageCardV2(
            PersonalMessageV2(
              timestamp: 150,
              data: 'hello from $name',
              peerUid: peer,
              peerUsername: name,
              sender: false,
              alreadyRead: false,
            ),
          ),
        ),
        notifications: notifications,
      );
      // One unread conversation is counted: the one of the peer that is not blocked.
      counts.setPersonalMessage(1);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.noticePage.cardMenu.delete.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.general.ok));
      await settle(tester);
      expect(
        notifications.events.whereType<NotificationDeletePersonalMessageRequested>().map((e) => (e.uid, e.peerUid)),
        [(_alice.uid, peer)],
      );
      return notifications;
    }

    testWidgets('deleting an unread conversation of a peer not blocked lowers the badge', (tester) async {
      await tester.runAsync(blockBob);
      await openCard(tester, _carol, 'Carol');
      expect(counts.state.personalMessage, 0);
    });

    testWidgets('deleting the unread conversation of a blocked peer does not lower the badge of the others', (
      tester,
    ) async {
      await tester.runAsync(blockBob);
      await openCard(tester, _bob, 'Bob');
      expect(counts.state.personalMessage, 1, reason: 'the muted conversation was never counted');
    });
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
