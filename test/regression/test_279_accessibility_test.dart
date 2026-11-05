/// Accessibility of the main pages, checked against the guidelines of `flutter_test`:
///
/// * [androidTapTargetGuideline]: anything that takes a tap is at least 48x48;
/// * [labeledTapTargetGuideline]: anything that takes a tap has a label (a tooltip or a semantics label);
/// * [textContrastGuideline]: the text keeps the WCAG AA contrast against what is behind it, in the light and the
///   dark theme.
///
/// The pages: the homepage, a forum, a thread (floor cards and the reply bar), the notifications, the settings, the
/// login, the editor toolbar, the author card of a floor and the search. Synthetic accounts and pages only: no
/// network, no login, nothing is sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/view/login_page.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _tid = 1264975;

/// A phone, 1.0 scale.
const _phone = Size(390, 844);

String _data(String name) => File('test/data/$name').readAsStringSync();

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

// ---------------------------------------------------------------------------------------------------------------------
// The forum.

/// A table wider than a phone, in the first floor: the button opening it in a page of its own is on the page.
final _wideTable = '<table><tr>${'<td>a wide table cell</td>' * 8}</tr></table>';

/// A floor of the synthetic thread (test_270), with a reply link so the floor has its own action row.
String _floor(int floor) {
  final pid = 9700000 + floor;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text<br />${'line<br />' * 3}
${floor == 1 ? _wideTable : ''}
</div></div></div>
<div class="pob"><em><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$_tid&amp;repquote=$pid">回复</a></em></div>
</td>
</tr></tbody></table></div>''';
}

/// A thread of 3 pages, 10 floors each: page [page].
String _threadPage(int page) {
  final pager =
      '<div class="pg">${[
        for (var i = 1; i <= 3; i++) i == page ? '<strong>$i</strong>' : '<a href="forum.php?mod=viewthread&tid=$_tid&page=$i">$i</a>',
      ].join()}<label><input type="text" name="custompage"/><span title="共 3 页"> / 3 页</span></label></div>';
  return '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$_tid" /></head><body>
$pager
<div id="postlist"><table><tr><td><span class="xi1">100</span><span class="xi1">29</span></td></tr></table>
<h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${[for (var f = (page - 1) * 10 + 1; f <= page * 10; f++) _floor(f)].join('\n')}
</div></div>
</body></html>''';
}

/// The author link of a thread row of the homepage.
const _carol = '<a href="home.php?mod=space&amp;uid=1003" target="_blank"><em>Carol</em></a>';

/// `forum.php` of Alice: the status bar and the pinned thread groups (test_226), owner marks as in test_171.
String _forumHome() {
  String threads(List<(String, int)> rows) => [
    for (final (title, tid) in rows)
      '<div class="Kahrpba_threads"><a href="forum.php?mod=viewthread&amp;tid=$tid">$title</a>$_carol</div>',
  ].join('\n');
  String button(int id, String title) => '<button type="button" id="Kahrpba_$id"><em>$title</em></button>';
  return '''
<html><head>
<script type="text/javascript">var STYLEID = '42', discuz_uid = '1000', cookiepre = 'Ystv_2132_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<div class="avt y"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg" class="_avt user_avatar"></a></div>
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p>
</div></div></div></div>
<form><input type="hidden" name="formhash" value="XXXXXXXX" /></form>
<div id="chart" class="bm bw0 cl"><p class="chart z">今日: <em>1234</em> | 昨日: <em>5678</em> | 帖子: <em>9012345</em></p></div>
<table id="Kahrpba"><tr>
<td id="Kahrpba_nav">
${button(1, '最新活动')}${button(2, '见习天使')}${button(3, '动漫新闻')}${button(4, '最新主题')}
${button(6, '今日话题')}${button(7, '动漫讨论')}${button(5, '发帖排行')}
</td>
<td id="Kahrpba_show">
<div id="Kahrpba_c_1">${threads([('【活动】十月签到挑战赛开始报名', 2001), ('【活动】秋季同人绘画征集', 2002), ('【公告】活动专区兑换商店开放', 2003)])}</div>
<div id="Kahrpba_c_2"><div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=1101">欢迎Momo加入~</a></div></div>
<div id="Kahrpba_c_3">${threads([('【新闻】十月新番播出时间表整理', 2004), ('【新闻】某长篇漫画宣布动画化', 2005)])}</div>
<div id="Kahrpba_c_4">${threads([('求推荐几部轻松的日常番', 2006), ('分享一下我的手办收藏', 2007)])}</div>
<div id="Kahrpba_c_5"><div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=1003">Carol</a><a href="home.php?mod=space&amp;uid=1003" target="_blank"><em>今日共发128贴</em></a></div></div>
<div id="Kahrpba_c_6">${threads([('你最喜欢的片头曲是哪首？', 2008)])}</div>
<div id="Kahrpba_c_7">${threads([('第 3 集的伏笔是不是太明显了', 2009)])}</div>
</td></tr></table>
</body></html>''';
}

