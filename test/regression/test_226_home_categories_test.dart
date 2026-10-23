import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
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
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/html.dart' as uh;

/// The phone homepage lists the pinned thread groups (the forum homepage block 最新活动 ... 发帖排行) as tabs of one
/// card instead of seven tall cards, and remembers the selected group; the support entry sits under the greeting, the
/// app bar has a support button, and the support dialog lists the rewards of the forum announcement 「支援天使」.
///
/// Synthetic accounts and pages only: no network, no login, nothing is paid or sent.
Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = 1002;

/// Titles of the groups in the order the homepage lists them (test_185).
const _groupTitles = ['最新活动', '见习天使', '动漫新闻', '最新主题', '今日话题', '动漫讨论', '发帖排行'];

/// Thread rows of the thread groups: title, author, uid.
const _threadRows = <String, List<(String, String, int)>>{
  '最新活动': [
    ('【活动】十月签到挑战赛开始报名', 'Carol', 1003),
    ('【活动】秋季同人绘画征集', 'Bob', _bob),
    ('【公告】活动专区兑换商店开放', 'Dave', 1004),
    ('【活动】每周动画观后感接龙', 'Erin', 1005),
    ('【活动】新人见面会 第 12 期', 'Carol', 1003),
  ],
  '动漫新闻': [
    ('【新闻】十月新番播出时间表整理', 'Dave', 1004),
    ('【新闻】某长篇漫画宣布动画化', 'Erin', 1005),
    ('【新闻】年度动画大赏提名公布', 'Carol', 1003),
  ],
  '最新主题': [
    ('求推荐几部轻松的日常番', 'Erin', 1005),
    ('分享一下我的手办收藏', 'Frank', 1006),
    ('这季度你在追哪几部？', 'Grace', 1007),
    ('关于字幕组时间轴的小问题', 'Dave', 1004),
    ('新人报到，请多关照', 'Heidi', 1008),
  ],
  '今日话题': [
    ('你最喜欢的片头曲是哪首？', 'Grace', 1007),
    ('如果能进入一部动画的世界', 'Carol', 1003),
    ('聊聊你入坑的第一部番', 'Frank', 1006),
  ],
  '动漫讨论': [
    ('第 3 集的伏笔是不是太明显了', 'Heidi', 1008),
    ('原作党来聊聊改编的取舍', 'Erin', 1005),
    ('这部的作画水准讨论', 'Dave', 1004),
    ('结局到底算不算圆满', 'Grace', 1007),
  ],
};

/// New members of 见习天使: name, uid.
const _members = [('Momo', 1101), ('Kuro', 1102), ('Yuki', 1103)];

/// Rows of 发帖排行: member, uid, posts today.
const _ranks = [('Carol', 1003, 128), ('Dave', 1004, 96), ('Erin', 1005, 73), ('Frank', 1006, 51)];

int _tidOf(String title) {
  var i = 0;
  for (final rows in _threadRows.values) {
    for (final row in rows) {
      i++;
      if (row.$1 == title) {
        return 2000 + i;
      }
    }
  }
  throw ArgumentError(title);
}

/// A thread row of a `Kahrpba` panel: the thread link, then the author link.
String _threadDiv(String title, String name, int uid) {
  final thread = '<a href="forum.php?mod=viewthread&amp;tid=${_tidOf(title)}">$title</a>';
  final author = '<a href="home.php?mod=space&amp;uid=$uid" target="_blank"><em>$name</em></a>';
  return '<div class="Kahrpba_threads">$thread$author</div>';
}

String _threadDivs(String group) => [
  for (final (title, name, uid) in _threadRows[group]!) _threadDiv(title, name, uid),
].join('\n');

/// A row of the rank panel: the member's space, then the post count linked to it too.
String _rankDiv(String name, int uid, int posts) {
  final member = '<a href="home.php?mod=space&amp;uid=$uid">$name</a>';
  final count = '<a href="home.php?mod=space&amp;uid=$uid" target="_blank"><em>今日共发$posts贴</em></a>';
  return '<div class="Kahrpba_threads">$member$count</div>';
}

