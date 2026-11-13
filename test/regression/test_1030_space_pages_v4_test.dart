/// The pages of the space read from the forum's app API (plugin 4.0.0, `tsdmv=4`): the records (`space_doing`, schema
/// 57) and their replies (`space_docomment`, 58), the broadcasts (`space_feed`, 59), the follow lists (`space_follow`,
/// 60), the blog list (`space_blog`, 61), the album list (`space_album`, 62), the wall (`space_wall`, 63) and the
/// greetings received (`space_poke`, 64).
///
/// * Asked as a page (`tsdmapp=json&tsdmv=4&nodoc=1`) only once `status` listed it in `space_pages`; otherwise the web
///   page is read as before, and no request carries `tsdmv`.
/// * The same data read either way gives the same items (the recorded answer and web page of the same list).
/// * The owner's privacy (`error: privacy`) is the forum's sentence with the owner's name, the forum's message its
///   words, the login prompt the login; another account's answer is refused; another refusal of the plugin reads the
///   web page.
///
/// Fixtures: the answers and web pages of the test forum (cleaned); the privacy answer is the plugin's shape
/// (`lib/v4/space.php`), no member of the test forum hides a page.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show Either;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/doing/models/doing_models.dart';
import 'package:tsdm_client/features/doing/repository/doing_repository.dart';
import 'package:tsdm_client/features/doing/utils/parse_doing.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/follow/repository/follow_repository.dart';
import 'package:tsdm_client/features/follow/utils/parse_follow.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_repository.dart';
import 'package:tsdm_client/features/space/utils/space_v4.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// A fake forum answering [api] to a request with `tsdmv=4`, [web] to the web page (`tsdmapp=json` without it).
V4Forum _forum({Object? api, Object? web}) => V4Forum((o) {
  final q = o.uri.queryParameters;
  if (q['action'] == 'status') {
    return null;
  }
  if (q['tsdmv'] == '4') {
    return api == null ? null : V4Reply(api);
  }
  return web == null ? null : V4Reply(web);
});

/// The requests of [forum] for pages (not `status`).
List<Map<String, String>> _pages(V4Forum forum) => [
  for (final r in forum.requests)
    if (r.uri.queryParameters['action'] != 'status') r.uri.queryParameters,
];

bool _asksV4(V4Forum forum) =>
    _pages(forum).isNotEmpty &&
    _pages(forum).every((q) => q['tsdmv'] == '4' && q['tsdmapp'] == 'json' && q['nodoc'] == '1');

bool _asksWeb(V4Forum forum) => _pages(forum).isNotEmpty && _pages(forum).every((q) => !q.containsKey('tsdmv'));

/// The path of [url]: the web page links relative to the forum (the app makes them absolute on its own host), the
/// answer absolute on the forum's.
String? _p(String? url) => url == null ? null : Uri.parse(url).path;

int? _pageOf(String? url) => url == null ? null : int.tryParse(Uri.parse(url).queryParameters['page'] ?? '');

SpaceListPage<T> _ok<T>(Either<AppException, SpaceListPage<T>> result) => result.getOrElse((e) => throw e);

