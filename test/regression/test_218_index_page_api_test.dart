/// The forum's app API, plugin 2.3.0: the homepage (`forum.php`) answered as structured fields (`schema: 5`).
///
/// The page is asked in the JSON mode as before, but an answer of plugin 2.3.0 carries every field the app reads:
/// the statistics of the status bar and its links, the viewer, the unread counts, the categories with their forums
/// and the viewer's favorite forums, the `Kahrpba` tabs in the order the website shows them and its slides, and
/// today's daily red packet. The shared repository keeps such an answer as a structured page ([ForumHomeApiPage]):
/// the homepage tab builds its state from the fields ([homepageStateFromApi]), the topics tab its groups
/// ([forumGroupsFromApi]), the activities page its links ([parseForumActivitiesFromApi]), and nobody parses the
/// `document` of such an answer, which a lean answer (`nodoc=1`) does not carry. An older plugin's answer (no
/// `schema`) and the web page are kept as the document ([ForumHomeWebPage]) and parsed as before.
///
/// The fixtures `index_v5_*.json` are answers of the test forum (Discuz X5.0.2 with plugin 2.3.0, 2026-10-20; fetched
/// again with plugin 2.8.1 on 2026-10-21, which adds `favorites`: the tests of the panel from `favorite_forums` drop
/// it, test_227 covers it):
/// `index_v5_member.json` keeps a `document` on purpose, a garbage one (other numbers, another tab), to prove that
/// path never reads it (but for the favorites panel of a plugin before 2.8.1, which finds no panel in it and looks the
/// favorites up among the categories); `index_v5_guest.json` is lean. `s3_index.json` is the answer of plugin 1.3.0 to the same
/// page, parsed from its `document` as it always was.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/activities/models/forum_activity.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The member's answer with [changes] applied on top (a copy), as plugin 2.3.0 to 2.8.0 answers it: without the
/// `favorites` of plugin 2.8.1 (test_227), the "我收藏的版块" panel named by `favorite_forums` only.
Map<String, dynamic> _member([Map<String, Object?> changes = const {}]) => {
  ...(_json('index_v5_member.json')..remove('favorites')),
  ...changes,
};

/// The viewer of the member's answer.
const _viewer = UserLoginInfo(uid: 35, username: 'ag_low2');

/// The titles of the `Kahrpba` tabs of the member's answer, in the order the website shows them.
const _tabs = ['最新活动', '见习天使', '动漫新闻', '最新主题', '今日话题', '动漫讨论', '发帖排行'];

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json, int status});

_Answer _html(String body) => (body: body, json: false, status: 200);

_Answer _api(Object answer, {int status = 200}) =>
    (body: answer is String ? answer : jsonEncode(answer), json: true, status: status);

/// A forum answering every request with [answer] and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Forum.always(_Answer answer) : this((_) => answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  List<RequestOptions> get gets => requests.where((e) => e.method == 'GET').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    return ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Authentication repository whose status is driven by the test.
final class _FakeAuth extends AuthenticationRepository {
  _FakeAuth(this.user);

  UserLoginInfo? user;
  final subject = BehaviorSubject<AuthStatus>();

  @override
  UserLoginInfo? get currentUser => user;

  @override
  Stream<AuthStatus> get status => subject.stream;

  @override
  Future<void> dispose() async {
    await subject.close();
    await super.dispose();
  }
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('indexApiAnswerOf tells the structured answers apart', () {
    test('schema 5 of the homepage, lean or not; the message of the plugin (login tells it)', () {
      for (final name in ['index_v5_member', 'index_v5_guest']) {
        expect(indexApiAnswerOf(_raw('$name.json')), isNotNull, reason: name);
        expect(indexApiAnswerOf(_json('$name.json')), isNotNull, reason: '$name as a map');
      }
      expect(_json('index_v5_guest.json'), isNot(contains('document')), reason: 'lean');
      final login = {'ok': 0, 'error': 'message', 'message': '请先登录', 'login': 1};
      expect(indexApiAnswerOf(login), login);
      expect(indexApiAnswerOf({...login, 'login': 0, 'schema': 5}), isNotNull);
    });

    test('not: another page, an older plugin, the web page, a failed build, a message of an old plugin', () {
      expect(indexApiAnswerOf(_raw('forum_v2_fid2_guest.json')), isNull, reason: 'the forum page is schema 2');
      expect(indexApiAnswerOf(_member({'type': 'forum'})), isNull);
      expect(indexApiAnswerOf(_member({'schema': 4})), isNull);
      expect(indexApiAnswerOf(_raw('s3_index.json')), isNull, reason: 'plugin 1.3.0: type index without schema');
      expect(indexApiAnswerOf(_raw('s3_index.html')), isNull);
      expect(indexApiAnswerOf({'ok': 0, 'error': 'internal'}), isNull);
      expect(indexApiAnswerOf({'ok': 0, 'error': 'message', 'message': 'x', 'document': '<p>x</p>'}), isNull);
      expect(indexApiAnswerOf(null), isNull);
      expect(indexApiAnswerOf(''), isNull);
    });
  });

