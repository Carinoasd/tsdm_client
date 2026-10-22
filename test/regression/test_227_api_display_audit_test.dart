// Regressions of an audit of the pages built from the forum's app API against the web pages they replace: what the
// structured path showed differently from the web page, each item with the forum's template or answer it follows.
//
// 1. A floor's author column (`author_html`) is put back in the cell the page prints it in (`td#userinfo_PID`), so the
//    brief profile reads the floor's `div#ts_avatar_PID` again: the nickname and the user group of a member.
// 2. The custom title and the profile rows are the text the page shows of the html the forum prints (entities).
// 3. The points of a debate and the umpire's point are the forum's html (`*_html`), rendered.
// 4. The times the app shows as absolute ones are the forum's wall clock (`timeoffset`), the relative ones instants.
// 5. Another member's friends list prints no credits for 0, as `space_list` does.
// 6. A reply without text quotes "......" ("..." in the guide), as the pages print it.
// 7. The thread's author is `thread.authorid` on every page: no extra request of the first page for the block list.
// 8. "TA的主题" of another member opens the search by their name, or their profile when the link names a uid only, not
//    the account's own list.
// 9. An anonymous last post of a forum row names "匿名", as the page does.
//
// The samples are synthetic, shaped as the production forum's answers and its X5 author column (test_004); the
// forum rows of item 9 are a public forum page of the production forum with the member names replaced.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/friend/utils/friend_page_api.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/latest_thread/utils/guide_page_api.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_api.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/search/utils/search_page_api.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_thread_card.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:universal_html/parsing.dart';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('test/data/tsdmapp/$name').readAsStringSync()) as Map<String, dynamic>;

/// The forum's unix seconds as the wall clock of a member whose times the forum shows with an offset: what the
/// page prints, as a naive [DateTime] (the expected values are written out, whatever the zone the tests run in).
DateTime _wall(int y, int m, int d, int h, int mi, [int s = 0]) => DateTime(y, m, d, h, mi, s);

/// The X5 author column of a floor as the production forum prints it for a member (the inside of `td.pls`, as the
/// plugin cuts it into `author_html`; the template of test_004), with the staff's group line ([staffTitle], the
/// `<em>` the template prints for `adminid` not 0) or the empty `forum/viewthread_authortitle` of a member.
String _authorColumn({
  required int pid,
  required int uid,
  required String name,
  String nickname = '',
  String badge = 'data/attachment/common/group/永恒天使.gif',
  String badgeAlt = '',
  String? staffTitle,
}) =>
    '''
  <!--userinfo block start. stay blank TD-->
 <div class="p_pop blk bui" id="userinfo$pid" style="display: none; ">
<div class="i y">
<div>
<strong><a href="home.php?mod=space&amp;uid=$uid" target="_blank" class="xi2">$name</a></strong>
<em>当前离线</em>
</div>
</div>
</div>
<div id="ts_avatar_$pid">
<div class="post_nickname">$nickname</div>
<div class="avatar" onmouseover="showauthor(this, 'userinfo$pid')"><a class="userinfo_float_a" href="home.php?mod=space&amp;uid=$uid" target="_blank"><img data-src="https://example.com/avatar/$uid.jpeg" class="_avt user_avatar"></a></div>
<br />
<div class="tsdm_norm_title"><img src="$badge" alt="$badgeAlt" class="vm" style="width:auto;height:20px" /></div>
</div>
<p></p>
<!--TSDM statbar-->
<div class="tsdm_statbar">
${staffTitle == null ? '<!-- forum/viewthread_authortitle -->' : '<em><a href="home.php?mod=spacecp&ac=usergroup&gid=2" target="_blank" class="stat_authortitle">$staffTitle</a></em><br />'}
<span class="tsstat_icn_1 tsstat_icn_c">UID:</span><span class="tsstat_txt_c">$uid</span><br />
<span class="tsstat_icn_2 tsstat_icn_c">精华:</span><span class="tsstat_txt_c tsstat_txt_red">0</span><br />
<span class="tsstat_icn_3 tsstat_icn_c">主题:</span><span class="tsstat_txt_c tsstat_txt_green">47</span><br />
<span class="tsstat_icn_4 tsstat_icn_c">帖子:</span><span class="tsstat_txt_c tsstat_txt_lblue">1017</span><br />
<span class="tsstat_icn_5 tsstat_icn_c">威望:</span><span class="tsstat_txt_c tsstat_txt_purple">99</span><br />
<span class="tsstat_icn_7 tsstat_icn_c">阅读权限:</span><span class="tsstat_txt_c tsstat_txt_org">100</span><br />
<span class="tsstat_icn_8 tsstat_icn_c">注册时间:</span><span class="tsstat_txt_c tsstat_txt_blue">2012-6-12</span><br />
<span class="tsstat_icn_3 tsstat_icn_c">状态:</span>
<a title="性别:ひみつ-当前离线"><span class="tsstat-secret_offline" title="不在线"></span></a>
<br />
</div>
<div class="tsdmtitle-badges"><div class="tsdmtitle-title"><img src="https://example.com/title/$uid.gif" alt="title" /></div></div>
    <!--userinfo block end-->
''';

