/// The state feedback of the pages and lists (UX audit, item 7), one group each:
///
/// 1. a failure is told by its kind ([LoadFailure], [FailureView]): no network, a dropped connection, a timeout
///    (dio's and the Android channel's), too many requests (429, the forum's "too frequent" with its wait), the
///    server, the site's browser check, the forum closed, log in, no permission, the forum's own message as it wrote
///    it; one sentence and what to do, the technical details folded away;
/// 2. one end of the lists ([ListFooter]): loading more, no more, failed with the reason and a retry; it asks the next
///    page once it comes near, without a pull; a next page that failed keeps what was loaded;
/// 3. the first load shows the shape of the page to come (homepage, guide lists, forum list, thread list), still
///    when the system asks for less motion;
/// 4. empty lists say what they are for, "nothing here" told apart from "nothing left by the filters";
/// 5. a refresh that failed keeps the list on screen and says so.
///
/// Screenshots: with `STATE_SHOTS_DIR` (output directory) and `STATE_SHOTS_FONT` (a font file with CJK glyphs) set,
/// the last group writes the states (light and dark) as png files.
library;

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
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/chat/bloc/chat_bloc.dart';
import 'package:tsdm_client/features/chat/bloc/chat_history_bloc.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/draft_box/cubit/draft_cubit.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/features/favorite/bloc/favorite_bloc.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/view/favorite_page.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/friend/bloc/friend_bloc.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/view/latest_thread_page.dart';
import 'package:tsdm_client/features/member_thread/cubit/member_thread_cubit.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/my_thread/bloc/my_thread_bloc.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/points/bloc/points_bloc.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/widgets/topics_placeholder.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart'
    show KotlinHttpClient, KotlinHttpClientAdapter;
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:universal_html/parsing.dart';

import 'draft_fixtures.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

final _options = RequestOptions(path: '$baseUrl/forum.php');

/// [e] as the caller of the net client gets it, and as the user is told.
LoadFailure _told(Object e) => LoadFailure.of(mapException(e, StackTrace.current));

DioException _dio(DioExceptionType type, {Object? error, int? status, Map<String, List<String>>? headers}) =>
    DioException(
      requestOptions: _options,
      type: type,
      error: error,
      message: 'fake ${type.name}',
      response: status == null
          ? null
          : Response<dynamic>(requestOptions: _options, statusCode: status, headers: Headers.fromMap(headers ?? {})),
    );

/// The forum: answers every request through [answer].
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  FutureOr<ResponseBody> Function(RequestOptions options) answer;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Every image request fails at once.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The forum's pages: two threads each, failing while [failing] says so.
final class _Forums extends ForumRepository {
  _Forums({this.pages = 3});

  final int pages;
  bool failing = false;

  /// Pages that fail whatever [failing] says.
  final failPages = <int>{};
  final asked = <int>[];

  /// Completes the answer of a page when set, to hold it back.
  Completer<void>? hold;

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async {
        asked.add(pageNumber);
        await hold?.future;
        if (failing || failPages.contains(pageNumber)) {
          return left(HttpHandshakeFailedException('offline', connectionFailed: true));
        }
        return right(_forumPage(pageNumber, pages: pages, threads: filterState.isFiltering() ? 0 : 2));
      });
}

NormalThread _thread(int tid) => NormalThread(
  title: 'thread $tid',
  url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
  threadID: '$tid',
  author: const User(name: 'a', url: ''),
  publishDate: null,
  latestReplyAuthor: const User(name: 'a', url: ''),
  latestReplyTime: null,
  iconUrl: '',
  threadType: null,
  replyCount: 3,
  viewCount: 40,
  price: null,
  css: null,
  stateSet: const {},
  privilege: null,
  isRecentThread: false,
);

ForumPageData _forumPage(int page, {int pages = 3, int threads = 2}) => ForumPageData(
  title: 'forum',
  rulesElement: null,
  normalThreadList: [for (var i = 0; i < threads; i++) _thread(page * 10 + i)],
  stickThreadList: const [],
  subredditList: const [],
  needLogin: false,
  havePermission: true,
  permissionDeniedMessage: null,
  canLoadMore: page < pages,
  currentPage: page,
  totalPages: pages,
  filterTypeList: const [],
  filterSpecialTypeList: const [],
  filterOrderList: const [],
  filterDatelineList: const [],
);

/// The guide list of [name] (`test/data`), failing while [failing] says so, holding back the answers by [hold].
final class _Guide extends LatestThreadRepository {
  _Guide(this.name);

  String name;
  bool failing = false;
  Completer<void>? hold;
  final urls = <String>[];

  @override
  AsyncEither<TsdmAppPageAnswer> fetchPage(String url) => AsyncEither(() async {
    urls.add(url);
    await hold?.future;
    if (failing) return left(HttpHandshakeFailedException('timeout', timedOut: true));
    return right(TsdmAppWebPage(parseHtmlDocument(File('test/data/$name').readAsStringSync())));
  });
}

/// The "my threads" lists of the forum's app API (`test/data/tsdmapp`), the next page answered by [next] when set.
final class _MyThreads extends MyThreadRepository {
  Either<AppException, TsdmAppPageAnswer>? next;
  int asked = 0;

  @override
  AsyncEither<TsdmAppPageAnswer> fetchPage(String url) => AsyncEither(() async {
    asked++;
    if (next != null) {
      return next!;
    }
    final name = url.contains('type=reply') ? 'reply' : (url.contains('uid=1103') ? 'other' : 'thread');
    return right(
      TsdmAppStructuredPage(
        jsonDecode(File('test/data/tsdmapp/mythread_v9_$name.json').readAsStringSync()) as Map<String, dynamic>,
      ),
    );
  });
}