/// The `Kahrpba` block as the forum prints it: the tab buttons in the order of the page (1, 2, 3, 4, 6, 7, 5) and the
/// panels in the order of their ids, the rank in panel 5; the parser puts them in the order of [_groupTitles].
String _kahrpba() {
  final members = [
    for (final (name, uid) in _members)
      '<div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=$uid">欢迎$name加入~</a></div>',
  ].join('\n');
  final ranks = [for (final (name, uid, posts) in _ranks) _rankDiv(name, uid, posts)].join('\n');
  String button(int id, String title) => '<button type="button" id="Kahrpba_$id"><em>$title</em></button>';
  return '''
<table id="Kahrpba"><tr>
<td id="Kahrpba_nav">
${button(1, '最新活动')}${button(2, '见习天使')}${button(3, '动漫新闻')}${button(4, '最新主题')}
${button(6, '今日话题')}${button(7, '动漫讨论')}${button(5, '发帖排行')}
</td>
<td id="Kahrpba_show">
<div id="Kahrpba_c_1">${_threadDivs('最新活动')}</div>
<div id="Kahrpba_c_2">$members</div>
<div id="Kahrpba_c_3">${_threadDivs('动漫新闻')}</div>
<div id="Kahrpba_c_4">${_threadDivs('最新主题')}</div>
<div id="Kahrpba_c_5">$ranks</div>
<div id="Kahrpba_c_6">${_threadDivs('今日话题')}</div>
<div id="Kahrpba_c_7">${_threadDivs('动漫讨论')}</div>
</td></tr></table>''';
}

/// `forum.php` of Alice with the forum status bar and, when [pinned], the `Kahrpba` block (owner marks as in test_171).
String _forumHome({required bool pinned}) =>
    '''
<html><head>
<script type="text/javascript">var STYLEID = '42', discuz_uid = '1000', cookiepre = 'Ystv_2132_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<div class="avt y"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg" class="_avt user_avatar"></a></div>
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p>
</div></div></div></div>
<form><input type="hidden" name="formhash" value="XXXXXXXX" /></form>
<div id="chart" class="bm bw0 cl"><p class="chart z">今日: <em>1234</em> | 昨日: <em>5678</em> | 帖子: <em>9012345</em></p></div>
${pinned ? _kahrpba() : ''}
</body></html>''';

const _profile = '''
<html><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="uhd"><div class="icn avt"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg"></a></div></div>
</body></html>''';

/// Answers `forum.php` (with the pinned block unless [pinned] is false) and the profile page, an empty page otherwise;
/// images and the thread page are offline.
final class _ForumAdapter implements HttpClientAdapter {
  final requests = <Uri>[];
  bool pinned = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    final q = uri.queryParameters;
    if (uri.path.endsWith('.jpg') || q['mod'] == 'viewthread') {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final body = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == null => _forumHome(pinned: pinned),
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

/// Every image request fails at once: images are not part of these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Authentication with a current account the test sets, as in test_171.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  @override
  UserLoginInfo? get effectiveCurrentUser => currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  AuthStatus? get latestStatus => null;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  @override
  AsyncVoidEither loginWithDocument(uh.Document document, {int? fetchedAs, int? epoch}) =>
      AsyncVoidEither(() async => rightVoid());

  @override
  int get identityEpoch => 0;

  Future<void> close() => _controller.close();
}

/// Notification bloc with a fixed state; events are recorded, never handled.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  final NotificationState state;

  final _controller = StreamController<NotificationState>.broadcast(sync: true);

  @override
  Stream<NotificationState> get stream => _controller.stream;

  @override
  void add(NotificationEvent event) {}

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => _controller.close();
}

