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
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_search.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/collapsing_app_bar.dart';
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
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// Search in a thread (the app bar's "search in thread"): the floors on screen are searched, their text without the
/// markup and their authors, whatever the case; the previous and next hits go round the hits in the order shown; the
/// hits are marked (a line at the floor's side, the words in its text) until the search is closed; pages not loaded
/// are offered to load, and searched once they are.
///
/// Review follow-up: words are searched once they settle and not while composed by an input method; the search bar
/// stays (the bar does not collapse) and is as tall as the app bar; back closes the search, not the page, and the page
/// stays one that may be closed on its own; a page loaded for the search never drops the page read; the current hit
/// gone (its author blocked) moves to the closest one; the hot copy of a floor is not marked; quotes of blocked users
/// and words split by a line break are not hits; the real newest first order and one author's floors are searched in
/// the order shown.
///
/// Second round: what is searched is what is shown (the same rules as the munched content, `HiddenContent`: a fold's
/// content in, what the `hidden` attribute, `visibility: hidden` or a style sheet hides out); the author's name is
/// searched apart from the text; going from hit to hit, or typing the same words in another case, munches no floor
/// again and keeps the current hit.
///
/// Third round: the floors replaced while searching (one author's floors from a floor's menu, every author's again)
/// have pages of their own: the pages searched before are let go, and a page of theirs may be loaded for the search.
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