  group('homepageStateFromApi builds the state of the member', () {
    final state = homepageStateFromApi(_json('index_v5_member.json'), _viewer.username);

    test('status, statistics, viewer and links; the garbage document is never read', () {
      expect(state.status, HomepageStatus.success);
      expect(state.forumStatus.todayCount, '100');
      expect(state.forumStatus.yesterdayCount, '50');
      expect(state.forumStatus.threadCount, '4815');
      final user = state.loggedUserInfo!;
      expect(user.username, 'ag_low2');
      expect(user.avatarUrl, 'https://www.tsdm39.com/data/avatar/noavatar.svg', reason: 'the answer names it');
      expect(user.relatedLinkPairList, [('我的帖子', 'home.php?mod=space&do=thread&view=me')]);
      expect(state.unreadNoticeCount, 0, reason: 'live: ag_low2 had no unread notice when the fixture was fetched');
      expect(state.hasUnreadMessage, isFalse);
      final withNotices = homepageStateFromApi({
        ..._json('index_v5_member.json'),
        'unread': {'notice': 5, 'pm': 0},
      }, _viewer.username);
      expect(withNotices.unreadNoticeCount, 5);
      expect(state.formHash, 'f1f2f3f4');
      expect(state.scrollSwiper, isTrue);
      expect(state.checkingDailyRedPacket, isFalse);
      expect(state.pinnedThreadGroupList.map((e) => e.title), isNot(contains('garbage')));
    });

    test('the account and the avatar the app has win, as with the web page', () {
      final own = homepageStateFromApi(_json('index_v5_member.json'), 'Other', avatarUrl: 'https://x/a.png');
      expect(own.loggedUserInfo!.username, 'Other');
      expect(own.loggedUserInfo!.avatarUrl, 'https://x/a.png');
      // No account from the app: the one the answer names.
      final named = homepageStateFromApi(_json('index_v5_member.json'), null);
      expect(named.status, HomepageStatus.success);
      expect(named.loggedUserInfo!.username, 'ag_low2');
    });

    test('the Kahrpba tabs: the order given, the rank by id, every row', () {
      final groups = state.pinnedThreadGroupList;
      expect(groups.map((e) => e.title), _tabs);
      expect(groups.map((e) => e.isRank), [false, false, false, false, false, false, true]);
      expect(groups.map((e) => e.threadList.length), everyElement(10));

      final latest = groups[0].threadList.first;
      expect(latest.threadUrl, 'forum.php?mod=viewthread&tid=9199892');
      expect(latest.threadTitle, startsWith('[BD][Jsum@U2]'));
      expect(latest.authorName, '神代小祈');
      expect(latest.authorUrl, 'home.php?mod=space&uid=83');

      // 见习天使 on this forum links the report thread, not the member's space: the member stays the name.
      final newcomer = groups[1].threadList.first;
      expect(newcomer.threadUrl, 'forum.php?mod=viewthread&tid=9199970');
      expect(newcomer.threadTitle, '欢迎ag_t21加入~');
      expect(newcomer.authorName, 'ag_t21');
      expect(newcomer.authorUrl, isEmpty);

      // The rank: the member as the row, the count as its "author", as the page parser keeps them.
      final rank = groups.last.threadList.first;
      expect(rank.threadUrl, 'home.php?mod=space&uid=33');
      expect(rank.threadTitle, 'ag_mid');
      expect(rank.authorName, '共发531贴');
      expect(rank.authorUrl, 'home.php?mod=space&uid=33');
    });

    test('a tab without rows, and a row without a link, are left out (#155); the rank keeps its mark', () {
      final blocks = (_json('index_v5_member.json')['blocks'] as List).cast<Map<String, dynamic>>();
      final changed = [
        for (final block in blocks)
          switch (block['id']) {
            3 => {...block, 'rows': <Object?>[]},
            2 => {
              ...block,
              'rows': [
                // A new member who did not report in: a span on the page, no link.
                {'title': '欢迎ag_t22加入~', 'url': '', 'author': 'ag_t22', 'author_url': '', 'tag': '未报到'},
                // One who did, linked to the member's space (as the production forum lists them).
                {
                  'title': '欢迎ag_t23加入~',
                  'url': 'home.php?mod=space&uid=99',
                  'author': 'ag_t23',
                  'author_url': 'home.php?mod=space&uid=99',
                  'tag': '',
                },
              ],
            },
            6 => {
              ...block,
              'rows': [
                {'title': 'x', 'url': '', 'author': 'y', 'author_url': '', 'tag': ''},
              ],
            },
            _ => block,
          },
      ];
      final groups = pinnedThreadGroupsFromApi(_member({'blocks': changed}));
      expect(groups.map((e) => e.title), ['最新活动', '见习天使', '最新主题', '动漫讨论', '发帖排行']);
      expect(groups.where((e) => e.isRank).map((e) => e.title), ['发帖排行']);
      final newcomers = groups[1].threadList;
      expect(newcomers, hasLength(1));
      expect(newcomers.single.threadUrl, 'home.php?mod=space&uid=99');
      expect(newcomers.single.authorUrl, newcomers.single.threadUrl, reason: 'tapping the row opens the profile');
      expect(newcomers.single.authorName, 'ag_t23');
      // No block at all: no tabs, as on a forum without the plugin.
      expect(pinnedThreadGroupsFromApi(_member({'blocks': <Object?>[]})), isEmpty);
      expect(pinnedThreadGroupsFromApi(_member({'blocks': null})), isEmpty);
    });

    test('the slides and the daily red packet', () {
      expect(state.swiperUrlList, hasLength(10));
      expect(state.swiperUrlList.first.coverUrl, 'https://tu.ts-dm.net/imgs/2026/03/ca31774678af2f49.png');
      expect(state.swiperUrlList.first.linkUrl, 'forum.php?mod=viewthread&tid=1123');
      final packet = state.dailyRedPacket!;
      expect(packet.entry, 1);
      expect(packet.dateFlag, '20261001');
      expect(packet.from, '系統 每日紅包');
      expect(packet.bless, '今日登入紅包,明天還可以再領');
      expect(packet.unit, '威望');
      // Claimed already: the forum prints no config, the answer null.
      expect(homepageStateFromApi(_member({'red_packet': null}), 'ag_low2').dailyRedPacket, isNull);
      // A slide without a picture is nothing to show.
      final slides = homepageStateFromApi(
        _member({
          'slides': [
            {'id': 1, 'image': '', 'url': 'forum.php?mod=viewthread&tid=1', 'label': '1'},
            {'id': 2, 'image': 'https://x/2.png', 'url': '', 'label': '2'},
          ],
        }),
        'ag_low2',
      ).swiperUrlList;
      expect(slides.map((e) => e.coverUrl), ['https://x/2.png']);
    });
  });

