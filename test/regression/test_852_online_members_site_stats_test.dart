/// The members online and the forum's statistics.
///
/// * The homepage's "在线会员" line is read from the web page the homepage already loaded (no request more); the
///   structured answer of the app API carries none, the block is then only the way to the list. The list is the
///   forum's own "在线会员" page (`home.php?mod=space&do=friend&view=online&type=member`): the structured friends
///   answer (plugin 2.5.0, schema 10) or its web page, every row a member online.
/// * The statistics (`misc.php?mod=stat`) are the web page (no answer of the app API): the tabs the forum offers, the
///   tables (pairs of labels and values, grids, the two halves of the moderation work joined), the trend from the
///   forum's `xml=1` answer or from a forum's daily log; a group that may not see them gets the forum's words.
///
/// The pages were captured from the test forum (Discuz! X5, plugin 3.7.0), cleaned.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/friend_page_api.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/models/home_block.dart';
import 'package:tsdm_client/features/homepage/utils/online_summary.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/site_stats/models/site_stats.dart';
import 'package:tsdm_client/features/site_stats/repository/site_stats_repository.dart';
import 'package:tsdm_client/features/site_stats/view/site_stats_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/site_stats';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

uh.Document _doc(String path) => parseHtmlDocument(File(path).readAsStringSync());

SiteStatsData _page(String name) => parseSiteStatsPage(parseHtmlDocument(_raw(name)))!;

