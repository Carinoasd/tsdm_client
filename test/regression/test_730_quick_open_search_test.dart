import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/quick_open/utils/quick_open_search.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Quick open box (Ctrl+K): what a typed text names by itself, and how the forums, the threads visited and the users
/// are matched and ordered.
void main() {
  const sources = QuickOpenSources(
    forums: [(fid: 1, name: '动漫天地'), (fid: 2, name: 'Anime Talk'), (fid: 3, name: '原创绘图区')],
    threads: [(tid: 900, title: '动漫新番推荐'), (tid: 800, title: 'Weekly anime chat'), (tid: 700, title: '无关的帖子')],
    users: [(uid: '31', name: 'Anime_fan'), (uid: '32', name: 'someone')],
  );

  group('typed target', () {
    test('digits are a thread id', () {
      final target = parseQuickOpenTarget(' 1234567 ')!;
      expect(target.kind, QuickOpenKind.typedThread);
      expect(target.route.screenPath, ScreenPaths.threadV1);
      expect(target.route.queryParameters, {'tid': '1234567'});
    });

    test('zero, a huge number and empty input are not a thread id', () {
      expect(parseQuickOpenTarget('0'), isNull);
      expect(parseQuickOpenTarget('12345678901234'), isNull);
      expect(parseQuickOpenTarget('   '), isNull);
    });

    test('a thread link is that thread, with its page', () {
      final target = parseQuickOpenTarget('https://www.tsdm39.com/forum.php?mod=viewthread&tid=555&page=2')!;
      expect(target.kind, QuickOpenKind.typedThread);
      expect(target.route.queryParameters['tid'], '555');
      expect(target.route.queryParameters['pageNumber'], '2');
    });

    test('a forum link is a page of the forum', () {
      final target = parseQuickOpenTarget('https://www.tsdm39.com/forum.php?mod=forumdisplay&fid=8')!;
      expect(target.kind, QuickOpenKind.typedLink);
      expect(target.route.screenPath, ScreenPaths.forum);
      expect(target.route.pathParameters, {'fid': '8'});
    });

    test('a link of another site, or plain words, are not opened', () {
      expect(parseQuickOpenTarget('https://example.com/forum.php?mod=viewthread&tid=555'), isNull);
      expect(parseQuickOpenTarget('anime talk'), isNull);
      expect(parseQuickOpenTarget('javascript:alert(1)'), isNull);
    });
  });

  group('candidates', () {
    test('nothing typed lists nothing', () {
      expect(buildQuickOpenCandidates('  ', sources), isEmpty);
    });

    test('the search is always the last line', () {
      final list = buildQuickOpenCandidates('zzz', sources);
      expect(list, hasLength(1));
      expect(list.single.kind, QuickOpenKind.search);
      expect(list.single.title, 'zzz');
      expect(list.single.route.screenPath, ScreenPaths.search);
      expect(list.single.route.queryParameters, {'keyword': 'zzz'});

      final withHits = buildQuickOpenCandidates('anime', sources);
      expect(withHits.last.kind, QuickOpenKind.search);
      expect(withHits.where((e) => e.kind == QuickOpenKind.search), hasLength(1));
    });

    test('a thread id comes before everything, then the matches', () {
      const withNumbers = QuickOpenSources(forums: [(fid: 7, name: '2024 活动')]);
      final list = buildQuickOpenCandidates('2024', withNumbers);
      expect(list.map((e) => e.kind), [QuickOpenKind.typedThread, QuickOpenKind.forum, QuickOpenKind.search]);
      expect(list.first.route.queryParameters, {'tid': '2024'});
    });

    test('matching ignores case and needs every word', () {
      final list = buildQuickOpenCandidates('WEEKLY chat', sources);
      expect(list.map((e) => e.title), ['Weekly anime chat', 'WEEKLY chat']);
      expect(buildQuickOpenCandidates('weekly nothing', sources).map((e) => e.kind), [QuickOpenKind.search]);
    });

    test('the best fit comes first, the same fit keeps forum, thread, user', () {
      final list = buildQuickOpenCandidates('anime', sources);
      expect(list.map((e) => e.title), ['Anime Talk', 'Anime_fan', 'Weekly anime chat', 'anime']);
      final kinds = buildQuickOpenCandidates('动漫', sources).map((e) => e.kind);
      expect(kinds, [QuickOpenKind.forum, QuickOpenKind.thread, QuickOpenKind.search]);
    });

    test('an exact name beats a longer one', () {
      const exact = QuickOpenSources(
        forums: [(fid: 1, name: '动漫天地'), (fid: 2, name: '动漫')],
      );
      expect(buildQuickOpenCandidates('动漫', exact).first.route.pathParameters, {'fid': '2'});
    });

    test('a word start beats the middle of a word', () {
      const words = QuickOpenSources(
        threads: [(tid: 1, title: 'reanimate'), (tid: 2, title: 'a anime')],
      );
      expect(buildQuickOpenCandidates('anime', words).first.route.queryParameters, {'tid': '2'});
    });

    test('the brackets around a title end the word before them', () {
      const brackets = QuickOpenSources(
        threads: [(tid: 1, title: '总结版规说明'), (tid: 2, title: '【公告】版规说明')],
      );
      final tids = buildQuickOpenCandidates('版规', brackets).where((e) => e.kind == QuickOpenKind.thread);
      expect(tids.map((e) => e.route.queryParameters['tid']), ['2', '1']);
    });

    test('the threads keep the order of the source: newest first', () {
      const threads = QuickOpenSources(
        threads: [(tid: 3, title: 'chat c'), (tid: 2, title: 'chat b'), (tid: 1, title: 'chat a')],
      );
      final tids = buildQuickOpenCandidates('chat', threads).where((e) => e.kind == QuickOpenKind.thread);
      expect(tids.map((e) => e.route.queryParameters['tid']), ['3', '2', '1']);
    });

    test('each kind is cut to the limit', () {
      final many = QuickOpenSources(forums: [for (var i = 1; i <= 20; i++) (fid: i, name: 'forum $i')]);
      final list = buildQuickOpenCandidates('forum', many);
      expect(list.where((e) => e.kind == QuickOpenKind.forum), hasLength(quickOpenPerKindLimit));
      expect(list.last.kind, QuickOpenKind.search);
    });

    test('the routes open the forum, the thread and the profile', () {
      final list = buildQuickOpenCandidates('anime', sources);
      final forum = list.firstWhere((e) => e.kind == QuickOpenKind.forum);
      expect(forum.route.screenPath, ScreenPaths.forum);
      expect(forum.route.pathParameters, {'fid': '2'});
      final user = list.firstWhere((e) => e.kind == QuickOpenKind.user);
      expect(user.route.screenPath, ScreenPaths.profile);
      expect(user.route.queryParameters, {'uid': '31'});
    });
  });
}