  group('the guest and the messages', () {
    test('the guest: nothing of a member, the login prompt unless the app has an account', () {
      final json = _json('index_v5_guest.json');
      final state = homepageStateFromApi(json, null);
      expect(state.status, HomepageStatus.needLogin);
      expect(state.loggedUserInfo!.username, isEmpty);
      expect(state.loggedUserInfo!.avatarUrl, isNull);
      expect(state.loggedUserInfo!.relatedLinkPairList, isEmpty);
      expect(state.forumStatus.todayCount, '100', reason: 'the statistics are printed to a guest too');
      expect(state.pinnedThreadGroupList, isEmpty);
      expect(state.swiperUrlList, isEmpty);
      expect(state.unreadNoticeCount, 0);
      expect(state.hasUnreadMessage, isFalse);
      expect(state.dailyRedPacket, isNull);
      expect(state.formHash, 'f1f2f3f4');
      expect(servedUserOf(json), isNull);
      expect(indexAnswerIsGuest(json), isTrue);
      // As with the web page: the account the app has is shown, even on a guest's page.
      expect(homepageStateFromApi(json, 'Alice').status, HomepageStatus.success);
    });

    test('the member is the account served', () {
      final json = _json('index_v5_member.json');
      expect(servedUserOf(json), _viewer);
      expect(indexAnswerIsGuest(json), isFalse);
      expect(servedUserOf(_member({'user': null})), isNull);
      expect(
        servedUserOf(
          _member({
            'user': <String, Object?>{'uid': 35, 'username': ''},
          }),
        ),
        isNull,
      );
    });

    test('the login prompt asks to log in; another message is a failure', () {
      final login = {'ok': 0, 'error': 'message', 'message': '请先登录', 'login': 1};
      expect(homepageStateFromApi(login, null).status, HomepageStatus.needLogin);
      expect(homepageStateFromApi(login, 'Alice').status, HomepageStatus.needLogin);
      expect(indexAnswerIsGuest(login), isTrue);
      expect(servedUserOf(login), isNull);
      final closed = {'ok': 0, 'error': 'message', 'message': '论坛已关闭', 'login': 0, 'schema': 5};
      expect(homepageStateFromApi(closed, 'Alice').status, HomepageStatus.failure);
      expect(homepageStateFromApi(closed, null).status, HomepageStatus.needLogin);
      expect(indexAnswerIsGuest(closed), isFalse);
      expect(ForumHomeApiPage(closed).servedUid, isNull);
    });

    test('the page as the repository hands it around', () {
      final member = ForumHomeApiPage(_json('index_v5_member.json'));
      expect(member.servedUid, 35);
      expect(member.formHash, 'f1f2f3f4');
      expect(member.dailyRedPacket?.dateFlag, '20261001');
      expect(member.dailyVisitUri, isNull, reason: 'no script in a structured answer');
      final guest = ForumHomeApiPage(_json('index_v5_guest.json'));
      expect(guest.servedUid, isNull);
      expect(guest.dailyRedPacket, isNull);
      expect(ForumHomeApiPage(_member({'formhash': ''})).formHash, isNull);
    });
  });