/// Search results: page N of 3 holds the threads N and N + 1.
final class _Searches extends SearchRepository {
  bool failing = false;
  final pages = <int>[];

  @override
  AsyncEither<SearchResult> searchWithParameters({
    required String keyword,
    required String fid,
    required String uid,
    required int pageNumber,
    String authorName = '',
  }) => AsyncEither(() async {
    final page = pageNumber < 1 ? 1 : pageNumber;
    pages.add(page);
    if (failing) return left(HttpHandshakeFailedException('offline', connectionFailed: true));
    return right(
      SearchResult(
        currentPage: page,
        totalPages: 3,
        count: 6,
        data: [
          for (final tid in [page, page + 1])
            SearchedThread(
              tid: tid,
              title: 'result $tid',
              url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
              author: const User(name: 'a', url: ''),
              publishTime: DateTime(2026, 10),
              forumName: 'Board',
              forumUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=8',
            ),
        ],
      ),
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _Forum forum;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum((o) => throw StateError('unexpected request: ${o.method} ${o.uri}'));
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// [child] under the providers of the app.
  Widget app(Widget child, {AuthenticationRepository? auth}) => TranslationProvider(
    child: RepositoryProvider<AuthenticationRepository>.value(
      value: auth ?? AuthenticationRepository(user: _alice),
      child: BlocProvider<SettingsBloc>.value(value: settingsBloc, child: child),
    ),
  );

  /// Lets the fake requests answer (outside of the fake clock) and the page settle on what they brought.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('1. a failure is told by its kind', () {
    test('the network: not reached, dropped, too slow', () {
      expect(_told(_dio(DioExceptionType.connectionError)).kind, LoadFailureKind.noNetwork);
      expect(_told(_dio(DioExceptionType.connectionTimeout)).kind, LoadFailureKind.noNetwork);
      expect(_told(_dio(DioExceptionType.receiveTimeout)).kind, LoadFailureKind.timeout);
      expect(_told(_dio(DioExceptionType.sendTimeout)).kind, LoadFailureKind.timeout);
      expect(
        _told(_dio(DioExceptionType.unknown, error: const SocketException('Connection reset by peer'))).kind,
        LoadFailureKind.connectionLost,
        reason: 'the forum was reached, the connection dropped',
      );
    });

    test('the status of the answer: too many requests, the site check, the server', () {
      final limited = _told(
        _dio(
          DioExceptionType.badResponse,
          status: 429,
          headers: {
            'retry-after': ['30'],
          },
        ),
      );
      expect((limited.kind, limited.retryAfterSeconds, limited.statusCode), (LoadFailureKind.rateLimited, 30, 429));
      final challenged = _told(
        _dio(
          DioExceptionType.badResponse,
          status: 503,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
      );
      expect(challenged.kind, LoadFailureKind.challenge);
      expect(_told(_dio(DioExceptionType.badResponse, status: 502)).kind, LoadFailureKind.server);
      expect(_told(_dio(DioExceptionType.badResponse, status: 503)).kind, LoadFailureKind.server);
      expect(_told(_dio(DioExceptionType.badResponse, status: 404)).statusCode, 404);
      expect(LoadFailure.of(HttpRequestFailedException(500)).kind, LoadFailureKind.server);
      expect(LoadFailure.of(HttpRequestFailedException(null)).kind, LoadFailureKind.unknown);
    });

    test('the app: the account changed meanwhile, a login asked, nothing known', () {
      expect(LoadFailure.of(IdentityChangedException()).kind, LoadFailureKind.accountChanged);
      expect(LoadFailure.of(ProfileNeedLoginException()).kind, LoadFailureKind.needLogin);
      expect(LoadFailure.of(null).kind, LoadFailureKind.unknown);
      expect(LoadFailure.of(LoginFormHashNotFoundException()).kind, LoadFailureKind.unknown);
    });

    test("the forum's messages: what they are about, kept as the forum wrote them", () {
      final cases = <(String, LoadFailureKind, int?)>[
        ('抱歉，您在 20 秒内只能进行一次搜索', LoadFailureKind.rateLimited, 20),
        ('抱歉，您兩次發表間隔少於 15 秒，請稍候再發表', LoadFailureKind.rateLimited, 15),
        ('抱歉，您的搜尋過於頻繁', LoadFailureKind.rateLimited, null),
        ('抱歉，本站暂时关闭，请稍后访问', LoadFailureKind.closed, null),
        ('論壇維護中，預計 30 分鐘後恢復', LoadFailureKind.closed, null),
        ('您需要先登录才能继续本操作', LoadFailureKind.needLogin, null),
        ('抱歉，您尚未登入，無法進行此操作', LoadFailureKind.needLogin, null),
        ('抱歉，您所在的用户组(游客)无法进行此操作', LoadFailureKind.needLogin, null),
        ('抱歉，您所在的用户组(新手上路)无法进行此操作', LoadFailureKind.noPermission, null),
        ('抱歉，您沒有權限訪問該版塊', LoadFailureKind.noPermission, null),
        ('抱歉！由于 Bob 的隐私设置，您不能访问当前内容', LoadFailureKind.noPermission, null),
        ('指定的主题不存在或已被删除或正在被审核', LoadFailureKind.forumMessage, null),
      ];
      for (final (message, kind, wait) in cases) {
        final failure = LoadFailure.of(ServerRespondedErrorException(message));
        expect(failure.kind, kind, reason: message);
        expect(failure.message, message, reason: 'the words of the forum, as it wrote them');
        expect(failure.retryAfterSeconds, wait, reason: message);
      }
    });

    test('the details: the exception and its status, secrets left out', () {
      final failure = LoadFailure.of(
        HttpHandshakeFailedException('failed: forum.php?formhash=a1b2c3d4&mod=post', statusCode: 502),
      );
      expect(failure.details, contains('HttpHandshakeFailedException (HTTP 502)'));
      expect(failure.details, isNot(contains('a1b2c3d4')));
    });

    test('a page that kept no failure tells the last request that failed', () async {
      forum.answer = (o) => throw DioException.connectionError(requestOptions: o, reason: 'offline');
      expect(LoadFailure.lastRequest().kind, LoadFailureKind.unknown, reason: 'nothing failed yet');
      final result = await getIt.get<NetClientProvider>().get('$baseUrl/forum.php').run();
      expect(result.isLeft(), isTrue);
      expect(LoadFailure.lastRequest().kind, LoadFailureKind.noNetwork);
    });

    group('the Android client', () {
      const channel = MethodChannel('kzs.th000.tsdm_client/httpChannel');

      Future<LoadFailure> failing(String code, String details) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: code, message: 'failed to perform http GET', details: details),
        );
        addTearDown(
          () =>
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
        );
        final client = NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))
            ..httpClientAdapter = KotlinHttpClientAdapter(KotlinHttpClient(android: true)),
        );
        final result = await client.get('$baseUrl/forum.php').run();
        return LoadFailure.of(result.getLeft().toNullable());
      }