/// The structured thread page `thread_v3_plain.json` (9 floors) for the account 35, its first floors' author columns
/// replaced by [columns] (pid → (author column, group)), with [changes] on the answer.
Map<String, dynamic> _threadWith(
  Map<int, (String html, Map<String, dynamic>? group)> columns, {
  Map<String, dynamic> changes = const {},
}) {
  final json = _json('thread_v3_plain.json')..addAll(changes);
  for (final p in (json['posts'] as List).cast<Map<String, dynamic>>()) {
    final column = columns[p['pid']];
    if (column != null) {
      p['author_html'] = column.$1;
      p['group'] = column.$2;
    }
  }
  return json;
}

/// The profile of a structured profile answer [json] that is one.
UserProfile _profile(Map<String, dynamic> json) => profileFromApi(json).match((e) => fail('$e'), (v) => v);

Post _floor(Map<String, dynamic> json, int pid) =>
    threadPageFromApi(json, 1).postList.firstWhere((e) => e.postID == '$pid');

/// Whether a rendered text span reads [text] and opens a link.
bool _hasLink(WidgetTester tester, String text) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    var found = false;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == text && span.recognizer is GestureRecognizer) {
        found = true;
      }
      return !found;
    });
    if (found) {
      return true;
    }
  }
  return false;
}