  group('the topics tab: forumGroupsFromApi', () {
    test('every category in order with its forums, no favorites panel without favorites', () {
      final groups = forumGroupsFromApi(_member({'favorite_forums': <Object?>[]}));
      expect(groups.map((e) => e.name), ['🏠 論壇大廳', 'BU 黑名單驗收分區', '🌸 動漫番劇區', '🎮 遊戲次元', '🎨 創作交流所']);
      expect(groups.map((e) => e.url), [
        'forum.php?gid=1',
        'forum.php?gid=24',
        'forum.php?gid=3',
        'forum.php?gid=4',
        'forum.php?gid=5',
      ]);
      expect(groups.where((e) => e.isFavorites), isEmpty);
      // The 分区版主 row (GitHub #22): the names the answer lists (plugin 2.4.0), none for the other groups.
      expect(groups.first.moderators, ['ag_mid', 'ag_area']);
      expect(groups.skip(1).every((e) => e.moderators.isEmpty), isTrue);
      expect(groups.map((e) => e.forumList.length), [3, 2, 3, 3, 3]);

      final checkin = groups[0].forumList[1];
      expect(checkin.forumID, 31);
      expect(checkin.name, 'PS 每日签到验收版');
      expect(checkin.url, '$baseUrl/forum.php?mod=forumdisplay&fid=31');
      expect(checkin.threadCount, 44);
      expect(checkin.replyCount, 280);
      expect(
        checkin.threadTodayCount,
        isNull,
        reason: 'the fixture tool pins every todayposts to 0; Forum.fromApi maps non-zero elsewhere',
      );
      expect(checkin.latestThreadUrl, '$baseUrl/forum.php?mod=redirect&tid=9199961&goto=lastpost');
      expect(checkin.latestThreadUserName, 'ag_t13');
      expect(checkin.latestThreadTitle, isNotEmpty);
      expect(checkin.subForumList, isNull);

      final empty = groups[1].forumList[0];
      expect(empty.forumID, 29);
      expect(empty.threadTodayCount, isNull);
      expect(empty.latestThreadUrl, isNull);
      expect(empty.latestThreadUserName, isNull);
      expect(favoriteForumIdsOf(_member({'favorite_forums': <Object?>[]})), isEmpty);

      // The viewer of the fixture favorited one forum: the panel as the page prints it (plugin 2.8.1), first.
      final real = forumGroupsFromApi(_json('index_v5_member.json'));
      expect(favoriteForumIdsOf(_json('index_v5_member.json')), [2]);
      expect(real, hasLength(6));
      expect(real.first.isFavorites, isTrue);
      expect(real.first.forumList.map((e) => e.forumID), [2]);
      expect(real.first.forumList.single.name, '📢 公告 & 新手報到');
    });

    test('the favorites panel first, in the order of the favorites; one not among the categories only seeded', () {
      final json = _member({
        'favorite_forums': [6, 2, 999],
      });
      final groups = forumGroupsFromApi(json);
      expect(groups, hasLength(6));
      final panel = groups.first;
      expect(panel.isFavorites, isTrue);
      expect(panel.name, '我收藏的版块');
      expect(panel.url, 'home.php?mod=space&do=favorite&type=forum');
      expect(panel.forumList.map((e) => e.forumID), [6, 2]);
      expect(panel.forumList.first.name, '新番追蹤');
      expect(
        groups.skip(1).map((e) => e.name),
        forumGroupsFromApi(_member({'favorite_forums': <Object?>[]})).map((e) => e.name),
      );
      expect(favoriteForumIdsOf(json), [6, 2, 999]);
      // Only unknown favorites: no panel, as the page prints none it can fill; still known as favorites.
      expect(
        forumGroupsFromApi(
          _member({
            'favorite_forums': [999],
          }),
        ).where((e) => e.isFavorites),
        isEmpty,
      );
      expect(
        favoriteForumIdsOf(
          _member({
            'favorite_forums': [999],
          }),
        ),
        [999],
      );
      expect(favoriteForumIdsOf(_member({'favorite_forums': null})), isEmpty);
    });

    test('the guest: the categories a guest sees, nothing favorited', () {
      final groups = forumGroupsFromApi(_json('index_v5_guest.json'));
      expect(groups, hasLength(5));
      expect(groups.map((e) => e.forumList.length), [3, 3, 3, 3, 3]);
      expect(groups.where((e) => e.isFavorites), isEmpty);
    });

    test('the moderators of a plugin before 2.4.0 (no field), and a field that is not a list of names', () {
      final json = _member({'favorite_forums': <Object?>[]});
      final categories = (json['categories'] as List).cast<Map<String, dynamic>>();
      categories[0].remove('moderators');
      categories[1]['moderators'] = [
        '',
        7,
        {'name': 'x'},
        'ag_mod',
      ];
      categories[2]['moderators'] = null;
      final groups = forumGroupsFromApi(json);
      expect(groups[0].moderators, isEmpty);
      expect(groups[1].moderators, ['ag_mod']);
      expect(groups[2].moderators, isEmpty);
    });

    test('the subforums the forum lists', () {
      final json = _member();
      final categories = (json['categories'] as List).cast<Map<String, dynamic>>();
      final first = categories.first['forums'] as List;
      first[0] = {
        ...first[0] as Map<String, dynamic>,
        'subforums': [
          {'fid': 101, 'name': '子版一'},
          {'fid': 102, 'name': '子版二'},
        ],
      };
      final forum = forumGroupsFromApi(json).first.forumList.first;
      expect(forum.subForumList, [
        ('子版一', '$baseUrl/forum.php?mod=forumdisplay&fid=101'),
        ('子版二', '$baseUrl/forum.php?mod=forumdisplay&fid=102'),
      ]);

      // A favorite subforum looked up among the categories (no `favorites`, no document with the panel): listed by
      // its id and name, all the categories tell of it.
      json['favorite_forums'] = [102, 6];
      final panel = forumGroupsFromApi(json).first;
      expect(panel.isFavorites, isTrue);
      expect(panel.forumList.map((e) => e.forumID), [102, 6]);
      final sub = panel.forumList.first;
      expect(sub.name, '子版二');
      expect(sub.url, '$baseUrl/forum.php?mod=forumdisplay&fid=102');
      expect(sub.threadCount, 0);
      expect(sub.latestThreadUrl, isNull);
      expect(sub.isExpanded, isFalse);
    });
  });