/// The repository answering [pages] (url to file) and recording what it was asked.
SiteStatsRepository _repository(Map<String, String> pages, List<String> asked) => SiteStatsRepository(
  fetchText: (url) {
    asked.add(url);
    final name = pages[url];
    return name == null ? TaskEither.left(HttpRequestFailedException(500)) : TaskEither.right(_raw(name));
  },
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the "在线会员" line of the homepage', () {
    test('folded (the forum online over 500): the total and the record', () {
      expect(parseOnlineSummary(_doc('test/data/forum_index_x5.html')), ['总计 1608 人在线', '最高记录是 12616 于 2026-9-7.']);
    });

    test('with the list: members, invisible ones and guests too', () {
      expect(parseOnlineSummary(_doc('test/data/tsdmapp/s3_index.html')), [
        '2 人在线',
        '2 会员(0 隐身), 0 位游客',
        '最高记录是 24 于 2026-9-24.',
      ]);
    });

    test('none on a page without it', () {
      expect(parseOnlineSummary(parseHtmlDocument('<div id="online"></div>')), isEmpty);
    });

    test('the state of the web page carries it, the structured answer none (and asks nothing for it)', () {
      final web = HomepageBloc.parseStateForTest(_doc('test/data/tsdmapp/s3_index.html'), 'ag_low');
      expect(web.onlineSummary, hasLength(3));
      final json =
          jsonDecode(File('test/data/tsdmapp/index_v5_member.json').readAsStringSync()) as Map<String, dynamic>;
      expect(homepageStateFromApi(json, 'ag_low').onlineSummary, isEmpty);
    });
  });

  group('the block of the homepage', () {
    test('the last block: a stored layout of before gets it shown at its end', () {
      expect(HomeBlock.values.last, HomeBlock.online);
      final layout = HomeBlockLayout.parse('tools,greeting,!stats');
      expect(layout.order.last, HomeBlock.online);
      expect(layout.isVisible(HomeBlock.online), isTrue);
      expect(HomeBlockLayout.parse('!online').visible, isNot(contains(HomeBlock.online)));
    });

    testWidgets('the line as the forum prints it, or the title alone', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  HomeOnlineCard(key: ValueKey('with'), summary: ['2 人在线', '最高记录是 24 于 2026-9-24.']),
                  HomeOnlineCard(key: ValueKey('without'), summary: []),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('2 人在线'), findsOneWidget);
      expect(find.text('最高记录是 24 于 2026-9-24.'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('without')), matching: find.byType(Text)),
        findsOneWidget,
        reason: 'the title alone',
      );
    });
  });

  group('the members online', () {
    test("the forum's link opens the list in the app", () {
      final route = 'https://www.tsdm39.com/home.php?mod=space&do=friend&view=online&type=member'.parseUrlToRoute();
      expect(route?.screenPath, ScreenPaths.friend);
      expect(route?.queryParameters, {'view': 'online'});
      // Another member's view of it is not the list of members online.
      expect(
        'https://www.tsdm39.com/home.php?mod=space&uid=3&do=friend&view=online&type=member'
            .parseUrlToRoute()
            ?.queryParameters,
        {'uid': '3'},
      );
      expect(FriendRepository.isOnlineUrl(FriendRepository.onlineListUrl), isTrue);
      expect(FriendRepository.isOnlineUrl(FriendRepository.visitorListUrl), isFalse);
    });

    test('the structured answer: every member with the group the forum gives', () {
      final json = friendApiAnswerOf(_raw('online_v10.json'))!;
      final page = friendListPageFromApi(json, FriendRepository.onlineListUrl);
      expect(page.items.map((e) => e.username), ['ag_admin', 'ag_mid', 'ag_low2', 'ag_mod', 'acct_pw']);
      expect(page.items.first.groupName, '管理员');
      expect(page.totalCount, 5);
      expect(page.nextPageUrl, isNull);
    });

    test('the web page: every row, friends or not (the rows carry an add-friend link)', () {
      final page = parseFriendListPage(_doc('$_dir/online_web.html'), visitor: true);
      expect(page.items.map((e) => e.uid), ['35', '33', '94']);
      expect(page.items.first.username, 'ag_low2');
    });
  });

  group('the statistics pages', () {
    test('basic: the tabs the forum offers, the pairs in order (a label may come twice), the note of the cache', () {
      final page = _page('basic.html');
      expect(page.title, '基本概况');
      expect(page.tabs.map((e) => e.label), ['基本概况', '版块统计', '管理团队', '管理统计', '会员列表', '趋势统计']);
      expect(page.tabs.where((e) => e.selected).single.label, '基本概况');
      expect(page.tabs[1].url, 'https://www.tsdm39.com/misc.php?mod=stat&op=forumstat');
      expect(page.tables.map((e) => e.title), ['会员统计', '站点统计']);
      expect(page.tables.every((e) => e.isKeyValue), isTrue);
      final members = page.tables.first.pairs;
      expect(members.first.$1.text, '注册会员');
      expect(members.first.$2.text, '5087');
      expect(members.map((e) => e.$1.text), contains('今日论坛之星'));
      final site = page.tables[1].pairs.map((e) => e.$1.text).toList();
      expect(site.where((e) => e == '主题数'), hasLength(2));
      expect(page.tables[1].pairs.firstWhere((e) => e.$1.text == '最热门的版块').$2.url, contains('fid=7'));
      expect(page.note, startsWith('统计数据已被缓存'));
      expect(page.chartUrl, isNull);
      expect(page.chart, isNull);
    });

    test('forums: a grid with a link into the daily log of each', () {
      final table = _page('forumstat.html').tables.single;
      expect(table.isKeyValue, isFalse);
      expect(table.rows.first.map((e) => e.text), ['版块名称', '帖子数']);
      expect(table.rows.first.first.header, isTrue);
      expect(table.rows[1].first.url, 'https://www.tsdm39.com/misc.php?mod=stat&op=forumstat&fid=2');
    });

    test("a forum's daily log: the trend from its own table (the forum's chart url is broken)", () {
      final page = _page('forumstat_fid.html');
      expect(page.chartUrl, isNull);
      final chart = page.chart!;
      expect(chart.labels, ['11-01', '11-03', '11-04', '11-05', '11-06', '11-07', '11-09']);
      expect(chart.series.single.values, [0, 0, 0, 0, 0, 1, 0]);
      expect(page.tables.last.title, '历史记录 - 神作殿堂');
    });

    test('the team: the heading above each table is its title', () {
      final page = _page('team.html');
      expect(page.tables.first.title, '管理员和超级版主');
      expect(page.tables.first.rows.first.first.text, '用户名');
      expect(page.tables.length, greaterThan(1));
    });

    test('the moderation work: names and numbers joined row by row, the months to switch to', () {
      final page = _page('modworks.html');
      expect(page.heading, '2026-11-01 至 2026-12-01 的管理统计数据');
      expect(page.months.first.label, '2026-11');
      expect(page.months.first.selected, isTrue);
      final table = page.tables.single;
      expect(table.rows.first.first.text, '用户名');
      expect(table.rows.first[1].text, '编辑');
      expect(table.rows.first.last.text, '合计');
      expect(table.rows.map((e) => e.length).toSet(), {table.rows.first.length});
      expect(table.rows.last.first.text, '合计');
    });

    test('the members: a paged list', () {
      final page = _page('memberlist.html');
      expect(page.currentPage, 1);
      expect(page.totalPages, 100);
      expect(page.nextPageUrl, contains('page=2'));
      expect(page.previousPageUrl, isNull);
      expect(page.tables.single.rows.first.first.url, contains('order=username'));
    });

    test('the trends: drawn from the xml answer the page names; the filter form is no table', () {
      final page = _page('trend.html');
      expect(page.tables, isEmpty);
      expect(
        page.chartUrl,
        'https://www.tsdm39.com/misc.php?mod=stat&op=trend&xml=1&type=all&primarybegin=2026-10-11&primaryend=2026-11-10',
      );
      final chart = parseSiteStatsChart(_raw('trend.xml'))!;
      expect(chart.labels.first, '10-11');
      expect(chart.labels.last, '11-10');
      expect(chart.labels, hasLength(30));
      expect(chart.series.map((e) => e.title), ['登录用户', '新注册用户', '论坛发帖量', '圈子', '互动']);
      expect(chart.series.first.values.first, 14);
      expect(chart.series.every((e) => e.values.length == 30), isTrue);
      // The answer of a forum's daily log quotes its attributes with ", not '.
      expect(
        parseSiteStatsChart(
          '<chart><xaxis><value xid="1">1101</value></xaxis><graphs><graph gid="0" title="发帖量"> '
          '<value xid="1">3</value></graph></graphs></chart>',
        )?.series.single.values,
        [3],
      );
      expect(parseSiteStatsChart('<!DOCTYPE html><html></html>'), isNull);
    });

    test("a group that may not see them: no page, the forum's words", () {
      for (final (name, words) in [
        ('no_permission.html', '抱歉，您所在的用户组(超级版主)无法进行此操作'),
        ('guest.html', '抱歉，您所在的用户组(游客)无法进行此操作'),
      ]) {
        final document = parseHtmlDocument(_raw(name));
        expect(parseSiteStatsPage(document), isNull, reason: name);
        expect(siteStatsServerMessage(document), words, reason: name);
      }
    });

    test("the forum's links to its statistics open the page in the app", () {
      for (final link in ['misc.php?mod=stat&op=team', 'https://tsdm39.com/misc.php?mod=stat&op=team']) {
        final route = link.parseUrlToRoute();
        expect(route?.screenPath, ScreenPaths.siteStats, reason: link);
        final url = route!.queryParameters['url']!;
        expect(url, 'https://www.tsdm39.com/misc.php?mod=stat&op=team');
        expect(SiteStatsRepository.isStatsUrl(url), isTrue);
      }
      expect('https://evil.example/misc.php?mod=stat'.parseUrlToRoute(), isNull);
    });

    test('only a statistics page of the forum is asked for a url given', () {
      expect(SiteStatsRepository.isStatsUrl('https://www.tsdm39.com/misc.php?mod=stat&op=team'), isTrue);
      expect(SiteStatsRepository.isStatsUrl('https://tsdm39.com/misc.php?mod=stat'), isTrue);
      expect(SiteStatsRepository.isStatsUrl('https://evil.example/misc.php?mod=stat'), isFalse);
      expect(SiteStatsRepository.isStatsUrl('https://www.tsdm39.com/misc.php?mod=ranklist'), isFalse);
      expect(SiteStatsRepository.isStatsUrl('http://www.tsdm39.com/misc.php?mod=stat'), isFalse);
    });
  });

  group('the repository', () {
    const trendUrl = 'https://www.tsdm39.com/misc.php?mod=stat&op=trend';
    const xmlUrl =
        'https://www.tsdm39.com/misc.php?mod=stat&op=trend&xml=1&type=all&primarybegin=2026-10-11&primaryend=2026-11-10';

    test('a page with a trend asks its xml once more', () async {
      final asked = <String>[];
      final page = (await _repository({
        trendUrl: 'trend.html',
        xmlUrl: 'trend.xml',
      }, asked).fetch(trendUrl).run()).getOrElse((e) => throw e);
      expect(asked, [trendUrl, xmlUrl]);
      expect(page.chart?.series, hasLength(5));
    });

    test('a trend that fails leaves the page without it; a page without one asks nothing more', () async {
      final asked = <String>[];
      final page = (await _repository({trendUrl: 'trend.html'}, asked).fetch(trendUrl).run()).getOrElse(
        (e) => throw e,
      );
      expect(page.title, '趋势统计');
      expect(page.chart, isNull);
      asked.clear();
      await _repository({SiteStatsRepository.basicUrl: 'basic.html'}, asked).fetch(SiteStatsRepository.basicUrl).run();
      expect(asked, [SiteStatsRepository.basicUrl]);
    });

    test('a trend the page names elsewhere is not asked', () async {
      final asked = <String>[];
      final html = _raw(
        'trend.html',
      ).replaceFirst("drawstatchart('misc.php", "drawstatchart('https://evil.example/misc.php");
      final page = (await SiteStatsRepository(
        fetchText: (url) {
          asked.add(url);
          return TaskEither.right(html);
        },
      ).fetch(trendUrl).run()).getOrElse((e) => throw e);
      expect(asked, [trendUrl]);
      expect(page.chart, isNull);
    });

    test("no permission: the forum's words", () async {
      final result = await _repository({
        SiteStatsRepository.basicUrl: 'no_permission.html',
      }, []).fetch(SiteStatsRepository.basicUrl).run();
      expect(
        result.getLeft().toNullable(),
        isA<ServerRespondedErrorException>().having((e) => e.message, 'message', contains('(超级版主)无法进行此操作')),
      );
    });
  });

  group('the page', () {
    Future<void> pump(WidgetTester tester, SiteStatsRepository repository) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: SiteStatsPage(repository: repository)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('the tables of the first tab; a tab replaces it', (tester) async {
      final asked = <String>[];
      final repository = _repository({
        SiteStatsRepository.basicUrl: 'basic.html',
        'https://www.tsdm39.com/misc.php?mod=stat&op=forumstat': 'forumstat.html',
      }, asked);
      await pump(tester, repository);
      expect(find.text('会员统计'), findsOneWidget);
      expect(find.text('5087'), findsOneWidget);
      expect(find.byKey(const ValueKey('site-stats-tab-5')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('site-stats-tab-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(asked.last, 'https://www.tsdm39.com/misc.php?mod=stat&op=forumstat');
      expect(find.text('版块名称'), findsOneWidget);
      expect(find.text('会员统计'), findsNothing);
    });

    testWidgets("no permission: the forum's words", (tester) async {
      await pump(tester, _repository({SiteStatsRepository.basicUrl: 'guest.html'}, []));
      expect(find.textContaining('抱歉，您所在的用户组(游客)无法进行此操作'), findsOneWidget);
    });
  });
}