const _profile = '''
<html><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="uhd"><div class="icn avt"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg"></a></div></div>
</body></html>''';

/// The forum: the homepage, the profile, a forum (JSON of the app plugin), a thread and a search; an empty page
/// otherwise. Nothing leaves the test.
final class _Forum implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final q = uri.queryParameters;
    final (body, json) = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == null => (_forumHome(), false),
      'forum.php' when q['mod'] == 'forumdisplay' => (_data('tsdmapp/preview_v2_forum.json'), true),
      'forum.php' when q['mod'] == 'viewthread' => (_threadPage(int.tryParse(q['page'] ?? '') ?? 1), false),
      'home.php' when q['mod'] == 'space' => (_profile, false),
      'search.php' => (_data('tsdmapp/preview_v6_search.json'), true),
      _ => ('<html><body></body></html>', false),
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [
          if (json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers a PNG for every image request.
final class _Images implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    _png,
    200,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// Notification bloc with a fixed state; events are dropped.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  final NotificationState state;

  @override
  void add(NotificationEvent event) {}

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// The login: the form hash comes at once, a login is refused.
final class _LoginRepository extends AuthenticationRepository {
  @override
  AsyncEither<LoginHash> fetchHash() =>
      AsyncEither(() async => right(const LoginHash(formHash: 'hash', loginHash: 'login')));

  @override
  AsyncVoidEither loginWithPassword(UserCredential credential) =>
      AsyncVoidEither(() async => left(LoginInvalidCredentialException()));
}

/// Let the requests (real futures) and the frames they cause finish.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The floor of the fixture `locked_purchase_x5.html` as a post with a plain body (test_267).
Post _fixturePost() {
  final doc = parseHtmlDocument(_data('locked_purchase_x5.html'));
  final original = doc.querySelector('div#post_77983102')!;
  final floor = original.clone(true) as uh.Element;
  original.parent!.append(floor);
  final post = Post.fromPostNode(floor, 1)!;
  return post.copyWith(data: '<p>floor body</p>', locked: const [], signature: null, pokemon: null, checkin: null);
}

final class _FakeContext extends Fake implements BuildContext {}

/// The global rect of [node]: its own, through the transforms up to the root.
Rect _globalRect(SemanticsNode node) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) {
      rect = MatrixUtils.transformRect(transform, rect);
    }
    current = current.parent;
  }
  return rect;
}

/// Whether [node] lies within one of the [exempt] rects (a hair of tolerance for the pixel snapping).
bool _isExempt(SemanticsNode node, List<Rect> exempt) {
  final rect = _globalRect(node);
  return exempt.any((e) => e.inflate(0.5).contains(rect.topLeft) && e.inflate(0.5).contains(rect.bottomRight));
}

/// The rects of what the [finders] find on screen.
List<Rect> _rectsOf(WidgetTester tester, List<Finder> finders) => [
  for (final finder in finders)
    for (final element in finder.evaluate())
      if (element.renderObject case final RenderBox box when box.hasSize)
        MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size),
];

/// [androidTapTargetGuideline] leaving out the nodes within [exempt].
final class _TapTargets extends MinimumTapTargetGuideline {
  const _TapTargets(this.exempt)
    : super(size: const Size(48, 48), link: 'https://support.google.com/accessibility/android/answer/7101858');

  final List<Rect> exempt;

  @override
  bool shouldSkipNode(SemanticsNode node) => super.shouldSkipNode(node) || _isExempt(node, exempt);
}

/// [textContrastGuideline] leaving out the text under one of the [exempt] rects: covered, not low in contrast.
final class _Contrast extends MinimumTextContrastGuideline {
  _Contrast(this.exempt);

  final List<Rect> exempt;

  /// Labels of the text nodes under an exempt rect, collected before the evaluation (the nodes it asks about carry
  /// no transform to the root).
  final _covered = <String>{};