/// Never answers: avatars and images are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Thread pages by page number, as the forum's app API answers them; every request is recorded.
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.pages);

  final Map<String, Map<String, dynamic>> pages;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final page = pages[options.uri.queryParameters['page'] ?? '1'];
    return ResponseBody.fromString(
      page == null ? '<html></html>' : jsonEncode(page),
      200,
      headers: {
        Headers.contentTypeHeader: [
          if (page == null) 'text/html; charset=utf-8' else 'application/json; charset=utf-8',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The forum's search: an empty result for every request, every request recorded.
final class _SearchAdapter implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      jsonEncode({
        'ok': 1,
        'type': 'search',
        'schema': 6,
        'uid': 0,
        'timeoffset': 8,
        'page': 1,
        'pages': 1,
        'count': 0,
        'threads': <Object>[],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = 2000;
const _troll = 3000;

/// Authentication with a fixed current account.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  Future<void> close() => _controller.close();
}

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Translations get _tr => LocaleSettings.instance.currentTranslations;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('1. the author column of a floor (author_html) as the brief profile reads it', () {
    test('the nickname, the avatar and the statistics of the X5 column are read again', () {
      final json = _threadWith({
        3940: (
          _authorColumn(pid: 3940, uid: 31, name: 'ag_low', nickname: '☂ 测试昵称 (fixture)'),
          {
            'gid': 62,
            'title': '永恒天使',
            'color': '',
            'icon': 'https://www.tsdm39.com/data/attachment/common/group/永恒天使.gif',
          },
        ),
      });
      final post = _floor(json, 3940);
      final profile = post.userBriefProfile;
      expect(profile, isNotNull, reason: 'the statistics column is there');
      // Read through `div#ts_avatar_3940`, which needs the id of the cell: none of these were read before.
      expect(profile!.nickname, '☂ 测试昵称 (fixture)');
      expect(profile.avatarUrl, 'https://example.com/avatar/31.jpeg');
      expect(profile.userGroup, '永恒天使');
      expect(profile.username, 'ag_low', reason: 'the name of the hidden user card');
      expect(profile.uid, '31');
      expect(profile.threadCount, '47');
      expect(profile.postCount, '1017');
      expect(profile.registrationDate, '2012-6-12');
      // The group badge and the title badge of the column, as before.
      expect(post.badge, '$baseUrl/data/attachment/common/group/永恒天使.gif');
      expect(post.secondBadge, 'https://example.com/title/31.gif');
    });

    test("a member's group is the forum's name of it, not the file name of its badge", () {
      final json = _threadWith({
        3940: (
          _authorColumn(pid: 3940, uid: 31, name: 'ag_low', badge: 'data/attachment/common/group/片翼天使.gif'),
          {'gid': 72, 'title': '片翼天使LV.2', 'color': '', 'icon': ''},
        ),
        3942: (
          // A colored group of a member (the forum's group setting: a color name or #RRGGBB).
          _authorColumn(pid: 3942, uid: 35, name: 'ag_low2', badge: 'data/attachment/common/group/莉莉丝2.gif'),
          {'gid': 119, 'title': '莉莉丝', 'color': '#FF0000', 'icon': ''},
        ),
      });
      final member = _floor(json, 3940).userBriefProfile!;
      expect(member.userGroup, '片翼天使LV.2', reason: 'the badge 片翼天使.gif names the group only roughly');
      expect(member.userGroupColor, isNull, reason: 'the group has no color');
      final colored = _floor(json, 3942).userBriefProfile!;
      expect(colored.userGroup, '莉莉丝');
      expect(colored.userGroupColor, const Color(0xFFFF0000));
    });

    test('the group the column prints as text (the staff) and the name the page gives the badge come first', () {
      final json = _threadWith({
        3954: (
          _authorColumn(
            pid: 3954,
            uid: 33,
            name: 'ag_mid',
            badge: 'data/attachment/common/group/大天使2.gif',
            staffTitle: '<font color="#FF0000">超级版主</font>',
          ),
          {'gid': 2, 'title': '超级版主（另一个名字）', 'color': 'Blue', 'icon': ''},
        ),
        3940: (
          _authorColumn(pid: 3940, uid: 31, name: 'ag_low', badgeAlt: '页面给的名字'),
          {'gid': 62, 'title': '永恒天使', 'color': '', 'icon': ''},
        ),
      });
      final staff = _floor(json, 3954).userBriefProfile!;
      expect(staff.userGroup, '超级版主');
      expect(staff.userGroupColor, const Color(0xFFFF0000), reason: 'the color of the printed name, #RRGGBB');
      expect(_floor(json, 3940).userBriefProfile!.userGroup, '页面给的名字');
    });

    test("without the floor's group the badge file name is still the fallback; a guest page has no profile", () {
      final json = _threadWith({3940: (_authorColumn(pid: 3940, uid: 31, name: 'ag_low'), null)});
      expect(_floor(json, 3940).userBriefProfile!.userGroup, '永恒天使');
      // The guest column of the production forum: no statistics, no profile, as on the web path.
      final guest = _threadWith({3940: ('\n    <div class="temp_test"></div>\n    <!--userinfo block end-->\n', null)});
      expect(_floor(guest, 3940).userBriefProfile, isNull);
    });

    test('the structured path reads the same profile as the web page path of the same column', () {
      final column = _authorColumn(pid: 3940, uid: 31, name: 'ag_low', nickname: 'nick');
      final web = Post.fromPostNode(
        parseHtmlDocument('''
<div id="post_3940"><table id="pid3940"><tr><td id="userinfo_3940" class="pls">$column</td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&ptid=1&pid=3940"><em>2</em><sup>#</sup></a>
</strong><div class="pti"><div class="authi"><a href="home.php?mod=space&amp;uid=31" target="_blank" class="xi2">ag_low</a>
<em id="authorposton3940">发表于 2026-9-30 18:28:50</em></div></div></div>
<div class="pct"><div class="pcb"><div class="t_fsz"><table><tr><td class="t_f" id="postmessage_3940">x</td></tr></table>
</div></div></div></td></tr></table></div>''').querySelector('div#post_3940')!,
        1,
      )!;
      final api = _floor(_threadWith({3940: (column, null)}), 3940);
      UserBriefProfile? read(Post post) => post.userBriefProfile;
      Object fields(UserBriefProfile p) => (
        p.username,
        p.uid,
        p.nickname,
        p.avatarUrl,
        p.userGroup,
        p.userGroupColor,
        p.threadCount,
        p.postCount,
        p.famous,
        p.privilege,
        p.registrationDate,
        p.online,
      );
      expect(fields(read(api)!), fields(read(web)!));
      expect(read(web)!.nickname, 'nick');
    });
  });

  group('2. the profile rows are the text the page shows', () {
    Map<String, dynamic> profile({required String customStatus, required List<Map<String, String>> rows}) => {
      'ok': 1,
      'type': 'profile',
      'schema': 4,
      'uid': 0,
      'timeoffset': 8,
      'user': {
        'uid': 10,
        'username': 'fixture_member',
        'groupid': 52,
        'group': '白夜天使',
        'avatar': 'https://example.com/avatar.jpg',
        'online': 0,
        'self': 0,
        'friend': 0,
        'email_verified': 0,
        'customstatus': customStatus,
        'signature_html': '',
      },
      'stats': {'friends': 15, 'credits': 28311, 'extcredits': <Object>[]},
      'profiles': rows,
      'medals': <Object>[],
      'manage_forums': <Object>[],
      'groups': {'admin': null, 'member': null, 'ext': <Object>[]},
      'activity': {'regdate': 1285891800},
    };

    test('the custom title: the entities the forum stores are decoded (`念念不回家&#3109;&#3178;&#3109;` of uid 10)', () {
      final p = _profile(profile(customStatus: '念念不回家&#3109;&#3178;&#3109;', rows: []));
      expect(p.customTitle, '念念不回家${String.fromCharCodes([3109, 3178, 3109])}');
      expect(p.customTitle, isNot(contains('&#')));
    });

    test('the text rows are decoded once, their tags dropped; the introduction stays html; the QQ number', () {
      final p = _profile(
        profile(
          customStatus: 'Tom &amp; Jerry &amp;lt;3 R&B',
          rows: [
            {'id': 'field1', 'title': '昵称', 'value': 'F.komo &quot;小&quot; &#9829;'},
            {'id': 'gender', 'title': '性别', 'value': '女'},
            {'id': 'residecity', 'title': '来自', 'value': '<a href="https://example.com/">马桶另一头</a> &amp; 小世界'},
            {'id': 'msn', 'title': 'MSN', 'value': 'msn&#95;fixture'},
            {'id': 'constellation', 'title': '星座', 'value': '天秤座'},
            {'id': 'bio', 'title': '自我介绍', 'value': '第一行<br />第二行 &amp; more'},
            {
              'id': 'qq',
              'title': 'QQ',
              'value':
                  '<a href="//wpa.qq.com/msgrd?v=3&uin=12345&site=x" target="_blank"><img src="q.gif" alt="QQ" /></a>',
            },
          ],
        ),
      );
      // `&amp;` is `&` once: a literal "&lt;" the member typed stays "&lt;", as the page shows it; a bare `&` stays.
      expect(p.customTitle, 'Tom & Jerry &lt;3 R&B');
      expect(p.nickname, 'F.komo "小" ♥');
      expect(p.gender, '女');
      expect(p.from, '马桶另一头 & 小世界');
      expect(p.msn, 'msn_fixture');
      expect(p.zodiac, '天秤座');
      expect(p.introduction, '第一行<br />第二行 &amp; more', reason: 'rendered as html by the profile page');
      expect(p.qq, '12345');
    });

    test('a row that is only markup is no row; an empty custom title none', () {
      final p = _profile(
        profile(
          customStatus: ' ',
          rows: [
            {'id': 'field1', 'title': '昵称', 'value': '<span></span>'},
          ],
        ),
      );
      expect(p.customTitle, isNull);
      expect(p.nickname, isNull);
    });
  });

  group("3. the points of a debate are the forum's html", () {
    Map<String, dynamic> debate({bool html = true}) => {
      'type': 'debate',
      'affirmpoint': '观点见这帖第二行',
      if (html) 'affirmpoint_html': '观点见<a href="$baseUrl/forum.php?mod=viewthread&amp;tid=1">这帖</a><br />第二行',
      'negapoint': '反方观点 plain',
      if (html) 'negapoint_html': '<strong>反方</strong>观点 plain',
      'affirmvotes': 2,
      'negavotes': 1,
      'endtime': 1790885730,
      'ended': 1,
      'umpire': 'ag_mod',
      'result': {
        'winner': 1,
        'umpirepoint': '正方胜 理由',
        if (html) 'umpirepoint_html': '<strong>正方胜</strong> <a href="https://example.com/why">理由</a>',
        'bestdebater': 'ag_low',
      },
    };

    test('the model keeps the html beside the text', () {
      final d = ThreadSpecial.fromApi(debate())! as DebateSpecial;
      expect(d.affirmPoint, '观点见这帖第二行');
      expect(d.affirmPointHtml, contains('<a href='));
      expect(d.negaPointHtml, '<strong>反方</strong>观点 plain');
      expect(d.result!.umpirePointHtml, contains('<strong>正方胜</strong>'));
      final plain = ThreadSpecial.fromApi(debate(html: false))! as DebateSpecial;
      expect((plain.affirmPointHtml, plain.negaPointHtml, plain.result!.umpirePointHtml), ('', '', ''));
    });

    group('the card', () {
      late AppDatabase db;
      late SettingsRepository settings;
      late SettingsBloc bloc;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        final storage = StorageProvider(db, {}, {});
        settings = SettingsRepository(storage);
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settings)
          ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
          ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
          ..registerSingleton<NetErrorSaver>(NetErrorSaver())
          ..registerSingleton<ImageCacheProvider>(
            ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
          );
        await settings.init();
        bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      });
      tearDown(() async {
        await bloc.close();
        await getIt.reset();
        await settings.dispose();
        await db.close();
      });

      Future<void> pump(WidgetTester tester, ThreadSpecial special) async {
        await tester.pumpWidget(
          BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(child: SpecialThreadCard(special, pid: '6301')),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      testWidgets('the points and the verdict are rendered: the links open, the plain text is not shown', (
        tester,
      ) async {
        await pump(tester, ThreadSpecial.fromApi(debate())!);
        expect(_hasLink(tester, '这帖'), isTrue, reason: 'the link of the affirmative point');
        expect(_hasLink(tester, '理由'), isTrue, reason: "the link of the umpire's point");
        expect(find.text('观点见这帖第二行'), findsNothing, reason: 'not the plain text');
        expect(find.textContaining('反方观点 plain', findRichText: true), findsOneWidget);
        expect(find.textContaining(_tr.specialThread.debate.bestDebater(name: 'ag_low')), findsOneWidget);
      });

      testWidgets('an answer without the html shows the plain text as before', (tester) async {
        await pump(tester, ThreadSpecial.fromApi(debate(html: false))!);
        expect(find.text('观点见这帖第二行'), findsOneWidget);
        expect(find.textContaining('正方胜 理由'), findsOneWidget);
        expect(_hasLink(tester, '这帖'), isFalse);
      });
    });
  });

  group("4. absolute times are the forum's wall clock, relative ones the instant", () {
    test('a floor: the publish time with the timeoffset of the answer', () {
      // 1790763526 is 2026-09-30 10:18:46 UTC.
      final page = threadPageFromApi(_json('thread_v3_plain.json')..['timeoffset'] = 9, 1);
      expect(page.postList.first.publishTime, _wall(2026, 9, 30, 19, 18, 46));
      final asForum = threadPageFromApi(_json('thread_v3_plain.json'), 1);
      expect(asForum.postList.first.publishTime, _wall(2026, 9, 30, 18, 18, 46));
    });

    test('the special blocks: the activity, the end of a debate and of a poll as dates', () {
      // 1790885730 is 2026-10-01 20:15:30 UTC.
      final activity =
          ThreadSpecial.fromApi({
                'type': 'activity',
                'starttimefrom': 1790885730,
                'starttimeto': 1790885730 + 3600,
                'expiration': 1790885730 - 3600,
                'applylist': [
                  {'uid': 31, 'username': 'ag_low', 'dateline': 1790885730},
                ],
              }, timeOffset: 9)!
              as ActivitySpecial;
      expect(activity.startFrom, _wall(2026, 10, 2, 5, 15, 30));
      expect(activity.startTo, _wall(2026, 10, 2, 6, 15, 30));
      expect(activity.expiration, _wall(2026, 10, 2, 4, 15, 30));
      expect(activity.applyList.single.dateline, _wall(2026, 10, 2, 5, 15, 30));
      final debate = ThreadSpecial.fromApi({'type': 'debate', 'endtime': 1790885730}, timeOffset: -5)! as DebateSpecial;
      expect(debate.endTime, _wall(2026, 10, 1, 15, 15, 30));
      // The end of a poll: the instant kept, the forum's clock shown; whether it ended is the forum's `expired`.
      final poll =
          ThreadSpecial.fromApi({'type': 'poll', 'expiration': 1790885730, 'expired': 0}, timeOffset: -5)!
              as PollSpecial;
      expect(poll.expiration, DateTime.fromMillisecondsSinceEpoch(1790885730 * 1000));
      expect(poll.expirationClock, _wall(2026, 10, 1, 15, 15, 30));
      expect(
        forumPollFromSpecial(poll, loggedIn: true).deadline,
        _tr.specialThread.poll.deadline(time: '2026-10-01 15:15'),
      );
      final ended =
          ThreadSpecial.fromApi({'type': 'poll', 'expiration': 1790885730, 'expired': 1}, timeOffset: -5)!
              as PollSpecial;
      expect(forumPollFromSpecial(ended, loggedIn: true).deadline, _tr.specialThread.poll.ended);
    });

    test("one page, one clock: a floor's time and the poll's end, whatever the device's zone", () {
      // The poll ends one hour after its first floor was posted (the review's probe): on the page both are the
      // forum's clock (+8 here, +12 below), so the end reads one hour after the floor, also on a device in New York.
      for (final offset in [8, 12, -5]) {
        final json = _json('special_v15_poll_single_before.json')..['timeoffset'] = offset;
        final first = (json['posts'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['first'] == 1);
        final posted = (first['dateline'] as num).toInt();
        json['special'] = {...(json['special'] as Map<String, dynamic>), 'expiration': posted + 3600, 'expired': 0};
        final page = threadPageFromApi(json, 1);
        final floor = page.postList.firstWhere((e) => e.postID == '${first['pid']}');
        final poll = forumPollFromSpecial(page.special! as PollSpecial, loggedIn: true);
        expect(floor.publishTime, tsdmAppWallClockTime(posted, offset), reason: 'offset $offset');
        expect(
          poll.deadline,
          _tr.specialThread.poll.deadline(time: floor.publishTime!.add(const Duration(hours: 1)).yyyyMMDDHHMM()),
          reason: 'offset $offset',
        );
      }
    });

    test("the poll read again after a vote takes the answer's timeoffset too", () {
      final json = _json('special_v15_poll_single_before.json')..['timeoffset'] = 12;
      // 1790885730 is 2026-10-01 20:15:30 UTC: 2026-10-02 08:15 at +12.
      json['special'] = {...(json['special'] as Map<String, dynamic>), 'expiration': 1790885730, 'expired': 0};
      final poll = PollRepository.pollOfApiAnswer(json, uid: (json['uid'] as num).toInt());
      expect(poll.deadline, _tr.specialThread.poll.deadline(time: '2026-10-02 08:15'));
    });

    test("the thread page reads the special block's times with the answer's timeoffset", () {
      final json = _json('special_v15_debate_ended_result.json');
      final end = ((json['special'] as Map<String, dynamic>)['endtime'] as num).toInt();
      json['timeoffset'] = 12;
      final page = threadPageFromApi(json, 1);
      expect((page.special! as DebateSpecial).endTime, tsdmAppWallClockTime(end, 12));
    });

    test('the lists: the publish date the wall clock, the last reply the instant', () {
      final forum = _json('forum_v2_fid2.json')..['timeoffset'] = 9;
      final row = (forum['threads'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tid'] == 9199345);
      final thread = forumPageFromApi(forum, '2').normalThreadList.firstWhere((e) => e.threadID == '9199345');
      expect(thread.publishDate, tsdmAppWallClockTime(row['dateline'], 9));
      expect(thread.latestReplyTime, DateTime.fromMillisecondsSinceEpoch((row['lastpost'] as int) * 1000));

      final search = _json('search_v6_results.json')..['timeoffset'] = 9;
      final searchRow = (search['threads'] as List).first as Map<String, dynamic>;
      expect(searchResultFromApi(search).data!.first.publishTime, tsdmAppWallClockTime(searchRow['dateline'], 9));

      const guideUrl = '$baseUrl/forum.php?mod=guide&view=new';
      final guide = _json('guide_v7_new.json')..['timeoffset'] = 9;
      final guideRow = (guide['threads'] as List).first as Map<String, dynamic>;
      expect(
        latestThreadsFromApi(guide, guideUrl).$1.first.latestReplyTime,
        tsdmAppWallClockTime(guideRow['lastpost'], 9),
      );

      const mineUrl = '$baseUrl/home.php?mod=space&do=thread&view=me&type=thread';
      final mine = _json('mythread_v9_thread.json')..['timeoffset'] = 9;
      final mineRow = (mine['threads'] as List).first as Map<String, dynamic>;
      final first = myThreadsFromApi(mine, mineUrl).$1.first;
      expect(first.latestReplyClock, tsdmAppWallClockTime(mineRow['lastpost'], 9));
      expect(first.latestReplyTime, DateTime.fromMillisecondsSinceEpoch((mineRow['lastpost'] as int) * 1000));
    });

    group('the card of "my threads"', () {
      late AppDatabase db;
      late SettingsRepository settings;
      late SettingsBloc bloc;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        final storage = StorageProvider(db, {}, {});
        settings = SettingsRepository(storage);
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settings)
          ..registerSingleton<NetErrorSaver>(NetErrorSaver())
          ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
          ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
          ..registerSingleton<ImageCacheProvider>(
            ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
          );
        await settings.init();
        bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      });
      tearDown(() async {
        await bloc.close();
        await getIt.get<ImageCacheProvider>().dispose();
        await getIt.reset();
        await settings.dispose();
        await db.close();
      });

      testWidgets("dates the last reply by the forum's clock and tells its age by the instant", (tester) async {
        // 1792499400 is 2026-10-20 12:30 UTC: 2026-10-21 00:30 for a member at +12, 2026-10-20 where the tests run
        // (+8 or UTC).
        final mine = _json('mythread_v9_thread.json')..['timeoffset'] = 12;
        (mine['threads'] as List).first as Map<String, dynamic>
          ..['lastpost'] = 1792499400
          ..['dateline'] = 1792499400;
        final thread = myThreadsFromApi(mine, '$baseUrl/home.php?mod=space&do=thread&view=me').$1.first;
        await tester.pumpWidget(
          TranslationProvider(
            child: BlocProvider<SettingsBloc>.value(
              value: bloc,
              child: MaterialApp(
                home: Scaffold(body: ListView(children: [MyThreadCard(thread)])),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('2026-10-21'), findsOneWidget);
        expect(find.text('2026-10-20'), findsNothing);
        // The age of the reply from the instant, as before.
        expect(
          find.text(
            DateTime.fromMillisecondsSinceEpoch(
              1792499400 * 1000,
            ).elapsedTillNow(tester.element(find.byType(MyThreadCard))),
          ),
          findsOneWidget,
        );
      });
    });
  });

  group("5. the credits of another member's friends", () {
    test('printed only when not 0, as `space_list` prints them', () {
      final json = _json('friend_v10_other.json');
      final row = (json['friends'] as List).first as Map<String, dynamic>;
      json['friends'] = [
        {...row, 'uid': 41, 'username': 'zero', 'credits': 0},
        {...row, 'uid': 42, 'username': 'some', 'credits': 1032},
        {...row, 'uid': 43, 'username': 'negative', 'credits': -3},
      ];
      const url = '$baseUrl/home.php?mod=space&uid=64&do=friend';
      final items = friendListPageFromApi(json, url).items;
      expect(items.map((e) => e.credits), [null, '1032', '-3']);
      // The owner's own list prints none at all.
      final own = friendListPageFromApi({...json, 'self': 1}, url).items;
      expect(own.map((e) => e.credits), [null, null, null]);
    });
  });

  group('6. a reply without text', () {
    test('"my threads": the reply page quotes "......", a numeric reply as it is, other pages nothing', () {
      final json = _json('mythread_v9_reply.json');
      final rows = (json['threads'] as List).cast<Map<String, dynamic>>();
      rows[0]['summary'] = '';
      rows[1]['summary'] = '0';
      const url = '$baseUrl/home.php?mod=space&do=thread&view=me&type=reply';
      final (threads, _) = myThreadsFromApi(json, url);
      expect(threads[0].quotedMessage, '......');
      expect(threads[1].quotedMessage, '0');
      expect(threads[2].quotedMessage, isNotEmpty);

      final list = _json('mythread_v9_thread.json');
      ((list['threads'] as List).first as Map<String, dynamic>)
        ..['pid'] = 5
        ..['summary'] = '';
      expect(myThreadsFromApi(list, url).$1.first.quotedMessage, isNull, reason: 'not the reply page');
    });

    test("the guide's 'my replies': '...' for an empty or '0' reply, as `guide_list_row` prints it", () {
      final json = _json('guide_v7_my_reply.json');
      final rows = (json['threads'] as List).cast<Map<String, dynamic>>();
      rows[0]['summary'] = '';
      rows[1]['summary'] = '0';
      final (threads, _) = latestThreadsFromApi(json, '$baseUrl/forum.php?mod=guide&view=my&type=reply');
      expect(threads[0].quotedMessage, '...');
      expect(threads[1].quotedMessage, '...');
      expect(threads[2].quotedMessage, rows[2]['summary']);
    });
  });

  group("7. the thread's author is the answer's thread.authorid", () {
    test('every page names it; an anonymous thread none', () {
      final page2 = _json('thread_v3_plain.json')
        ..['page'] = 2
        ..['pages'] = 2;
      expect(threadPageFromApi(page2, 2).authorUid, 32);
      final anonymous = _json('thread_v3_plain.json');
      (anonymous['thread'] as Map<String, dynamic>)
        ..['authorid'] = 0
        ..['author'] = ''
        ..['anonymous'] = 1;
      expect(threadPageFromApi(anonymous, 1).authorUid, isNull);
      expect(threadPageFromApi(anonymous, 1).asOffline(DateTime(2026)).authorUid, isNull);
      expect(threadPageFromApi(page2, 2).asOffline(DateTime(2026)).authorUid, 32);
    });

    group('the thread page opened on a later page with somebody blocked', () {
      late AppDatabase db;
      late StorageProvider storage;
      late SettingsRepository settings;
      late SettingsBloc settingsBloc;
      late UserBlockRepository blocks;
      late _Auth auth;
      late _ThreadAdapter adapter;

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
        getIt.registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
        settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
        blocks = UserBlockRepository(storage);
        auth = _Auth(_alice);
        ThreadAuthorCache.clear();
      });

      tearDown(() async {
        await settingsBloc.close();
        await blocks.dispose();
        await auth.close();
        await getIt.get<ImageCacheProvider>().dispose();
        await getIt.reset();
        await settings.dispose();
        await db.close();
        ThreadAuthorCache.clear();
      });

      /// Page 2 of thread 1264975 for Alice: floors of Bob and Alice, the thread started by [author].
      Map<String, dynamic> page2({required int author}) {
        final json = _json('thread_v3_plain.json');
        final posts = (json['posts'] as List).cast<Map<String, dynamic>>();
        json
          ..['uid'] = _alice.uid
          ..['page'] = 2
          ..['pages'] = 2
          ..['posts'] = [
            for (final (pid, uid, name) in [(11, _bob, 'Bob'), (12, _alice.uid, 'Alice')])
              {
                ...posts[1],
                'pid': pid,
                'position': pid,
                'first': 0,
                'authorid': uid,
                'author': name,
                'author_html': '',
                'signature_html': '',
                'rate': null,
                'body_html':
                    '<div class="t_fsz"><table><tr><td class="t_f" id="postmessage_$pid">floor $pid text</td></tr></table></div>',
                'message': null,
              },
          ];
        (json['thread'] as Map<String, dynamic>)
          ..['tid'] = 1264975
          ..['subject'] = 'Secret title'
          ..['authorid'] = author
          ..['author'] = author > 0 ? 'u$author' : ''
          ..['anonymous'] = author > 0 ? 0 : 1;
        return json;
      }

      Future<void> pump(WidgetTester tester, Map<String, Map<String, dynamic>> pages) async {
        adapter = _ThreadAdapter(pages);
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        );
        await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: _troll, username: 'troll'));
        final info = NotificationInfoRepository();
        final counts = NotificationStateCubit(info);
        final cubit = UserBlockCubit(
          repository: blocks,
          currentUid: () => auth.currentUser?.uid,
          authStatus: auth.status,
        );
        final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const ThreadPage(
                threadID: '1264975',
                findPostID: null,
                pageNumber: '2',
                overrideReverseOrder: false,
                overrideWithExactOrder: null,
              ),
            ),
          ],
        );
        addTearDown(() async {
          router.dispose();
          await cubit.close();
          await history.close();
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
                  BlocProvider<NotificationBloc>.value(value: _Notifications()),
                  BlocProvider<NotificationStateCubit>.value(value: counts),
                  BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
                ],
                child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
              ),
            ),
          ),
        );
        await _settle(tester);
      }

      testWidgets('the author the page names is used: no request of the first page, the thread hidden', (tester) async {
        await pump(tester, {'2': page2(author: _troll)});
        expect(adapter.requests.map((e) => e.queryParameters['page']), ['2'], reason: 'the first page is not asked');
        expect(ThreadAuthorCache.authorOf('1264975'), _troll);
        expect(find.text(_tr.userBlock.threadHidden), findsOneWidget);
        expect(find.text('Secret title'), findsNothing);
      });

      testWidgets('an author nobody blocked: shown at once, without the first page', (tester) async {
        await pump(tester, {'2': page2(author: _bob)});
        expect(adapter.requests.map((e) => e.queryParameters['page']), ['2']);
        expect(find.text(_tr.userBlock.threadHidden), findsNothing);
        expect(find.textContaining('Secret title', findRichText: true), findsWidgets);
      });

      testWidgets('an anonymous thread names none: the first page is asked as before', (tester) async {
        final first = _json('thread_v3_plain.json')
          ..['uid'] = _alice.uid
          ..['posts'] = [
            {
              ...((_json('thread_v3_plain.json')['posts'] as List).first as Map<String, dynamic>),
              'authorid': 0,
              'author': '',
              'anonymous': 1,
              'author_html': '',
              'signature_html': '',
              'body_html':
                  '<div class="t_fsz"><table><tr><td class="t_f" id="postmessage_3938">floor 1 text</td></tr></table></div>',
              'message': null,
            },
          ];
        (first['thread'] as Map<String, dynamic>)['tid'] = 1264975;
        await pump(tester, {'1': first, '2': page2(author: 0)});
        expect(adapter.requests.map((e) => e.queryParameters['page']), containsAll(['1', '2']));
      });
    });
  });

  group("8. a member's thread list", () {
    test("of another member: their page (test_235); of nobody: the account's own list", () {
      // Superseded by the member's page (test_235): by uid and/or by name, their threads or their replies.
      final other = 'home.php?mod=space&uid=1103&do=thread&view=me&from=space'.parseUrlToRoute()!;
      expect(other.screenPath, ScreenPaths.memberThread);
      expect(other.queryParameters, {'uid': '1103'});
      final escaped = '$baseUrl/home.php?mod=space&amp;uid=1103&amp;do=thread&amp;type=thread&amp;view=me'
          .unescapeHtml()!
          .parseUrlToRoute()!;
      expect(escaped.screenPath, ScreenPaths.memberThread);
      expect(escaped.queryParameters, {'uid': '1103'});
      final byName = 'home.php?mod=space&username=fixture&do=thread&view=me'.parseUrlToRoute()!;
      expect(byName.screenPath, ScreenPaths.memberThread);
      expect(byName.queryParameters, {'username': 'fixture'});

      expect('home.php?mod=space&do=thread&view=me'.parseUrlToRoute()!.screenPath, ScreenPaths.myThread);
      expect(myThreadReplyUrl.parseUrlToRoute()!.screenPath, ScreenPaths.myThread);
      expect('home.php?mod=space&uid=0&do=thread&view=me'.parseUrlToRoute()!.screenPath, ScreenPaths.myThread);
    });

    test('their comments have no page in the app: an unsupported forum link (the web page)', () {
      expect('home.php?mod=space&uid=1103&do=thread&view=me&type=postcomment'.parseUrlToRoute(), isNull);
      // Their profile is still their profile.
      final profile = 'home.php?mod=space&uid=1103'.parseUrlToRoute()!;
      expect(profile.screenPath, ScreenPaths.profile);
      expect(profile.queryParameters, {'uid': '1103'});
    });

    group('the search it opens', () {
      late AppDatabase db;
      late SettingsRepository settings;
      late _SearchAdapter adapter;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        final storage = StorageProvider(db, {}, {});
        settings = SettingsRepository(storage);
        adapter = _SearchAdapter();
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settings)
          ..registerSingleton<NetErrorSaver>(NetErrorSaver())
          ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
          ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
          ..registerFactory<NetClientProvider>(
            () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
          );
        await settings.init();
      });
      tearDown(() async {
        await getIt.reset();
        await settings.dispose();
        await db.close();
      });

      /// The search the profile's "搜索此人的帖子" opens with [query]: the query of the request it sends.
      Future<Map<String, String>> searchOf(WidgetTester tester, Map<String, String> query) async {
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => SearchPage(authorUid: query['authorUid'], authorName: query['authorName']),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
        await _settle(tester);
        return adapter.requests.single.queryParameters;
      }

      testWidgets('a member named by digits only is searched by name, not as a uid', (tester) async {
        final query = await searchOf(tester, {'authorName': '12345'});
        expect(query['srchuname'], '12345');
        expect(query.containsKey('srchuid'), isFalse);
      });

      testWidgets('a member named by name and uid is searched by the name alone', (tester) async {
        final query = await searchOf(tester, {'authorUid': '1103', 'authorName': 'fixture'});
        expect(query['srchuname'], 'fixture');
        expect(query.containsKey('srchuid'), isFalse);
      });
    });
  });

  group('9. an anonymous last post of a forum row', () {
    // Two subforums of a public forum page of the production forum (fid 131), the member's name replaced.
    final anonymousRow = {
      'fid': 577,
      'name': 'GREAT PRETENDER',
      'description': '',
      'icon': 'https://img.tsdm39.com/img01/LOGO/577.png',
      'namecolor': '',
      'threads': 304,
      'posts': 2278,
      'todayposts': 0,
      'redirect': '',
      'lastpost': {'tid': 1023864, 'subject': '【大欺诈师】壁纸 x1', 'dateline': 1792198043, 'author': ''},
      'moderators': <Object>[],
      'subforums': <Object>[],
      'permission': 2,
    };
    final namedRow = {
      ...anonymousRow,
      'fid': 300,
      'name': '魔法科高中的劣等生：来访者篇',
      'lastpost': {'tid': 426506, 'subject': '【度娘】图包', 'dateline': 1788484007, 'author': 'fixture_member'},
    };

    void expectRows(List<Forum> forums) {
      final anonymous = forums.firstWhere((e) => e.forumID == 577);
      expect(anonymous.latestThreadUserName, '匿名', reason: "the page prints the forum's anonymous text");
      expect(anonymous.latestThreadUserUrl, isNull, reason: 'without a link');
      expect(anonymous.latestThreadTitle, '【大欺诈师】壁纸 x1');
      final named = forums.firstWhere((e) => e.forumID == 300);
      expect(named.latestThreadUserName, 'fixture_member');
      expect(named.latestThreadUserUrl, '$baseUrl/home.php?mod=space&username=fixture_member');
    }

    test('the subforums of a forum page', () {
      final page = forumPageFromApi({
        'ok': 1,
        'type': 'forum',
        'schema': 2,
        'uid': 0,
        'timeoffset': 8,
        'forum': {'fid': 131, 'name': 'Board'},
        'types': {'prefix': 0, 'listable': 0, 'items': <Object>[]},
        'filters': <String, Object>{},
        'subforums': [anonymousRow, namedRow],
        'threads': <Object>[],
      }, '131');
      expectRows(page.subredditList);
    });

    test('the forums of the homepage categories', () {
      final groups = forumGroupsFromApi({
        'ok': 1,
        'type': 'index',
        'schema': 5,
        'uid': 0,
        'timeoffset': 8,
        'categories': [
          {
            'gid': 1,
            'name': 'Category',
            'forums': [anonymousRow, namedRow],
          },
        ],
      });
      expectRows(groups.expand((e) => e.forumList).toList());
    });

    test('a forum without a last post has no name', () {
      final none = Forum.fromApi({...anonymousRow, 'lastpost': null});
      expect(none.latestThreadUserName, isNull);
    });
  });
}
