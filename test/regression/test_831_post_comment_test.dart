/// The comments (点评) of a floor: shown under its content, written, and deleted by a moderator.
///
/// The samples under `test/data/post_comment/` are the test forum's answers (Discuz! X5 with the app plugin; thread
/// `1234567`, floors 11262 of `ag_low` uid 31 and 11263, 11264 of `ag_low2` uid 35; the moderator is `ag_mid` uid 33):
///
/// * `thread_api_member.json`, `thread_api_moderator.json`: the thread page asked in the JSON mode of plugin 3.6.0 by a
///   member and by a moderator (floor 11263 with 7 comments, 5 printed and a next page; the moderator's with the
///   delete link of each); `thread_api_moderator_370.json`: the same page later, from plugin 3.7.0 (`can.comment`,
///   `urls.comment` and the comment fields of a floor);
/// * `thread_member.html`: the web page by the member (`a.cmmnt` on the floors the member may comment on);
/// * `more_api.json`, `more_moderator.xml`: page 2 of the comments of 11263 (`misc&action=commentmore`);
/// * `window*.{json,xml}`: the comment window (`misc&action=comment`), the refused window of the first floor;
///   `comment_*`: the forum's answers to the comment form (taken, too soon after the last post);
/// * `delete_*`: the moderators' window deleting a comment (`topicadmin&action=delcomment`), refused to a member, and
///   the answers to its form.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/post_comment/repository/post_comment_repository.dart';
import 'package:tsdm_client/features/post_comment/widgets/post_comment_widgets.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
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
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/post_comment';

String _read(String name) => File('$_dir/$name').readAsStringSync();

/// A JSON answer as dio gives it: decoded.
Map<String, dynamic> _json(String name) => jsonDecode(_read(name)) as Map<String, dynamic>;

Map<String, Post> _apiFloors(String name) => {
  for (final p in threadPageFromApi(_json(name), 1).postList) p.postID: p,
};

/// The floors of the web page, as the thread page reads each `div#post_PID`.
Map<String, Post> _webFloors() {
  final floors = <String, Post>{};
  for (final e in parseHtmlDocument(_read('thread_member.html')).querySelectorAll('div[id^="post_"]')) {
    final post = RegExp(r'^post_\d+$').hasMatch(e.id) ? Post.fromPostNode(e, 1) : null;
    if (post != null) {
      floors[post.postID] = post;
    }
  }
  return floors;
}

const _window = '$baseUrl/forum.php?mod=misc&action=comment&tid=1234567&pid=11263&extra=&page=1';

/// The transports of a [PostCommentRepository]: the answers by a part of the url, every request kept.
final class _Forum {
  _Forum({this.reads = const {}, this.answer});

  /// The answer of a read whose url contains the key.
  final Map<String, Object?> reads;

  /// The answer of every form sent; throws when null.
  final Object? answer;

  final readUrls = <String>[];
  final sent = <(String, Map<String, String>)>[];

  PostCommentRepository get repository => PostCommentRepository(
    get: (url) async {
      readUrls.add(url);
      for (final MapEntry(:key, :value) in reads.entries) {
        if (url.contains(key)) {
          return value;
        }
      }
      throw Exception('offline');
    },
    post: (url, fields) async {
      sent.add((url, fields));
      if (answer == null) {
        throw Exception('connection reset');
      }
      return answer;
    },
  );
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.uid);

  int? uid;

  @override
  int? get effectiveCurrentUid => uid;
}