  void _collect(SemanticsNode node) {
    node.visitChildren((child) {
      _collect(child);
      return true;
    });
    final rect = _globalRect(node);
    if (exempt.any((e) => e.overlaps(rect))) {
      final data = node.getSemanticsData();
      _covered.add(data.label.isEmpty ? data.value : data.label);
    }
  }

  @override
  Future<Evaluation> evaluate(WidgetTester tester) {
    _covered.clear();
    for (final view in tester.binding.renderViews) {
      _collect(view.owner!.semanticsOwner!.rootSemanticsNode!);
    }
    return super.evaluate(tester);
  }

  @override
  bool shouldSkipNode(SemanticsData data) =>
      super.shouldSkipNode(data) || _covered.contains(data.label.isEmpty ? data.value : data.label);
}

/// [labeledTapTargetGuideline] (whose constructor is private) leaving out the nodes within [exempt].
final class _LabeledTargets extends AccessibilityGuideline {
  const _LabeledTargets(this.exempt);

  final List<Rect> exempt;

  @override
  String get description => 'Tappable widgets should have a semantic label';

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    var result = const Evaluation.pass();
    for (final view in tester.binding.renderViews) {
      result += _traverse(view.owner!.semanticsOwner!.rootSemanticsNode!);
    }
    return result;
  }

  Evaluation _traverse(SemanticsNode node) {
    var result = const Evaluation.pass();
    node.visitChildren((child) {
      result += _traverse(child);
      return true;
    });
    if (node.isMergedIntoParent ||
        node.isInvisible ||
        node.flagsCollection.isHidden ||
        node.flagsCollection.isTextField ||
        _isExempt(node, exempt)) {
      return result;
    }
    final data = node.getSemanticsData();
    if (!data.hasAction(SemanticsAction.longPress) && !data.hasAction(SemanticsAction.tap)) {
      return result;
    }
    if (data.label.isEmpty && data.tooltip.isEmpty) {
      result += Evaluation.fail('$node: expected tappable node to have semantic label, but none was found.');
    }
    return result;
  }
}

ThemeData _theme({required bool dark}) => dark
    ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: '')
    : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: '');

