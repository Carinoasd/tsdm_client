import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_search.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
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

/// Search in a thread (the app bar's "search in thread"): the floors on screen are searched, their text without the
/// markup and their authors, whatever the case; the previous and next hits go round the hits in the order shown; the
/// hits are marked (a line at the floor's side, the words in its text) until the search is closed; pages not loaded
/// are offered to load, and searched once they are.
///
/// The thread pages are synthetic (grounded in the Discuz template), no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  void add(NotificationEvent event) {}

  @override
  final NotificationState state;

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Serves the thread page asked for (`page=N`) from [pages].
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.pages);

  List<String> pages;

  final asked = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'search tests must never perform a forum write');
    final page = (int.tryParse(options.uri.queryParameters['page'] ?? '') ?? 1).clamp(1, pages.length);
    asked.add(page);
    return ResponseBody.fromString(
      pages[page - 1],
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Post id of floor [floor].
int _pid(int floor) => 9000 + floor;

/// A floor, tall enough (many lines) that the list is far from its end on the first floors.
String _floor(int floor, {String text = '', String name = 'Alice', int uid = 1000}) {
  final pid = _pid(floor);
  final lines = '<br>line' * 30;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor $text$lines</div></div></div></td>
</tr></tbody></table></div>''';
}

/// Page [page] of [pages] of the thread, holding [floors].
String _threadPage(List<String> floors, {int page = 1, int pages = 1}) {
  String link(int p, String text, {String cls = ''}) =>
      '<a href="forum.php?mod=viewthread&amp;tid=1269&amp;page=$p"${cls.isEmpty ? '' : ' class="$cls"'}>$text</a>';
  final pager = pages <= 1
      ? ''
      : '<div class="pg">'
            '${[for (var p = 1; p <= pages; p++) p == page ? '<strong>$p</strong>' : link(p, '$p')].join()}'
            '${page < pages ? link(page + 1, '下一页', cls: 'nxt') : ''}</div>';
  return '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1269" /></head><body>
<div id="pgt">$pager</div>
<div id="postlist"><h1 class="ts"><span id="thread_subject">Search title</span></h1><div class="bm">
${floors.join('\n')}
</div></div>
</body></html>''';
}

/// One page of ten floors: the word in floors 3, 6 and 9 (in a quote) written in three cases, and in the name of the
/// author of floor 5.
List<String> _onePage({bool reversed = false}) {
  final floors = [
    for (var f = 1; f <= 10; f++)
      _floor(
        f,
        text: switch (f) {
          3 => 'a Needle here',
          6 => 'NEEDLE again',
          9 => '<div class="quote"><blockquote>quoted needle</blockquote></div>',
          _ => 'hay',
        },
        name: f == 5 ? 'NeedleFan' : 'Alice',
        uid: f == 5 ? 2000 : 1000,
      ),
  ];
  return [_threadPage(reversed ? floors.reversed.toList() : floors)];
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late AuthenticationRepository auth;
  late _ThreadAdapter adapter;

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
    adapter = _ThreadAdapter(_onePage());
    getIt
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      )
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        ),
      );
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = AuthenticationRepository(user: _alice);
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await blocks.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    final cubit = UserBlockCubit(repository: blocks, currentUid: () => _alice.uid, authStatus: auth.status);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const ThreadPage(
            threadID: '1269',
            findPostID: null,
            pageNumber: '1',
            overrideReverseOrder: false,
            overrideWithExactOrder: null,
          ),
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await cubit.close();
      await info.dispose();
      await counts.close();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: cubit),
              BlocProvider<NotificationBloc>.value(
                value: _Notifications(const NotificationState(status: NotificationStatus.success)),
              ),
              BlocProvider<NotificationStateCubit>.value(value: counts),
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder searchField() => find.byKey(const ValueKey('thread-search-field'));
  Finder count() => find.byKey(const ValueKey('thread-search-count'));
  String countText(WidgetTester tester) => tester.widget<Text>(count()).data!;
  Finder hitMark(int floor) => find.byKey(ValueKey('thread-search-hit-${_pid(floor)}'));
  Finder appBarMenu() => find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert));
  Finder loadMore() => find.byKey(const ValueKey('thread-search-load-more'));

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(appBarMenu());
    // The menu opened all the way.
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    await tester.tap(find.text('Search in thread'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(searchField(), findsOneWidget);
  }

  /// Type [text], and wait for the search to settle on it.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(searchField(), text);
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
  }

  /// Let the hold of a floor brought into view end (2 s).
  Future<void> holdEnds(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
  }

  /// Floor [floor] is a hit at the top of the list: its mark right under the app bar.
  void expectAtTop(WidgetTester tester, int floor) {
    expect(hitMark(floor), findsOneWidget, reason: 'floor $floor is built and marked');
    final top = tester.getRect(find.byType(AppBar)).bottom;
    final mark = tester.getRect(hitMark(floor));
    expect(mark.top, inInclusiveRange(top, top + 120), reason: 'floor $floor is at the top of the list');
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey('thread-search-$key')));
    await settle(tester);
  }

  /// The text marked as found in the floors built.
  List<String> marked(WidgetTester tester) {
    final found = <String>[];
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      text.text.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor != null && span.text != null) {
          found.add(span.text!);
        }
        return true;
      });
    }
    return found;
  }

  test('the pattern: every word in order, any white space between them, any case', () {
    expect(threadSearchPattern('   '), isNull);
    final pattern = threadSearchPattern(' foo  Bar ')!;
    expect(pattern.hasMatch('xx FOO\n bar yy'), isTrue);
    expect(pattern.hasMatch('bar foo'), isFalse);
    expect(threadSearchPattern('a.b')!.hasMatch('axb'), isFalse, reason: 'the words are not a regular expression');
  });

  test('the hits: each floor once in the order given, a hot reply only without its floor, never a hidden one', () {
    Post post(String pid, String data, {bool hot = false, String? uid, String? signature}) => Post(
      postID: pid,
      postFloor: hot ? null : int.parse(pid),
      author: User(name: 'u$pid', url: 'u', uid: uid),
      publishTime: DateTime(2026, 11, 3),
      data: data,
      replyAction: null,
      rateAction: null,
      lastEditUsername: null,
      lastEditTime: null,
      shareLink: null,
      page: 1,
      isDraft: false,
      packetAllTaken: false,
      hot: hot,
      signature: signature,
    );
    final posts = [
      post('7', 'a <b>Needle</b>', hot: true),
      post('8', 'needle', hot: true),
      post('1', 'hay', signature: 'needle in the signature'),
      post('2', '<span style="display:none">needle</span>hay<style>.needle{}</style>'),
      post('3', 'NEE<font color="red">DLE</font>'),
      post('4', 'needle', uid: '66'),
      post('7', 'needle'),
    ];
    final hits = threadSearchHits(posts, threadSearchPattern('needle')!, hidden: (e) => e.author.uid == '66');
    expect(hits.map((e) => e.postID), ['8', '3', '7'], reason: 'the hot copy of floor 7 left out, floor 8 only hot');
    expect(hits.first.hot, isTrue);
  });

  testWidgets('a search counts the floors found whatever the case, author names and quotes included', (tester) async {
    await pump(tester);
    await openSearch(tester);
    expect(count(), findsNothing, reason: 'nothing counted before anything is typed');
    await type(tester, 'nEeDlE');
    expect(countText(tester), '1 / 4', reason: 'floors 3, 5 (author), 6 and 9 (quote), the first one current');
    expect(adapter.asked, [1], reason: 'only the loaded page is searched, nothing more is asked');
    expect(loadMore(), findsNothing, reason: 'the only page is loaded');
    expectAtTop(tester, 3);
    expect(marked(tester), contains('Needle'), reason: 'the word is marked in the text as written');
    await holdEnds(tester);
  });

  testWidgets('next and previous go round the hits in the order shown', (tester) async {
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expectAtTop(tester, 3);
    await tapKey(tester, 'next');
    expect(countText(tester), '2 / 4');
    expectAtTop(tester, 5);
    await tapKey(tester, 'next');
    await tapKey(tester, 'next');
    expect(countText(tester), '4 / 4');
    expectAtTop(tester, 9);
    await tapKey(tester, 'next');
    expect(countText(tester), '1 / 4', reason: 'past the last hit, back to the first');
    expectAtTop(tester, 3);
    await tapKey(tester, 'previous');
    expect(countText(tester), '4 / 4', reason: 'before the first hit, the last one');
    expectAtTop(tester, 9);
    await tapKey(tester, 'previous');
    expect(countText(tester), '3 / 4');
    expectAtTop(tester, 6);
    await holdEnds(tester);
  });

  testWidgets('newest first, the hits go in the order shown', (tester) async {
    adapter.pages = _onePage(reversed: true);
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 4');
    expectAtTop(tester, 9);
    await tapKey(tester, 'next');
    expectAtTop(tester, 6);
    await holdEnds(tester);
  });

  testWidgets('nothing found counts 0 / 0, and the arrows do nothing', (tester) async {
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'nowhere');
    expect(countText(tester), '0 / 0');
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('thread-search-next'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('thread-search-previous'))).onPressed, isNull);
    expect(marked(tester), isEmpty);
  });

  testWidgets('closing the search drops the marks and brings the app bar back', (tester) async {
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(hitMark(3), findsOneWidget);
    expect(marked(tester), isNotEmpty);
    await holdEnds(tester);
    await tapKey(tester, 'close');
    expect(searchField(), findsNothing);
    expect(appBarMenu(), findsOneWidget);
    expect(hitMark(3), findsNothing);
    expect(marked(tester), isEmpty, reason: 'the floors are munched again without the marks');
    expect(find.textContaining('a Needle here', findRichText: true), findsWidgets);
  });

  testWidgets('a page not loaded yet is offered, loaded on demand and searched', (tester) async {
    // A small phone: the search bar fits with every button.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 780);
    addTearDown(tester.view.reset);
    adapter.pages = [
      _threadPage([for (var f = 1; f <= 10; f++) _floor(f, text: f == 1 ? 'needle' : 'hay')], pages: 2),
      _threadPage([for (var f = 11; f <= 20; f++) _floor(f, text: f == 15 ? 'needle' : 'hay')], page: 2, pages: 2),
    ];
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 1');
    expect(adapter.asked, [1], reason: 'the search itself loads nothing');
    expect(loadMore(), findsOneWidget);
    await holdEnds(tester);

    await tester.tap(loadMore());
    await settle(tester);
    expect(adapter.asked, [1, 2]);
    expect(countText(tester), '1 / 2', reason: 'searched again with the new page, the current hit kept');
    expect(loadMore(), findsNothing, reason: 'every page is loaded');
    await tapKey(tester, 'next');
    expect(countText(tester), '2 / 2');
    expectAtTop(tester, 15);
    await holdEnds(tester);
  });
}

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