  group('the activities page', () {
    // Plugin 2.8.2: the description as the page prints it is `description_html`; `description` is plain text (see
    // test_228 for the plugins before it).
    test('the links of the description of 活动专区, as from the page; none without the forum', () {
      final json = _json('index_v5_member.json');
      final categories = (json['categories'] as List).cast<Map<String, dynamic>>();
      final forums = categories.first['forums'] as List;
      forums[0] = {
        ...forums[0] as Map<String, dynamic>,
        'name': '活动专区',
        'description_html':
            '<a href="forum.php?mod=viewthread&amp;tid=1">十月活动</a> | <a href="https://example.com/x">站外</a> '
            '<p align="center"><a href="forum.php?mod=viewthread&amp;tid=2">九月 活动</a></p> '
            '<a href="javascript:void(0)">no</a>',
      };
      final activities = parseForumActivitiesFromApi(json);
      expect(activities.map((e) => e.title), ['十月活动', '站外', '九月 活动']);
      expect(activities.first.url, '$baseUrl/forum.php?mod=viewthread&tid=1');
      expect(activities[1].url, 'https://example.com/x');
      expect(parseForumActivitiesFromApi(_json('index_v5_member.json')), isEmpty);
      expect(parseForumActivitiesFromApi(_json('index_v5_guest.json')), isEmpty);
      forums[0] = {...forums[0] as Map<String, dynamic>, 'description_html': ''};
      expect(parseForumActivitiesFromApi(json), isEmpty);
    });
  });

