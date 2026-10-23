/// Navigation rework (UX audit, item 8).
///
/// * Every navigation (bottom bar on phones, rail on tablets, drawer on desktop windows) has the same four tabs:
///   homepage, forums, notifications (with the unread count) and "me". Back on another tab shows the homepage first.
/// * The notifications are a tab: a tap on a system notification, the bell of the app bars and the menus show that tab
///   (closing the reading pages above the shell), or open the notice page above pages that cannot be closed.
/// * The "me" tab gathers the account and its pages; the settings (a tab before) and about are entries of it. A guest
///   gets the login, the settings and about.
/// * The homepage of a guest shows the forums and the guide instead of a login wall, under a card asking to log in.
/// * The forum page has a labelled post button, folded while scrolling down; a guest or an account the forum does not
///   let post gets told why instead of the editor.
///
/// Synthetic accounts, forums and threads only: no network, nothing is posted.
///
/// Screenshots: with `NAV_SHOTS_DIR` (output directory) and `NAV_SHOTS_FONT` (a font file with CJK glyphs) set, the
/// last group writes the four tabs, the "me" tab of a guest, the homepage of a guest and the forum page, light and
/// dark, on a 1080x2280 phone and a 1600x2560 tablet.
library;

// The notes are written as the forum prints them, pieces of one html string.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/cubit/init_cubit.dart';
import 'package:tsdm_client/features/home/view/home_page.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/features/multi_user/widgets/account_switch_dialog.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/utils/notice_page_tab.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
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
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/back_to_home_button.dart';
import 'package:universal_html/html.dart' as uh;

Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

// ---------------------------------------------------------------------------------------------------------------------
// Synthetic forum.
// ---------------------------------------------------------------------------------------------------------------------

/// Forum groups: gid, name, forums (fid, name, posts today).
const _groups = <(int, String, List<(int, String, int)>)>[
  (1, '综合讨论区', [(2, '新人报到', 12), (3, '站务公告', 0), (4, '意见反馈', 3), (5, '闲聊灌水', 58)]),
  (10, '动漫天地', [(11, '新番讨论', 31), (12, '动漫资讯', 7), (13, '动画推荐', 4), (14, '声优茶话会', 2)]),
  (20, '游戏乐园', [(21, '手游情报', 9), (22, '主机与 PC', 6), (23, '美少女游戏', 5)]),
  (30, '创作交流', [(31, '原创绘图', 14), (32, '同人小说', 3), (33, 'COS 与摄影', 2)]),
];

/// Thread titles with their author (name, uid).
const _threads = <(String, String, int)>[
  ('十月新番播出时间表整理（持续更新）', 'Dave', 1004),
  ('求推荐几部轻松的日常番', 'Erin', 1005),
  ('分享一下我的手办收藏', 'Frank', 1006),
  ('这季度你在追哪几部？', 'Grace', 1007),
  ('关于字幕组时间轴的小问题', 'Dave', 1004),
  ('新人报到，请多关照', 'Heidi', 1008),
  ('你最喜欢的片头曲是哪首？', 'Grace', 1007),
  ('第 3 集的伏笔是不是太明显了', 'Heidi', 1008),
  ('原作党来聊聊改编的取舍', 'Erin', 1005),
  ('这部的作画水准讨论', 'Dave', 1004),
  ('结局到底算不算圆满', 'Grace', 1007),
  ('秋季同人绘画征集', 'Carol', 1003),
];

/// Seconds of a forum time [minutesAgo] minutes before 2026-10-23 15:00 at +8.
int _ago(int minutesAgo) =>
    DateTime.utc(2026, 10, 23, 7).subtract(Duration(minutes: minutesAgo)).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp/$name').readAsStringSync()) as Map<String, dynamic>;

/// The forum index of the app API (schema 5), for a guest or Alice.
Map<String, dynamic> _index({required bool guest}) {
  final json = _fixture(guest ? 'index_v5_guest.json' : 'index_v5_member.json')..remove('document');
  final uid = guest ? 0 : _alice.uid!;
  var tid = 3000;
  return json
    ..['uid'] = uid
    ..['user'] = {'uid': uid, 'username': guest ? '' : _alice.username, 'avatar': ''}
    ..['unread'] = {'notice': guest ? 0 : 2, 'pm': guest ? 0 : 1}
    ..['stats'] = {'todayposts': 1288, 'yesterdayposts': 3460, 'posts': 2827744, 'members': 221806, 'newest': 'Momo'}
    ..['links'] = [
      {'title': '我的帖子', 'url': 'home.php?mod=space&do=thread&view=me'},
    ]
    ..['categories'] = [
      for (final (gid, name, forums) in _groups)
        {
          'fid': gid,
          'name': name,
          'moderators': ['Carol', 'Dave'],
          'forums': [
            for (final (fid, forumName, today) in forums)
              {
                'fid': fid,
                'name': forumName,
                'description': '',
                'description_html': '',
                'threads': 1200 + fid * 37,
                'posts': 48000 + fid * 911,
                'todayposts': today,
                'icon': '',
                'lastpost': {
                  'tid': 3000 + fid,
                  'subject': _threads[fid % _threads.length].$1,
                  'author': _threads[fid % _threads.length].$2,
                  'authorid': _threads[fid % _threads.length].$3,
                  'dateline': _ago(fid * 7),
                },
                'subforums': <Object>[],
                'redirect': '',
                'private': 0,
              },
          ],
        },
    ]
    ..['favorite_forums'] = <Object>[]
    ..['favorites'] = <Object>[]
    ..['blocks'] = [
      for (final (id, title) in [(1, '最新活动'), (2, '最新主题'), (3, '今日话题'), (4, '动漫新闻')])
        {
          'id': id,
          'title': title,
          'rows': [
            for (final (title, author, authorUid) in _threads.skip(id).take(5))
              {
                'title': title,
                'url': 'forum.php?mod=viewthread&tid=${tid++}',
                'author': author,
                'author_url': 'home.php?mod=space&uid=$authorUid',
                'tag': '',
              },
          ],
        },
    ]
    ..['blocks_html'] = ''
    ..['slides'] = <Object>[]
    ..remove('red_packet');
}

