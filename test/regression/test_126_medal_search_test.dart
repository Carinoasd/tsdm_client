/// Issue #122: keyword search in the medal centre.
///
/// The forum searches the whole catalogue by name or description: the first page is a POST of `searchstr` (plus the
/// session formhash) to `plugin.php?id=dsu_medalCenter:memcp`, following pages are GET links carrying
/// `sq=<base64 of the UTF-8 query>&page=N`, and a category link leaves the search. Pages below are synthetic; the
/// markup follows the live form and result pages, identity and tokens are made up.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/medal_center/cubit/medal_center_cubit.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:tsdm_client/features/medal_center/view/medal_center_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

const _form =
    '<form action="plugin.php?id=dsu_medalCenter:memcp" method="post" class="mbm">'
    '<input type="hidden" name="formhash" value="TEST_HASH" />'
    '<input name="searchstr" size="38" type="text" class="px vm" value="%QUERY%" placeholder="搜索勋章名称或说明" />'
    '<button type="submit" class="pn vm"><em>搜索</em></button>'
    '<a href="forum.php?mod=viewthread&amp;tid=1" target="_blank"><img src="static/image/logo.gif" alt="" /></a></form>';

String _sq(String query) => base64.encode(utf8.encode(query));

/// A synthetic catalogue or result page; [medals] are (id, name, description).
String _page({
  String query = '',
  List<(int, String, String)> medals = const [],
  int page = 1,
  String? next,
  String? previous,
  int uid = 1000,
  bool form = true,
}) {
  final items = StringBuffer();
  for (final (id, name, description) in medals) {
    items.write(
      '<li id="dsumc_m$id"><img src="static/image/common/m$id.gif" alt="" id="mc_medal$id" />'
      '<p class="mtn"><strong>$name</strong></p><span class="way">管理员颁发</span></li>'
      '<div id="mc_medal${id}_menu" class="medal_hover_menu" style="display:none;">'
      '<p class="desc">$description</p><p><strong>有效期：</strong>永久</p></div>',
    );
  }
  final escaped = const HtmlEscape().convert(query);
  return '''
<script>var discuz_uid = '$uid';</script>
<div id="ct" class="ct2_a wp cl dsumc"><div class="mn"><div class="bm bw0">
${form ? _form.replaceFirst('%QUERY%', escaped) : ''}
<h3 class="tbmu mbw cl"><a href="plugin.php?id=dsu_medalCenter:memcp">全部</a><span class="pipe">|</span><a href="plugin.php?id=dsu_medalCenter:memcp&amp;typeid=1">永久徽章</a></h3>
${medals.isEmpty ? '<p class="emp">没有可以显示的勋章。</p>' : '<ul class="mdl cl">$items</ul>'}
<div class="pg">${previous == null ? '' : '<a href="$previous" class="prev">上一页</a>'}<strong>$page</strong>${next == null ? '' : '<a href="$next" class="nxt">下一页</a>'}</div>
</div></div></div>''';
}

final _catalog = _page(medals: [(1, '普通勋章', '日常')], next: 'plugin.php?id=dsu_medalCenter:memcp&amp;page=2');
final _category = _page(medals: [(2, '永久徽章甲', '分类内')]);

/// Records every request and answers from [pages] keyed by URL, or [search] for the search POST.
final class _Server {
  _Server({Map<String, String>? pages, String Function(Map<String, String> data)? search})
    : pages = pages ?? {},
      search = search ?? ((_) => _page());

  final Map<String, String> pages;
  final String Function(Map<String, String> data) search;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  Future<String> get(String url) async {
    gets.add(url);
    return pages[url] ?? (throw HttpException('unexpected GET $url'));
  }