  group('the repository', () {
    tearDown(() async {
      if (getIt.isRegistered<NetClientProvider>()) {
        await getIt.unregister<NetClientProvider>();
      }
    });

    /// The repository of a forum answering [answer] to every request.
    (ForumHomeRepository, _Forum) repositoryOf(_Answer answer) {
      final forum = _Forum.always(answer);
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
      return (ForumHomeRepository(), forum);
    }

    test('schema 5 is kept as the structured page, one lean request, cached and published', () async {
      final (repo, forum) = repositoryOf(_api(_raw('index_v5_member.json')));
      addTearDown(repo.dispose);
      final published = repo.pageStream.first;
      final page = _right(await repo.fetchHomePage().run());
      expect(page, isA<ForumHomeApiPage>());
      expect(page.servedUid, 35);
      expect(forum.gets.single.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(forum.gets.single.uri.queryParameters, containsPair('nodoc', '1'));
      expect(forum.gets.single.uri.path, '/forum.php');
      expect(same(page).matches(await published, {}), isTrue);
      expect(repo.hasCache(), isTrue);
      expect(same(page).matches(repo.getCache(), {}), isTrue);
      // The cache answers the next fetch; a forced one asks again.
      expect(same(page).matches(_right(await repo.fetchHomePage().run()), {}), isTrue);
      expect(forum.gets, hasLength(1));
      expect(same(page).matches(_right(await repo.fetchTopicPage(force: true).run()), {}), isFalse);
      expect(forum.gets, hasLength(2));
      repo.invalidate();
      expect(repo.hasCache(), isFalse);
    });

    test('the lean guest answer is a page too: no challenge, no failure', () async {
      final (repo, forum) = repositoryOf(_api(_raw('index_v5_guest.json')));
      addTearDown(repo.dispose);
      final page = _right(await repo.fetchHomePage().run());
      expect(page, isA<ForumHomeApiPage>());
      expect(page.servedUid, isNull);
      expect(forum.gets, hasLength(1));
    });

    test('an older plugin and the web page are kept as the document and parsed by the old code', () async {
      final (older, _) = repositoryOf(_api(_raw('s3_index.json')));
      addTearDown(older.dispose);
      final olderPage = _right(await older.fetchHomePage().run());
      expect(olderPage, isA<ForumHomeWebPage>());
      final document = (olderPage as ForumHomeWebPage).document;
      expect(olderPage.servedUid, 31);
      expect(olderPage.formHash, 'd0bf9e72');
      final groups = buildGroupListFromDocument(document);
      expect(groups.map((e) => e.name), ['🏠 論壇大廳', 'BU 黑名單驗收分區', '🌸 動漫番劇區', '🎮 遊戲次元', '🎨 創作交流所']);
      final state = HomepageBloc.parseStateForTest(document, 'ag_low');
      expect(state.status, HomepageStatus.success);
      expect(state.loggedUserInfo?.username, 'ag_low');
      expect(state.formHash, 'd0bf9e72');
      await getIt.unregister<NetClientProvider>();

      final (web, _) = repositoryOf(_html(_raw('s3_index.html')));
      addTearDown(web.dispose);
      final webPage = _right(await web.fetchHomePage().run());
      expect(webPage, isA<ForumHomeWebPage>());
      expect(
        buildGroupListFromDocument((webPage as ForumHomeWebPage).document).map((e) => e.name),
        groups.map((e) => e.name),
      );
    });

    test('an answer without a page is a failed request, as before', () async {
      for (final answer in [
        _api({'ok': 0, 'error': 'internal'}),
        _api(''),
        _html('   '),
      ]) {
        final (repo, _) = repositoryOf(answer);
        addTearDown(repo.dispose);
        final result = await repo.fetchHomePage().run();
        expect(result.getLeft().toNullable(), isA<HttpRequestFailedException>(), reason: answer.body);
        expect(repo.hasCache(), isFalse);
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group('the daily rewards on the structured page', () {
    test('processFields: no visit without a script, the packet claimed with the form hash of the answer', () async {
      final repo = DailyRewardsRepository(now: () => DateTime(2026, 10, 20, 12));
      final page = ForumHomeApiPage(_json('index_v5_member.json'));
      final claims = <String>[];
      var visits = 0;
      Future<bool> run({int? uid = 35, bool enabled = true}) => repo.processFields(
        servedUid: page.servedUid,
        visitUri: page.dailyVisitUri,
        packet: page.dailyRedPacket,
        formHash: page.formHash,
        uid: uid,
        isCurrent: () => true,
        autoClaimEnabled: () => enabled,
        visit: (_) async {
          visits++;
          return true;
        },
        claim: (hash) async {
          claims.add(hash);
          return DailyRedPacketResult.fromJson({'ok': true, 'amount': 5});
        },
      );
      expect(await run(uid: 36), isFalse, reason: 'another account');
      expect(await run(uid: null), isFalse, reason: 'a guest');
      expect(await run(enabled: false), isFalse);
      expect(claims, isEmpty);
      expect(await run(), isTrue, reason: 'claimed: the page is fetched once more');
      expect(claims, ['f1f2f3f4']);
      expect(visits, 0);
      expect(await run(), isFalse, reason: 'today is claimed');
      expect(claims, hasLength(1));
    });

    test('through the repository: the checknewpm visit of the answer, the claim, then the reload', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      final settings = SettingsRepository(storage);
      final cookie = CookieProvider(_viewer, {});
      var claimed = false;
      const checknewpm = 'home.php?mod=spacecp&ac=pm&op=checknewpm&rand=123';
      final forum = _Forum((o) {
        if (o.uri.path == '/forum.php') {
          return _api(_member({'checknewpm': checknewpm, if (claimed) 'red_packet': null}));
        }
        if (o.uri.path == '/home.php') {
          expect(o.uri.queryParameters['op'], 'checknewpm');
          return _html('');
        }
        expect(o.uri.queryParameters['id'], 'hongbao:daily');
        expect(o.method, 'POST');
        claimed = true;
        return _api({'ok': true, 'amount': 5});
      });
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(cookie)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
      await settings.init();
      await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
      final repo = ForumHomeRepository();
      addTearDown(() async {
        await repo.dispose();
        await settings.dispose();
        await getIt.unregister<SettingsRepository>();
        await getIt.unregister<StorageProvider>();
        await getIt.unregister<CookieProvider>();
        await db.close();
      });

      final replaced = repo.pageReplacements.first;
      final page = _right(await repo.fetchHomePage().run());
      // The page is answered at once; the visit, the claim and the reload follow in the background (cold start).
      expect(page, isA<ForumHomeApiPage>());
      expect(page.servedUid, 35);
      expect(page.dailyRedPacket, isNotNull, reason: 'the page as fetched, before the claim');
      await repo.dailyRewardsDone;
      expect(forum.requests.map((e) => e.uri.path), ['/forum.php', '/home.php', '/plugin.php', '/forum.php']);
      // `mobile=no` is added by the net client to every forum request.
      expect(Map.of(forum.requests[1].uri.queryParameters)..remove('mobile'), {
        'mod': 'spacecp',
        'ac': 'pm',
        'op': 'checknewpm',
        'rand': '123',
      });
      final replacement = await replaced;
      expect(identical(replacement.previous, page), isTrue);
      expect(replacement.page.dailyRedPacket, isNull, reason: 'the reloaded page, the packet claimed');
      expect(repo.getCache()?.dailyRedPacket, isNull);
    });
  });

  group('the blocs on the structured page', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late _Forum forum;
    late ForumHomeRepository forumHome;
    late FavoriteRepository favorites;
    late _FakeAuth auth;
    late Map<String, dynamic> answer;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      answer = _member({
        'favorite_forums': [6, 2, 999],
      });
      forum = _Forum((_) => _api(answer));
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
      await settings.init();
      forumHome = ForumHomeRepository();
      favorites = FavoriteRepository();
      auth = _FakeAuth(_viewer);
    });
    tearDown(() async {
      await forumHome.dispose();
      await favorites.dispose();
      await auth.dispose();
      await settings.dispose();
      await getIt.unregister<NetClientProvider>();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await getIt.unregister<CookieProvider>();
      await db.close();
    });

    test('the topics tab: the groups with the favorites panel, every favorite seeded, the page trusted', () async {
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      )..add(TopicsLoadRequested());
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(loaded.forumGroupList, hasLength(6));
      expect(loaded.forumGroupList.first.isFavorites, isTrue);
      expect(loaded.forumGroupList.first.forumList.map((e) => e.forumID), [6, 2]);
      expect(forum.gets.where((e) => e.uri.path == '/forum.php'), hasLength(1), reason: 'served to the viewer');
      for (final fid in ['6', '2', '999']) {
        expect(favorites.isForumFavorited(uid: 35, fid: fid), isTrue, reason: 'seeded from favorite_forums: $fid');
      }
      expect(favorites.isForumFavorited(uid: 35, fid: '7'), isFalse);

      // The homepage refreshed the shared page without the favorites: the panel goes, nothing fetched by the bloc.
      answer = _member({'favorite_forums': <Object?>[]});
      final shrunk = bloc.stream.firstWhere((s) => s.forumGroupList.length == 5);
      await forumHome.fetchHomePage(force: true).run();
      await shrunk;
      expect(favorites.isForumFavorited(uid: 35, fid: '6'), isFalse);
      expect(forum.gets.where((e) => e.uri.path == '/forum.php'), hasLength(2));
    });

    test("the topics tab: another account's page is not shown, fetched again once", () async {
      auth.user = const UserLoginInfo(uid: 36, username: 'Other');
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      )..add(TopicsLoadRequested());
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(forum.gets.where((e) => e.uri.path == '/forum.php'), hasLength(2), reason: 'ignored once, then shown');
      expect(loaded.forumGroupList, hasLength(6));
      expect(favorites.isForumFavorited(uid: 36, fid: '6'), isFalse, reason: 'never seeded for the wrong account');
      expect(favorites.isForumFavorited(uid: 35, fid: '6'), isFalse);
    });

    test('the homepage bloc starts from the cached structured page', () async {
      await forumHome.fetchHomePage().run();
      final bloc = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(bloc.close);
      expect(bloc.state.status, HomepageStatus.success);
      expect(bloc.state.loggedUserInfo?.username, 'ag_low2');
      expect(bloc.state.pinnedThreadGroupList.map((e) => e.title), _tabs);
      expect(bloc.state.dailyRedPacket?.dateFlag, '20261001');
      expect(bloc.state.formHash, 'f1f2f3f4');
    });
  });