      test('a read timeout is a timeout, a dropped connection is not', () async {
        expect((await failing('KT_HTTP_ERROR', 'timeout')).kind, LoadFailureKind.timeout);
        expect((await failing('KT_HTTP_ERROR', 'Read timed out')).kind, LoadFailureKind.timeout);
        expect((await failing('KT_HTTP_ERROR', 'Connection reset')).kind, LoadFailureKind.connectionLost);
        expect(
          (await failing('KT_HTTP_UNREACHABLE', 'failed to connect to /x (port 443) after 10000ms')).kind,
          LoadFailureKind.noNetwork,
        );
      });
    });
  });

  group('1. the failure view', () {
    Future<void> pumpView(WidgetTester tester, Widget view) async {
      await tester.pumpWidget(app(MaterialApp(home: Scaffold(body: view))));
      await tester.pump();
    }

    testWidgets('one sentence, what to do, the retry; the details folded away', (tester) async {
      var retried = 0;
      final failure = LoadFailure.of(HttpHandshakeFailedException('Failed host lookup', connectionFailed: true));
      await pumpView(tester, FailureView(failure: failure, onRetry: () => retried++));
      expect(find.text(t.loadState.failure.noNetwork.title), findsOneWidget);
      expect(find.text(t.loadState.failure.noNetwork.hint), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off_outlined), findsOneWidget);
      expect(find.textContaining('Failed host lookup'), findsNothing, reason: 'the technical words are folded');
      await tester.tap(find.byKey(failureDetailsKey));
      await tester.pump();
      expect(find.textContaining('Failed host lookup'), findsOneWidget);
      expect(find.byTooltip(t.loadState.copyDetails), findsOneWidget);
      await tester.tap(find.byKey(failureRetryKey));
      expect(retried, 1);
    });

    testWidgets('each kind its own words: the server, a timeout, the site check, closed', (tester) async {
      final cases = <(LoadFailure, String)>[
        (LoadFailure(LoadFailureKind.server, statusCode: 502), t.loadState.failure.server.title),
        (LoadFailure(LoadFailureKind.server, statusCode: 404), t.loadState.failure.badStatus.title),
        (LoadFailure(LoadFailureKind.timeout), t.loadState.failure.timeout.title),
        (LoadFailure(LoadFailureKind.connectionLost), t.loadState.failure.connectionLost.title),
        (LoadFailure(LoadFailureKind.challenge), t.loadState.failure.challenge.title),
        (LoadFailure(LoadFailureKind.accountChanged), t.loadState.failure.accountChanged.title),
        (LoadFailure(LoadFailureKind.unknown), t.loadState.failure.unknown.title),
      ];
      for (final (failure, title) in cases) {
        await pumpView(tester, FailureView(key: UniqueKey(), failure: failure, onRetry: () {}));
        expect(find.text(title), findsOneWidget, reason: '${failure.kind}');
      }
    });

    testWidgets("the forum's words: under the sentence, or the sentence itself", (tester) async {
      await pumpView(
        tester,
        FailureView(failure: LoadFailure.fromMessage('抱歉，本站暂时关闭，请稍后访问'), onRetry: () {}),
      );
      expect(find.text(t.loadState.failure.closed.title), findsOneWidget);
      expect(find.text('抱歉，本站暂时关闭，请稍后访问'), findsOneWidget);
      await pumpView(
        tester,
        FailureView(key: UniqueKey(), failure: LoadFailure.fromMessage('指定的主题不存在或已被删除'), onRetry: () {}),
      );
      expect(find.text('指定的主题不存在或已被删除'), findsOneWidget, reason: 'once, as the title');
    });

    testWidgets('log in: the login comes first, the retry stays', (tester) async {
      var logins = 0;
      await pumpView(
        tester,
        FailureView(failure: LoadFailure(LoadFailureKind.needLogin), onLogin: () => logins++, onRetry: () {}),
      );
      expect(find.text(t.loadState.failure.needLogin.title), findsOneWidget);
      await tester.tap(find.byKey(failureLoginKey));
      expect(logins, 1);
      expect(find.byKey(failureRetryKey), findsOneWidget);
    });

    testWidgets('too many requests: the retry waits for the seconds asked', (tester) async {
      var retried = 0;
      await pumpView(
        tester,
        FailureView(
          failure: LoadFailure(LoadFailureKind.rateLimited, retryAfterSeconds: 3),
          onRetry: () => retried++,
        ),
      );
      expect(find.text(t.loadState.failure.rateLimited.hintSeconds(seconds: 3)), findsOneWidget);
      expect(find.text(t.loadState.retryIn(seconds: 3)), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(failureRetryKey)).onPressed, isNull);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text(t.general.retry), findsOneWidget);
      await tester.tap(find.byKey(failureRetryKey));
      expect(retried, 1);
    });

    testWidgets('a page that kept no failure tells the last one of the app', (tester) async {
      getIt.get<NetErrorSaver>().save('timeout', failure: HttpHandshakeFailedException('timeout', timedOut: true));
      await pumpView(tester, FailureView(onRetry: () {}));
      expect(find.text(t.loadState.failure.timeout.title), findsOneWidget);
    });
  });

  group('2. the end of the lists', () {
    Future<void> pumpFooter(WidgetTester tester, Widget footer, {bool reduceMotion = false}) async {
      await tester.pumpWidget(
        app(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Scaffold(body: footer),
            ),
          ),
        ),
      );
    }

    testWidgets('more: asks the next page once it is built, again only for more items', (tester) async {
      var asked = 0;
      Widget footer(int count, [ListFooterStatus status = ListFooterStatus.more]) =>
          ListFooter(status: status, itemCount: count, onLoadMore: () => asked++);
      await pumpFooter(tester, footer(10));
      await tester.pump();
      expect(asked, 1);
      await pumpFooter(tester, footer(10));
      await tester.pump();
      expect(asked, 1, reason: 'no second request for the same items');
      await pumpFooter(tester, footer(10, ListFooterStatus.loading));
      await tester.pump();
      expect(find.text(t.loadState.footer.loading), findsOneWidget);
      expect(asked, 1);
      await pumpFooter(tester, footer(20));
      await tester.pump();
      expect(asked, 2, reason: 'the page came: asked again while the end is still in view');
    });

    testWidgets('no more, failed with the reason and a retry', (tester) async {
      await pumpFooter(tester, const ListFooter(status: ListFooterStatus.noMore));
      expect(find.text(t.general.noMoreData), findsOneWidget);
      var retried = 0;
      await pumpFooter(
        tester,
        ListFooter(
          status: ListFooterStatus.failed,
          failure: LoadFailure(LoadFailureKind.timeout),
          onRetry: () => retried++,
        ),
      );
      expect(find.text(t.loadState.footer.failed(reason: t.loadState.failure.timeout.title)), findsOneWidget);
      await tester.tap(find.byKey(listFooterRetryKey));
      expect(retried, 1);
    });

    testWidgets('less motion: no spinning', (tester) async {
      await pumpFooter(tester, const ListFooter(status: ListFooterStatus.loading), reduceMotion: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await pumpFooter(tester, const ListFooter(status: ListFooterStatus.loading));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the last item of a long lazy list: asked only once the end comes near', (tester) async {
      var asked = 0;
      await tester.pumpWidget(
        app(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                itemCount: 61,
                itemBuilder: (_, i) => i < 60
                    ? SizedBox(height: 80, child: Text('row $i'))
                    : ListFooter(status: ListFooterStatus.more, itemCount: 60, onLoadMore: () => asked++),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(asked, 0);
      await tester.drag(find.byType(ListView), const Offset(0, -6000));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(asked, 1);
    });
  });

  group('3. the shape of the page to come', () {
    testWidgets('the shimmer stands still when the system asks for less motion', (tester) async {
      for (final reduce in [false, true]) {
        await tester.pumpWidget(
          app(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: reduce),
                child: const Scaffold(body: ThreadListSkeleton()),
              ),
            ),
          ),
        );
        expect(tester.widgetList<Shimmer>(find.byType(Shimmer)).map((e) => e.enabled), everyElement(!reduce));
      }
    });

    testWidgets('the skeletons fit a small phone and are told as loading', (tester) async {
      tester.view
        ..physicalSize = const Size(320, 640)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      for (final skeleton in const [ThreadListSkeleton(), HomepagePlaceholder(), TopicsPlaceholder()]) {
        await tester.pumpWidget(app(MaterialApp(home: Scaffold(body: skeleton))));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '${skeleton.runtimeType}');
        expect(find.bySemanticsLabel(t.loadState.loading), findsOneWidget, reason: '${skeleton.runtimeType}');
      }
      handle.dispose();
    });

    test('the first load of the homepage, the forum list, the guide and the forum use them', () {
      String source(String path) => File(path).readAsStringSync();
      expect(source('lib/features/homepage/view/homepage_page.dart'), contains('child: const HomepagePlaceholder()'));
      expect(source('lib/features/topics/view/topics_page.dart'), contains('const TopicsPlaceholder('));
      expect(source('lib/features/latest_thread/view/latest_thread_page.dart'), contains('const ThreadListSkeleton()'));
      expect(
        source('lib/features/forum/view/forum_page.dart'),
        contains('const Expanded(child: ThreadListSkeleton())'),
      );
    });

    testWidgets('the guide list: the skeleton while it loads, no spinner over the page', (tester) async {
      final guide = _Guide('guide_new_x5.html')..hold = Completer();
      await tester.pumpWidget(
        app(
          MaterialApp(
            home: LatestThreadPage(url: '$baseUrl/x', repository: guide),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ThreadListSkeleton), findsOneWidget);
      expect(find.byType(CenteredCircularIndicator), findsNothing);
      guide.hold!.complete();
      await settle(tester);
      expect(find.byType(ThreadListSkeleton), findsNothing);
      expect(find.byType(LatestThreadCard), findsWidgets);
    });
  });

  group('2 and 5. a next page or a refresh that failed keeps what was loaded', () {
    ResponseBody json(String name) => ResponseBody.fromString(
      File('test/data/tsdmapp/$name').readAsStringSync(),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
    Never offline(RequestOptions o) => throw DioException.connectionError(requestOptions: o, reason: 'offline');

    test('forum: a refresh that failed keeps the threads and tells why; a good one replaces them', () async {
      final repository = _Forums();
      final bloc = ForumBloc(fid: '7', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((s) => s.status == ForumStatus.success);
      repository.failing = true;
      bloc.add(ForumRefreshRequested());
      final refreshing = await bloc.stream.firstWhere((s) => s.refreshing);
      expect(refreshing.normalThreadList, hasLength(2), reason: 'not cleared while it runs');
      final failed = await bloc.stream.firstWhere((s) => !s.refreshing);
      expect(failed.status, ForumStatus.success, reason: 'no retry page over the threads');
      expect(failed.normalThreadList.map((e) => e.threadID), ['10', '11']);
      expect(failed.failure?.kind, LoadFailureKind.noNetwork);
      repository.failing = false;
      bloc.add(ForumRefreshRequested());
      final again = await bloc.stream.firstWhere((s) => !s.refreshing);
      expect(again.normalThreadList.map((e) => e.threadID), ['10', '11'], reason: 'replaced, not added');
      expect(again.failure, isNull);
    });

    test('forum: one next page at a time; a page asked before a refresh is not added to the new list', () async {
      final repository = _Forums();
      final bloc = ForumBloc(fid: '7', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((s) => s.status == ForumStatus.success);
      final hold = repository.hold = Completer();
      bloc
        ..add(const ForumLoadMoreRequested(2))
        ..add(const ForumLoadMoreRequested(2));
      await bloc.stream.firstWhere((s) => s.loadingMore);
      bloc.add(ForumRefreshRequested());
      await bloc.stream.firstWhere((s) => s.refreshing);
      repository.hold = null;
      hold.complete();
      final done = await bloc.stream.firstWhere((s) => !s.refreshing);
      await Future<void>.delayed(Duration.zero);
      expect(repository.asked, [1, 2, 1], reason: 'the second next page was not asked');
      expect(bloc.state.normalThreadList.map((e) => e.threadID), ['10', '11']);
      expect(done.loadingMore, isFalse);
    });

    test('guide lists: the next page that failed keeps the threads; so does a refresh', () async {
      final guide = _Guide('guide_hot_x5.html');
      final bloc = LatestThreadBloc(latestThreadRepository: guide)
        ..add(const LatestThreadRefreshRequested('$baseUrl/x'));
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status == LatestThreadStatus.success);
      final count = loaded.threadList.length;
      guide.failing = true;
      bloc.add(LatestThreadLoadMoreRequested());
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect((failed.status, failed.threadList.length), (LatestThreadStatus.success, count));
      expect(failed.failure?.kind, LoadFailureKind.timeout);
      bloc.add(const LatestThreadRefreshRequested('$baseUrl/x'));
      final refreshed = await bloc.stream.firstWhere((s) => !s.refreshing && s.failure != null && !s.loadMoreFailed);
      expect((refreshed.status, refreshed.threadList.length), (LatestThreadStatus.success, count));
      guide.failing = false;
      bloc.add(LatestThreadLoadMoreRequested());
      final more = await bloc.stream.firstWhere((s) => s.pageNumber == 2);
      expect(more.threadList.length, count * 2);
      expect((more.loadMoreFailed, more.failure), (false, null));
    });

    test('favorites: the next page failed is told at the end of the list, a refresh keeps the records', () async {
      var failing = false;
      forum.answer = (o) => failing ? offline(o) : json('favorite_v8_thread.json');
      final repository = FavoriteRepository();
      addTearDown(repository.dispose);
      final bloc = FavoriteBloc(
        favoriteRepository: repository,
        authenticationRepository: AuthenticationRepository(user: _alice),
      )..add(const FavoriteLoadRequested());
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status == FavoriteStatus.success);
      expect(loaded.nextPageUrl, isNotNull);
      failing = true;
      bloc.add(const FavoriteLoadMoreRequested());
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect((failed.items.length, failed.failure?.kind), (20, LoadFailureKind.noNetwork));
      expect(failed.failureCount, 0, reason: 'no snack bar for it, the end of the list tells it');
      bloc.add(const FavoriteRefreshRequested());
      final refreshed = await bloc.stream.firstWhere((s) => !s.refreshing);
      expect((refreshed.status, refreshed.items.length), (FavoriteStatus.success, 20));
    });

    test('friends: the same', () async {
      var failing = false;
      forum.answer = (o) => failing ? offline(o) : json('friend_v10_me.json');
      final bloc = FriendBloc(
        friendRepository: const FriendRepository(),
        firstPageUrl: FriendRepository.listUrl(uid: '35'),
      )..add(const FriendLoadRequested());
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status == FriendStatus.success);
      failing = true;
      bloc.add(const FriendLoadMoreRequested());
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect(failed.items.length, loaded.items.length);
      bloc.add(const FriendRefreshRequested());
      final refreshed = await bloc.stream.firstWhere((s) => !s.refreshing);
      expect((refreshed.status, refreshed.items.length), (FriendStatus.success, loaded.items.length));
      expect(refreshed.failure?.kind, LoadFailureKind.noNetwork);
    });

    test("another member's lists: the next page failed, or answered the forum's message", () async {
      final repository = _MyThreads();
      final cubit = MemberThreadCubit(repository: repository, uid: '1103', session: () => (uid: 35, generation: 1));
      addTearDown(cubit.close);
      await cubit.load(MemberThreadTab.thread);
      final rows = cubit.state.thread.items.length;
      expect(rows, greaterThan(0));
      repository.next = left(HttpHandshakeFailedException('offline', connectionFailed: true));
      await cubit.loadMore(MemberThreadTab.thread);
      expect((cubit.state.thread.loadMoreFailed, cubit.state.thread.items.length), (true, rows));
      expect(cubit.state.thread.failure?.kind, LoadFailureKind.noNetwork);
      repository.next = right(const TsdmAppStructuredPage({'ok': 0, 'uid': 35, 'message': '抱歉，您沒有權限訪問'}));
      await cubit.loadMore(MemberThreadTab.thread);
      expect(cubit.state.thread.failure?.kind, LoadFailureKind.noPermission);
      expect(cubit.state.thread.items.length, rows);
    });

    test('my threads: the next page failed keeps the threads and tells why', () async {
      final repository = _MyThreads();
      final bloc = MyThreadBloc(myThreadRepository: repository)..add(MyThreadLoadInitialDataRequested());
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status == MyThreadStatus.success);
      repository.next = left(HttpHandshakeFailedException('offline', connectionFailed: true));
      bloc.add(const MyThreadLoadMoreThreadRequested());
      final failed = await bloc.stream.firstWhere((s) => s.threadLoadMoreFailed);
      expect(failed.threadList.length, loaded.threadList.length);
      expect((failed.loadingMoreThread, failed.threadFailure?.kind), (false, LoadFailureKind.noNetwork));
    });

    test('search: the end of the results appends the next page, a failure keeps them', () async {
      final repository = _Searches();
      final bloc = SearchBloc(searchRepository: repository)
        ..add(const SearchRequested(keyword: 'k', fid: '0', uid: '0', pageNumer: 1));
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((s) => s.status == SearchStatus.success);
      bloc.add(const SearchLoadMoreRequested());
      final more = await bloc.stream.firstWhere((s) => s.searchResult?.currentPage == 2);
      expect(more.searchResult!.data!.map((e) => e.tid), [1, 2, 3], reason: 'thread 2 of page 2 not twice');
      repository.failing = true;
      bloc.add(const SearchLoadMoreRequested());
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect((failed.status, failed.searchResult!.data!.length), (SearchStatus.success, 3));
      expect(repository.pages, [1, 2, 3]);
    });

    test('points: the next page that failed keeps the records, a refresh too', () async {
      var failing = false;
      forum.answer = (o) => failing ? offline(o) : json('credit_v12_log.json');
      final bloc = PointsChangelogBloc(pointsRepository: PointsRepository())..add(PointsChangelogRefreshRequested());
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((s) => s.status == PointsStatus.success);
      failing = true;
      bloc.add(const PointsChangelogLoadMoreRequested(1));
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect((failed.status, failed.fullChangelog.length, failed.currentPage), (PointsStatus.success, 20, 1));
      bloc.add(PointsChangelogRefreshRequested());
      final refreshed = await bloc.stream.firstWhere((s) => !s.refreshing && !s.loadMoreFailed);
      expect((refreshed.status, refreshed.fullChangelog.length), (PointsStatus.success, 20));
      expect(refreshed.failure?.kind, LoadFailureKind.noNetwork);
    });

    test('a conversation: an earlier page or a reload that failed keeps the messages', () async {
      var failing = false;
      forum.answer = (o) => failing ? offline(o) : json('pm_v11_view_p2.json');
      final bloc = ChatHistoryBloc(const ChatRepository())
        ..add(const ChatHistoryLoadHistoryRequested(uid: '36', page: null));
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status == ChatHistoryStatus.success);
      expect(loaded.previousPage, 2);
      failing = true;
      bloc.add(const ChatHistoryLoadHistoryRequested(uid: '36', page: 2));
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect((failed.status, failed.messages.length), (ChatHistoryStatus.success, loaded.messages.length));
      bloc.add(const ChatHistoryLoadHistoryRequested(uid: '36', page: null));
      final reload = await bloc.stream.firstWhere((s) => s.status == ChatHistoryStatus.success && !s.loadMoreFailed);
      expect((reload.messages.length, reload.failure?.kind), (loaded.messages.length, LoadFailureKind.noNetwork));
    });

    test('the dialog: a reload that failed keeps the messages, nothing shown yet is the failure', () async {
      var failing = true;
      forum.answer = (o) => failing
          ? offline(o)
          : ResponseBody.fromString(
              File('test/data/chat_dialog_x5.xml').readAsStringSync(),
              200,
              headers: {
                Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
              },
            );
      final bloc = ChatBloc(const ChatRepository())..add(const ChatFetchHistoryRequested('31'));
      addTearDown(bloc.close);
      final first = await bloc.stream.firstWhere((s) => s.status == ChatStatus.failure);
      expect(first.failure?.kind, LoadFailureKind.noNetwork);
      failing = false;
      bloc.add(const ChatFetchHistoryRequested('31'));
      final loaded = await bloc.stream.firstWhere((s) => s.status == ChatStatus.success);
      expect(loaded.messageList, isNotEmpty);
      failing = true;
      bloc.add(const ChatFetchHistoryRequested('31'));
      await bloc.stream.firstWhere((s) => s.status == ChatStatus.loading);
      final kept = await bloc.stream.firstWhere((s) => s.status != ChatStatus.loading);
      expect((kept.status, kept.messageList.length), (ChatStatus.success, loaded.messageList.length));
      expect(kept.failure?.kind, LoadFailureKind.noNetwork);
    });

    test('drafts: a refresh that failed keeps the rows of the account', () async {
      var fail = false;
      final cubit = DraftCubit(
        currentUid: () => 1000,
        repository: () => DraftRepository((_) async {
          if (fail) throw StateError('synthetic failure');
          return draftList();
        }),
      );
      addTearDown(cubit.close);
      await cubit.load();
      final rows = cubit.state.entries;
      expect(rows, isNotEmpty);
      fail = true;
      await cubit.load();
      expect((cubit.state.failed, cubit.state.entries), (true, rows));
    });
  });

  group('2, 4 and 5. the pages', () {
    /// The forum page of [repository] in a phone window, as test_079 hosts it.
    Future<void> pumpForum(WidgetTester tester, ForumRepository repository) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository(user: _alice);
      final favorites = FavoriteRepository();
      addTearDown(favorites.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const ForumPage(fid: '7'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<ForumRepository>.value(value: repository),
              RepositoryProvider<FavoriteRepository>.value(value: favorites),
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
              RepositoryProvider<NotificationRepository>(create: (_) => NotificationRepository()),
              RepositoryProvider<NotificationInfoRepository>(create: (_) => NotificationInfoRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<NotificationStateCubit>(
                  create: (ctx) => NotificationStateCubit(RepositoryProvider.of<NotificationInfoRepository>(ctx)),
                ),
                BlocProvider<NotificationBloc>(
                  create: (ctx) => NotificationBloc(
                    notificationRepository: RepositoryProvider.of<NotificationRepository>(ctx),
                    infoRepository: RepositoryProvider.of<NotificationInfoRepository>(ctx),
                    authRepo: auth,
                    storageProvider: storage,
                  ),
                ),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('forum: the end of the list asks the next page, tells its failure, retries; no more at the end', (
      tester,
    ) async {
      final repository = _Forums(pages: 2);
      repository.failing = false;
      await pumpForum(tester, repository);
      // Two threads fit the screen: the end of the list is in view and asked page 2 by itself.
      expect(repository.asked, [1, 2]);
      expect(find.text(t.general.noMoreData), findsOneWidget, reason: 'the forum has two pages');
      expect(find.byType(NormalThreadCard), findsNWidgets(4));

      final failing = _Forums()..failPages.add(2);
      await tester.pumpWidget(const SizedBox());
      await pumpForum(tester, failing);
      // Page 1 came, page 2 failed: the threads stay, the end of the list tells why.
      expect(find.byType(NormalThreadCard), findsNWidgets(2));
      final told = t.loadState.footer.failed(reason: t.loadState.failure.noNetwork.title);
      expect(find.text(told), findsOneWidget);
      failing.failPages.clear();
      await tester.tap(find.byKey(listFooterRetryKey));
      await settle(tester);
      expect(find.text(told), findsNothing);
      expect(failing.asked, [1, 2, 2, 3], reason: 'the retry asked page 2 again, then the list went on');
    });

    testWidgets('forum: a pull that failed keeps the threads and says why', (tester) async {
      final repository = _Forums(pages: 1);
      await pumpForum(tester, repository);
      repository.failing = true;
      final bloc = BlocProvider.of<ForumBloc>(tester.element(find.byType(CustomScrollView)));
      bloc.add(ForumRefreshRequested());
      await settle(tester);
      expect(find.byType(NormalThreadCard), findsNWidgets(2));
      expect(find.text(t.loadState.refreshFailed(reason: t.loadState.failure.noNetwork.title)), findsOneWidget);
    });

    testWidgets('forum: nothing left by the filters is not "no thread", and clears them', (tester) async {
      final repository = _Forums(pages: 1);
      await pumpForum(tester, repository);
      final bloc = BlocProvider.of<ForumBloc>(tester.element(find.byType(CustomScrollView)));
      bloc.add(const ForumChangeThreadFilterStateRequested(FilterState(filterDigest: FilterDigest(digest: true))));
      await settle(tester);
      expect(find.text(t.forumPage.threadTab.noFilteredThread), findsOneWidget);
      expect(find.text(t.forumPage.threadTab.noThread), findsNothing);
      await tester.tap(find.text(t.forumPage.threadTab.clearFilter));
      await settle(tester);
      expect(bloc.state.filterState.isFiltering(), isFalse);
      expect(find.byType(NormalThreadCard), findsNWidgets(2));
    });

    testWidgets('search: nothing found with an author limit says to widen it', (tester) async {
      forum.answer = (o) => ResponseBody.fromString(
        '<div id="messagetext"><p>没有找到匹配结果</p></div>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
      await tester.pumpWidget(app(const MaterialApp(home: SearchPage(authorUid: '35'))));
      await settle(tester);
      expect(find.text(t.searchPage.result.noData), findsOneWidget);
      expect(find.text(t.searchPage.result.noDataFiltered), findsOneWidget);
    });

    testWidgets('favorites: an empty tab says how a thread gets in it', (tester) async {
      forum.answer = (o) => ResponseBody.fromString(
        File('test/data/tsdmapp/favorite_v8_empty.json').readAsStringSync(),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
      final repository = FavoriteRepository();
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        app(
          RepositoryProvider<FavoriteRepository>.value(
            value: repository,
            child: const MaterialApp(home: FavoritePage()),
          ),
        ),
      );
      await settle(tester);
      expect(find.text(t.favoritePage.empty), findsOneWidget);
      expect(find.text(t.favoritePage.emptyHint), findsOneWidget);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['STATE_SHOTS_DIR'];
    final font = Platform.environment['STATE_SHOTS_FONT'];
    final skip = dir == null || font == null ? 'set STATE_SHOTS_DIR and STATE_SHOTS_FONT to write them' : null;
    const family = 'ShotSans';
    const frame = Size(390, 760);

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

    Widget page(String title, Widget body) => SizedBox.fromSize(
      size: frame,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: body,
      ),
    );

    Widget listEndingWith(ListFooter footer) => ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      children: [
        for (final tid in [101, 102, 103]) ...[NormalThreadCard(_thread(tid)), appListSeparator],
        footer,
      ],
    );

    Map<String, List<Widget>> sheets() {
      final f = t.forumPage.threadTab;
      return {
        'failures': [
          page('版塊', FailureView(failure: LoadFailure(LoadFailureKind.noNetwork), onRetry: () {})),
          page(
            t.searchPage.title,
            FailureView(
              failure: LoadFailure(
                LoadFailureKind.rateLimited,
                message: '抱歉，您在 20 秒内只能进行一次搜索',
                retryAfterSeconds: 20,
              ),
              onRetry: () {},
            ),
          ),
          page(t.favoritePage.title, FailureView(failure: LoadFailure(LoadFailureKind.needLogin), onRetry: () {})),
          page(
            '某個版塊',
            FailureView(failure: LoadFailure.fromMessage('抱歉，您沒有權限訪問該版塊'), onRetry: () {}),
          ),
          page(
            t.latestThreadPage.title,
            FailureView(
              failure: LoadFailure.of(
                HttpHandshakeFailedException(
                  'This exception was thrown because the response has a status code of 502',
                  statusCode: 502,
                ),
              ),
              onRetry: () {},
            ),
          ),
        ],
        'empty': [
          page(
            t.favoritePage.title,
            AppStateView(icon: Icons.star_outline, message: t.favoritePage.empty, detail: t.favoritePage.emptyHint),
          ),
          page(
            'Board',
            AppStateView(
              icon: Icons.filter_alt_off_outlined,
              message: f.noFilteredThread,
              action: FilledButton.tonalIcon(
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: Text(f.clearFilter),
                onPressed: () {},
              ),
            ),
          ),
          page(
            t.searchPage.title,
            AppStateView(
              icon: Icons.search_off_outlined,
              message: t.searchPage.result.noData,
              detail: t.searchPage.result.noDataFiltered,
            ),
          ),
        ],
        'skeletons': [
          page('Board', const ThreadListSkeleton()),
          page(t.homepage.title, const HomepagePlaceholder()),
          page(t.navigation.topics, const TopicsPlaceholder()),
        ],
        'footers': [
          page('Board', listEndingWith(const ListFooter(status: ListFooterStatus.loading))),
          page('Board', listEndingWith(const ListFooter(status: ListFooterStatus.noMore))),
          page(
            'Board',
            listEndingWith(
              ListFooter(
                status: ListFooterStatus.failed,
                failure: LoadFailure(LoadFailureKind.timeout),
                onRetry: () {},
              ),
            ),
          ),
        ],
      };
    }

    for (final dark in [false, true]) {
      for (final name in ['failures', 'empty', 'skeletons', 'footers']) {
        testWidgets('$name, ${dark ? 'dark' : 'light'}', skip: skip != null, (tester) async {
          final frames = sheets()[name]!;
          tester.view
            ..physicalSize = Size(frame.width * frames.length + 16.0 * (frames.length + 1), frame.height + 32)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final theme = dark
              ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: family)
              : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: family);
          const key = ValueKey('sheet');
          await tester.pumpWidget(
            app(
              MaterialApp(
                theme: theme,
                debugShowCheckedModeBanner: false,
                home: RepaintBoundary(
                  key: key,
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerLowest,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, f) in frames.indexed) ...[if (i > 0) const SizedBox(width: 16), f],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          if (name == 'failures') {
            await tester.tap(find.byKey(failureDetailsKey).last);
            await tester.pump();
          }
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
          final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
          image.dispose();
          Directory(dir!).createSync(recursive: true);
          File('$dir/${name}_${dark ? 'dark' : 'light'}.png').writeAsBytesSync(bytes.buffer.asUint8List());
        });
      }
    }
  });
}

final class _FakeContext extends Fake implements BuildContext {}