/// Serves the thread page asked for (`page=N`) from [pages]; asked newest first (`ordertype=1`), from [newestFirst]
/// when set; asked for one author's floors (`authorid`), from [byAuthor] when set.
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.pages);

  List<String> pages;

  List<String>? newestFirst;

  Map<String, List<String>>? byAuthor;

  final asked = <int>[];

  final queries = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'search tests must never perform a forum write');
    final query = options.uri.queryParameters;
    queries.add(query);
    final served = switch ((query['ordertype'], query['authorid'])) {
      (_, final String uid) when byAuthor?[uid] != null => byAuthor![uid]!,
      ('1', _) when newestFirst != null => newestFirst!,
      _ => pages,
    };
    final page = (int.tryParse(query['page'] ?? '') ?? 1).clamp(1, served.length);
    asked.add(page);
    return ResponseBody.fromString(
      served[page - 1],
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

/// A floor, tall enough (many lines) that the list is far from its end on the first floors; [hot] for its copy as a
/// hot reply (numbered -1 by the forum).
String _floor(int floor, {String text = '', String name = 'Alice', int uid = 1000, int lines = 30, bool hot = false}) {
  final pid = _pid(floor);
  final more = '<br>line' * lines;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>${hot ? -1 : floor}</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor $text$more</div></div></div></td>
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

  /// The thread page opened at [page]; [stacked] over a home page (`/`) it can be closed to.
  Future<void> pump(
    WidgetTester tester, {
    int page = 1,
    bool reverseOrder = false,
    String? onlyVisibleUid,
    bool stacked = false,
  }) async {
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    final cubit = UserBlockCubit(repository: blocks, currentUid: () => _alice.uid, authStatus: auth.status);
    final thread = ThreadPage(
      threadID: '1269',
      findPostID: null,
      pageNumber: '$page',
      overrideReverseOrder: reverseOrder,
      overrideWithExactOrder: null,
      onlyVisibleUid: onlyVisibleUid,
    );
    final router = GoRouter(
      initialLocation: stacked ? '/thread' : '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => stacked ? const Scaffold(body: Text('home')) : thread,
          routes: [GoRoute(path: 'thread', builder: (_, _) => thread)],
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
  bool loadMoreEnabled(WidgetTester tester) => tester.widget<IconButton>(loadMore()).onPressed != null;

  /// Load the page offered for the search.
  Future<void> loadForSearch(WidgetTester tester) async {
    expect(loadMoreEnabled(tester), isTrue);
    await tester.tap(loadMore());
    await settle(tester);
  }

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

  /// The munched content of the floor whose text holds [text]: the same widget while the floor is not munched again.
  Widget munchedOf(WidgetTester tester, String text) => tester.widget<ClipRect>(
    find
        .descendant(
          of: find.descendant(
            of: find.ancestor(of: find.textContaining(text, findRichText: true), matching: find.byType(PostCard)),
            matching: find.byType(MunchedHtml),
          ),
          matching: find.byType(ClipRect),
        )
        .first,
  );

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

  test('the text searched is what is shown: a fold in, what an attribute, a style or the style sheets hide out', () {
    Post post(String data) => Post(
      postID: '1',
      postFloor: 1,
      author: const User(name: 'Alice', url: 'u', uid: '1000'),
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
    );
    String text(String data) => threadSearchText(post(data)).replaceAll(RegExp(r'\s+'), ' ').trim();

    // A fold the post made itself (shown by a click on another element) is shown by the app as a spoiler: searched.
    expect(
      text(
        '<div onclick="document.getElementById(\'c1\').style.display=\'\'">▼ 展开</div> '
        '<div id="c1" style="display:none">fold needle</div>后文',
      ),
      '▼ 展开 fold needle 后文',
    );
    expect(
      text('<a href="javascript:;" onclick="\$(\'c2\').style.display=\'\'">开</a><div id="c2" hidden>in</div>'),
      '开 in',
    );
    // Hidden and no fold: nothing shows it, or it is one of the forum's popups.
    expect(text('a<div id="lonely" style="display:none">needle</div>b'), 'ab');
    expect(
      text(
        'a<div id="aimg_1_menu" class="tip" style="display:none">needle</div><span onclick="\$(\'aimg_1_menu\')">图</span>',
      ),
      'a图',
    );
    // Hidden as the web page hides it, whatever the way.
    expect(text('a<span hidden>needle</span>b'), 'ab');
    expect(text('a<span style="visibility:hidden">needle</span>b'), 'ab');
    expect(text('a<span style="DISPLAY:NONE">needle</span>b'), 'ab');
    expect(text('a<span style="color:red; display : none">needle</span>b'), 'ab');
    // The style sheet after some text: a leading `<style>` is moved to the head by the parser, for the muncher too.
    expect(text('a<style>.answer{display:none}</style><span class="answer">needle</span>b'), 'ab');
    expect(text('a<font class="jammer">needle</font>b'), 'ab');
    expect(text('a<script>needle</script><form><input value="needle"></form>b'), 'ab');
    // Shown: a style that does not hide, a class the style sheets do not hide.
    expect(text('a<span style="display:inline-block">needle</span>b'), 'aneedleb');
    expect(text('a<style>.q{color:red}</style><span class="q">needle</span>b'), 'aneedleb');
  });

  test('the author is searched apart from the text: words are not found across the two', () {
    Post post(String pid, String name, String data) => Post(
      postID: pid,
      postFloor: int.parse(pid),
      author: User(name: name, url: 'u', uid: '1000'),
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
    );
    final posts = [post('1', 'Alice', '你好'), post('2', 'Bob', 'Alice 你好')];
    expect(threadSearchText(posts.first), isNot(contains('Alice')), reason: 'the name is not part of the text');
    List<String> hits(String query) =>
        threadSearchHits(posts, threadSearchPattern(query)!).map((e) => e.author.name).toList();
    expect(hits('Alice 你好'), ['Bob'], reason: 'floor by Alice starting with 你好 is no hit');
    expect(hits('alice'), ['Alice', 'Bob'], reason: 'the name is searched, whatever the case');
    expect(hits('你好'), ['Alice', 'Bob']);
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

  testWidgets('going from hit to hit keeps the state of the floors', (tester) async {
    // Short floors: all of them on screen together.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 3000);
    addTearDown(tester.view.reset);
    adapter.pages = [
      _threadPage([
        for (var f = 1; f <= 8; f++)
          _floor(f, text: f == 3 ? 'a Needle here' : (f == 6 ? 'NEEDLE again' : 'hay'), lines: 1),
      ]),
    ];
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    State<StatefulWidget> card(String text) =>
        tester.state(find.ancestor(of: find.textContaining(text, findRichText: true), matching: find.byType(PostCard)));
    final third = card('floor 3 a Needle');
    final sixth = card('floor 6 NEEDLE');
    final thirdContent = munchedOf(tester, 'floor 3 a Needle');
    final sixthContent = munchedOf(tester, 'floor 6 NEEDLE');
    expect(marked(tester), ['Needle', 'NEEDLE'], reason: 'the words are marked the same in every hit');
    await tapKey(tester, 'next');
    expect(countText(tester), '2 / 2');
    expect(card('floor 3 a Needle'), same(third), reason: 'the floor left is not built anew');
    expect(card('floor 6 NEEDLE'), same(sixth), reason: 'the floor gone to is not built anew');
    expect(munchedOf(tester, 'floor 3 a Needle'), same(thirdContent), reason: 'the floor left is not munched again');
    expect(munchedOf(tester, 'floor 6 NEEDLE'), same(sixthContent), reason: 'the floor gone to is not munched again');
    expect(marked(tester), ['Needle', 'NEEDLE']);
    await holdEnds(tester);
  });

  testWidgets('the same words in another case keep the current hit and munch no floor again', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 3000);
    addTearDown(tester.view.reset);
    adapter.pages = [
      _threadPage([
        for (var f = 1; f <= 8; f++)
          _floor(f, text: f == 3 ? 'a Needle here' : (f == 6 ? 'NEEDLE again' : 'hay'), lines: 1),
      ]),
    ];
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    await tapKey(tester, 'next');
    expect(countText(tester), '2 / 2');
    final sixthContent = munchedOf(tester, 'floor 6 NEEDLE');
    await type(tester, 'NEEDLE');
    expect(countText(tester), '2 / 2', reason: 'the same hits, the current one kept');
    expect(munchedOf(tester, 'floor 6 NEEDLE'), same(sixthContent));
    await type(tester, 'needle again');
    expect(countText(tester), '1 / 1', reason: 'other words: searched anew');
    expect(munchedOf(tester, 'floor 6 NEEDLE'), isNot(same(sixthContent)), reason: 'marked anew');
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

  testWidgets('the words are searched once they settled for a moment, not at every key', (tester) async {
    await pump(tester);
    await openSearch(tester);
    await tester.enterText(searchField(), 'needle');
    await tester.pump(const Duration(milliseconds: 200));
    expect(count(), findsNothing, reason: 'still typing: nothing searched yet');
    expect(hitMark(3), findsNothing);
    await tester.enterText(searchField(), 'needle ');
    await tester.pump(const Duration(milliseconds: 200));
    expect(count(), findsNothing, reason: 'every key starts the wait again');
    await tester.pump(const Duration(milliseconds: 150));
    await settle(tester);
    expect(countText(tester), '1 / 4');
    await holdEnds(tester);
  });

  testWidgets('nothing is searched while the input method composes the words', (tester) async {
    await pump(tester);
    await openSearch(tester);
    await tester.showKeyboard(searchField());
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'needle',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(count(), findsNothing, reason: 'the words are not chosen yet');
    expect(hitMark(3), findsNothing, reason: 'nothing brought into view while composing');
    // Enter while composing chooses the words; it does not search.
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(count(), findsNothing);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'needle', selection: TextSelection.collapsed(offset: 6)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(countText(tester), '1 / 4', reason: 'searched once the words are chosen, the text unchanged');
    expectAtTop(tester, 3);
    await holdEnds(tester);
  });

  testWidgets('Enter goes to the next hit and the field keeps the focus', (tester) async {
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    await holdEnds(tester);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(countText(tester), '2 / 4');
    final editable = find.descendant(of: searchField(), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue, reason: 'still in the search field');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(countText(tester), '3 / 4');
    await holdEnds(tester);
  });

  testWidgets('the search bar is as tall as the app bar and stays while the floors are scrolled', (tester) async {
    await pump(tester);
    final height = tester.getSize(find.byType(CollapsingAppBar)).height;
    await openSearch(tester);
    expect(tester.getSize(find.byType(CollapsingAppBar)).height, height, reason: 'the floors do not move');
    await type(tester, 'nowhere');
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(tester.getSize(find.byType(CollapsingAppBar)).height, height, reason: 'the search bar does not collapse');
    expect(tester.getRect(searchField()).top, greaterThanOrEqualTo(0));

    await tapKey(tester, 'close');
    expect(tester.getSize(find.byType(CollapsingAppBar)).height, height);
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(
      tester.getSize(find.byType(CollapsingAppBar)).height,
      lessThan(height),
      reason: 'the app bar collapses again',
    );
  });

  testWidgets('back closes the search first, then the page; the page may still be closed on its own', (tester) async {
    await pump(tester, stacked: true);
    await openSearch(tester);
    await type(tester, 'needle');
    await holdEnds(tester);
    final route = ModalRoute.of(tester.element(find.byType(ThreadPage)))!;
    expect(route.popDisposition, isNot(RoutePopDisposition.doNotPop), reason: 'no PopScope holding the page');
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(searchField(), findsNothing, reason: 'the search closed');
    expect(find.byType(ThreadPage), findsOneWidget, reason: 'the page stays');
    expect(hitMark(3), findsNothing);
    await tester.binding.handlePopRoute();
    // The page goes away over a few frames.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await settle(tester);
    expect(find.byType(ThreadPage), findsNothing, reason: 'then back closes the page');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('asked newest first, the hits go in the order the forum shows them', (tester) async {
    final floors = [
      for (var f = 1; f <= 10; f++)
        _floor(f, text: f == 3 || f == 6 || f == 9 ? 'needle' : 'hay', name: f == 5 ? 'NeedleFan' : 'Alice'),
    ];
    // The forum keeps the first floor first and puts the latest replies after it.
    adapter.newestFirst = [
      _threadPage([floors.first, ...floors.skip(1).toList().reversed]),
    ];
    await tester.runAsync(() => settings.setValue(SettingsKeys.threadReverseOrder, true));
    await pump(tester, reverseOrder: true);
    expect(adapter.queries.first['ordertype'], '1');
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 4');
    expectAtTop(tester, 9);
    for (final floor in [6, 5, 3, 9]) {
      await tapKey(tester, 'next');
      expectAtTop(tester, floor);
    }
    await holdEnds(tester);
  });

  testWidgets("one author's floors are searched, only theirs", (tester) async {
    adapter.byAuthor = {
      '1000': [
        _threadPage([
          for (final f in [1, 3, 6, 9]) _floor(f, text: f == 1 ? 'hay' : 'needle'),
        ]),
      ],
    };
    await pump(tester, onlyVisibleUid: '1000');
    expect(adapter.queries.first['authorid'], '1000');
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 3');
    expectAtTop(tester, 3);
    await tapKey(tester, 'next');
    expectAtTop(tester, 6);
    await tapKey(tester, 'previous');
    await tapKey(tester, 'previous');
    expect(countText(tester), '3 / 3');
    expectAtTop(tester, 9);
    await holdEnds(tester);
  });

  testWidgets("one author's floors from a floor's menu, and every author's again, have pages of their own to load", (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 780);
    addTearDown(tester.view.reset);
    // Floors short enough for the menu at the end of the first one to be on screen, tall enough for three of them to
    // fill the screen (the list asks for no page of its own).
    String floor(int f, {required int hit}) => _floor(f, text: f == hit ? 'needle' : 'hay', lines: 12);
    adapter.pages = [
      _threadPage([for (var f = 1; f <= 10; f++) floor(f, hit: 1)], pages: 2),
      _threadPage([for (var f = 11; f <= 20; f++) floor(f, hit: 15)], page: 2, pages: 2),
    ];
    adapter.byAuthor = {
      '1000': [
        _threadPage([
          for (final f in [1, 4, 7]) floor(f, hit: 7),
        ], pages: 2),
        _threadPage(
          [
            for (final f in [12, 15, 18]) floor(f, hit: 15),
          ],
          page: 2,
          pages: 2,
        ),
      ],
    };
    Finder floorMenu(int floor) => find.descendant(
      of: find.ancestor(of: find.textContaining('floor $floor ', findRichText: true), matching: find.byType(PostCard)),
      matching: find.byIcon(Icons.more_vert),
    );
    Future<void> chooseFromMenu(WidgetTester tester, int floor, String item) async {
      await tester.tap(floorMenu(floor));
      await tester.pump(const Duration(milliseconds: 500));
      await settle(tester);
      await tester.tap(find.text(item));
      await settle(tester);
    }

    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    await holdEnds(tester);
    await loadForSearch(tester);
    expect(countText(tester), '1 / 2');
    expect(loadMore(), findsNothing, reason: 'both pages of every author searched');

    // One author's floors: page 2 is asked for, their page 2, with pages of their own.
    await chooseFromMenu(tester, 1, 'Only view the author');
    expect(adapter.queries.last['authorid'], '1000');
    expect(adapter.asked.last, 2);
    expect(countText(tester), '1 / 1', reason: 'floor 15 among floors 12, 15 and 18');
    expect(loadMore(), findsOneWidget, reason: "the author's page 1 was not searched");
    await loadForSearch(tester);
    expect(adapter.asked.last, 1);
    expect(adapter.queries.last['authorid'], '1000');
    expect(countText(tester), '2 / 2', reason: 'floor 7 found before floor 15, the current hit kept');
    expect(loadMore(), findsNothing);

    // Every author's floors again: pages of their own too.
    await chooseFromMenu(tester, 12, 'View all authors');
    expect(adapter.queries.last.containsKey('authorid'), isFalse);
    expect(countText(tester), '1 / 1', reason: 'floor 15 among floors 11 to 20');
    expect(loadMore(), findsOneWidget);
    await loadForSearch(tester);
    expect(adapter.asked.last, 1);
    expect(countText(tester), '2 / 2');
    expect(loadMore(), findsNothing);
    await holdEnds(tester);
  });

  testWidgets('the hot copy of a floor is not marked with it', (tester) async {
    // Tall enough for every floor to be built.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 2400);
    addTearDown(tester.view.reset);
    adapter.pages = [
      _threadPage([
        _floor(3, text: 'a Needle here', lines: 1, hot: true),
        for (var f = 1; f <= 4; f++) _floor(f, text: f == 3 ? 'a Needle here' : 'hay', lines: 1),
      ]),
    ];
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 1', reason: 'the floor once');
    await holdEnds(tester);
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, 2000));
    await settle(tester);
    expect(find.textContaining('a Needle here', findRichText: true), findsNWidgets(2), reason: 'both built');
    expect(hitMark(3), findsOneWidget, reason: 'the floor marked, not its copy');
    expect(marked(tester), ['Needle'], reason: 'the words marked in the floor only');
  });

  testWidgets('the quote of a blocked user and words split by a line break are not hits', (tester) async {
    adapter.pages = [
      _threadPage([
        _floor(1, text: 'hay'),
        _floor(2, text: 'needle from Bob', name: 'Bob', uid: 3000),
        _floor(
          3,
          text:
              '<div class="quote"><blockquote><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=${_pid(2)}'
              '&amp;ptid=1269">Bob 发表于 2026-11-3</a><br>needle from Bob</blockquote></div>hay',
        ),
        _floor(4, text: 'nee<br>dle'),
        _floor(5, text: '<div>nee</div><div>dle</div>'),
        _floor(6, text: 'hay<br>needle'),
      ]),
    ];
    await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: 3000, username: 'Bob'));
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 1', reason: 'only floor 6: Bob hidden, his quote replaced, nee|dle two words');
    expectAtTop(tester, 6);
    await holdEnds(tester);
  });

  testWidgets('the current hit gone (its author blocked) moves to the closest hit, never 0 / N', (tester) async {
    adapter.pages = [
      _threadPage([
        for (var f = 1; f <= 10; f++)
          _floor(
            f,
            text: f == 3 || f == 6 || f == 9 ? 'needle' : 'hay',
            name: f == 6 ? 'Bob' : 'Alice',
            uid: f == 6 ? 3000 : 1000,
          ),
      ]),
    ];
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    await tapKey(tester, 'next');
    expect(countText(tester), '2 / 3');
    expectAtTop(tester, 6);
    await holdEnds(tester);
    await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: 3000, username: 'Bob'));
    await settle(tester);
    expect(countText(tester), '2 / 2', reason: 'floor 9, the hit after the one gone');
    await tapKey(tester, 'next');
    expect(countText(tester), '1 / 2');
    expectAtTop(tester, 3);
    await holdEnds(tester);
  });

  /// A thread of [pages] pages of eight floors (far from the end: the list asks for no page of its own), the word
  /// only in the first floor of page [hitPage].
  List<String> windowPages(int pages, int hitPage) => [
    for (var p = 1; p <= pages; p++)
      _threadPage(
        [
          for (var f = p * 8 - 7; f <= p * 8; f++) _floor(f, text: p == hitPage && f == p * 8 - 7 ? 'needle' : 'hay'),
        ],
        page: p,
        pages: pages,
      ),
  ];

  testWidgets('pages loaded for the search never drop the page read: the button stops instead', (tester) async {
    adapter.pages = windowPages(12, 1);
    await pump(tester);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 1');
    await holdEnds(tester);
    for (var page = 2; page <= threadWindowPages; page++) {
      await loadForSearch(tester);
      expect(adapter.asked.last, page);
      expect(countText(tester), '1 / 1');
    }
    expect(loadMore(), findsOneWidget, reason: 'pages 11 and 12 are not loaded');
    expect(loadMoreEnabled(tester), isFalse, reason: 'page 11 would drop page 1, the page read');
    expect(countText(tester), '1 / 1');
    expectAtTop(tester, 1);
    await holdEnds(tester);
  });

  testWidgets('with the window full, the pages before are loaded instead, each page once', (tester) async {
    adapter.pages = windowPages(12, 3);
    await pump(tester, page: 3);
    await openSearch(tester);
    await type(tester, 'needle');
    expect(countText(tester), '1 / 1');
    await holdEnds(tester);
    for (var page = 4; page <= 12; page++) {
      await loadForSearch(tester);
      expect(adapter.asked.last, page);
    }
    // Pages 3 to 12 on screen: the page before goes above them and drops page 12, never page 3.
    await loadForSearch(tester);
    expect(adapter.asked.last, 2);
    await loadForSearch(tester);
    expect(adapter.asked.last, 1, reason: 'page 12 was searched already: not loaded again');
    expect(loadMoreEnabled(tester), isFalse, reason: 'every page searched');
    expect(countText(tester), '1 / 1');
    expectAtTop(tester, 17);
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