/// A thread row of the app API, from the first row of a fixture.
Map<String, dynamic> _threadRow(Map<String, dynamic> template, int i, {int fid = 11, int displayorder = 0}) {
  final (title, author, uid) = _threads[i % _threads.length];
  return Map<String, dynamic>.of(template)
    ..['tid'] = 4000 + i
    ..['fid'] = fid
    ..['subject'] = title
    ..['author'] = author
    ..['authorid'] = uid
    ..['dateline'] = _ago(30 + i * 45)
    ..['lastpost'] = _ago(i * 9 + 1)
    ..['lastposter'] = _threads[(i + 3) % _threads.length].$2
    ..['views'] = 300 + i * 97
    ..['replies'] = 4 + i * 3
    ..['displayorder'] = displayorder
    ..['typeid'] = 0
    ..['typename'] = ''
    ..['digest'] = i == 2 ? 1 : 0
    ..['attachment'] = 0
    ..['price'] = 0
    ..['special'] = 0
    ..['closed'] = 0;
}

/// The guide index (schema 7) with synthetic threads in every module.
Map<String, dynamic> _guide({required bool guest}) {
  final json = _fixture('guide_v7_index_guest.json')..['uid'] = guest ? 0 : _alice.uid;
  final modules = (json['modules'] as List).cast<Map<String, dynamic>>();
  for (final (m, module) in modules.indexed) {
    final threads = (module['threads'] as List).cast<Map<String, dynamic>>();
    if (threads.isEmpty) {
      continue;
    }
    final template = threads.first;
    module['threads'] = [
      for (var i = 0; i < 6; i++)
        Map<String, dynamic>.of(template)
          ..['tid'] = 5000 + m * 10 + i
          ..['fid'] = 11
          ..['forum'] = '新番讨论'
          ..['subject'] = _threads[(m + i) % _threads.length].$1
          ..['subject_html'] = _threads[(m + i) % _threads.length].$1
          ..['author'] = _threads[(m + i) % _threads.length].$2
          ..['authorid'] = _threads[(m + i) % _threads.length].$3
          ..['dateline'] = _ago(60 + i * 30)
          ..['lastpost'] = _ago(i * 11 + 2)
          ..['lastposter'] = 'Carol'
          ..['replies'] = 12 + i * 5
          ..['views'] = 480 + i * 77
          ..['price'] = 0
          ..['extra'] = '',
    ];
  }
  return json;
}

/// Alice's own profile (schema 4).
Map<String, dynamic> _profile() {
  final json = _fixture('profile_v4_self.json')..remove('document');
  json['uid'] = _alice.uid;
  (json['user'] as Map<String, dynamic>)
    ..['uid'] = _alice.uid
    ..['username'] = _alice.username
    ..['group'] = '中级天使'
    // Offline in the tests: the avatar falls back to the initial.
    ..['avatar'] = '$baseUrl/uc_server/data/avatar/000/00/10/00_avatar_middle.jpg';
  ((json['groups'] as Map<String, dynamic>)['member'] as Map<String, dynamic>)['title'] = '中级天使';
  json['profile_html'] = '';
  return json;
}

/// The forum 新番讨论 (schema 2) as [uid] sees it, posting allowed or not.
Map<String, dynamic> _forum({required int uid, required bool allowPost}) {
  final json = _fixture('forum_v2_fid2.json')..remove('document');
  final template = (json['threads'] as List).cast<Map<String, dynamic>>().first;
  json['uid'] = uid;
  (json['forum'] as Map<String, dynamic>)
    ..['fid'] = 11
    ..['name'] = '新番讨论'
    ..['rules'] = ''
    ..['moderators'] = ['Carol', 'Dave']
    ..['allow_post'] = allowPost ? 1 : 0
    ..['allow_poll'] = 0;
  json
    ..['subforums'] = <Object>[]
    ..['page'] = 1
    ..['pages'] = 3
    ..['threads'] = [
      _threadRow(template, 0, displayorder: 1),
      for (var i = 1; i < 12; i++) _threadRow(template, i),
    ];
  return json;
}