  group('the additions of the plugin review', () {
    test("checknewpm: the daily login request of a structured answer, the forum's own only", () {
      const own = 'home.php?mod=spacecp&ac=pm&op=checknewpm&rand=123';
      final page = ForumHomeApiPage(_member({'checknewpm': own}));
      expect(page.dailyVisitUri, Uri.parse('$baseUrl/$own'));
      expect(ForumHomeApiPage(_member({'checknewpm': '$baseUrl/$own'})).dailyVisitUri, Uri.parse('$baseUrl/$own'));
      expect(ForumHomeApiPage(_json('index_v5_member.json')).dailyVisitUri, isNull, reason: 'the forum printed none');
      for (final bad in [
        '',
        '   ',
        'https://evil.example/home.php?mod=spacecp&ac=pm&op=checknewpm',
        'home.php?mod=spacecp&ac=pm&op=other',
        'home.php?mod=spacecp&ac=pm&op=checknewpm&extra=1',
        'forum.php?mod=spacecp&ac=pm&op=checknewpm',
        'home.php?mod=spacecp&ac=pm&op=checknewpm#x',
      ]) {
        expect(ForumHomeApiPage(_member({'checknewpm': bad})).dailyVisitUri, isNull, reason: bad);
        expect(dailyVisitUriOfSource(bad), isNull, reason: bad);
      }
      expect(ForumHomeApiPage(_member({'checknewpm': null})).dailyVisitUri, isNull);
    });

    test('checknewpm: a JSON answer kept as its document names it too; the web page keeps its script', () {
      const own = 'home.php?mod=spacecp&ac=pm&op=checknewpm&rand=7';
      final withScript = parseHtmlDocument(
        '<html><head><script src="home.php?mod=spacecp&amp;ac=pm&amp;op=checknewpm&amp;rand=9"></script></head> '
        '<body></body></html>',
      );
      final without = parseHtmlDocument('<html><body></body></html>');
      expect(ForumHomeWebPage(without, checknewpm: own).dailyVisitUri, Uri.parse('$baseUrl/$own'));
      expect(ForumHomeWebPage(without, checknewpm: '').dailyVisitUri, isNull);
      expect(ForumHomeWebPage(without).dailyVisitUri, isNull);
      expect(ForumHomeWebPage(withScript).dailyVisitUri?.queryParameters['rand'], '9', reason: 'scanned as before');
      expect(ForumHomeWebPage(withScript, checknewpm: own).dailyVisitUri?.queryParameters['rand'], '7');
      // Named but not the forum's own: the scripts of the page are scanned as before.
      const bad = 'https://evil.example/home.php?mod=spacecp&ac=pm&op=checknewpm';
      expect(ForumHomeWebPage(withScript, checknewpm: bad).dailyVisitUri?.queryParameters['rand'], '9');
      expect(ForumHomeWebPage(without, checknewpm: bad).dailyVisitUri, isNull);
    });

    test(
      'checknewpm: through the repository, the cached guest index of plugin 2.3.0 (unknown with document)',
      () async {
        const own = 'home.php?mod=spacecp&ac=pm&op=checknewpm&rand=5';
        final forum = _Forum.always(
          _api({
            'ok': 0,
            'error': 'unknown',
            'formhash': 'f1f2f3f4',
            'checknewpm': own,
            'document': _raw('s3_index.json').isEmpty ? '' : (_json('s3_index.json')['document'] as String),
          }),
        );
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
        addTearDown(() => getIt.unregister<NetClientProvider>());
        final repo = ForumHomeRepository();
        addTearDown(repo.dispose);
        final page = _right(await repo.fetchHomePage().run());
        expect(page, isA<ForumHomeWebPage>());
        expect(page.dailyVisitUri, Uri.parse('$baseUrl/$own'));
        expect((page as ForumHomeWebPage).servedUid, 31, reason: 'the document is the page, as before');
      },
    );

    test('blocks_html: an old Kahrpba template gives the table, parsed as from the page', () {
      final html = File('test/data/homepage_kahrpba_tabs_x5.html').readAsStringSync();
      final nav = html.indexOf('id="Kahrpba_nav"');
      final start = html.lastIndexOf('<table', nav);
      final end = html.indexOf('</table>', html.indexOf('id="Kahrpba_show"')) + '</table>'.length;
      final table = html.substring(start, end);
      final fromPage = HomepageBloc.parsePinnedThreadGroups(parseHtmlDocument(html));
      expect(
        parsePinnedThreadGroupsFromDocument(parseHtmlDocument(html)).map((e) => e.title),
        fromPage.map((e) => e.title),
        reason: 'the page parser lives with the API helpers now, the bloc forwards to it',
      );
      expect(fromPage.map((e) => e.title), _tabs, reason: 'the fixture holds every tab');

      final groups = pinnedThreadGroupsFromApi(_member({'blocks': <Object?>[], 'blocks_html': table}));
      expect(groups.map((e) => e.title), fromPage.map((e) => e.title));
      expect(groups.map((e) => e.isRank), fromPage.map((e) => e.isRank));
      expect(groups.map((e) => e.threadList.length), fromPage.map((e) => e.threadList.length));
      expect(groups[1].threadList.first.authorName, 'user16');
      expect(groups.last.isRank, isTrue);
      // The state built from such an answer carries them.
      final state = homepageStateFromApi(_member({'blocks': <Object?>[], 'blocks_html': table}), 'ag_low2');
      expect(state.pinnedThreadGroupList.map((e) => e.title), _tabs);

      // The structured blocks win when there are any; nothing from nothing.
      expect(pinnedThreadGroupsFromApi(_member({'blocks_html': table})).map((e) => e.title), _tabs);
      expect(
        pinnedThreadGroupsFromApi(_member({'blocks_html': table}))[1].threadList.first.threadUrl,
        'forum.php?mod=viewthread&tid=9199970',
        reason: 'the rows of the structured blocks, not of the table',
      );
      expect(pinnedThreadGroupsFromApi(_member({'blocks': <Object?>[], 'blocks_html': ''})), isEmpty);
      expect(pinnedThreadGroupsFromApi(_member({'blocks': <Object?>[], 'blocks_html': '  '})), isEmpty);
      expect(pinnedThreadGroupsFromApi(_member({'blocks': <Object?>[], 'blocks_html': '<p>x</p>'})), isEmpty);
    });

    test('the group page (gid): the group of the structured answer, the old answer parsed as before', () async {
      final member = _json('index_v5_member.json');
      final category = (member['categories'] as List).cast<Map<String, dynamic>>()[2];
      final group = _member({
        'categories': [category],
        'stats': {'todayposts': 0, 'yesterdayposts': 0, 'posts': 0, 'members': 5086, 'newest': 'agperf6003'},
      });
      Future<ForumGroup?> fetch(_Answer answer, {String gid = '3'}) async {
        final forum = _Forum.always(answer);
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
        try {
          final result = await ForumRepository().fetchForumGroup(gid).run();
          expect(forum.gets.single.uri.queryParameters, containsPair('gid', gid));
          expect(forum.gets.single.uri.queryParameters, containsPair('nodoc', '1'));
          return _right(result);
        } finally {
          await getIt.unregister<NetClientProvider>();
        }
      }

      final built = (await fetch(_api(group)))!;
      expect(built.name, '🌸 動漫番劇區');
      expect(built.url, 'forum.php?gid=3');
      expect(built.forumList.map((e) => e.forumID), [6, 7, 8]);
      // The favorites panel, were it printed, is not the group asked for.
      final withPanel = (await fetch(
        _api({
          ...group,
          'favorite_forums': [6],
        }),
      ))!;
      expect(withPanel.name, '🌸 動漫番劇區');
      expect(await fetch(_api({...group, 'categories': <Object?>[]})), isNull);

      final older = (await fetch(_api(_raw('s3_index.json')), gid: '1'))!;
      expect(older.name, '🏠 論壇大廳');
      final web = (await fetch(_html(_raw('s3_index.html')), gid: '1'))!;
      expect(web.name, older.name);

      final forum = _Forum.always(_api({'ok': 0, 'error': 'internal'}));
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
      addTearDown(() => getIt.unregister<NetClientProvider>());
      final failed = await ForumRepository().fetchForumGroup('3').run();
      expect(failed.getLeft().toNullable(), isA<HttpRequestFailedException>());
    });
  });
}