void main() {
  setUpAll(() async {
    registerV4TestServices();
    // The forum's own words are Chinese: the app's words for them are compared in the same language.
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('records (doing, schema 57) and their replies (docomment, 58)', () {
    const url = 'https://www.tsdm39.com/home.php?mod=space&do=doing&view=all';

    Future<SpaceListPage<Doing>> fetch(V4Forum forum, {int uid = _uid}) async {
      useV4Forum(forum);
      return _ok(await DoingRepository(currentUid: () => uid).fetchList(url).run());
    }

    List<Object?> rows(SpaceListPage<Doing> page) => [
      for (final d in page.items)
        (d.doid, d.uid, d.username, _p(d.avatarUrl), d.imageUrls.map(_p).join(','), d.replyCount, d.canDelete),
    ];

    test('the answer and the web page of the same list give the same records', () async {
      knowV4Status();
      final api = _forum(api: v4Json('space_doing_v57.json'));
      final fromApi = await fetch(api);
      expect(_asksV4(api), isTrue);
      TsdmAppApi.reset();
      final web = _forum(web: v4Raw('space_doing_web.html'));
      final fromWeb = await fetch(web);
      expect(_asksWeb(web), isTrue, reason: 'no status: the web page as before');
      expect(fromApi.items, hasLength(20));
      expect(rows(fromApi), rows(fromWeb));
      expect(fromApi.canPost, fromWeb.canPost);
      expect(fromApi.session?.uid, fromWeb.session?.uid);
      expect(fromApi.session?.formHash, fromWeb.session?.formHash);
      expect(_pageOf(fromApi.nextPageUrl), 2);
      expect(_pageOf(fromWeb.nextPageUrl), 2);
      final tagged = fromApi.items.firstWhere((d) => d.doid == 2);
      expect(tagged.content.querySelector('a.doing_tag'), isNotNull, reason: 'message_html rendered as html');
      expect(tagged.content.text, contains('<b>'), reason: 'escaped text stays text');
      expect(tagged.time, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
    });

    test("another member's records: no post box, the last page has no next", () async {
      knowV4Status();
      final page = await fetch(_forum(api: v4Json('space_doing_v57_member.json')));
      expect(page.items.single.doid, 3);
      expect(page.canPost, isFalse);
      expect(page.nextPageUrl, isNull);
    });

    test('not listed in space_pages: the web page, no tsdmv', () async {
      knowV4Status(v4Status({'space_pages': <String>[]}));
      final web = _forum(web: v4Raw('space_doing_web.html'));
      expect((await fetch(web)).items, hasLength(20));
      expect(_asksWeb(web), isTrue);
    });

    test('the replies of the answer and of the fragment are the same', () async {
      knowV4Status();
      final api = _forum(api: v4Json('space_docomment_v58.json'));
      useV4Forum(api);
      final fromApi = (await const DoingRepository(currentUid: _current).fetchComments(3).run()).getOrElse(
        (e) => throw e,
      );
      expect(_asksV4(api), isTrue);
      expect(_pages(api).single['page_c'], '1');
      TsdmAppApi.reset();
      final web = _forum(web: v4Json('space_docomment_web.json'));
      useV4Forum(web);
      final fromWeb = (await const DoingRepository(currentUid: _current).fetchComments(3).run()).getOrElse(
        (e) => throw e,
      );
      List<Object?> rows(DoingCommentPage p) => [
        for (final c in p.comments) (c.id, c.uid, c.username, c.nested, c.canReply, c.canDelete),
      ];
      expect(fromApi.comments, isNotEmpty);
      expect(rows(fromApi), rows(fromWeb));
      expect(fromApi.hasMore, isTrue);
      expect(fromWeb.hasMore, isTrue);
    });

    test("the replies: the login prompt without words is the login, the forum's words are its words", () async {
      knowV4Status();
      Future<DoingCommentPage> fetch(Map<String, dynamic> api, {int uid = _uid}) async {
        useV4Forum(_forum(api: api));
        return (await DoingRepository(currentUid: () => uid).fetchComments(3).run()).getOrElse((e) => throw e);
      }

      final guest = await fetch(const {'ok': 0, 'error': 'message', 'message': '', 'login': 1, 'uid': 0}, uid: 0);
      expect(guest.comments, isEmpty);
      expect(guest.message, t.general.needLogin);
      final off = await fetch(const {
        'ok': 0,
        'error': 'message',
        'message': '抱歉，记录功能尚未开启',
        'message_key': 'doing_status_off',
        'login': 0,
        'uid': _uid,
      });
      expect(off.message, '抱歉，记录功能尚未开启');
      final hidden = await fetch(const {
        'ok': 0,
        'error': 'privacy',
        'owner': {'uid': 58, 'username': 'ag_t22'},
        'uid': _uid,
      });
      expect(hidden.message, t.spacePage.forumWords.privacy(name: 'ag_t22'));
    });

    test('a reply to a reply begins with whom it answers; a deleted row is left out', () {
      final json = v4Json('space_docomment_v58.json');
      final rows = (json['comments'] as List).cast<Map<String, dynamic>>();
      json['comments'] = [
        {
          ...rows[1],
          'id': 90,
          'reply_to': {'uid': 37, 'username': 'ag_t01'},
        },
        {...rows[1], 'id': 91, 'deleted': 1, 'uid': 0, 'username': ''},
      ];
      final page = doingCommentsFromApi(json, doid: 3, page: 1);
      expect(page.comments.map((c) => c.id), [90]);
      expect(page.comments.single.message.text, startsWith(t.spacePage.doing.replyTo(name: 'ag_t01')));
    });
  });

  group('broadcasts (feed, schema 59)', () {
    const url = 'https://www.tsdm39.com/home.php?mod=follow&view=follow';

    test("the first page: the broadcasts and the forum's next part, asked as the website would", () async {
      knowV4Status();
      final api = _forum(api: v4Json('space_feed_v59.json'));
      useV4Forum(api);
      final page = _ok(await const FollowRepository(currentUid: _current).fetchFeed(url).run());
      expect(_asksV4(api), isTrue);
      expect(page.items, isNotEmpty);
      expect(page.session?.formHash, 'f1f2f3f4');
      final next = Uri.parse(page.nextPageUrl!).queryParameters;
      expect(isFollowMoreFeedUrl(page.nextPageUrl!), isTrue);
      expect(next, containsPair('page', '2'));
      expect(next, containsPair('inajax', '1'), reason: 'the web parser reads it as a fragment too');
      expect(next, containsPair('viewtype', 'follow'));
      final first = page.items.first;
      expect(first.threadId, 9202998);
      expect(first.threadTitle, isNotEmpty);
      expect(first.content, isNotNull);
      expect(first.forumName, isNotEmpty);
    });

    test("a further part asks the forum's next without inajax and reads it", () async {
      knowV4Status();
      final api = _forum(api: v4Json('space_feed_v59_more.json'));
      useV4Forum(api);
      const more =
          'https://www.tsdm39.com/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=0&page=2&viewtype=follow'
          '&inajax=1';
      final page = _ok(await const FollowRepository(currentUid: _current).fetchFeed(more).run());
      expect(_asksV4(api), isTrue);
      expect(_pages(api).single.containsKey('inajax'), isFalse);
      expect(page.items, isNotEmpty);
    });

    test('parts without a broadcast are skipped up to three; the empty next ends the list', () async {
      knowV4Status();
      var asked = 0;
      final forum = V4Forum((o) {
        if (o.uri.queryParameters['action'] == 'status') return null;
        asked++;
        final json = v4Json('space_feed_v59_more.json');
        json['feeds'] = <Object>[];
        json['next'] = asked < 2 ? 'home.php?mod=spacecp&ac=follow&op=getfeed&archiver=1&page=$asked' : '';
        return V4Reply(json);
      });
      useV4Forum(forum);
      const more = 'https://www.tsdm39.com/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=0&page=2&viewtype=follow';
      final page = _ok(await const FollowRepository(currentUid: _current).fetchFeed(more).run());
      expect(asked, 2);
      expect(page.items, isEmpty);
      expect(page.nextPageUrl, isNull);
    });

    test('a thread the viewer may not read and a thread gone', () {
      final json = v4Json('space_feed_v59.json');
      final rows = (json['feeds'] as List).cast<Map<String, dynamic>>();
      final thread = rows.first['thread'] as Map<String, dynamic>;
      json['feeds'] = [
        {
          ...rows.first,
          'thread': {
            ...thread,
            'restricted': 'forum',
            'subject': '',
            'forum': '',
            'fid': 0,
            'content_html': null,
            'reply_url': '',
          },
        },
        {...rows.first, 'feedid': 1, 'thread': null, 'deleted': 1, 'note_html': 'a <b>note</b>'},
      ];
      final feeds = followFeedsFromApi(json);
      expect(feeds.first.threadTitle, isNull);
      expect(feeds.first.forumName, isNull);
      expect(feeds.first.content!.text, t.spacePage.forumWords.threadRestricted);
      expect(feeds.first.threadMissing, isFalse);
      expect(feeds.last.threadMissing, isTrue);
      expect(feeds.last.content!.text, t.spacePage.forumWords.threadDeleted);
      expect(feeds.last.note!.querySelector('b')?.text, 'note');
    });
  });

  group('follow lists (follow, schema 60)', () {
    test("the answer and the web page of the account's followed give the same members", () async {
      const url = 'https://www.tsdm39.com/home.php?mod=follow&do=following';
      knowV4Status();
      final api = _forum(api: v4Json('space_follow_v60.json'));
      useV4Forum(api);
      final fromApi = _ok(await const FollowRepository(currentUid: _current).fetchList(url).run());
      expect(_asksV4(api), isTrue);
      TsdmAppApi.reset();
      final web = _forum(web: v4Raw('space_follow_web.html'));
      useV4Forum(web);
      final fromWeb = _ok(await const FollowRepository(currentUid: _current).fetchList(url).run());
      expect(_asksWeb(web), isTrue);
      List<Object?> rows(SpaceListPage<FollowUser> p) => [
        for (final u in p.items)
          (u.uid, u.username, u.remark, u.followerCount, u.followingCount, u.following, u.mutual, u.canRemark),
      ];
      expect(fromApi.items, hasLength(20));
      expect(rows(fromApi), rows(fromWeb));
      expect(fromApi.items.first.remark, isNotNull);
      expect(_pageOf(fromApi.nextPageUrl), 2);
      expect(_pageOf(fromWeb.nextPageUrl), 2);
    });
  });

  group('blog list (blog, 61), album list (album, 62), wall (wall, 63), greetings (poke, 64)', () {
    test('blogs: the same as the web page, the hidden note and the next page', () async {
      const url = 'https://www.tsdm39.com/home.php?mod=space&uid=35&do=blog&view=me';
      knowV4Status();
      final api = _forum(api: v4Json('space_blog_v61.json'));
      useV4Forum(api);
      final fromApi = _ok(await const SpaceRepository(currentUid: _current).fetchBlogList(url).run());
      expect(_asksV4(api), isTrue);
      TsdmAppApi.reset();
      final web = _forum(web: v4Raw('space_blog_web.html'));
      useV4Forum(web);
      final fromWeb = _ok(await const SpaceRepository(currentUid: _current).fetchBlogList(url).run());
      List<Object?> rows(SpaceListPage<SpaceBlog> p) => [
        for (final b in p.items) (b.blogId, b.uid, b.title, b.author, b.summary, b.category, b.replies, b.privacy),
      ];
      expect(fromApi.items, isNotEmpty);
      expect(rows(fromApi), rows(fromWeb));
      expect(fromApi.hiddenNote, fromWeb.hiddenNote);
      expect(_pageOf(fromApi.nextPageUrl), 2);
      expect(_pageOf(fromWeb.nextPageUrl), 2);
    });

    test("a blog not everyone's is labelled as the forum labels it", () {
      final json = v4Json('space_blog_v61.json');
      final rows = (json['blogs'] as List).cast<Map<String, dynamic>>();
      json['blogs'] = [
        for (final (i, friend) in [0, 1, 2, 3, 4].indexed) {...rows.first, 'blogid': 100 + i, 'friend': friend},
      ];
      final words = t.spacePage.forumWords;
      expect(spaceBlogListPageFromApi(json, 'u').items.map((b) => b.privacy), [
        null,
        words.blogFriends,
        words.blogChosen,
        words.blogSelf,
        words.blogPassword,
      ]);
    });

    test("albums: the member's own list ends with the default album, as the web page", () async {
      const url = 'https://www.tsdm39.com/home.php?mod=space&uid=35&do=album&view=me';
      knowV4Status();
      useV4Forum(_forum(api: v4Json('space_album_v62_own.json')));
      final fromApi = _ok(await SpaceRepository(currentUid: () => 35).fetchAlbumList(url).run());
      TsdmAppApi.reset();
      useV4Forum(_forum(web: v4Raw('space_album_own_web.html')));
      final fromWeb = _ok(await SpaceRepository(currentUid: () => 35).fetchAlbumList(url).run());
      List<Object?> rows(SpaceListPage<SpaceAlbum> p) => [
        for (final a in p.items) (a.albumId, a.uid, a.name, _p(a.coverUrl), a.count),
      ];
      expect(fromApi.items.map((a) => a.albumId), [1, -1]);
      expect(rows(fromApi), rows(fromWeb));
    });

    test('wall: the same messages, the message box and the session', () async {
      const url = 'https://www.tsdm39.com/home.php?mod=space&uid=35&do=wall';
      knowV4Status();
      useV4Forum(_forum(api: v4Json('space_wall_v63.json')));
      final fromApi = _ok(await const SpaceRepository(currentUid: _current).fetchWall(url).run());
      TsdmAppApi.reset();
      useV4Forum(_forum(web: v4Raw('space_wall_web.html')));
      final fromWeb = _ok(await const SpaceRepository(currentUid: _current).fetchWall(url).run());
      List<Object?> rows(SpaceListPage<SpaceBlogComment> p) => [
        for (final c in p.items) (c.cid, c.author, c.uid, c.canDelete, c.canReply),
      ];
      expect(fromApi.items, hasLength(20));
      expect(rows(fromApi), rows(fromWeb));
      expect(fromApi.canPost, isTrue);
      expect(fromApi.canPost, fromWeb.canPost);
      expect(fromApi.session?.formHash, fromWeb.session?.formHash);
      expect(_pageOf(fromApi.nextPageUrl), 2);
      expect(_pageOf(fromWeb.nextPageUrl), 2);
    });

    test('greetings: the same members, the greeting and what was said', () async {
      const url = 'https://www.tsdm39.com/home.php?mod=spacecp&ac=poke';
      knowV4Status();
      useV4Forum(_forum(api: v4Json('space_poke_v64.json')));
      final fromApi = _ok(await const SpaceRepository(currentUid: _current).fetchPokes(url).run());
      TsdmAppApi.reset();
      useV4Forum(_forum(web: v4Raw('space_poke_web.html')));
      final fromWeb = _ok(await const SpaceRepository(currentUid: _current).fetchPokes(url).run());
      expect(
        [for (final p in fromApi.items) (p.uid, p.username, _p(p.avatarUrl))],
        [
          for (final p in fromWeb.items) (p.uid, p.username, _p(p.avatarUrl)),
        ],
      );
      expect(
        fromApi.items.single.content.querySelector('img')?.attributes['src'],
        endsWith('/static/image/poke/wx.gif'),
      );
      expect(fromApi.items.single.content.text, contains('SOCIALAPP'));
      expect(fromApi.session?.formHash, fromWeb.session?.formHash);
    });
  });

  group('refusals', () {
    const url = 'https://www.tsdm39.com/home.php?mod=space&uid=58&do=blog&view=me';

    Future<Either<AppException, SpaceListPage<SpaceBlog>>> fetch(V4Forum forum, {int uid = _uid}) {
      useV4Forum(forum);
      return SpaceRepository(currentUid: () => uid).fetchBlogList(url).run();
    }

    test("the owner's privacy: the forum's sentence with the owner's name, no web page asked", () async {
      knowV4Status();
      final forum = _forum(
        api: const {
          'ok': 0,
          'error': 'privacy',
          'owner': {'uid': 58, 'username': 'ag_t22'},
          'api': 1,
          'uid': _uid,
          'formhash': 'f1f2f3f4',
        },
      );
      final page = _ok(await fetch(forum));
      expect(page.items, isEmpty);
      expect(page.message, t.spacePage.forumWords.privacy(name: 'ag_t22'));
      expect(page.needLogin, isFalse);
      expect(_asksV4(forum), isTrue);
    });

    test("the forum's message is its words; the login prompt of a guest is the login", () async {
      knowV4Status();
      final missing = _ok(await fetch(_forum(api: v4Json('space_wall_v63_nouser.json'))));
      expect(missing.message, '抱歉，您指定的用户空间不存在');
      expect(missing.needLogin, isFalse);
      useV4Forum(_forum(api: v4Json('space_poke_v64_guest.json')));
      final guest = _ok(
        await SpaceRepository(
          currentUid: () => 0,
        ).fetchPokes('https://www.tsdm39.com/home.php?mod=spacecp&ac=poke').run(),
      );
      expect(guest.needLogin, isTrue);
      useV4Forum(_forum(api: v4Json('space_poke_v64_guest.json')));
      final expired = await SpaceRepository(
        currentUid: () => _uid,
      ).fetchPokes('https://www.tsdm39.com/home.php?mod=spacecp&ac=poke').run();
      expect(_ok(expired).needLogin, isTrue, reason: 'the session ended: the login prompt served to a guest');
    });

    test("another account's answer is refused", () async {
      knowV4Status();
      final result = await fetch(_forum(api: v4Json('space_blog_v61.json')), uid: 32);
      expect(result.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test('another refusal of the plugin, or an error that tells nothing: the web page', () async {
      knowV4Status();
      for (final api in const [
        {'ok': 0, 'error': 'unknown', 'uid': _uid},
        {'ok': 0, 'error': 'somethingelse', 'uid': _uid},
      ]) {
        final forum = _forum(api: api, web: v4Raw('space_blog_web.html'));
        final page = _ok(await fetch(forum));
        expect(page.items, isNotEmpty);
        expect(_pages(forum).map((q) => q['tsdmv']), ['4', null]);
      }
    });

    test('the plugin is not used without status: nothing asked with tsdmv', () async {
      TsdmAppApi.reset();
      expect(TsdmAppV4.on, isFalse);
      final forum = _forum(web: v4Raw('space_blog_web.html'));
      expect(_ok(await fetch(forum)).items, isNotEmpty);
      expect(_asksWeb(forum), isTrue);
    });
  });
}

int _current() => _uid;