/// Answers the pages of the synthetic forum: the index, the guide, Alice's profile and the forum 新番讨论; images and
/// anything else are offline.
final class _ForumAdapter implements HttpClientAdapter {
  _ForumAdapter({required this.guest});

  /// The answers are a guest's.
  bool guest;

  /// The forum lets the account post.
  bool allowPost = true;

  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    final q = uri.queryParameters;
    final Map<String, dynamic>? json = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == null => _index(guest: guest),
      'forum.php' when q['mod'] == 'guide' => _guide(guest: guest),
      'forum.php' when q['mod'] == 'forumdisplay' => _forum(uid: guest ? 0 : _alice.uid!, allowPost: allowPost),
      'home.php' when !guest && q['mod'] == 'space' && q['uid'] == '${_alice.uid}' => _profile(),
      _ => null,
    };
    if (json == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromString(
      jsonEncode(json),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Authentication with the account the test sets.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  @override
  UserLoginInfo? get effectiveCurrentUser => currentUser;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  AuthStatus? get latestStatus => null;

  @override
  int get identityEpoch => 0;

  @override
  AsyncVoidEither loginWithDocument(uh.Document document, {int? fetchedAs, int? epoch}) =>
      AsyncVoidEither(() async => rightVoid());

  @override
  AsyncVoidEither loginWithServedUser(UserLoginInfo? user, {required bool guest, int? fetchedAs, int? epoch}) =>
      AsyncVoidEither(() async => rightVoid());

  Future<void> close() => _controller.close();
}

/// The notification bloc: a fixed state, events dropped.
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

NoticeV2 _notice(int id, String note, {required String type, int authorId = 0, String author = '', int minutes = 3}) =>
    Notice.toV2FromApi({
      'id': id,
      'new': minutes < 60 ? 1 : 0,
      'type': type,
      'category': authorId == 0 ? 3 : 1,
      'authorid': authorId,
      'author': author,
      'note': note,
      'text': '',
      'dateline': _ago(minutes),
      'from_id': 0,
      'from_idtype': type,
      'from_num': 1,
    }, timeOffset: 8)!;

List<NoticeV2> _notices() => [
  _notice(
    1,
    '<a href="home.php?mod=space&uid=1004">Dave</a> 回复了您的帖子 '
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=4001&pid=7001" target="_blank">求推荐几部轻松的日常番</a>',
    type: 'post',
    authorId: 1004,
    author: 'Dave',
  ),
  _notice(
    2,
    '<a href="home.php?mod=space&uid=1007">Grace</a> 在主题 '
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=4003&pid=7002" target="_blank">这季度你在追哪几部？</a> '
    '中提到了您',
    type: 'at',
    authorId: 1007,
    author: 'Grace',
    minutes: 42,
  ),
  _notice(
    3,
    '您在主题 <a href="forum.php?mod=redirect&goto=findpost&pid=7003&ptid=4005" target="_blank">新人报到，请多关照</a> '
    '的帖子被 <a href="home.php?mod=space&uid=1003">Carol</a> 评分 威望 +1',
    type: 'rate',
    authorId: 1003,
    author: 'Carol',
    minutes: 60 * 20,
  ),
  _notice(
    4,
    '您发表的主题 <a href="forum.php?mod=viewthread&tid=4007" target="_blank">原作党来聊聊改编的取舍</a> 已由管理团队 审核通过！',
    type: 'system',
    minutes: 60 * 50,
  ),
];

/// A few frames with real time in between, for the database and the fake network.
Future<void> _settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Stand-in of a page opened above the shell: its path and query.
class _Stub extends StatelessWidget {
  const _Stub(this.path, this.state);

  final String path;
  final GoRouterState state;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('stub $path')),
    body: Text('at ${state.uri}', key: ValueKey('stub $path')),
  );
}

/// The pages the tests open above the shell, as stand-ins.
const _stubPaths = [
  ScreenPaths.threadV1,
  ScreenPaths.login,
  ScreenPaths.myThread,
  ScreenPaths.favorite,
  ScreenPaths.threadVisitHistory,
  ScreenPaths.friend,
  ScreenPaths.points,
  ScreenPaths.medalTitleHub,
  ScreenPaths.activities,
  ScreenPaths.medalCenter,
  ScreenPaths.titleShop,
  ScreenPaths.bank,
  ScreenPaths.pokemon,
  ScreenPaths.achievements,
  ScreenPaths.manageAccount,
  ScreenPaths.about,
  ScreenPaths.loggedUserProfile,
  ScreenPaths.editPost,
  ScreenPaths.createPoll,
  ScreenPaths.search,
  ScreenPaths.rootNotice,
  ScreenPaths.userBlock,
  ScreenPaths.openInApp,
];