/// No network: the card's images do not load.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The card shows nothing that needs these.
Post _bare(Post post) => post.copyWith(
  author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
  userBriefProfile: null,
  postMedals: null,
  badge: null,
  secondBadge: null,
  signature: null,
  pokemon: null,
  checkin: null,
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. reading the comments', () {
    test("plugin 3.6.0: cut out of the floor's content, newest first, each with its author, time and text", () {
      final floors = _apiFloors('thread_api_member.json');
      final floor = floors['11263']!;
      expect(floor.comments.map((e) => e.authorName), ['ag_mid', 'ag_t05', 'ag_t04', 'ag_t03', 'ag_t02']);
      expect(floor.comments.map((e) => e.authorUid), [33, 41, 40, 39, 38]);
      final first = floor.comments.first;
      expect(first.content, 'CM測試 ag_mid 點評 & <tag> "q"');
      // The full time the page keeps for a relative one ("6 秒前").
      expect(first.time, '2026-11-10 10:34');
      expect(first.avatarUrl, '$baseUrl/data/avatar/noavatar.svg');
      // A member is not offered to delete any.
      expect(floor.comments.every((e) => !e.canDelete && e.id == null), isTrue);
      expect(floor.moreComments, isTrue, reason: '7 comments, the forum prints 5');
      // The block is gone from the content, the content is not.
      expect(floor.data, isNot(contains('id="comment_11263"')));
      expect(floor.data, isNot(contains('ag_t05')));
      expect(floor.data, contains('postmessage_11263'));
      expect(floor.data, contains('post_rate_div_11263'));
      // A floor without comments: its empty block goes as well, nothing to show.
      expect(floors['11262']!.comments, isEmpty);
      expect(floors['11262']!.moreComments, isFalse);
      expect(floors['11262']!.data, isNot(contains('id="comment_11262"')));
    });

    test("a moderator's page: each comment's id, which the forum offers to delete", () {
      final floor = _apiFloors('thread_api_moderator.json')['11263']!;
      expect(floor.comments.map((e) => e.id), [18, 17, 16, 15, 14]);
      expect(floor.comments.every((e) => e.canDelete), isTrue);
      // The IP and the delete link the moderator's time line carries are not the time.
      expect(floor.comments.first.time, '2026-11-10 10:34');
      expect(floor.comments.first.content, 'CM測試 ag_mid 點評 & <tag> "q"');
    });

    test('the web page gives the same', () {
      final web = _webFloors();
      final api = _apiFloors('thread_api_moderator_370.json');
      for (final pid in ['11262', '11263', '11264']) {
        expect(
          web[pid]!.comments.map((e) => (e.authorName, e.authorUid, e.time, e.content)),
          api[pid]!.comments.map((e) => (e.authorName, e.authorUid, e.time, e.content)),
          reason: pid,
        );
        expect(web[pid]!.moreComments, api[pid]!.moreComments, reason: pid);
        expect(web[pid]!.data, isNot(contains('id="comment_$pid"')), reason: pid);
      }
      final floor = web['11263']!;
      expect(floor.comments.map((e) => e.authorName), ['ag_t08', 'ag_t07', 'ag_t06', 'ag_t04', 'ag_t03']);
      // A line break the author typed is kept.
      expect(floor.comments.first.content, 'CM測試 ag_t08 第一行\n第二行');
      expect(floor.moreComments, isTrue);
      expect(web['11264']!.comments.single.content, 'CM測試 舊路徑點評');
    });

    test("plugin 3.7.0's comment fields hold the same: the model is what they will feed", () {
      final json = _json('thread_api_moderator_370.json');
      final api = _apiFloors('thread_api_moderator_370.json');
      for (final p in (json['posts'] as List).cast<Map<String, dynamic>>()) {
        final parsed = api['${p['pid']}']!;
        final fields = (p['comments'] as List).cast<Map<String, dynamic>>();
        expect(
          parsed.comments.map((e) => (e.id, e.authorUid, e.authorName, e.content, e.canDelete)),
          fields.map(
            (c) => (c['id'], c['authorid'], c['author'], c['comment'], c['can_delete'] == 1),
          ),
          reason: '${p['pid']}',
        );
        expect(parsed.moreComments, p['comment_more'] == 1, reason: '${p['pid']}');
      }
    });

    test('the more pages: page 2 of the comments, with or without the plugin', () async {
      final page = parsePostCommentMore(_json('more_api.json')['document'] as String, page: 2);
      expect(page.comments.map((e) => e.authorName), ['ag_t02', 'ag_t01', 'ag_low']);
      expect(page.hasMore, isFalse);
      // The avatar is not in a link on these pages.
      expect(page.comments.last.avatarUrl, 'https://example.com/img/avatar.gif');
      expect(page.comments.first.time, '2026-11-10 10:34');

      final forum = _Forum(reads: {'commentmore': _read('more_moderator.xml')});
      final more = await forum.repository.fetchMore(tid: '1234567', pid: '11263', page: 2);
      expect(forum.readUrls.single, contains('action=commentmore&tid=1234567&pid=11263&page=2&inajax=1'));
      expect(more!.comments.map((e) => e.id), [14, 13, 12]);
      expect(more.comments.every((e) => e.canDelete), isTrue);
      expect(await _Forum().repository.fetchMore(tid: '1234567', pid: '11263', page: 2), isNull);
    });

    test("a comment made by a reply, a guest's, the item scores' row", () {
      final html = [
        '<div class="pstl"><div class="psta"><a href="home.php?mod=space&amp;uid=5" class="xi2 xw1">甲</a></div>',
        '<div class="psti">好 <a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=9&amp;ptid=1" class="xi2">详情',
        '</a> <a href="forum.php?mod=post&amp;action=reply&amp;fid=2&amp;tid=1&amp;repquote=9" class="xi2">回复</a>',
        '<span class="xg1">发表于 2026-1-1 10:00</span></div></div>',
        '<div class="pstl"><div class="psta vm"><a c="1"><img src="./data/avatar/noavatar.svg"></a>游客</div>',
        '<div class="psti">路过 <b>粗</b><br />下一行<span class="xg1">发表于 2026-1-2 10:00</span></div></div>',
        '<div class="pstl">外观: <i>4.5</i></div>',
      ].join();
      final page = parsePostCommentMore(html, page: 1);
      expect(page.comments.map((e) => (e.authorName, e.authorUid, e.content, e.time)), [
        ('甲', 5, '好', '2026-1-1 10:00'),
        ('游客', null, '路过 粗\n下一行', '2026-1-2 10:00'),
      ]);
    });

    test('a block whose end cannot be found is left in the content', () {
      const data = '<div class="pcbs">x</div><div id="comment_1" class="cm"><div class="pstl">';
      final split = splitPostComments(data, '1');
      expect(split.data, data);
      expect(split.comments, isNull);
      expect(splitPostComments('<div class="pcbs">x</div>', '1').data, '<div class="pcbs">x</div>');
    });
  });

  group('2. where the account may comment', () {
    test('the web page: the floors the forum prints the comment link on', () {
      final web = _webFloors();
      expect(web['11262']!.commentAction, isNull, reason: "the member's own first floor");
      expect(web['11263']!.commentAction, _window);
      expect(web['11264']!.commentAction, contains('pid=11264'));
    });

    test('plugin 3.6.0: a floor the account may reply to and did not write, past the first', () {
      final member = _apiFloors('thread_api_member.json');
      expect(member['11262']!.commentAction, isNull, reason: 'the first floor, and the member wrote it');
      expect(member['11263']!.commentAction, _window);
      final moderator = _apiFloors('thread_api_moderator.json');
      expect(moderator['11262']!.commentAction, isNull, reason: 'the first floor');
      expect(moderator['11264']!.commentAction, contains('pid=11264'));
      // A guest, a floor the account may not reply to.
      final json = _json('thread_api_member.json');
      ((json['posts'] as List)[1] as Map<String, dynamic>)['can'] = {'reply': 0};
      expect(threadPageFromApi(json, 1).postList[1].commentAction, isNull);
    });

    test("plugin 3.7.0: the answer's own can.comment and urls.comment", () {
      final floors = _apiFloors('thread_api_moderator_370.json');
      expect(floors['11262']!.commentAction, isNull, reason: 'can.comment 0');
      expect(floors['11263']!.commentAction, _window);
      final json = _json('thread_api_moderator_370.json');
      (((json['posts'] as List)[1] as Map<String, dynamic>)['can'] as Map<String, dynamic>)['comment'] = 0;
      expect(threadPageFromApi(json, 1).postList[1].commentAction, isNull);
    });
  });

  group('3. the forms', () {
    test("the comment window: its form and the forum's limit, with or without the plugin", () async {
      final forum = _Forum(reads: {'action=comment': _json('window_api.json')});
      final window = await forum.repository.openComment(_window);
      final url = Uri.parse(forum.readUrls.single);
      expect(url.queryParameters, containsPair('infloat', 'yes'));
      expect(url.queryParameters, containsPair('handlekey', 'comment'));
      expect(url.queryParameters, containsPair('inajax', '1'));
      expect(url.queryParameters, containsPair('pid', '11263'));
      final form = (window as PostCommentWindowForm).form;
      expect(form.action, startsWith('$baseUrl/forum.php?mod=post&action=reply&comment=yes&tid=1234567&pid=11263'));
      expect(form.action, contains('commentsubmit=yes'));
      expect(form.action, endsWith('&inajax=1'));
      expect(form.fields, {'formhash': 'f1f2f3f4', 'handlekey': 'comment', 'commentsubmit': 'true'});
      expect(form.uid, 31);
      expect(form.maxLength, 200);

      final old = await _Forum(reads: {'action=comment': _read('window.xml')}).repository.openComment(_window);
      final oldForm = (old as PostCommentWindowForm).form;
      expect(oldForm.fields, form.fields);
      expect(oldForm.uid, isNull);
    });

    test("a refused window: the forum's words", () async {
      for (final answer in [_json('window_refused_api.json'), _read('window_refused.xml')]) {
        final window = await _Forum(reads: {'action=comment': answer}).repository.openComment(_window);
        expect((window as PostCommentWindowRefused).message, '抱歉，您不能点评此帖或帖子尚未找到');
      }
      expect(await _Forum().repository.openComment(_window), isA<PostCommentWindowFailed>());
    });

    test("the comment is sent once; the forum's verdict", () async {
      final form =
          ((await _Forum(
                    reads: {'action=comment': _json('window_api.json')},
                  ).repository.openComment(_window))
                  as PostCommentWindowForm)
              .form;
      for (final (answer, expected) in [
        (_json('comment_ok_api.json'), const PostCommentDone('帖子点评成功')),
        (_read('comment_ok.xml'), const PostCommentDone('帖子点评成功')),
        (_json('comment_flood_api.json'), const PostCommentRefused('抱歉，您两次发表间隔少于 15 秒，请稍候再发表')),
        (_read('comment_flood.xml'), const PostCommentRefused('抱歉，您两次发表间隔少于 15 秒，请稍候再发表')),
      ]) {
        final forum = _Forum(answer: answer);
        final outcome = await forum.repository.sendComment(form, '好帖');
        expect(outcome.runtimeType, expected.runtimeType);
        expect(
          switch (outcome) {
            PostCommentDone(:final message) || PostCommentRefused(:final message) => message,
            PostCommentUnknown() => null,
          },
          switch (expected) {
            PostCommentDone(:final message) || PostCommentRefused(:final message) => message,
            PostCommentUnknown() => null,
          },
        );
        expect(forum.sent.single.$1, form.action);
        expect(forum.sent.single.$2, {...form.fields, 'message': '好帖'});
      }
      final failing = _Forum();
      expect(await failing.repository.sendComment(form, '好帖'), isA<PostCommentUnknown>());
      expect(failing.sent, hasLength(1), reason: 'never sent again');
    });

    test('a success with words not known, a page: no verdict (the page is read again, nothing sent twice)', () {
      final ok = _json('comment_ok_api.json')
        ..['message_key'] = 'post_reply_mod_succeed'
        ..['alert'] = 'info';
      expect(postCommentOutcomeOf(ok, doneKeys: const {'comment_add_succeed'}), isA<PostCommentUnknown>());
      expect(
        postCommentOutcomeOf(_json('window_api.json'), doneKeys: const {'comment_add_succeed'}),
        isA<PostCommentUnknown>(),
      );
      // The forum's escapes in its handler's words.
      final escaped = postCommentOutcomeOf(
        r"<root><![CDATA[<script>errorhandle_comment('第一行\n\'引号\'', {});</script>]]></root>",
        doneKeys: const {},
      );
      expect((escaped as PostCommentRefused).message, "第一行\n'引号'");
    });

    test("the moderators' delete: its window, its form with the reason, the forum's verdict", () async {
      final forum = _Forum(reads: {'action=delcomment': _json('delete_window_api.json')});
      final window = await forum.repository.openDelete(tid: '1234567', commentId: 16);
      expect(forum.readUrls.single, contains('mod=topicadmin&action=delcomment&tid=1234567'));
      expect(forum.readUrls.single, contains('topiclist[]=16'));
      final form = (window as PostCommentWindowForm).form;
      expect(form.action, contains('action=delcomment&modsubmit=yes'));
      expect(form.fields, {
        'formhash': 'f1f2f3f4',
        'fid': '25',
        'tid': '1234567',
        'handlekey': 'mods',
        'topiclist': '16',
        'modsubmit': 'ture',
      });
      final refused = await _Forum(
        reads: {'action=delcomment': _json('delete_window_refused_api.json')},
      ).repository.openDelete(tid: '1234567', commentId: 16);
      expect((refused as PostCommentWindowRefused).message, '抱歉，您没有权限使用管理功能');

      for (final answer in [_json('delete_ok_api.json'), _read('delete_ok.xml')]) {
        final sender = _Forum(answer: answer);
        expect(await sender.repository.sendDelete(form, '重复'), isA<PostCommentDone>());
        expect(sender.sent.single.$2, {...form.fields, 'reason': '重复'});
      }
      final gone = await _Forum(answer: _json('delete_not_found_api.json')).repository.sendDelete(form, '');
      expect((gone as PostCommentRefused).message, '帖子点评未找到');
    });
  });

  group('4. on screen', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.en);
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

    Future<void> pump(WidgetTester tester, Widget child, {_Forum? forum, int? uid = 31}) async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PostCommentRepository>.value(value: (forum ?? _Forum()).repository),
            RepositoryProvider<AuthenticationRepository>.value(value: _Auth(uid)),
          ],
          child: BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                scaffoldMessengerKey: snackbarKey,
                home: Scaffold(body: SingleChildScrollView(child: child)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
      await tester.pumpAndSettle();
    }

    testWidgets("the floor's comments under its content, and its menu's comment where the forum offers it", (
      tester,
    ) async {
      final floors = _apiFloors('thread_api_member.json');
      await pump(tester, PostCard(_bare(floors['11263']!)));
      expect(find.text(t.postComment.title), findsOneWidget);
      expect(find.text('CM測試 ag_t05 點評 & <tag> "q"'), findsOneWidget);
      // Not munched with the content as well.
      expect(find.textContaining('ag_t05  2026', findRichText: true), findsOneWidget);
      // Outside a thread page: no more pages, no delete.
      expect(find.byKey(const ValueKey('post-comment-more')), findsNothing);
      await openMenu(tester);
      expect(find.text(t.postComment.menu), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, PostCard(_bare(floors['11262']!)));
      expect(find.text(t.postComment.title), findsNothing, reason: 'no comments, no room taken');
      await openMenu(tester);
      expect(find.text(t.postComment.menu), findsNothing);
    });

    testWidgets("comment: the window first, sent once, the forum's words; the page reloaded when taken", (
      tester,
    ) async {
      var reloads = 0;
      final forum = _Forum(
        reads: {'action=comment': _json('window_api.json')},
        answer: _json('comment_flood_api.json'),
      );
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => showPostCommentDialog(context, _window, onDone: () => reloads++),
            child: const Text('open'),
          ),
        ),
        forum: forum,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final send = find.byKey(const ValueKey('post-comment-send'));
      expect(tester.widget<TextButton>(send).onPressed, isNull, reason: 'nothing typed');
      await tester.enterText(find.byKey(const ValueKey('post-comment-input')), '好帖');
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      // Refused: the forum's words, the dialog and the text kept.
      expect(find.text('抱歉，您两次发表间隔少于 15 秒，请稍候再发表'), findsOneWidget);
      expect(find.text('好帖'), findsOneWidget);
      expect(forum.sent, hasLength(1));
      expect(reloads, 0);
    });

    testWidgets('comment taken: the dialog closes, the page is reloaded', (tester) async {
      var reloads = 0;
      final forum = _Forum(reads: {'action=comment': _json('window_api.json')}, answer: _json('comment_ok_api.json'));
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => showPostCommentDialog(context, _window, onDone: () => reloads++),
            child: const Text('open'),
          ),
        ),
        forum: forum,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('post-comment-input')), '好帖');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('post-comment-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('post-comment-input')), findsNothing);
      expect(find.text('帖子点评成功'), findsOneWidget);
      expect(forum.sent.single.$2['message'], '好帖');
      expect(reloads, 1);
    });

    testWidgets('the floor built again while the dialog is up (a reload re-keys it): the page is still reloaded', (
      tester,
    ) async {
      var reloads = 0;
      final generation = ValueNotifier(0);
      addTearDown(generation.dispose);
      final forum = _Forum(reads: {'action=comment': _json('window_api.json')}, answer: _json('comment_ok_api.json'));
      await pump(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: generation,
          builder: (_, value, _) => Builder(
            key: ValueKey(value),
            builder: (context) => TextButton(
              onPressed: () async => showPostCommentDialog(context, _window, onDone: () => reloads++),
              child: const Text('open'),
            ),
          ),
        ),
        forum: forum,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      generation.value++;
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('post-comment-input')), '好帖');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('post-comment-send')));
      await tester.pumpAndSettle();
      expect(reloads, 1);
      expect(find.text('帖子点评成功'), findsOneWidget);
    });

    testWidgets('a refused window, another account: nothing is sent', (tester) async {
      for (final (reads, uid, words) in [
        ({'action=comment': _json('window_refused_api.json')}, 31, '抱歉，您不能点评此帖或帖子尚未找到'),
        // The window was served to uid 31, the account in use is another.
        ({'action=comment': _json('window_api.json')}, 35, t.postComment.accountChanged),
      ]) {
        final forum = _Forum(reads: reads, answer: _json('comment_ok_api.json'));
        await pump(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => showPostCommentDialog(context, _window),
              child: const Text('open'),
            ),
          ),
          forum: forum,
          uid: uid,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('post-comment-input')), findsNothing);
        expect(find.text(words), findsOneWidget);
        expect(forum.sent, isEmpty);
        snackbarKey.currentState?.clearSnackBars();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the more pages on demand; the delete a moderator is offered, asked first', (tester) async {
      var reloads = 0;
      final floor = _apiFloors('thread_api_moderator.json')['11263']!;
      final forum = _Forum(
        reads: {
          'commentmore': _read('more_moderator.xml'),
          'action=delcomment': _json('delete_window_api.json'),
        },
        answer: _json('delete_ok_api.json'),
      );
      await pump(
        tester,
        PostCommentSection(floor, tid: '1234567', onReload: () => reloads++),
        forum: forum,
        uid: 33,
      );
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(5));
      expect(forum.readUrls, isEmpty, reason: 'nothing asked before the reader asks');
      await tester.tap(find.byKey(const ValueKey('post-comment-more')));
      await tester.pumpAndSettle();
      expect(find.textContaining('ag_t01  2026', findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('post-comment-more')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('post-comment-delete-16')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('post-comment-delete-reason')), '重复');
      await tester.tap(find.byKey(const ValueKey('post-comment-delete-confirm')));
      await tester.pumpAndSettle();
      expect(forum.sent.single.$2, containsPair('topiclist', '16'));
      expect(forum.sent.single.$2, containsPair('reason', '重复'));
      expect(find.text('管理操作成功'), findsOneWidget);
      expect(reloads, 1);
    });

    test("the forum's count: an ASCII character 1, any other 2, as its cutstr", () {
      expect(postCommentLength('ab &<>"\n'), 8);
      expect(postCommentLength('字字'), 4);
      expect(postCommentLength('\u{1F600}'), 2);
      expect(postCommentLength('a\rb'), 2);
      expect(postCommentFit('ab字字', 5), 'ab字');
      // Measured on the test forum: "CM測試長度" and 150 "字" were kept as "CM測試長度" and 95 "字".
      expect(postCommentFit('CM測試長度${'字' * 150}', 200), 'CM測試長度${'字' * 95}');
    });

    test('cut to fit: only what the edit put in, whole characters; what was typed stays', () {
      TextEditingValue at(String text, int caret) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      );
      final typed = 'a' * 190;
      // Pasted at the start: the typed text is all kept, the paste cut to the room left.
      final pasted = postCommentLimitEdit(at(typed, 0), at('${'b' * 20}$typed', 20), 200);
      expect(pasted.text, '${'b' * 10}$typed');
      expect(pasted.selection.baseOffset, 10);
      // In the middle.
      final middle = postCommentLimitEdit(at(typed, 95), at('${'a' * 95}字字字字字字${'a' * 95}', 101), 200);
      expect(middle.text, '${'a' * 95}字字字字字${'a' * 95}');
      expect(middle.selection.baseOffset, 100);
      // A family emoji is not cut in half: it does not fit whole, it is left out.
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      expect(postCommentLimitEdit(at('a' * 196, 196), at('${'a' * 196}$family', 204), 200).text, 'a' * 196);
      // Being composed: let through.
      final composing = TextEditingValue(
        text: '字' * 101,
        selection: const TextSelection.collapsed(offset: 101),
        composing: const TextRange(start: 100, end: 101),
      );
      expect(postCommentLimitEdit(at('字' * 100, 100), composing, 200), composing);
    });

    testWidgets('the limit counts as the forum does; pasted text is cut to fit', (tester) async {
      final forum = _Forum(reads: {'action=comment': _json('window_api.json')});
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => showPostCommentDialog(context, _window),
            child: const Text('open'),
          ),
        ),
        forum: forum,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('post-comment-input'));
      await tester.enterText(input, '字' * 101);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '字' * 100);
      expect(find.text('200/200'), findsOneWidget);
      await tester.enterText(input, '');
      await tester.pump();
      await tester.enterText(input, '${'a' * 199}字');
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, 'a' * 199);
      expect(find.text('199/200'), findsOneWidget);
    });

    testWidgets('a delete window that cannot be read: nothing sent, no reload', (tester) async {
      var reloads = 0;
      final floor = _apiFloors('thread_api_moderator.json')['11263']!;
      final forum = _Forum(answer: _json('delete_ok_api.json'));
      await pump(
        tester,
        PostCommentSection(floor, tid: '1234567', onReload: () => reloads++),
        forum: forum,
        uid: 33,
      );
      await tester.tap(find.byKey(const ValueKey('post-comment-delete-16')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('post-comment-delete-confirm')));
      await tester.pumpAndSettle();
      expect(forum.sent, isEmpty);
      expect(reloads, 0);
      expect(find.text(t.postComment.loadFailed), findsOneWidget);
    });

    testWidgets("a member's more page: a comment shown already is not added again", (tester) async {
      final json = _json('thread_api_member.json');
      final floor = threadPageFromApi(json, 1).postList.firstWhere((e) => e.postID == '11263');
      // Page 2 after two more comments: it starts with the two last of page 1 (rows without ids for a member).
      final body = ((json['posts'] as List)[1] as Map<String, dynamic>)['body_html'] as String;
      final rows = RegExp(
        r'<div class="pstl xs1 cl">[\s\S]*?</span></span>\s*</div>\s*</div>',
      ).allMatches(body).toList();
      expect(rows, hasLength(5));
      final shifted = '${rows[3][0]}${rows[4][0]}${_json('more_api.json')['document']}';
      final forum = _Forum(reads: {'commentmore': shifted});
      await pump(tester, PostCommentSection(floor, tid: '1234567'), forum: forum);
      await tester.tap(find.byKey(const ValueKey('post-comment-more')));
      await tester.pumpAndSettle();
      for (final name in ['ag_t03', 'ag_t02', 'ag_t01', 'ag_low']) {
        expect(find.textContaining('$name  2026', findRichText: true), findsOneWidget, reason: name);
      }
    });

    testWidgets('without a reload (the post of a notice, an offline copy): no delete', (tester) async {
      final floor = _apiFloors('thread_api_moderator.json')['11263']!;
      await pump(tester, PostCommentSection(floor, tid: '1234567'));
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });
  });
}