void main() {
  late Directory tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late AuthenticationRepository auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
    tmp = Directory.systemTemp.createTempSync('tsdm_a11y_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
        'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
        'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${tmp.path}/docs',
        _ => null,
      },
    );
    await initCache();
  });

  tearDownAll(() => tmp.delete(recursive: true));

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Forum()),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Images())),
      );
    await settings.init();
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = AuthenticationRepository(user: _alice);
    info = NotificationInfoRepository();
    counts = NotificationStateCubit(info);
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await info.dispose();
    await counts.close();
    await settingsBloc.close();
    await blocks.dispose();
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  /// [home] at `/` under the providers of the app, with [routes] beside it, in the light or the [dark] theme.
  Future<void> pump(WidgetTester tester, Widget home, {required bool dark, List<RouteBase> routes = const []}) async {
    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final blockCubit = UserBlockCubit(
      repository: blocks,
      currentUid: () => _alice.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
    final home_ = HomeCubit();
    final checkin = CheckinBloc(
      checkinRepository: CheckinRepository(storageProvider: storage),
      authenticationRepository: auth,
      settingsRepository: settings,
    );
    final forumHome = ForumHomeRepository();
    final theme = ThemeCubit();
    final status = StreamController<AuthStatus>.broadcast(sync: true);
    final titles = CurrentTitleCubit(
      currentUid: () => _alice.uid,
      authStatus: status.stream,
      fetchTitles: () => TaskEither.right(const []),
    );
    final notices = NotificationRepository(storageProvider: storage);
    final auto = AutoNotificationCubit(
      authenticationRepository: auth,
      notificationRepository: notices,
      storageProvider: storage,
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        ...routes,
      ],
    );
    addTearDown(() async {
      router.dispose();
      await blockCubit.close();
      await history.close();
      await home_.close();
      await checkin.close();
      await forumHome.dispose();
      await theme.close();
      await titles.close();
      await status.close();
      await auto.close();
      await notices.dispose();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<NotificationInfoRepository>.value(value: info),
            RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
            RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
            RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: blockCubit),
              BlocProvider<NotificationBloc>.value(
                value: _Notifications(
                  NotificationState(
                    status: NotificationStatus.success,
                    ownerUid: _alice.uid,
                    noticeList: const [
                      NoticeV2(id: 1, timestamp: 1788000001, data: 'unread notice one'),
                      NoticeV2(id: 2, timestamp: 1788000002, data: 'read notice two', alreadyRead: true),
                    ],
                  ),
                ),
              ),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              BlocProvider<AutoNotificationCubit>.value(value: auto),
              BlocProvider<HomeCubit>.value(value: home_),
              BlocProvider<CheckinBloc>.value(value: checkin),
              BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
              BlocProvider<ThemeCubit>.value(value: theme),
              BlocProvider<CurrentTitleCubit>.value(value: titles),
            ],
            child: MaterialApp.router(
              debugShowCheckedModeBanner: false,
              theme: _theme(dark: dark),
              routerConfig: router,
              scaffoldMessengerKey: snackbarKey,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  /// Take the page down and let the timers of its indicators run out.
  Future<void> unpump(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  /// The three guidelines on what is on screen: tap targets of 48 ([tapTargetExempt] left out), labels on everything
  /// tappable ([labelExempt] left out), text contrast (the text under [covered] left out).
  Future<void> audit(
    WidgetTester tester, {
    List<Finder> tapTargetExempt = const [],
    List<Finder> labelExempt = const [],
    List<Finder> covered = const [],
  }) async {
    final handle = tester.ensureSemantics();
    await tester.pump();
    await expectLater(tester, meetsGuideline(_TapTargets(_rectsOf(tester, tapTargetExempt))));
    await expectLater(tester, meetsGuideline(_LabeledTargets(_rectsOf(tester, labelExempt))));
    await expectLater(tester, meetsGuideline(_Contrast(_rectsOf(tester, covered))));
    handle.dispose();
  }

  /// The tap target of the [avatar]: the box of the gesture detector around it.
  Rect avatarTarget(WidgetTester tester, Finder avatar) =>
      tester.getRect(find.ancestor(of: avatar, matching: find.byType(GestureDetector)).first);

  /// The floating buttons of a list: the text of the last row on screen may run under them, where it is covered,
  /// not low in contrast (the guideline reads the pixels of the button over the text).
  Finder floatingButtons() => find.byType(FloatingActionButton);

  /// The button opening a table of a floor in a page of its own: 32 wide on purpose (test_271), a corner of the table
  /// that must not cover its cells; the table scrolls and zooms without it.
  Finder tableFullscreen() => find.byTooltip(tr.html.table.fullscreen);

  /// The name of the author of a floor opens the author card like the 48 wide avatar before it does: the equivalent
  /// control is there, the name stays the height of its line.
  Finder floorAuthorName(String name) => find.widgetWithText(GestureDetector, name);

  /// The buttons the bbcode editor package builds (the style toggles, undo, redo, lists, alignment ...): the package
  /// puts their tooltip on a node of its own around the button instead of on the button, so the button node has no
  /// label; the tooltip is still read. The package is a submodule, not changed here; the app's own buttons are checked.
  Finder packageToolbarButtons() => find.descendant(
    of: find.byType(BBCodeEditorToolbar),
    matching: find.byWidgetPredicate((w) => w is IconButton && w.tooltip == null),
  );

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    testWidgets('homepage, $mode', (tester) async {
      final opened = <Uri>[];
      await pump(
        tester,
        const HomepagePage(),
        dark: dark,
        routes: [
          GoRoute(
            path: ScreenPaths.profile,
            name: ScreenPaths.profile,
            builder: (_, state) {
              opened.add(state.uri);
              return const Scaffold(body: Text('profile page'));
            },
          ),
        ],
      );
      await _settle(tester);
      expect(find.text('【活动】十月签到挑战赛开始报名'), findsOneWidget, reason: 'the pinned threads are on the page');
      await audit(tester);
      // The whole 48 box of the avatar takes the tap: its end edge, past the circle, opens the user, not the thread
      // of the row (the tile's own tap).
      final avatar = avatarTarget(tester, find.byType(HeroUserAvatar).first);
      expect(avatar.width, 48);
      await tester.tapAt(Offset(avatar.right - 1, avatar.center.dy));
      await _settle(tester);
      expect(opened.map((e) => e.queryParameters['username']), ['Carol']);
      expect(find.text('profile page'), findsOneWidget);
      await unpump(tester);
    });

    testWidgets('forum page, $mode', (tester) async {
      await pump(
        tester,
        const ForumPage(fid: '13', title: 'COS・攝影'),
        dark: dark,
      );
      await _settle(tester);
      expect(find.text('Alice'), findsWidgets, reason: 'the thread cards are on the page');
      await audit(tester, covered: [floatingButtons()]);
      // The 48 box of the avatar and its circle, name and date where they were with the 40 circle (16, 12 from the
      // corner of the card, the name 12 after the circle): the target grew around the circle, not the head.
      final card = tester.getRect(find.byType(Card).first);
      final circle = tester.getRect(find.descendant(of: find.byType(Card).first, matching: find.byType(CircleAvatar)));
      final box = avatarTarget(tester, find.byType(HeroUserAvatar).first);
      expect(box.size, const Size(48, 48));
      expect(circle.size, const Size(40, 40));
      expect(circle.topLeft - card.topLeft, const Offset(16, 12));
      final name = tester.getRect(find.descendant(of: find.byType(Card).first, matching: find.text('Alice')));
      expect(name.left - circle.right, 12);
      // The texts (name over date) centered on the circle, as with the 40 circle at the default size.
      final texts = tester.getRect(find.ancestor(of: find.text('Alice').first, matching: find.byType(Column)).first);
      expect(texts.height, lessThan(48), reason: 'the default size: the box decides the height of the head');
      expect(texts.center.dy, closeTo(circle.center.dy, 0.5));
      await unpump(tester);
    });

    testWidgets('thread page, $mode', (tester) async {
      await pump(
        tester,
        const ThreadPage(
          threadID: '$_tid',
          findPostID: null,
          pageNumber: '1',
          overrideReverseOrder: false,
          overrideWithExactOrder: null,
        ),
        dark: dark,
      );
      await _settle(tester);
      expect(find.textContaining('floor 1 text'), findsOneWidget, reason: 'the floors are on the page');
      expect(tableFullscreen(), findsOneWidget, reason: 'the table of the first floor is wider than the phone');
      await audit(tester, tapTargetExempt: [tableFullscreen(), floorAuthorName('Bob')]);
      await unpump(tester);
    });

    testWidgets('notification page, $mode', (tester) async {
      await pump(tester, const NotificationPage(), dark: dark);
      await _settle(tester);
      expect(find.text('unread notice one'), findsOneWidget, reason: 'the notices are on the page');
      await audit(tester);
      await unpump(tester);
    });

    testWidgets('settings page, $mode', (tester) async {
      await pump(tester, const SettingsPage(), dark: dark);
      await audit(tester);
      await unpump(tester);
    });

    testWidgets('login page, $mode', (tester) async {
      final login = _LoginRepository();
      addTearDown(login.dispose);
      await pump(
        tester,
        RepositoryProvider<AuthenticationRepository>.value(value: login, child: const LoginPage()),
        dark: dark,
      );
      expect(find.text(tr.loginPage.password), findsOneWidget, reason: 'the form is on the page');
      await audit(tester);
      await unpump(tester);
    });

    testWidgets('editor toolbar, $mode', (tester) async {
      final controller = buildBBCodeEditorController(initialText: 'abcd');
      addTearDown(controller.dispose);
      await pump(
        tester,
        Scaffold(body: EditorToolbar(bbcodeController: controller)),
        dark: dark,
      );
      expect(find.byKey(const ValueKey('editor-quick-phrases')), findsOneWidget, reason: "the app's own button");
      await audit(tester, labelExempt: [packageToolbarButtons()]);
      await unpump(tester);
    });

    testWidgets('author card, $mode', (tester) async {
      final post = _fixturePost();
      await pump(
        tester,
        Scaffold(body: SingleChildScrollView(child: PostCard(post))),
        dark: dark,
      );
      await audit(tester, tapTargetExempt: [floorAuthorName(post.author.name)]);
      // The whole 48 box of the avatar takes the tap: a corner of it, outside the circle, opens the author card.
      final avatar = avatarTarget(tester, find.byType(HeroUserAvatar).first);
      expect(avatar.size, const Size(48, 48));
      await tester.tapAt(avatar.topLeft + const Offset(1, 1));
      await _settle(tester, rounds: 12);
      expect(find.text(tr.postCard.profileDialog.tabName.info), findsOneWidget, reason: 'the dialog is open');
      await audit(tester);
      await unpump(tester);
    });

    testWidgets('search page, $mode', (tester) async {
      await pump(tester, const SearchPage(), dark: dark);
      await audit(tester);
      await tester.enterText(find.byType(TextFormField).first, '000000');
      await tester.tap(find.byIcon(Icons.search_outlined));
      await _settle(tester, rounds: 12);
      expect(find.text('Alice'), findsWidgets, reason: 'the results are on the page');
      await audit(tester);
      await unpump(tester);
    });
  }
}