/// The app's router shape: the home shell with its four tabs (built by [tab]), the forum page, the settings and
/// stand-ins for the other pages.
GoRouter _router({required String initial, required Widget Function(HomeTab tab) tab, PopupRouteObserver? popups}) =>
    GoRouter(
      initialLocation: initial,
      observers: [?popups],
      routes: [
        StatefulShellRoute(
          builder: (context, state, navigator) => HomePage(showNavigationBar: true, child: navigator),
          navigatorContainerBuilder: (context, shell, children) =>
              AnimatedBranchPageView(navigationShell: shell, children: children),
          branches: [
            for (final t in HomeTab.values)
              StatefulShellBranch(
                routes: [AppRoute(path: homeTabPath(t), builder: (_) => tab(t))],
              ),
          ],
        ),
        AppRoute(
          path: ScreenPaths.forum,
          builder: (s) => ForumPage(fid: s.pathParameters['fid']!, title: s.uri.queryParameters['appBarTitle']),
        ),
        AppRoute(path: ScreenPaths.settings.path, builder: (s) => _Stub(ScreenPaths.settings.path, s)),
        for (final path in _stubPaths) AppRoute(path: path, builder: (s) => _Stub(path, s)),
      ],
    );

/// Placeholder pages of the four tabs.
Widget _placeholderTab(HomeTab tab) => Scaffold(body: Center(child: Text('tab ${tab.name}')));

/// The real pages of the four tabs.
Widget _realTab(HomeTab tab) => switch (tab) {
  HomeTab.home => const HomepagePage(),
  HomeTab.topic => const TopicsPage(),
  HomeTab.notice => const NotificationPage(asTab: true),
  HomeTab.me => const MePage(),
};

/// The app around the pages: repositories, blocs, network and storage, Alice logged in or a guest.
final class _App {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late _Auth auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;
  late _ForumAdapter adapter;
  late GoRouter router;

  final _closers = <Future<void> Function()>[];