/// A few frames with real time in between, for database and fake network answers.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A [size] phone or window, text at [scale].
void _window(WidgetTester tester, Size size, {double scale = 1}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

const _phone = Size(390, 844);

/// The stand-in thread page: the route the app would open, with its query.
const ValueKey<String> _threadStubKey = ValueKey('thread-stub');

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late _Auth auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;
  late _ForumAdapter adapter;
  late List<MethodCall> clipboard;

  setUp(() async {
    ThreadAuthorCache.clear();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _ForumAdapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = _Auth(_alice);
    info = NotificationInfoRepository();
    counts = NotificationStateCubit(info);
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method.startsWith('Clipboard.')) {
          clipboard.add(call);
        }
        return null;
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
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

  /// Open the homepage in a [size] window, the settings read through [bloc] (default: [settingsBloc]).
  Future<void> openHomepage(WidgetTester tester, {Size size = _phone, double scale = 1, SettingsBloc? bloc}) async {
    _window(tester, size, scale: scale);
    final home = HomeCubit();
    final checkin = CheckinBloc(
      checkinRepository: CheckinRepository(storageProvider: storage),
      authenticationRepository: auth,
      settingsRepository: settings,
    );
    final forumHome = ForumHomeRepository();
    final blockCubit = UserBlockCubit(
      repository: blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    addTearDown(() async {
      await blockCubit.close();
      await home.close();
      await checkin.close();
      await forumHome.dispose();
    });
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomepagePage()),
        GoRoute(
          path: ScreenPaths.threadV1,
          name: ScreenPaths.threadV1,
          builder: (_, state) => Scaffold(
            key: _threadStubKey,
            body: Text('thread ${state.uri.queryParameters}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<NotificationInfoRepository>.value(value: info),
            RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
            RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: bloc ?? settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: blockCubit),
              BlocProvider<NotificationBloc>.value(
                value: _Notifications(const NotificationState(status: NotificationStatus.success)),
              ),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              BlocProvider<HomeCubit>.value(value: home),
              BlocProvider<CheckinBloc>.value(value: checkin),
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(homepageBloc(tester).state.status, HomepageStatus.success);
  }

  Finder tab(String title) => find.widgetWithText(HomeCardTab, title);

  bool selected(WidgetTester tester, String title) => tester.widget<HomeCardTab>(tab(title)).selected;

  /// Second lines of the rows of the card (thread titles, the welcome text of new members), top to bottom.
  List<String?> rowTitles(WidgetTester tester) => tester
      .widgetList<ListTile>(find.descendant(of: find.byType(PinTabSection), matching: find.byType(ListTile)))
      .map((e) => (e.subtitle as Text?)?.data)
      .toList();

  Future<void> selectTab(WidgetTester tester, String title) async {
    await tester.ensureVisible(tab(title));
    await tester.pumpAndSettle();
    await tester.tap(tab(title));
    await _settle(tester);
  }

  Finder inAppBar(Finder finder) => find.descendant(of: find.byType(AppBar), matching: finder);

  group('one card of tabs on the phone', () {
    testWidgets('the seven groups are tabs of one card, the first one shown, a tap shows another', (tester) async {
      await openHomepage(tester);
      expect(find.byType(PinTabSection), findsOneWidget);
      expect(find.byType(PinSection), findsNothing, reason: 'no card per group on a phone');
      expect(
        tester.widgetList<HomeCardTab>(find.byType(HomeCardTab)).map((e) => e.label).where(_groupTitles.contains),
        _groupTitles,
        reason: 'every group, in the order of the website',
      );
      expect(selected(tester, '最新活动'), isTrue);
      expect(_groupTitles.skip(1).where((e) => selected(tester, e)), isEmpty);
      expect(rowTitles(tester), [for (final row in _threadRows['最新活动']!) row.$1]);

      await selectTab(tester, '动漫新闻');
      expect(selected(tester, '动漫新闻'), isTrue);
      expect(selected(tester, '最新活动'), isFalse);
      expect(rowTitles(tester), [for (final row in _threadRows['动漫新闻']!) row.$1]);
      expect(find.text('【活动】十月签到挑战赛开始报名'), findsNothing);

      await selectTab(tester, '见习天使');
      expect(rowTitles(tester), [for (final (name, _) in _members) '欢迎$name加入~'], reason: 'the members, as before');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row opens its thread like the cards did', (tester) async {
      await openHomepage(tester);
      final row = find.text('【公告】活动专区兑换商店开放');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await _settle(tester);
      expect(find.byKey(_threadStubKey), findsOneWidget);
      expect(
        find.text('thread ${{'tid': '${_tidOf('【公告】活动专区兑换商店开放')}', 'appBarTitle': '【公告】活动专区兑换商店开放'}}'),
        findsOneWidget,
      );
    });

    testWidgets('the rank keeps its reversed rows: the member as title, the post count on the right', (tester) async {
      await openHomepage(tester);
      await selectTab(tester, '发帖排行');
      expect(selected(tester, '发帖排行'), isTrue);
      final tiles = tester.widgetList<ListTile>(
        find.descendant(of: find.byType(PinTabSection), matching: find.byType(ListTile)),
      );
      expect(tiles, hasLength(_ranks.length));
      for (final (i, tile) in tiles.indexed) {
        final (name, _, posts) = _ranks[i];
        expect(tile.subtitle, isNull);
        expect((((tile.title! as GestureDetector).child! as Row).children.single as Text).data, name);
        expect((tile.trailing! as Text).data, '今日共发$posts贴');
      }
    });

    testWidgets('a blocked author is left out by the uid of the row, the author of each thread is recorded', (
      tester,
    ) async {
      await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: _bob, username: 'Bob'));
      await openHomepage(tester);
      expect(find.text('【活动】秋季同人绘画征集'), findsNothing);
      expect(rowTitles(tester), [
        for (final row in _threadRows['最新活动']!)
          if (row.$3 != _bob) row.$1,
      ]);
      expect(ThreadAuthorCache.authorOf('${_tidOf('【活动】秋季同人绘画征集')}'), _bob);
      // The threads of the groups not shown are recorded too, as when each group had its card.
      expect(ThreadAuthorCache.authorOf('${_tidOf('第 3 集的伏笔是不是太明显了')}'), 1008);
      expect(ThreadAuthorCache.authorOf('${_tidOf('【新闻】年度动画大赏提名公布')}'), 1003);
    });

    testWidgets('no groups: no card', (tester) async {
      adapter.pinned = false;
      await openHomepage(tester);
      expect(find.byType(PinTabSection), findsNothing);
      expect(find.byType(PinSection), findsNothing);
    });
  });

  group('the selected group is remembered', () {
    testWidgets('by its title in the settings, across a refresh and a restart', (tester) async {
      await openHomepage(tester);
      await selectTab(tester, '今日话题');
      expect(settings.currentSettings.homepagePinnedGroup, '今日话题');

      // A pull to refresh builds the card anew.
      homepageBloc(tester).add(HomepageRefreshRequested());
      await _settle(tester);
      expect(homepageBloc(tester).state.status, HomepageStatus.success);
      expect(selected(tester, '今日话题'), isTrue);
      expect(rowTitles(tester), [for (final row in _threadRows['今日话题']!) row.$1]);

      // A restart reads the settings from the database again.
      await tester.pumpWidget(const SizedBox());
      final restarted = SettingsRepository(storage);
      await tester.runAsync(restarted.init);
      final restartedBloc = SettingsBloc(settingsRepository: restarted, fragmentsRepository: FragmentsRepository());
      expect(restarted.currentSettings.homepagePinnedGroup, '今日话题');
      await openHomepage(tester, bloc: restartedBloc);
      expect(selected(tester, '今日话题'), isTrue);
      expect(rowTitles(tester), [for (final row in _threadRows['今日话题']!) row.$1]);

      // The repository and the bloc of the restart are left open: their streams were set up across the fake and
      // the real zone of the test and their close never completes in either; they hold nothing that outlives it.
    });

    testWidgets('a title the forum no longer has shows the first group and is kept', (tester) async {
      await tester.runAsync(() => settings.setValue(SettingsKeys.homepagePinnedGroup, '已经没有的分类'));
      await openHomepage(tester);
      expect(selected(tester, '最新活动'), isTrue);
      expect(rowTitles(tester), [for (final row in _threadRows['最新活动']!) row.$1]);
      expect(settings.currentSettings.homepagePinnedGroup, '已经没有的分类', reason: 'nothing selected by the user');
    });

    testWidgets('a remembered group past the right edge has its tab scrolled into view, the page stays at the top', (
      tester,
    ) async {
      await tester.runAsync(() => settings.setValue(SettingsKeys.homepagePinnedGroup, '发帖排行'));
      await openHomepage(tester, size: const Size(360, 780));
      await tester.pumpAndSettle();
      expect(selected(tester, '发帖排行'), isTrue);
      final card = tester.getRect(find.byType(PinTabSection));
      final rank = tester.getRect(tab('发帖排行'));
      expect(rank.left, greaterThanOrEqualTo(card.left));
      expect(rank.right, lessThanOrEqualTo(card.right));
      final page = tester.widget<ListView>(find.byType(ListView).first).controller!;
      expect(page.offset, 0, reason: 'only the tab row scrolled');
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching keeps the page offset; the card follows the rows of the new group', (tester) async {
      await openHomepage(tester);
      final page = tester.widget<ListView>(find.byType(ListView).first).controller!;
      // The tab row at the top of the screen, as a reader scrolling to it would have it.
      final top = tester.getTopLeft(find.byType(PinTabSection)).dy - tester.getTopLeft(find.byType(ListView)).dy;
      page.jumpTo(top);
      await tester.pumpAndSettle();
      final offset = page.offset;
      final tall = tester.getSize(find.byType(PinTabSection)).height;

      await tester.tap(tab('动漫新闻'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final midway = tester.getSize(find.byType(PinTabSection)).height;
      await _settle(tester);
      final short = tester.getSize(find.byType(PinTabSection)).height;

      expect(short, lessThan(tall), reason: 'three rows instead of five');
      expect(midway, inExclusiveRange(short, tall), reason: 'the height changes smoothly');
      expect(page.offset, offset);
      expect(tester.takeException(), isNull);
    });
  });

  group('wider desktop layouts are unchanged', () {
    for (final (name, size) in [('medium', const Size(800, 900)), ('wide', const Size(1280, 900))]) {
      testWidgets(
        '$name: one card per group, the support card where it was',
        (tester) async {
          await openHomepage(tester, size: size);
          expect(find.byType(PinSection), findsOneWidget);
          expect(find.byType(PinTabSection), findsNothing);
          for (final title in _groupTitles) {
            expect(find.descendant(of: find.byType(PinSection), matching: find.text(title)), findsOneWidget);
          }
          expect(find.byType(HomeSupportCard), findsOneWidget);
          final support = tester.getRect(find.byType(HomeSupportCard));
          final stats = tester.getRect(find.byType(HomeForumStatsCard));
          if (name == 'medium') {
            expect(support.top, stats.top, reason: 'beside the statistics');
            expect(support.left, greaterThan(stats.right));
          } else {
            final pinned = tester.getRect(find.byType(PinSection));
            expect(support.left, greaterThan(pinned.right), reason: 'in the side column');
            expect(support.top, greaterThan(stats.bottom));
          }
          expect(inAppBar(find.byIcon(Icons.favorite_border)), findsOneWidget, reason: 'every layout');
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  });

  group('support entries', () {
    testWidgets('phone: the support card right under the greeting, and only there', (tester) async {
      await openHomepage(tester);
      expect(find.byType(HomeSupportCard), findsOneWidget);
      final greeting = tester.getRect(find.byType(HomeGreetingCard));
      final support = tester.getRect(find.byType(HomeSupportCard));
      expect(support.top - greeting.bottom, 12, reason: 'the next card, one gap below');
      expect(support.bottom, lessThan(tester.getRect(find.byType(PinTabSection)).top));
      await tester.scrollUntilVisible(find.byType(HomeToolsCard), 300, scrollable: find.byType(Scrollable).first);
      expect(find.byType(HomeSupportCard), findsOneWidget, reason: 'no second one at the bottom');
      expect(
        tester.getRect(find.byType(HomeToolsCard)).top,
        greaterThan(tester.getRect(find.byType(GuideSection)).bottom),
        reason: 'the tools are the last card',
      );
    });

    testWidgets('the app bar heart opens the support dialog', (tester) async {
      await openHomepage(tester);
      final heart = inAppBar(find.byIcon(Icons.favorite_border));
      expect(heart, findsOneWidget);
      expect(
        tester.widget<IconButton>(find.ancestor(of: heart, matching: find.byType(IconButton))).tooltip,
        tr.aboutPage.supportDevelopment,
      );
      await tester.tap(heart);
      await tester.pumpAndSettle();
      expect(find.byType(SupportDevelopmentDialog), findsOneWidget);
    });

    for (final (name, size, scale) in [
      ('360dp', const Size(360, 780), 1.0),
      ('360dp, large text', const Size(360, 780), 1.3),
      ('320dp', const Size(320, 640), 1.0),
      ('300dp, large text', const Size(300, 640), 1.3),
    ]) {
      testWidgets('$name: the app bar overflows nothing and keeps every entry reachable', (tester) async {
        await openHomepage(tester, size: size, scale: scale);
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(AppBar));
        final buttons = inAppBar(find.byWidgetPredicate((w) => w is IconButton || w is PopupMenuButton));
        for (final rect in buttons.evaluate().map((e) => tester.getRect(find.byWidget(e.widget)))) {
          expect(rect.left, greaterThanOrEqualTo(bar.left));
          expect(rect.right, lessThanOrEqualTo(bar.right));
        }
        final title = tester.getRect(inAppBar(find.text(tr.homepage.title)));
        expect(title.width, greaterThan(0));
        expect(title.right, lessThanOrEqualTo(tester.getRect(buttons.first).left));
        expect(inAppBar(find.byIcon(Icons.search_outlined)), findsOneWidget);
        expect(inAppBar(find.byType(HeroUserAvatar)), findsOneWidget);

        final more = inAppBar(find.byKey(const ValueKey('homepage-app-bar-more')));
        // The notifications are a tab of the navigation since 2026-10-23, the bar lost their button: four buttons fit
        // down to a 320dp phone, and a 360dp one with large text.
        if (name != '300dp, large text') {
          expect(more, findsNothing, reason: 'four buttons fit');
          expect(inAppBar(find.byIcon(Icons.favorite_border)), findsOneWidget);
          expect(inAppBar(find.byIcon(Icons.catching_pokemon)), findsOneWidget);
          return;
        }
        // Too narrow: the pokemon centre and the support entry share one menu.
        expect(inAppBar(find.byIcon(Icons.favorite_border)), findsNothing);
        expect(inAppBar(find.byIcon(Icons.catching_pokemon)), findsNothing);
        await tester.tap(more);
        await tester.pumpAndSettle();
        Finder inMenu(Finder finder) =>
            find.descendant(of: find.byWidgetPredicate((w) => w is PopupMenuItem), matching: finder);
        expect(inMenu(find.text(tr.pokemon.title)), findsOneWidget);
        await tester.tap(inMenu(find.text(tr.aboutPage.supportDevelopment)));
        await tester.pumpAndSettle();
        expect(find.byType(SupportDevelopmentDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('forum rewards in the support dialog', () {
    Future<void> openDialog(WidgetTester tester) async {
      await openHomepage(tester);
      await tester.tap(inAppBar(find.byIcon(Icons.favorite_border)));
      await tester.pumpAndSettle();
    }

    Finder inDialog(Finder finder) => find.descendant(of: find.byType(SupportDevelopmentDialog), matching: finder);

    testWidgets('the rewards of the announcement, before the donation code', (tester) async {
      await openDialog(tester);
      final reward = tr.aboutPage.forumReward;
      expect(inDialog(find.text(reward.title)), findsOneWidget);
      expect(inDialog(find.text(reward.description)), findsOneWidget);
      for (final (amount, text) in [
        (reward.tier50.amount, reward.tier50.reward),
        (reward.tier100.amount, reward.tier100.reward),
        (reward.tier200.amount, reward.tier200.reward),
        (reward.tierEvery100.amount, reward.tierEvery100.reward),
        (reward.tier500.amount, reward.tier500.reward),
      ]) {
        expect(inDialog(find.text('$amount${reward.separator}$text', findRichText: true)), findsOneWidget);
      }
      expect(
        inDialog(find.text('${reward.claimTitle}${reward.separator}${reward.claim}', findRichText: true)),
        findsOneWidget,
      );
      expect(
        tester.getRect(inDialog(find.text(reward.title))).top,
        lessThan(tester.getRect(inDialog(find.byType(Image))).top),
        reason: 'read before scanning the code',
      );
      expect(tr.aboutPage.donationDescription, isNot(contains('not an official forum fundraiser')));
    });

    testWidgets('logged in: the account to write in the note, copied with one tap', (tester) async {
      await openDialog(tester);
      final reward = tr.aboutPage.forumReward;
      final account = inDialog(find.text(reward.account(username: 'Alice', uid: 1000)));
      expect(account, findsOneWidget);
      expect(inDialog(find.text(reward.notLoggedIn)), findsNothing);
      final copy = inDialog(find.byTooltip(reward.copyUsername));
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(clipboard.single.method, 'Clipboard.setData');
      expect((clipboard.single.arguments as Map)['text'], 'Alice');
      expect(find.text(reward.usernameCopied), findsOneWidget);
      expect(find.byType(SupportDevelopmentDialog), findsOneWidget, reason: 'the dialog stays open');
      expect(adapter.requests.where((e) => e.path.endsWith('home.php')), hasLength(1), reason: 'nothing fetched');
    });

    testWidgets('logged in, Simplified Chinese: the name and the uid in one line', (tester) async {
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
      addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
      await openDialog(tester);
      expect(inDialog(find.text('你的论坛账号：Alice（UID 1000）')), findsOneWidget);
      expect(inDialog(find.text('论坛奖励')), findsOneWidget);
      expect(
        inDialog(find.textContaining('同样可以领取论坛「支援天使」公告的奖励（见下方）')),
        findsOneWidget,
        reason: 'the description no longer says it is no forum fundraiser',
      );
    });

    testWidgets('logged out: a hint to write the username in the note, nothing to copy', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      auth.currentUser = null;
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp(
              scaffoldMessengerKey: snackbarKey,
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(context: context, builder: (_) => const SupportDevelopmentDialog()),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final reward = tr.aboutPage.forumReward;
      expect(inDialog(find.text(reward.notLoggedIn)), findsOneWidget);
      expect(inDialog(find.byTooltip(reward.copyUsername)), findsNothing);
      expect(inDialog(find.byKey(const ValueKey('forum-reward-account'))), findsNothing);
      expect(inDialog(find.textContaining('Alice')), findsNothing);
    });

    testWidgets('the announcement opens in the app thread page, in place of the dialog', (tester) async {
      await openDialog(tester);
      final button = inDialog(find.text(tr.aboutPage.forumReward.viewAnnouncement));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await _settle(tester);
      expect(find.byType(SupportDevelopmentDialog), findsNothing);
      expect(find.byKey(_threadStubKey), findsOneWidget);
      expect(find.text('thread ${{'tid': '1266879'}}'), findsOneWidget);
      expect(SupportDevelopmentDialog.forumRewardUrl, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266879');
    });
  });
}

HomepageBloc homepageBloc(WidgetTester tester) => BlocProvider.of<HomepageBloc>(tester.element(find.byType(AppBar)));