  Future<String> post(String url, Map<String, String> data) async {
    posts.add((url, data));
    return search(data);
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('result links', () {
    test('the observed pagination link is kept canonical and its query decoded', () {
      expect(_sq('永久'), '5rC45LmF', reason: 'the live link for 永久');
      expect(
        medalCatalogUrl('plugin.php?id=dsu_medalCenter:memcp&sq=5rC45LmF&page=2'),
        '$medalCenterUrl&sq=5rC45LmF&page=2',
      );
      expect(medalSearchQuery('5rC45LmF'), '永久');
    });

    test('base64 +, / and = survive whether the link escapes them or not', () {
      const query = '~~~???!';
      const sq = 'fn5+Pz8/IQ==';
      expect(_sq(query), sq);
      const canonical = '$medalCenterUrl&sq=fn5%2BPz8%2FIQ%3D%3D&page=2';
      expect(medalCatalogUrl('plugin.php?id=dsu_medalCenter:memcp&sq=$sq&page=2'), canonical);
      expect(medalCatalogUrl('plugin.php?id=dsu_medalCenter:memcp&sq=fn5%2BPz8%2FIQ%3D%3D&page=2'), canonical);
      expect(Uri.parse(canonical).queryParameters['sq'], sq, reason: 'the transport sends + as %2B, not a space');
      expect(medalSearchQuery(Uri.parse(canonical).queryParameters['sq']!), query);
    });

    test('ambiguous, malformed and foreign search links are refused', () {
      final sq = _sq('初音');
      for (final (reason, href) in [
        ('duplicate sq', 'plugin.php?id=dsu_medalCenter:memcp&sq=$sq&sq=$sq'),
        ('duplicate page', 'plugin.php?id=dsu_medalCenter:memcp&sq=$sq&page=2&page=3'),
        ('search is global, never per category', 'plugin.php?id=dsu_medalCenter:memcp&sq=$sq&typeid=1'),
        ('not base64', 'plugin.php?id=dsu_medalCenter:memcp&sq=abc'),
        ('not UTF-8', 'plugin.php?id=dsu_medalCenter:memcp&sq=/w=='),
        ('blank query', 'plugin.php?id=dsu_medalCenter:memcp&sq=${_sq('   ')}'),
        ('empty sq', 'plugin.php?id=dsu_medalCenter:memcp&sq='),
        ('broken escape', 'plugin.php?id=dsu_medalCenter:memcp&sq=%E0%A4%A&page=2'),
        ('action forwarded', 'plugin.php?id=dsu_medalCenter:memcp&action=claim&sq=$sq'),
        ('non-numeric page', 'plugin.php?id=dsu_medalCenter:memcp&sq=$sq&page=2a'),
        ('foreign origin', 'https://evil.example/plugin.php?id=dsu_medalCenter:memcp&sq=$sq'),
      ]) {
        expect(medalCatalogUrl(href), isNull, reason: reason);
      }
    });
  });

  group('search form', () {
    test('the live catalogue form is recognised; only the token and text are posted', () {
      final form = medalSearchForm(parseHtmlDocument(File('test/data/medal_catalog_v3_x5.html').readAsStringSync()));
      expect(form?.url, medalCenterUrl);
      expect(form?.body('初音 & <x>'), {'formhash': 'XXXXXXXX', 'searchstr': '初音 & <x>'});
      expect(parseMedalCatalog(parseHtmlDocument(_catalog)).searchForm?.formHash, 'TEST_HASH');
    });

    test('a form posting elsewhere, by GET or duplicated is not used', () {
      MedalSearchForm? parse(String html) => medalSearchForm(parseHtmlDocument(html));
      const input = '<input type="hidden" name="formhash" value="T" /><input name="searchstr" />';
      expect(parse('<form action="plugin.php?id=dsu_medalCenter:memcp" method="post">$input</form>'), isNotNull);
      for (final (reason, html) in [
        (
          'foreign',
          '<form action="https://evil.example/plugin.php?id=dsu_medalCenter:memcp" method="post">$input</form>',
        ),
        (
          'extra parameter',
          '<form action="plugin.php?id=dsu_medalCenter:memcp&amp;typeid=1" method="post">$input</form>',
        ),
        (
          'other action',
          '<form action="plugin.php?id=dsu_medalCenter:memcp&amp;action=claim" method="post">$input</form>',
        ),
        ('GET', '<form action="plugin.php?id=dsu_medalCenter:memcp" method="get">$input</form>'),
        (
          'two search forms',
          '<form action="plugin.php?id=dsu_medalCenter:memcp" method="post">$input</form>'
              '<form action="plugin.php?id=dsu_medalCenter:memcp" method="post">$input</form>',
        ),
        (
          'conflicting tokens',
          '<form action="plugin.php?id=dsu_medalCenter:memcp" method="post">$input'
              '<input type="hidden" name="formhash" value="U" /></form>',
        ),
      ]) {
        expect(parse(html), isNull, reason: reason);
      }
    });
  });

  group('cubit', () {
    const categoryUrl = '$medalCenterUrl&typeid=1';
    final page2 = '$medalCenterUrl&sq=${_sq('永久')}&page=2';

    _Server server() => _Server(
      pages: {
        medalCenterUrl: _catalog,
        categoryUrl: _category,
        page2: _page(
          query: '永久',
          medals: [(9, '永久乙', '第二页')],
          page: 2,
          previous: 'plugin.php?id=dsu_medalCenter:memcp&amp;sq=${_sq('永久')}&amp;page=1',
        ),
      },
      search: (data) => _page(
        query: data['searchstr']!,
        medals: [(8, '永久甲', '说明含${data['searchstr']}')],
        next: 'plugin.php?id=dsu_medalCenter:memcp&amp;sq=${_sq(data['searchstr']!)}&amp;page=2',
      ),
    );

    test(
      'search posts the served form, pages keep the query, refresh re-runs it, clear restores the category',
      () async {
        final s = server();
        final cubit = MedalCenterCubit(currentUid: () => 1000, fetchPage: s.get, submitForm: s.post);
        addTearDown(cubit.close);
        await cubit.load(categoryUrl);
        expect(cubit.state.searchForm, isNotNull);

        await cubit.search('  永久 ');
        expect(s.posts.single.$1, medalCenterUrl);
        expect(s.posts.single.$2, {'formhash': 'TEST_HASH', 'searchstr': '永久'});
        expect(cubit.state.query, '永久');
        expect(cubit.state.returnUrl, categoryUrl);
        expect(cubit.state.catalog!.medals.single.name, '永久甲');
        expect(cubit.state.catalog!.nextUrl, page2);

        await cubit.load(cubit.state.catalog!.nextUrl);
        expect(s.gets.last, page2);
        expect(cubit.state.query, '永久', reason: 'a result page link keeps the search');
        expect(cubit.state.catalog!.medals.single.name, '永久乙');

        await cubit.load();
        expect(s.gets.last, page2, reason: 'refreshing a result page re-reads it');
        expect(cubit.state.query, '永久');

        await cubit.load(medalCenterUrl);
        await cubit.search('永久');
        await cubit.load();
        expect(s.posts, hasLength(3), reason: 'refreshing the first result page posts the search again');
        expect(cubit.state.query, '永久');

        await cubit.clearSearch();
        expect(cubit.state.query, isNull);
        expect(cubit.state.url, medalCenterUrl, reason: 'the search was started from the full catalogue that time');
      },
    );

    test('clearing returns to the category open before the search; a category link leaves the search', () async {
      final s = server();
      final cubit = MedalCenterCubit(currentUid: () => 1000, fetchPage: s.get, submitForm: s.post);
      addTearDown(cubit.close);
      await cubit.load(categoryUrl);
      await cubit.search('永久');
      await cubit.load(cubit.state.catalog!.nextUrl);
      await cubit.clearSearch();
      expect(cubit.state.url, categoryUrl);
      expect(cubit.state.query, isNull);
      expect(cubit.state.catalog!.medals.single.name, '永久徽章甲');

      await cubit.search('永久');
      await cubit.load(cubit.state.catalog!.categories.first.url);
      expect(cubit.state.query, isNull, reason: 'category links omit the query, as on the website');
      expect(cubit.state.returnUrl, isNull);
    });

    test('blank text never posts; while searching it returns to the ordinary catalogue', () async {
      final s = server();
      final cubit = MedalCenterCubit(currentUid: () => 1000, fetchPage: s.get, submitForm: s.post);
      addTearDown(cubit.close);
      await cubit.load(categoryUrl);
      final gets = s.gets.length;
      await cubit.search('   ');
      expect(s.posts, isEmpty);
      expect(s.gets, hasLength(gets));
      await cubit.search('永久');
      await cubit.search(' \t ');
      expect(s.posts, hasLength(1));
      expect(cubit.state.query, isNull);
      expect(cubit.state.url, categoryUrl);
    });

    test('an older search answering last never replaces the newer one', () async {
      final answers = <String, Completer<String>>{};
      final cubit = MedalCenterCubit(
        currentUid: () => 1000,
        fetchPage: (url) async => url == categoryUrl ? _category : _catalog,
        submitForm: (url, data) => (answers[data['searchstr']!] = Completer<String>()).future,
      );
      addTearDown(cubit.close);
      await cubit.load();
      final first = cubit.search('甲');
      final second = cubit.search('乙');
      answers['乙']!.complete(_page(query: '乙', medals: [(2, '乙', '')]));
      await second;
      answers['甲']!.complete(_page(query: '甲', medals: [(1, '甲', '')]));
      await first;
      expect(cubit.state.query, '乙');
      expect(cubit.state.catalog!.medals.single.name, '乙');

      final pending = cubit.search('丙');
      await cubit.load(categoryUrl);
      answers['丙']!.complete(_page(query: '丙', medals: [(3, '丙', '')]));
      await pending;
      expect(cubit.state.query, isNull, reason: 'a category chosen meanwhile wins');
      expect(cubit.state.catalog!.medals.single.name, '永久徽章甲');
    });

    test('an account switch drops the pending search, its query and its form', () async {
      var uid = 1000;
      final answer = Completer<String>();
      final cubit = MedalCenterCubit(
        currentUid: () => uid,
        fetchPage: (_) async => _page(uid: uid, medals: [(1, '普通勋章', '')]),
        submitForm: (_, _) => answer.future,
      );
      addTearDown(cubit.close);
      await cubit.load();
      final pending = cubit.search('永久');
      uid = 2000;
      cubit.invalidate();
      expect(cubit.state.query, isNull);
      expect(cubit.state.searchForm, isNull);
      answer.complete(_page(uid: 1000, query: '永久', medals: [(8, '永久甲', '')]));
      await pending;
      expect(cubit.state.catalog, isNull, reason: 'the old account result is discarded');
      await cubit.load();
      expect(cubit.state.query, isNull);
      expect(cubit.state.catalog!.medals.single.name, '普通勋章');
    });

    test('a failed search is retried as the same search, not as the catalogue', () async {
      var fail = true;
      final posts = <String>[];
      final cubit = MedalCenterCubit(
        currentUid: () => 1000,
        fetchPage: (_) async => _catalog,
        submitForm: (_, data) async {
          posts.add(data['searchstr']!);
          if (fail) throw const HttpException('offline');
          return _page(query: data['searchstr']!, medals: [(8, '永久甲', '')]);
        },
      );
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.search('永久');
      expect(cubit.state.failed, isTrue);
      expect(cubit.state.query, '永久');
      expect(cubit.state.searchForm, isNotNull, reason: 'retry still has a form to post');
      fail = false;
      await cubit.load();
      expect(posts, ['永久', '永久']);
      expect(cubit.state.catalog!.medals.single.name, '永久甲');
    });
  });

  group('page', () {
    Future<void> pump(WidgetTester tester, MedalCenterCubit cubit, {double width = 400}) async {
      await LocaleSettings.setLocale(AppLocale.en);
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MedalCenterPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('searching shows its own loading, results and empty wording; clear restores the catalogue', (
      tester,
    ) async {
      Completer<String>? answer;
      final cubit = MedalCenterCubit(
        currentUid: () => 1000,
        fetchPage: (_) async => _catalog,
        submitForm: (_, _) => (answer = Completer<String>()).future,
      );
      await pump(tester, cubit);
      expect(find.text('普通勋章'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('medal-search')), '初音');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text(t.medalCenter.searching(query: '初音')), findsOneWidget);
      answer!.complete(_page(query: '初音', medals: [(7, '初音未来', '歌姬')]));
      await tester.pumpAndSettle();
      expect(find.text(t.medalCenter.searchResults(query: '初音')), findsOneWidget);
      expect(find.text('初音未来'), findsOneWidget);
      expect(find.text('普通勋章'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('medal-search')), '不存在');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      answer!.complete(_page(query: '不存在'));
      await tester.pumpAndSettle();
      expect(find.textContaining(t.medalCenter.searchEmpty(query: '不存在')), findsOneWidget);
      expect(find.textContaining(t.medalCenter.empty), findsNothing, reason: 'not the empty-category wording');

      await tester.tap(find.byTooltip(t.medalCenter.clearSearch));
      await tester.pumpAndSettle();
      expect(cubit.state.query, isNull);
      expect(find.text('普通勋章'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('medal-search'))).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await cubit.close();
    });

    testWidgets('a failed search says so and retries the search; narrow screens do not overflow', (tester) async {
      var fail = true;
      final cubit = MedalCenterCubit(
        currentUid: () => 1000,
        fetchPage: (_) async => _catalog,
        submitForm: (_, data) async {
          if (fail) throw const HttpException('offline');
          return _page(query: data['searchstr']!, medals: [(7, '初音未来' * 6, '歌姬')]);
        },
      );
      await pump(tester, cubit, width: 320);
      await tester.enterText(find.byKey(const ValueKey('medal-search')), '初音');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text(t.medalCenter.searchFailed(query: '初音')), findsOneWidget);
      fail = false;
      await tester.tap(find.text(t.general.retry));
      await tester.pumpAndSettle();
      expect(find.text(t.medalCenter.searchResults(query: '初音')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await cubit.close();
    });
  });
}