  Future<void> setUp({required bool guest}) async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _ForumAdapter(guest: guest);
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
    if (!guest) {
      await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    }
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = _Auth(guest ? null : _alice);
    info = NotificationInfoRepository();
    counts = NotificationStateCubit(info);
  }

  Future<void> tearDown() async {
    for (final close in _closers.reversed) {
      await close();
    }
    _closers.clear();
    await info.dispose();
    await counts.close();
    await settingsBloc.close();
    await blocks.dispose();
    await auth.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  }

  /// Pump the app at [initial] in a [size] window (logical pixels at [ratio]), the tabs built by [tab].
  Future<void> pump(
    WidgetTester tester, {
    required String initial,
    Widget Function(HomeTab tab) tab = _placeholderTab,
    Size size = const Size(411, 868),
    double ratio = 1,
    ThemeData? theme,
    Key? boundary,
    PopupRouteObserver? popups,
  }) async {
    tester.view
      ..physicalSize = size * ratio
      ..devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    router = _router(initial: initial, tab: tab, popups: popups);
    final init = InitCubit()..skipAutoClearImageCache();
    final checkin = CheckinBloc(
      checkinRepository: CheckinRepository(storageProvider: storage),
      authenticationRepository: auth,
      settingsRepository: settings,
    );
    final blockCubit = UserBlockCubit(
      repository: blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    final auto = AutoNotificationCubit(
      authenticationRepository: auth,
      notificationRepository: NotificationRepository(storageProvider: storage),
      storageProvider: storage,
    );
    final notifications = _Notifications(
      auth.currentUser == null
          ? const NotificationState()
          : NotificationState(status: NotificationStatus.success, noticeList: _notices(), ownerUid: _alice.uid),
    );
    final accounts = CurrentAccountCubit(
      currentUser: () => auth.currentUser,
      authStatus: auth.status,
      accounts: Stream.value([if (auth.currentUser != null) _alice, const UserLoginInfo(username: 'Bob', uid: 1001)]),
    );
    final forumHome = ForumHomeRepository();
    _closers.addAll([
      () async => router.dispose(),
      init.close,
      checkin.close,
      blockCubit.close,
      auto.close,
      notifications.close,
      accounts.close,
      forumHome.dispose,
    ]);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<NotificationInfoRepository>.value(value: info),
            RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
            RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<InitCubit>.value(value: init),
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: blockCubit),
              BlocProvider<CheckinBloc>.value(value: checkin),
              BlocProvider<NotificationBloc>.value(value: notifications),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              BlocProvider<AutoNotificationCubit>.value(value: auto),
              BlocProvider<CurrentAccountCubit>.value(value: accounts),
            ],
            child: RepaintBoundary(
              key: boundary,
              child: Builder(
                builder: (context) => MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  theme: theme,
                  routerConfig: router,
                  scaffoldMessengerKey: snackbarKey,
                  locale: TranslationProvider.of(context).flutterLocale,
                  supportedLocales: AppLocaleUtils.supportedLocales,
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  builder: (_, child) => ResponsiveBreakpoints.builder(
                    breakpoints: WindowSize.values
                        .map((e) => Breakpoint(start: e.start, end: e.end, name: e.name))
                        .toList(),
                    child: child!,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    if (auth.currentUser != null) {
      // Set once the app is up: the counts start from what the storage holds.
      counts.setAll(noticeCount: 2, personalMessageCount: 1, broadcastMessageCount: 0);
      await _settle(tester, rounds: 2);
    }
  }

  String? get top => routerTopLocation(router);

  List<String?> get stack => router.routerDelegate.navigatorKey.currentState!.widget.pages.map((p) => p.name).toList();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _App app;
  late DateTime now;

  setUp(() {
    app = _App();
    now = DateTime(2026, 10, 23, 15);
    HomeTabDoubleTapDetector.clock = () => now;
  });

  tearDown(() async {
    HomeTabDoubleTapDetector.clock = DateTime.now;
    noticePageTabRequest.value = null;
  });

  Future<void> tapText(WidgetTester tester, String text) async {
    now = now.add(const Duration(seconds: 1));
    await tester.tap(find.text(text).last);
    await _settle(tester, rounds: 8);
  }

  group('four tabs', () {
    setUp(() async => app.setUp(guest: false));
    tearDown(() async => app.tearDown());

    testWidgets('phone: home, forums, notifications and me; the bar follows', (tester) async {
      await app.pump(tester, initial: ScreenPaths.homepage);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(4));
      for (final (i, (label, tab)) in [
        (tr.navigation.topics, HomeTab.topic),
        (tr.navigation.notice, HomeTab.notice),
        (tr.navigation.me, HomeTab.me),
        (tr.navigation.homepage, HomeTab.home),
      ].indexed) {
        await tapText(tester, label);
        expect(app.top, homeTabPath(tab), reason: '$i: $label');
        expect(find.text('tab ${tab.name}'), findsOneWidget);
        expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, tab.index);
      }
      expect(find.text(tr.navigation.settings), findsNothing, reason: 'the settings are no tab any more');
      expect(tester.takeException(), isNull);
    });

    for (final (name, size, type) in [
      ('tablet', const Size(800, 1280), NavigationRail),
      ('desktop', const Size(1440, 900), NavigationDrawer),
    ]) {
      testWidgets('$name: the same four tabs on the side', (tester) async {
        await app.pump(tester, initial: ScreenPaths.homepage, size: size);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(type), findsOneWidget);
        for (final label in [tr.navigation.homepage, tr.navigation.topics, tr.navigation.notice, tr.navigation.me]) {
          expect(
            find.descendant(of: find.byType(type), matching: find.text(label)),
            findsOneWidget,
            reason: label,
          );
        }
        expect(find.descendant(of: find.byType(type), matching: find.text(tr.bank.title)), findsNothing);
        await tapText(tester, tr.navigation.me);
        expect(app.top, ScreenPaths.me);
        expect(find.text('tab me'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('back on another tab shows the homepage first', (tester) async {
      await app.pump(tester, initial: ScreenPaths.homepage);
      for (final label in [tr.navigation.topics, tr.navigation.notice, tr.navigation.me]) {
        await tapText(tester, label);
        await tester.binding.handlePopRoute();
        await _settle(tester, rounds: 4);
        expect(app.top, ScreenPaths.homepage, reason: 'back on $label');
        expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.home.index);
      }
    });

    testWidgets('a page opened from a tab goes back to that tab', (tester) async {
      await app.pump(tester, initial: ScreenPaths.me);
      unawaited(app.router.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '4001'}));
      await _settle(tester, rounds: 8);
      expect(app.top, ScreenPaths.threadV1);
      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(app.top, ScreenPaths.me);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.me.index);
    });

    testWidgets('the unread count on the notifications tab, three digits as 99+', (tester) async {
      await app.pump(tester, initial: ScreenPaths.homepage);
      Finder badge(String text) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.descendant(of: find.byType(Badge), matching: find.text(text)),
      );
      expect(badge('3'), findsOneWidget);
      app.counts.setAll(noticeCount: 120, personalMessageCount: 0, broadcastMessageCount: 0);
      await _settle(tester, rounds: 2);
      expect(badge('99+'), findsOneWidget);
      app.counts.setAll(noticeCount: 0, personalMessageCount: 0, broadcastMessageCount: 0);
      await _settle(tester, rounds: 2);
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)), findsNothing);
    });

    testWidgets('a notification tap: the reading pages close, the notifications tab shows', (tester) async {
      await app.pump(tester, initial: ScreenPaths.topic);
      unawaited(app.router.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '4001'}));
      await _settle(tester, rounds: 4);
      final (:top, :action) = openNoticePageForTap(app.router, loggedIn: true, hasPopup: false);
      await _settle(tester, rounds: 4);
      expect((top, action), (ScreenPaths.threadV1, LocalNoticeTapAction.showNoticeTab));
      expect(app.stack, hasLength(1));
      expect(app.top, ScreenPaths.notice);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.notice.index);
    });

    testWidgets('a link opened in the app is a page above the shell, back returns to the tab', (tester) async {
      await app.pump(tester, initial: ScreenPaths.topic);
      // What the deep link channel does with a forum url.
      unawaited(
        app.router.pushNamed(ScreenPaths.openInApp, queryParameters: {'url': '$baseUrl/forum.php', 'autoOpen': 'true'}),
      );
      await _settle(tester, rounds: 4);
      expect(app.top, ScreenPaths.openInApp);
      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(app.top, ScreenPaths.topic);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.topic.index);
    });
  });

  group('the me tab', () {
    group('with an account', () {
      setUp(() async => app.setUp(guest: false));
      tearDown(() async => app.tearDown());

      testWidgets('the account card, the pages of the account, the services and the app', (tester) async {
        await app.pump(tester, initial: ScreenPaths.me, tab: _realTab);
        expect(find.byKey(const ValueKey('me-account-card')), findsOneWidget);
        expect(find.text('Alice'), findsWidgets);
        expect(find.text(tr.mePage.uid(uid: 1000)), findsOneWidget);
        expect(find.text('中级天使'), findsOneWidget, reason: 'the user group of the profile');
        for (final key in [
          'me-my-threads',
          'me-favorites',
          'me-history',
          'me-drafts',
          'me-messages',
          'me-friends',
          'me-points',
          'me-medals',
          'me-switch-account',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        final list = find.byKey(const ValueKey('me-page-list'));
        for (final key in [
          'me-activities',
          'me-medal-center',
          'me-title-shop',
          'me-bank',
          'me-pokemon',
          'me-achievements',
          'me-manage-accounts',
          'me-settings',
          'me-about',
        ]) {
          await tester.scrollUntilVisible(
            find.byKey(ValueKey(key)),
            200,
            scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first,
          );
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        expect(tester.takeException(), isNull);
      });

      for (final (key, path, query) in [
        ('me-my-threads', ScreenPaths.myThread, ''),
        ('me-drafts', ScreenPaths.myThread, '?tab=drafts'),
        ('me-favorites', ScreenPaths.favorite, ''),
        ('me-history', ScreenPaths.threadVisitHistory, ''),
        ('me-friends', ScreenPaths.friend, ''),
        ('me-points', ScreenPaths.points, ''),
        ('me-account-profile', ScreenPaths.loggedUserProfile, ''),
        ('me-settings', ScreenPaths.settings.path, ''),
        ('me-about', ScreenPaths.about, ''),
        ('me-bank', ScreenPaths.bank, ''),
      ]) {
        testWidgets('$key opens $path$query above the shell', (tester) async {
          await app.pump(tester, initial: ScreenPaths.me, tab: _realTab);
          final entry = find.byKey(ValueKey(key));
          await tester.scrollUntilVisible(
            entry,
            200,
            scrollable: find
                .descendant(of: find.byKey(const ValueKey('me-page-list')), matching: find.byType(Scrollable))
                .first,
          );
          await tester.ensureVisible(entry);
          await _settle(tester, rounds: 2);
          await tester.tap(entry);
          await _settle(tester, rounds: 4);
          expect(app.top, path);
          expect(find.text('at $path$query'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await _settle(tester, rounds: 4);
          expect(app.top, ScreenPaths.me);
        });
      }

      testWidgets('the private messages: the notifications tab, on its private messages', (tester) async {
        await app.pump(tester, initial: ScreenPaths.me, tab: _realTab);
        await tester.tap(find.byKey(const ValueKey('me-messages')));
        await _settle(tester, rounds: 6);
        expect(app.top, ScreenPaths.notice);
        expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.notice.index);
        final tabs = tester.widget<TabBar>(find.byType(TabBar));
        expect(tabs.controller!.index, NoticePageTab.personalMessage.index);
        expect(noticePageTabRequest.value, isNull, reason: 'taken by the page');

        // Asked again while the page lives (it was left on another tab meanwhile).
        tabs.controller!.index = 0;
        await tapText(tester, tr.navigation.me);
        await tester.tap(find.byKey(const ValueKey('me-messages')));
        await _settle(tester, rounds: 6);
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, NoticePageTab.personalMessage.index);
      });

      testWidgets('switch account: every saved account, the one in use marked, add and manage', (tester) async {
        await tester.runAsync(() async {
          for (final user in [_alice, const UserLoginInfo(username: 'Bob', uid: 1001)]) {
            await app.storage.saveCookie(
              username: user.username!,
              uid: user.uid!,
              cookie: {
                '.index': '["$baseHost"]',
                baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${user.uid}; Path=/;_crt=1"}}',
              },
            );
          }
        });
        await app.pump(tester, initial: ScreenPaths.me, tab: _realTab);
        await tester.tap(find.byKey(const ValueKey('me-switch-account')));
        await _settle(tester, rounds: 6);
        expect(find.byType(AccountSwitchDialog), findsOneWidget);
        expect(find.byKey(const ValueKey('account-switch-1000')), findsOneWidget);
        expect(find.byKey(const ValueKey('account-switch-1001')), findsOneWidget);
        expect(find.text(tr.mePage.inUse), findsOneWidget);
        expect(find.byKey(const ValueKey('account-switch-add')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('account-switch-manage')));
        await _settle(tester, rounds: 4);
        expect(app.top, ScreenPaths.manageAccount);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    });

    group('as a guest', () {
      setUp(() async => app.setUp(guest: true));
      tearDown(() async => app.tearDown());

      testWidgets('the login, the settings and about, nothing of an account', (tester) async {
        await app.pump(tester, initial: ScreenPaths.me, tab: _realTab);
        expect(find.byKey(const ValueKey('me-guest-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('me-account-card')), findsNothing);
        expect(find.byKey(const ValueKey('me-my-threads')), findsNothing);
        expect(find.byKey(const ValueKey('me-manage-accounts')), findsNothing);
        expect(find.byKey(const ValueKey('me-settings')), findsOneWidget);
        expect(find.byKey(const ValueKey('me-about')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('me-login')));
        await _settle(tester, rounds: 4);
        expect(app.top, ScreenPaths.login);
      });

      testWidgets('the notifications tab asks for a login itself', (tester) async {
        await app.pump(tester, initial: ScreenPaths.notice, tab: _realTab);
        expect(find.byKey(const ValueKey('notice-page-guest')), findsOneWidget);
        expect(find.text(tr.noticePage.guestHint), findsOneWidget);
        await tester.tap(find.text(tr.loginPage.login));
        await _settle(tester, rounds: 4);
        expect(app.top, ScreenPaths.login);
      });
    });
  });

  group('the notice page', () {
    setUp(() async => app.setUp(guest: false));
    tearDown(() async => app.tearDown());

    testWidgets('as the tab: no "back to the homepage" button; opened above other pages: the button', (tester) async {
      await app.pump(tester, initial: ScreenPaths.notice, tab: _realTab);
      expect(find.byType(BackToHomeButton), findsNothing);
      expect(find.text('Dave'), findsWidgets, reason: 'the notices are listed');

      app.router.go(ScreenPaths.homepage);
      await _settle(tester, rounds: 4);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a double tap on its tab scrolls the list in view to top', (tester) async {
      await app.pump(tester, initial: ScreenPaths.notice, tab: _realTab, size: const Size(411, 420));
      final list = find
          .descendant(
            of: find.byType(TabBarView),
            matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down),
          )
          .first;
      await tester.drag(list, const Offset(0, -200));
      await _settle(tester, rounds: 2);
      expect(tester.state<ScrollableState>(list).position.pixels, greaterThan(0));
      await tapText(tester, tr.navigation.notice);
      now = now.add(const Duration(milliseconds: 100));
      await tester.tap(find.text(tr.navigation.notice).last);
      await _settle(tester, rounds: 6);
      expect(tester.state<ScrollableState>(list).position.pixels, 0);
    });
  });

  group('the homepage of a guest', () {
    setUp(() async => app.setUp(guest: true));
    tearDown(() async => app.tearDown());

    testWidgets('no login wall: the login card, the support entry, the forums and the guide', (tester) async {
      await app.pump(tester, initial: ScreenPaths.homepage, tab: _realTab);
      expect(find.text(tr.general.needLoginToSeeThisPage), findsNothing);
      expect(find.byKey(const ValueKey('homepage-guest-card')), findsOneWidget);
      expect(find.text(tr.homepage.guest.title), findsOneWidget);
      expect(find.text(tr.aboutPage.supportDevelopment), findsWidgets, reason: 'the support entry keeps its place');
      final entries = find.byKey(const ValueKey('homepage-forum-entries'));
      expect(entries, findsOneWidget);
      // Every group as a tab, the forums of the first one as entries.
      for (final (_, name, _) in _groups) {
        expect(
          find.descendant(of: entries, matching: find.text(name)),
          findsOneWidget,
          reason: name,
        );
      }
      expect(find.descendant(of: entries, matching: find.text('新人报到')), findsOneWidget);
      await tester.tap(find.descendant(of: entries, matching: find.text('动漫天地')));
      await tester.pump();
      expect(find.descendant(of: entries, matching: find.text('新番讨论')), findsOneWidget);
      await tester.tap(find.descendant(of: entries, matching: find.text('新番讨论')));
      await _settle(tester, rounds: 6);
      expect(app.top, ScreenPaths.forum.replaceFirst(':fid', '11'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the guide is there, and "all forums" shows the forums tab', (tester) async {
      await app.pump(tester, initial: ScreenPaths.homepage, tab: _realTab);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text(_threads[1].$1).first, 300, scrollable: list);
      expect(find.text(_threads[1].$1), findsWidgets, reason: 'a thread of the guide');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('homepage-guest-login')), -300, scrollable: list);
      await tester.tap(find.text(tr.homepage.guest.allForums).first);
      await _settle(tester, rounds: 6);
      expect(app.top, ScreenPaths.topic);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.topic.index);
    });

    testWidgets('the login button opens the login page', (tester) async {
      await app.pump(tester, initial: ScreenPaths.homepage, tab: _realTab);
      await tester.tap(find.byKey(const ValueKey('homepage-guest-login')));
      await _settle(tester, rounds: 4);
      expect(app.top, ScreenPaths.login);
    });
  });

  group('the post button of a forum', () {
    test('the permission the forum gives: member yes or no, unknown for a guest and an older answer', () {
      Map<String, dynamic> answer({required int uid, Object? allow}) {
        final json = _forum(uid: uid, allowPost: true);
        final forum = json['forum'] as Map<String, dynamic>;
        if (allow == null) {
          forum.remove('allow_post');
        } else {
          forum['allow_post'] = allow;
        }
        return json;
      }

      expect(forumPageFromApi(answer(uid: 1000, allow: 1), '11').postAllowed, isTrue);
      expect(forumPageFromApi(answer(uid: 1000, allow: 0), '11').postAllowed, isFalse);
      expect(forumPageFromApi(answer(uid: 0, allow: 0), '11').postAllowed, isNull, reason: 'a guest needs to log in');
      expect(forumPageFromApi(answer(uid: 1000), '11').postAllowed, isNull, reason: 'an older plugin');
    });

    Finder button() => find.byKey(const ValueKey('forum-new-thread'));
    bool extended(WidgetTester tester) => tester.widget<FloatingActionButton>(button()).isExtended;

    Future<void> openForum(WidgetTester tester) async {
      await app.pump(tester, initial: '/forum/11?appBarTitle=新番讨论', tab: _placeholderTab);
      expect(button(), findsOneWidget);
    }

    group('with an account', () {
      setUp(() async => app.setUp(guest: false));
      tearDown(() async => app.tearDown());

      testWidgets('labelled, folded while scrolling down, unfolded scrolling up; opens the editor', (tester) async {
        await openForum(tester);
        expect(find.descendant(of: button(), matching: find.text(tr.forumPage.newThread.label)), findsOneWidget);
        expect(extended(tester), isTrue);
        final list = find.byType(CustomScrollView).first;
        await tester.drag(list, const Offset(0, -300));
        await _settle(tester, rounds: 2);
        expect(button(), findsOneWidget, reason: 'still there');
        expect(extended(tester), isFalse);
        await tester.drag(list, const Offset(0, 100));
        await _settle(tester, rounds: 2);
        expect(extended(tester), isTrue);

        await tester.tap(button());
        await _settle(tester, rounds: 4);
        expect(app.top, '/editPost/0/11');
      });

      testWidgets('the forum does not let the account post: told why, no editor', (tester) async {
        app.adapter.allowPost = false;
        await openForum(tester);
        await tester.tap(button());
        await _settle(tester, rounds: 4);
        expect(find.text(tr.forumPage.newThread.noPermissionTitle), findsOneWidget);
        expect(find.text(tr.forumPage.newThread.noPermissionMessage), findsOneWidget);
        expect(app.top, '/forum/11');
      });
    });

    group('as a guest', () {
      setUp(() async => app.setUp(guest: true));
      tearDown(() async => app.tearDown());

      testWidgets('told to log in, with the login', (tester) async {
        await openForum(tester);
        await tester.tap(button());
        await _settle(tester, rounds: 4);
        expect(find.text(tr.forumPage.newThread.guestTitle), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, tr.loginPage.login));
        await _settle(tester, rounds: 4);
        expect(app.top, ScreenPaths.login);
      });
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['NAV_SHOTS_DIR'];
    final font = Platform.environment['NAV_SHOTS_FONT'];
    final skip = dir == null || font == null ? 'set NAV_SHOTS_DIR and NAV_SHOTS_FONT to write them' : null;
    const family = 'ShotSans';

    setUpAll(() async {
      if (skip != null) {
        return;
      }
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())))).load();
      final root = Platform.environment['FLUTTER_ROOT'];
      final icons = root == null ? null : '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
      if (icons != null && File(icons).existsSync()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(File(icons).readAsBytesSync())))).load();
      }
    });

    ThemeData theme({required bool dark}) => dark
        ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: family)
        : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: family);

    const shotKey = ValueKey('shot');

    Future<void> capture(WidgetTester tester, String name, double ratio) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: ratio)))!;
      final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      image.dispose();
      Directory(dir!).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    }

    /// (name, logical size, pixel ratio): a 1080x2280 phone, a 1600x2560 tablet.
    const devices = [('phone', Size(1080 / 2.625, 2280 / 2.625), 2.625), ('tablet', Size(800, 1280), 2.0)];

    /// (name, guest, location).
    const pages = [
      ('home', false, ScreenPaths.homepage),
      ('forums', false, ScreenPaths.topic),
      ('notice', false, ScreenPaths.notice),
      ('me', false, ScreenPaths.me),
      ('me_guest', true, ScreenPaths.me),
      ('home_guest', true, ScreenPaths.homepage),
      ('forum_fab', false, '/forum/11?appBarTitle=新番讨论'),
    ];

    for (final guest in [false, true]) {
      group(guest ? 'guest' : 'account', () {
        setUp(() async => app.setUp(guest: guest));
        tearDown(() async => app.tearDown());

        for (final (page, pageGuest, location) in pages.where((e) => e.$2 == guest)) {
          for (final (device, size, ratio) in devices) {
            for (final dark in [false, true]) {
              final name = '${page}_${device}_${dark ? 'dark' : 'light'}';
              testWidgets(name, skip: skip != null || pageGuest != guest, (tester) async {
                await app.pump(
                  tester,
                  initial: location,
                  tab: _realTab,
                  size: size,
                  ratio: ratio,
                  theme: theme(dark: dark),
                  boundary: shotKey,
                );
                // Real shadows instead of the outlines tests draw for them, for this capture only.
                debugDisableShadows = false;
                await _settle(tester, rounds: 20);
                await capture(tester, name, ratio);
                debugDisableShadows = true;
                await tester.pumpWidget(const SizedBox());
                await tester.pump(const Duration(seconds: 5));
              });
            }
          }
        }
      });
    }
  });
}

final class _FakeContext extends Fake implements BuildContext {}
