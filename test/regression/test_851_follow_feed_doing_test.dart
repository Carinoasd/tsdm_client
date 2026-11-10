/// Following members, the broadcasts and the records (记录), as measured on the test site (Discuz! X5, plugin 3.8.0;
/// the forum's app API leaves these pages alone and answers the web page, the posts as the popup's handler):
///
/// * following a member is the website's link `home.php?mod=spacecp&ac=follow&op=add&hash=FORMHASH&fuid=N`; the forum
///   takes the same fields posted (`follow_add_succeed` "成功关注"), refuses the account itself
///   (`follow_not_follow_self`), a member already followed (`follow_followed_ta`), and answers a stale hash a bare
///   "Access Denied"; `op=del&fuid=N` is `follow_cancel_succeed` whether or not the member was followed; `op=bkname`
///   with `editbkname` notes a name (`follow_remark_succeed`), cut to 30 (`cutstr`), echoed in `values.bkname`;
/// * the lists are `home.php?mod=follow&do=following|follower[&uid=N][&page=P]`, twenty a page; the account's own
///   lists carry the follow links and the remark; the head of another member's pages tells what the viewer is to them
///   (`div#followflag` or `div#unfollowflag`, the other one `display: none`; 互相关注, "TA已关注您");
/// * the lists belong to `followerstatus` ("抱歉，关注功能尚未开启"), the broadcasts to `followstatus` ("抱歉，广播功能
///   尚未开启"): two switches;
/// * the broadcasts are `home.php?mod=follow[&view=follow|other]` and `&uid=N&do=view`; more of them are loaded as the
///   website does, `home.php?mod=spacecp&ac=follow&op=getfeed&archiver=A&page=P&inajax=1` with `viewtype` or `uid`: a
///   fragment of `<li>`, the word `false` once there are no more; the filed ones (`archiver=1`) follow the recent ones;
/// * a relay is `op=relay&tid=T` with `relaysubmit`, a note of at most 140 bytes (`follow_input_word_limit`) and
///   `addnewreply` to post it as a reply too, which the second relay of a thread needs
///   (`follow_only_allow_the_relay_time`); a broadcast is deleted with `op=delete&feedid=F` and `deletesubmit`;
/// * the records are `home.php?mod=space&do=doing&view=all|follow|we|me[&uid=N][&page=P]`, twenty a page; a record is
///   posted to `home.php?mod=spacecp&ac=doing` with `addsubmit`, answered by going back (a `redirect` result, `ok` 1;
///   a 301 without the app API), cut to 200 (a Chinese character counting two), refused empty (`should_write_that`)
///   or within 15 seconds of another post (`operating_too_fast`);
/// * the replies of a record are the fragment `op=getcomment&doid=N&inajax=1&page_c=P`: ten top replies a page, each
///   with its own (`dtll`); a reply is posted to `op=comment&doid=N&docid=C` with `commentsubmit` (`do_success`); a
///   delete (`op=delete&doid=N[&docid=C]`, `deletesubmit`) is answered by going back whether or not the forum took it;
/// * a new follower is a notice of type `follower` without an author ("NAME 关注了您。点击查看"), a reply to a record
///   one of type `comment` linking `home.php?mod=space&uid=N&do=doing&view=me&doid=M&highlight=C`.
///
/// The fixtures (`test/data/space_social/`) are the test site's pages, cut to their content, the accounts and the site
/// renamed, the form hash and the time replaced.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/doing/models/doing_models.dart';
import 'package:tsdm_client/features/doing/repository/doing_repository.dart';
import 'package:tsdm_client/features/doing/utils/parse_doing.dart';
import 'package:tsdm_client/features/doing/widgets/doing_widgets.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/follow/repository/follow_repository.dart';
import 'package:tsdm_client/features/follow/utils/parse_follow.dart';
import 'package:tsdm_client/features/follow/widgets/follow_widgets.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/space_social';

/// The fixtures of this test: the follow lists, the broadcasts, the records, their results and notices.
final _fixtures = RegExp(
  '^(follow_|feed_|doing_|notices_follow|result_(follow|bkname|relay|feed|doing|docomment)|ajax_(follow|docomment))',
);

String _text(String name) => File('$_dir/$name').readAsStringSync();

uh.Document _doc(String name) => parseHtmlDocument(_text('$name.html'));

Object? _json(String name) => jsonDecode(_text('$name.json'));

const _session = SpaceSession(uid: 31, formHash: 'f1f2f3f4');

Response<dynamic> _answer(Object? data, String url, {int status = 200}) => Response<dynamic>(
  requestOptions: RequestOptions(path: url),
  statusCode: status,
  data: data,
);

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A transport recording what goes out.
final class _Transport {
  _Transport({this.uid = 31});

  int? uid;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  Object? Function(String url) page = (_) => null;
  Object? Function(String url, Map<String, String> body) postAnswer = (_, _) => null;
  int postStatus = 200;
  bool failPost = false;

  Future<SyncEither<Response<dynamic>>> get(String url) async {
    gets.add(url);
    return right(_answer(page(url), url));
  }

  Future<SyncEither<Response<dynamic>>> post(String url, Map<String, String> body) async {
    posts.add((url, body));
    if (failPost) return left(HttpRequestFailedException(null));
    return right(_answer(postAnswer(url, body), url, status: postStatus));
  }

  FollowWriteRepository follow() =>
      FollowWriteRepository.withTransport(currentUid: () => uid, getPage: get, sendForm: post);

  DoingWriteRepository doing() =>
      DoingWriteRepository.withTransport(currentUid: () => uid, getPage: get, sendForm: post);
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the follow lists', () {
    test('the members followed: the remark, the numbers, the follow link, the next page', () {
      final page = parseFollowListPage(_doc('follow_following'));
      expect(page.items.map((e) => e.uid), [35, 58, 53]);
      expect(page.session?.uid, 31);
      expect(page.session?.formHash, 'f1f2f3f4');
      expect(page.nextPageUrl, '$baseUrl/home.php?mod=follow&do=following&page=2');
      expect(page.items.every((e) => (e.following ?? false) && e.canRemark), isTrue);
      final friend = page.items.firstWhere((e) => e.uid == 35);
      expect(friend.username, '测试会员乙');
      expect(friend.remark, '老朋友');
      expect(friend.avatarUrl, '$baseUrl/data/avatar/000/00/00/35_avatar_small.jpg');
      expect((friend.followerCount, friend.followingCount), (1, 1));
      expect(friend.recentNote, isNotNull);
      expect(friend.recentNote, isNot(contains('最近动作')));
      expect(page.items.firstWhere((e) => e.uid == 53).remark, isNull);

      final last = parseFollowListPage(_doc('follow_following_p2'));
      expect(last.items, hasLength(2));
      expect(last.nextPageUrl, isNull);
    });

    test('the followers: one followed back is mutual, no remark', () {
      final page = parseFollowListPage(_doc('follow_follower'));
      expect(page.items.map((e) => e.uid), contains(35));
      final back = page.items.firstWhere((e) => e.uid == 35);
      expect(back.mutual, isTrue);
      expect(back.following, isTrue);
      expect(back.canRemark, isFalse);
      // A follower not followed back is offered to be followed.
      final fan = page.items.where((e) => e.uid != 35).firstOrNull;
      if (fan != null) {
        expect(fan.following, isFalse);
        expect(fan.mutual, isFalse);
      }
    });

    test("another member's list: no follow link on the rows, the relation in its head", () {
      final page = parseFollowListPage(_doc('follow_relation_mutual'));
      expect(page.items.single.uid, 31);
      expect(page.items.single.following, isNull);
      expect(page.items.single.canRemark, isFalse);

      final mutual = parseFollowRelation(_doc('follow_relation_mutual'), 35)!;
      expect((mutual.following, mutual.followsViewer), (true, true));
      expect(mutual.username, '测试会员乙');
      expect(mutual.remark, '老朋友');
      expect(mutual.session.uid, 31);
      expect(mutual.followingCount, 1);
      expect(mutual.followerCount, greaterThanOrEqualTo(1));
      expect(mutual.feedCount, greaterThan(0));

      final none = parseFollowRelation(_doc('follow_relation_none'), 59)!;
      expect((none.following, none.followsViewer, none.remark), (false, false, null));
      final fan = parseFollowRelation(_doc('follow_relation_fan'), 61)!;
      expect((fan.following, fan.followsViewer), (false, true));

      // The account's own pages have no relation, nor has a guest's.
      expect(parseFollowRelation(_doc('follow_following'), 31), isNull);
      expect(parseFollowRelation(_doc('follow_guest'), 35), isNull);
    });

    test("switched off, a guest, a member that does not exist: the forum's words", () {
      final off = parseFollowListPage(_doc('follow_off'));
      expect(off.message, '抱歉，关注功能尚未开启');
      expect(spaceModuleSwitchedOff(off.message), isTrue);
      expect(off.needLogin, isFalse);
      final guest = parseFollowListPage(_doc('follow_guest'));
      expect(guest.needLogin, isTrue);
      final missing = parseFollowListPage(_doc('follow_missing'));
      expect(missing.message, '抱歉，您所访问的用户不存在');
      expect(spaceModuleSwitchedOff(missing.message), isFalse);
    });

    test('the relation is loaded for the account it was served to only', () async {
      final transport = _Transport()..page = (_) => _text('follow_relation_fan.html');
      final load = await transport.follow().loadRelation(61);
      expect(load.kind, SpaceFormLoadKind.ready);
      expect(load.form?.followsViewer, isTrue);
      expect(transport.gets.single, '$baseUrl/home.php?mod=follow&do=following&uid=61&tsdmapp=json&nodoc=1');

      final other = _Transport(uid: 35)..page = (_) => _text('follow_relation_fan.html');
      expect((await other.follow().loadRelation(61)).kind, SpaceFormLoadKind.identityChanged);

      final off = _Transport()..page = (_) => _text('follow_off.html');
      final denied = await off.follow().loadRelation(61);
      expect(denied.kind, SpaceFormLoadKind.denied);
      expect(denied.message, '抱歉，关注功能尚未开启');

      final guest = _Transport()..page = (_) => _text('follow_guest.html');
      expect((await guest.follow().loadRelation(61)).kind, SpaceFormLoadKind.loginRequired);
    });
  });

  group('follow writes', () {
    test('follow and unfollow, each posted once with the form hash of the page', () async {
      final transport = _Transport()..postAnswer = (_, _) => _json('result_follow_added');
      final followed = await transport.follow().follow(_session, 35);
      expect(followed.outcome, SpaceWriteOutcome.done);
      expect(followed.message, '成功关注');
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=follow&op=add&fuid=35&inajax=1');
      expect(transport.posts.single.$2, {'hash': 'f1f2f3f4', 'handlekey': 'followmod'});

      transport
        ..posts.clear()
        ..postAnswer = (_, _) => _json('result_follow_cancelled');
      final cancelled = await transport.follow().unfollow(_session, 35);
      expect(cancelled.outcome, SpaceWriteOutcome.done);
      expect(cancelled.message, '取消成功');
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=follow&op=del&fuid=35&inajax=1');
      expect(transport.posts.single.$2['formhash'], 'f1f2f3f4');
    });

    test("refusals are the forum's words; a stale hash is refused, not unknown", () async {
      for (final (fixture, message) in [
        ('result_follow_already', '您已经关注了TA'),
        ('result_follow_self', '不能关注自己'),
        ('result_follow_missing', '抱歉，您指定的用户空间不存在'),
      ]) {
        final transport = _Transport()..postAnswer = (_, _) => _json(fixture);
        final result = await transport.follow().follow(_session, 35);
        expect(result.outcome, SpaceWriteOutcome.rejected, reason: fixture);
        expect(result.message, message);
        expect(transport.posts, hasLength(1));
      }
      final stale = _Transport()..postAnswer = (_, _) => _json('result_follow_bad_hash');
      final result = await stale.follow().follow(_session, 59);
      expect(result.outcome, SpaceWriteOutcome.rejected);
      expect(result.message, isNull);
      // The forum without the app API prints the same two words.
      final plain = _Transport()..postAnswer = (_, _) => 'Access Denied';
      expect((await plain.follow().follow(_session, 59)).outcome, SpaceWriteOutcome.rejected);
    });

    test("without the app API: the popup's handler", () async {
      final transport = _Transport()..postAnswer = (_, _) => _text('ajax_follow_added.xml');
      final result = await transport.follow().follow(_session, 35);
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(result.message, '成功关注');
    });

    test('a remark: the name the forum kept comes back', () async {
      final transport = _Transport()..postAnswer = (_, _) => _json('result_bkname_saved');
      final answer = await transport.follow().remark(_session, 35, ' 老朋友<b>x</b> ');
      expect(answer.result.outcome, SpaceWriteOutcome.done);
      expect(answer.result.message, '备注成功');
      expect(answer.remark, '老朋友x');
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=follow&op=bkname&fuid=35&inajax=1');
      expect(transport.posts.single.$2, {
        'formhash': 'f1f2f3f4',
        'editbkname': 'true',
        'bkname': '老朋友<b>x</b>',
        'handlekey': 'fbkname_35',
      });

      final refused = _Transport()..postAnswer = (_, _) => _json('result_bkname_not_followed');
      final none = await refused.follow().remark(_session, 33, 'x');
      expect(none.result.outcome, SpaceWriteOutcome.rejected);
      expect(none.result.message, '未指定用户');
      expect(none.remark, isNull);
    });

    test('nothing is sent for another account; a failed request is not sent again', () async {
      final transport = _Transport(uid: 35);
      final repository = transport.follow();
      // The page was served to 31, the repository belongs to 35.
      expect((await repository.follow(_session, 33)).outcome, SpaceWriteOutcome.identityChanged);
      expect((await repository.unfollow(_session, 33)).outcome, SpaceWriteOutcome.identityChanged);
      expect((await repository.remark(_session, 33, 'x')).result.outcome, SpaceWriteOutcome.identityChanged);
      expect((await repository.relay(_session, 1, 'x', reply: false)).outcome, SpaceWriteOutcome.identityChanged);
      expect((await repository.deleteFeed(_session, 1)).outcome, SpaceWriteOutcome.identityChanged);
      expect(transport.posts, isEmpty);

      // The account changes after the repository was built.
      final switched = _Transport();
      final built = switched.follow();
      switched.uid = 35;
      expect((await built.follow(_session, 33)).outcome, SpaceWriteOutcome.identityChanged);
      expect((await built.loadRelation(33)).kind, SpaceFormLoadKind.identityChanged);
      expect(switched.posts, isEmpty);
      expect(switched.gets, isEmpty);

      final failing = _Transport()..failPost = true;
      expect((await failing.follow().follow(_session, 33)).outcome, SpaceWriteOutcome.unconfirmed);
      expect(failing.posts, hasLength(1));
    });
  });

  group('the broadcasts', () {
    test('the first page: a relay with its note, a thread, the counts; more follow from page two', () {
      final url = followFeedUrl();
      expect(url, '$baseUrl/home.php?mod=follow&view=follow');
      final page = parseFollowFeedPage(_doc('feed_follow'), url);
      expect(page.items.map((e) => e.feedId), [718, 716, 715, 709]);
      expect(page.session?.uid, 31);
      expect(
        page.nextPageUrl,
        '$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=0&page=2&inajax=1&viewtype=follow',
      );

      final relay = page.items.first;
      expect((relay.uid, relay.username), (31, '测试会员甲'));
      expect(relay.note?.text?.trim(), '转播并回帖实测三，这是一则同时回复的转播');
      expect(relay.threadId, 9202766);
      expect(relay.threadTitle, '活动：周末联机开黑');
      expect(relay.origin, '测试会员乙 发表于 2026-11-7 22:05');
      expect(relay.forumName, isNotEmpty);
      expect((relay.relayCount, relay.replyCount), (1, 3));
      expect((relay.canRelay, relay.canDelete, relay.threadMissing), (true, true, false));
      expect(relay.time, isNotNull);

      final thread = page.items[1];
      expect((thread.uid, thread.note, thread.origin), (33, null, null));
      expect(thread.threadId, isNotNull);
      expect(thread.content?.text, isNotEmpty);
      expect((thread.canRelay, thread.canDelete), (true, false));
      // The second of a member's run has no avatar block: it is still read.
      expect(page.items[2].uid, 33);
    });

    test("a member's broadcasts ask for more with their uid; a short list goes on with the filed ones", () {
      final url = followFeedUrl(uid: 35);
      expect(url, '$baseUrl/home.php?mod=follow&uid=35&do=view');
      final page = parseFollowFeedPage(_doc('feed_member'), url);
      expect(page.items, hasLength(3));
      expect(page.items.every((e) => e.uid == 35), isTrue);
      expect(page.nextPageUrl, '$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=0&page=2&inajax=1&uid=35');
      // The head of a member's broadcasts tells the relation too.
      expect(parseFollowRelation(_doc('feed_member'), 35)?.following, isTrue);

      final last = parseFollowFeedPage(_doc('feed_last'), followFeedUrl(uid: 33));
      expect(last.items, hasLength(2));
      // Fewer than twenty and no script to load more: the website stops, the filed ones are still asked for.
      expect(last.nextPageUrl, '$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=1&page=1&inajax=1&uid=33');
      expect(
        followMoreFeedUrl(followFeedUrl(view: FollowFeedView.hall), archive: true, page: 2),
        '$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=1&page=2&inajax=1&viewtype=other',
      );
    });

    test("switched off and a guest: the forum's words", () {
      final off = parseFollowFeedPage(_doc('feed_off'), followFeedUrl());
      expect(off.message, '抱歉，广播功能尚未开启');
      expect(spaceModuleSwitchedOff(off.message), isTrue);
      expect(parseFollowFeedPage(_doc('follow_guest'), followFeedUrl()).needLogin, isTrue);
    });

    test('more broadcasts: the recent ones page after page, then the filed ones from their first page', () async {
      final asked = <String>[];
      final answers = <String, Object?>{
        'archiver=0&page=2': _json('feed_more'),
        'archiver=0&page=3': _json('feed_more_end'),
        'archiver=1&page=1': _text('feed_more_archive.xml'),
        'archiver=1&page=2': _text('feed_more_end.xml'),
      };
      final repository = FollowRepository(
        get: (url) async {
          asked.add(url);
          final key = answers.keys.firstWhere(url.contains);
          return right(_answer(answers[key], url));
        },
      );
      const first = '$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=0&page=2&inajax=1&viewtype=follow';
      final second = (await repository.fetchFeed(first).run()).getOrElse((e) => fail('$e'));
      expect(second.items, hasLength(3));
      expect(second.nextPageUrl, first.replaceFirst('page=2', 'page=3'));
      // Asked as the app API answers an AJAX fragment.
      expect(asked.single, '$first&tsdmapp=json');

      // The recent ones are over: the filed ones follow in the same go.
      asked.clear();
      final filed = (await repository.fetchFeed(second.nextPageUrl!).run()).getOrElse((e) => fail('$e'));
      expect(asked, hasLength(2));
      expect(asked.last, contains('archiver=1&page=1'));
      expect(filed.items.single.feedId, 182);
      expect(filed.nextPageUrl, contains('archiver=1&page=2'));
      // The pictures of the beginning of a thread are served from the forum, its attachments left to the thread.
      final content = filed.items.single.content!;
      expect(content.querySelector('img')?.attributes['src'], startsWith('$baseUrl/data/attachment/forum/'));
      expect(content.querySelector('div.flw_attach'), isNull);

      // The filed ones are over: the end.
      final end = (await repository.fetchFeed(filed.nextPageUrl!).run()).getOrElse((e) => fail('$e'));
      expect(end.items, isEmpty);
      expect(end.nextPageUrl, isNull);
    });

    test("more broadcasts: the forum's message is a failed page, never an empty one", () async {
      final repository = FollowRepository(
        get: (url) async => right(_answer(_json('result_follow_self'), url)),
      );
      final result = await repository
          .fetchFeed('$baseUrl/home.php?mod=spacecp&ac=follow&op=getfeed&archiver=0&page=2&inajax=1&viewtype=follow')
          .run();
      expect(result.isLeft(), isTrue);
    });

    test('a relay and a delete, each posted once', () async {
      final transport = _Transport()..postAnswer = (_, _) => _json('result_relay_done');
      final relayed = await transport.follow().relay(_session, 9202766, ' 转播实测一 ', reply: true);
      expect(relayed.outcome, SpaceWriteOutcome.done);
      expect(relayed.message, '转播成功');
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=follow&op=relay&tid=9202766&inajax=1');
      expect(transport.posts.single.$2, {
        'formhash': 'f1f2f3f4',
        'relaysubmit': 'true',
        'tid': '9202766',
        'note': '转播实测一',
        'addnewreply': '1',
        'handlekey': 'qrelay_9202766',
      });
      transport.posts.clear();
      await transport.follow().relay(_session, 9202766, 'x', reply: false);
      expect(transport.posts.single.$2.containsKey('addnewreply'), isFalse);

      for (final (fixture, message) in [
        ('result_relay_twice', '抱歉，第二次转播必须同时进行回帖操作'),
        ('result_relay_too_long', '您输入的转播理由超过140个字'),
        ('result_relay_missing', '转播的内容不存在'),
      ]) {
        final refused = _Transport()..postAnswer = (_, _) => _json(fixture);
        final result = await refused.follow().relay(_session, 9202766, 'x', reply: false);
        expect((result.outcome, result.message), (SpaceWriteOutcome.rejected, message), reason: fixture);
      }

      final deleting = _Transport()..postAnswer = (_, _) => _json('result_feed_deleted');
      expect((await deleting.follow().deleteFeed(_session, 717)).outcome, SpaceWriteOutcome.done);
      expect(deleting.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=follow&op=delete&feedid=717&inajax=1');
      expect(deleting.posts.single.$2, {
        'formhash': 'f1f2f3f4',
        'deletesubmit': 'true',
        'handlekey': 'c_delete_717',
      });
      final denied = _Transport()..postAnswer = (_, _) => _json('result_feed_delete_denied');
      final result = await denied.follow().deleteFeed(_session, 709);
      expect((result.outcome, result.message), (SpaceWriteOutcome.rejected, '您没有权限进行此操作'));
    });
  });

  group('the records', () {
    test('a list: the records, the delete link on the own ones, the form, the next page', () {
      final page = parseDoingListPage(_doc('doing_all'));
      expect(page.items, hasLength(4));
      expect(page.session?.uid, 31);
      expect(page.canPost, isTrue);
      expect(page.nextPageUrl, contains('do=doing&view=all&page=2'));
      final own = page.items.firstWhere((e) => e.doid == 2);
      expect((own.uid, own.username, own.canDelete), (31, '测试会员甲', true));
      // What was typed as html is text; the forum's own tag link stays.
      expect(own.content.querySelector('b'), isNull);
      expect(own.content.text, contains('<b>粗体</b>'));
      expect(own.content.querySelector('a.doing_tag')?.text, '#补番#');
      expect(own.time, isNotNull);
      final other = page.items.firstWhere((e) => e.doid == 3);
      expect((other.uid, other.canDelete), (35, false));
      expect(other.replyCount, greaterThan(0));
      expect(other.avatarUrl, '$baseUrl/data/avatar/000/00/00/35_avatar_small.jpg');
      expect(page.items.where((e) => e.uid != 31).every((e) => !e.canDelete), isTrue);

      final last = parseDoingListPage(_doc('doing_all_p2'));
      expect(last.items, hasLength(2));
      expect(last.nextPageUrl, isNull);
    });

    test("a member's records and a guest's view have no form; none is an empty list", () {
      final member = parseDoingListPage(_doc('doing_member'));
      expect(member.items.single.uid, 35);
      expect(member.canPost, isFalse);
      expect(member.session?.uid, 31);
      final none = parseDoingListPage(_doc('doing_none'));
      expect(none.items, isEmpty);
      expect((none.message, none.needLogin), (null, false));
      final guest = parseDoingListPage(_doc('doing_guest'));
      expect(guest.items, hasLength(2));
      expect((guest.session, guest.canPost), (null, false));
      expect(guest.items.every((e) => !e.canDelete), isTrue);
    });

    test("switched off, and the lists of an account asked by a guest: the forum's words", () {
      final off = parseDoingListPage(_doc('doing_off'));
      expect(off.message, '抱歉，记录功能尚未开启');
      expect(spaceModuleSwitchedOff(off.message), isTrue);
      expect(parseDoingListPage(_doc('doing_guest_me')).needLogin, isTrue);
    });

    test('the urls of the lists, and the length as the forum counts it', () {
      expect(doingListUrl(), '$baseUrl/home.php?mod=space&do=doing&view=all');
      expect(doingListUrl(view: DoingView.friends), '$baseUrl/home.php?mod=space&do=doing&view=we');
      expect(doingListUrl(view: DoingView.mine), '$baseUrl/home.php?mod=space&do=doing&view=me');
      expect(doingListUrl(uid: 35), '$baseUrl/home.php?mod=space&uid=35&do=doing&view=me');
      expect(doingUrl(3), '$baseUrl/home.php?mod=space&do=doing&doid=3');
      expect(doingLengthOf('abc'), 3);
      expect(doingLengthOf('记录 ok'), 7);
      expect(doingLengthOf('长' * 100), doingMaxLength);
    });

    test('the replies: the top ones with their own under them, the hidden ones too, more on a next page', () {
      final page = parseDoingComments(spaceAjaxFragmentOf(_text('doing_comments.xml'))!, doid: 3, page: 1);
      expect(page.hasMore, isTrue);
      // The row that unfolds the hidden replies is none.
      expect(page.comments.map((e) => e.id), [1, 4, 5, 6, 7, 8, 2, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11]);
      expect(page.comments.where((e) => e.nested).map((e) => e.id), [4, 5, 6, 7, 8, 2, 20]);
      final first = page.comments.first;
      expect((first.uid, first.username, first.doid), (31, '测试会员甲', 3));
      expect((first.canReply, first.canDelete), (true, true));
      expect(first.time, matches(RegExp(r'^\d{4}-\d{1,2}-\d{1,2} \d{2}:\d{2}$')));
      expect(first.message.querySelector('i'), isNull);
      // A reply to a reply of a reply names whom it answers; another member's reply has no delete link.
      final deep = page.comments.firstWhere((e) => e.id == 20);
      expect(deep.message.text, contains('回复 测试会员01'));
      expect(page.comments.firstWhere((e) => e.id == 4).canDelete, isFalse);

      expect(
        parseDoingComments(spaceAjaxFragmentOf(_text('doing_comments_empty.xml'))!, doid: 2, page: 1).comments,
        isEmpty,
      );
    });

    test('the replies are read as the app API answers them, or as the forum does', () async {
      final asked = <String>[];
      final repository = DoingRepository(
        get: (url) async {
          asked.add(url);
          return right(
            _answer(url.contains('page_c=2') ? _json('doing_comments_p2') : _text('doing_comments.xml'), url),
          );
        },
      );
      final first = (await repository.fetchComments(3).run()).getOrElse((e) => fail('$e'));
      expect((first.comments.length, first.hasMore, first.page), (17, true, 1));
      expect(
        asked.single,
        '$baseUrl/home.php?mod=spacecp&ac=doing&op=getcomment&doid=3&inajax=1&page_c=1&tsdmapp=json',
      );
      final second = (await repository.fetchComments(3, page: 2).run()).getOrElse((e) => fail('$e'));
      expect(second.comments.map((e) => e.id), [10, 9]);
      expect((second.hasMore, second.page), (false, 2));

      // A guest is answered nothing: a failed request. The forum's message is its words.
      final nothing = DoingRepository(get: (url) async => right(_answer('', url)));
      expect((await nothing.fetchComments(3).run()).isLeft(), isTrue);
      final off = DoingRepository(
        get: (url) async => right(
          _answer({...(_json('result_doing_empty')! as Map<String, dynamic>), 'message': '抱歉，记录功能尚未开启'}, url),
        ),
      );
      final message = (await off.fetchComments(3).run()).getOrElse((e) => fail('$e'));
      expect(message.comments, isEmpty);
      expect(message.message, '抱歉，记录功能尚未开启');
    });
  });

  group('record writes', () {
    test('a record: posted once, done when the forum goes back', () async {
      final transport = _Transport()..postAnswer = (_, _) => _json('result_doing_posted');
      final result = await transport.doing().post(_session, ' 今天把动画补完了 ');
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=doing&inajax=1');
      expect(transport.posts.single.$2, {
        'formhash': 'f1f2f3f4',
        'addsubmit': 'true',
        'message': '今天把动画补完了',
        'handlekey': 'doing',
      });

      // The forum without the app API: the redirect itself.
      final plain = _Transport()
        ..postStatus = 301
        ..postAnswer = (_, _) => '';
      expect((await plain.doing().post(_session, 'x')).outcome, SpaceWriteOutcome.done);
    });

    test("refusals are the forum's words", () async {
      for (final (fixture, message) in [
        ('result_doing_too_fast', '抱歉，两次发布操作太快，请等待 15 秒再试'),
        ('result_doing_empty', '至少应该写点东西'),
      ]) {
        final transport = _Transport()..postAnswer = (_, _) => _json(fixture);
        final result = await transport.doing().post(_session, 'x');
        expect((result.outcome, result.message), (SpaceWriteOutcome.rejected, message), reason: fixture);
        expect(transport.posts, hasLength(1));
      }
    });

    test('a reply to a record and to one of its replies', () async {
      final transport = _Transport()..postAnswer = (_, _) => _json('result_docomment_posted');
      final repository = transport.doing();
      final result = await repository.comment(_session, 3, ' 剧场版好看吗？ ');
      expect((result.outcome, result.message), (SpaceWriteOutcome.done, '操作成功'));
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=doing&op=comment&doid=3&docid=0&inajax=1');
      expect(transport.posts.single.$2, {
        'formhash': 'f1f2f3f4',
        'commentsubmit': 'true',
        'message': '剧场版好看吗？',
        'handlekey': 'doing_3',
      });
      await repository.comment(_session, 3, 'x', docid: 4);
      expect(transport.posts.last.$1, contains('op=comment&doid=3&docid=4'));

      final missing = _Transport()..postAnswer = (_, _) => _json('result_docomment_missing');
      final refused = await missing.doing().comment(_session, 99999, 'x');
      expect((refused.outcome, refused.message), (SpaceWriteOutcome.rejected, '抱歉，请正确指定要评论的记录'));

      final plain = _Transport()..postAnswer = (_, _) => _text('ajax_docomment_posted.xml');
      expect((await plain.doing().comment(_session, 3, 'x')).outcome, SpaceWriteOutcome.done);
    });

    test('a delete of a record or of a reply: done when the forum goes back', () async {
      final transport = _Transport()..postAnswer = (_, _) => _json('result_doing_deleted');
      final repository = transport.doing();
      expect((await repository.delete(_session, 4)).outcome, SpaceWriteOutcome.done);
      expect(transport.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=doing&op=delete&doid=4&inajax=1');
      expect(transport.posts.single.$2, {'formhash': 'f1f2f3f4', 'deletesubmit': 'true', 'handlekey': 'doinghk_4'});
      expect((await repository.delete(_session, 3, docid: 7)).outcome, SpaceWriteOutcome.done);
      expect(transport.posts.last.$1, '$baseUrl/home.php?mod=spacecp&ac=doing&op=delete&doid=3&docid=7&inajax=1');
      expect(transport.posts.last.$2['handlekey'], 'doinghk_3_7');

      final plain = _Transport()
        ..postStatus = 302
        ..postAnswer = (_, _) => '';
      expect((await plain.doing().delete(_session, 4)).outcome, SpaceWriteOutcome.done);
    });

    test('nothing is sent for another account; a failed request is not sent again', () async {
      final transport = _Transport(uid: 35);
      final repository = transport.doing();
      expect((await repository.post(_session, 'x')).outcome, SpaceWriteOutcome.identityChanged);
      expect((await repository.comment(_session, 3, 'x')).outcome, SpaceWriteOutcome.identityChanged);
      expect((await repository.delete(_session, 3)).outcome, SpaceWriteOutcome.identityChanged);
      expect(transport.posts, isEmpty);

      final failing = _Transport()..failPost = true;
      expect((await failing.doing().post(_session, 'x')).outcome, SpaceWriteOutcome.unconfirmed);
      expect(failing.posts, hasLength(1));
      // A redirect tells nothing of a form the forum answers with its words.
      final redirected = _Transport()
        ..postStatus = 302
        ..postAnswer = (_, _) => '';
      expect((await redirected.doing().comment(_session, 3, 'x')).outcome, SpaceWriteOutcome.unconfirmed);
    });
  });

  group('links and notices', () {
    test('the follow links open the broadcasts and the lists', () {
      for (final (url, path, query) in [
        ('home.php?mod=follow', ScreenPaths.followFeed, <String, String>{}),
        ('home.php?mod=follow&view=other', ScreenPaths.followFeed, <String, String>{}),
        ('home.php?mod=follow&uid=35&do=view', ScreenPaths.followFeed, {'uid': '35'}),
        ('home.php?mod=follow&do=following', ScreenPaths.followMembers, <String, String>{}),
        ('home.php?mod=follow&do=following&uid=35', ScreenPaths.followMembers, {'uid': '35'}),
        ('home.php?mod=follow&do=follower&uid=35', ScreenPaths.followMembers, {'uid': '35', 'tab': 'follower'}),
      ]) {
        final route = '$baseUrl/$url'.parseUrlToRoute();
        expect(route?.screenPath, path, reason: url);
        expect(route?.queryParameters, query, reason: url);
      }
    });

    test('the links of the records open them: the lists, a member, one record', () {
      for (final (url, query) in [
        ('home.php?mod=space&do=doing', <String, String>{}),
        ('home.php?mod=space&do=doing&view=me', <String, String>{}),
        ('home.php?mod=space&uid=35&do=doing&view=me&from=space', {'uid': '35'}),
        ('home.php?mod=space&do=doing&doid=3', {'doid': '3'}),
        ('home.php?mod=space&uid=31&do=doing&view=me&doid=3&highlight=2', {'doid': '3'}),
      ]) {
        final route = '$baseUrl/$url'.parseUrlToRoute();
        expect(route?.screenPath, ScreenPaths.doing, reason: url);
        expect(route?.queryParameters, query, reason: url);
      }
      // The profile of a member is still theirs.
      expect('$baseUrl/home.php?mod=space&uid=35'.parseUrlToRoute()?.screenPath, ScreenPaths.profile);
    });

    test('a tap on a follow notice opens who followed, on the news the broadcasts, on a reply its record', () {
      final notices = (_json('notices_follow')! as List<dynamic>).cast<Map<String, dynamic>>();
      String? tap(String type) {
        final n = notices.firstWhere((e) => e['type'] == type);
        final info = NoticeInfo.of(
          NoticeV2(
            id: 1,
            timestamp: 1700000000,
            data: n['note'] as String,
            ignoreType: type,
            authorId: n['authorid'] as int,
            fromIdType: n['from_idtype'] as String,
          ),
        );
        return noticeTapUrlOf(info, n['note'] as String);
      }

      final follower = tap('follower');
      expect(follower, '$baseUrl/home.php?mod=space&uid=31');
      expect(follower!.parseUrlToRoute()?.screenPath, ScreenPaths.profile);
      expect(tap('follow')!.parseUrlToRoute()?.screenPath, ScreenPaths.followFeed);
      final reply = tap('comment')!.parseUrlToRoute();
      expect(reply?.screenPath, ScreenPaths.doing);
      expect(reply?.queryParameters, {'doid': '3'});
    });
  });

  test('the fixtures carry nothing of the test forum', () {
    final files = Directory(_dir).listSync().whereType<File>().where(
      (f) => _fixtures.hasMatch(f.uri.pathSegments.last),
    );
    expect(files.length, greaterThan(40));
    for (final file in files) {
      final raw = file.readAsStringSync();
      expect(raw, isNot(matches(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'))), reason: '${file.path}: an IPv4 address');
      expect(raw, isNot(matches(RegExp(r'[\w.+-]+@[\w-]+\.[a-z]{2,}'))), reason: '${file.path}: an email address');
      expect(raw, isNot(contains('/home/')), reason: file.path);
      for (final hash in RegExp(r'''(?:form)?hash["'=:\s]+(?:value=")?([0-9a-f]{8})\b''').allMatches(raw)) {
        expect(hash.group(1), 'f1f2f3f4', reason: file.path);
      }
    }
  });

  // The avatars are asked from an image cache without a network: they stay the placeholder.
  late AppDatabase db;

  void offlineImages() {
    db = AppDatabase(NativeDatabase.memory());
    getIt
      ..registerSingleton<StorageProvider>(StorageProvider(db, {}, {}))
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    addTearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await db.close();
    });
  }

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SizedBox(width: 320, child: child)),
        ),
      ),
    ),
  );

  testWidgets('a broadcast lays out on a narrow screen, its menu offering what the forum printed', (tester) async {
    offlineImages();
    final feed = parseFollowFeedPage(_doc('feed_follow'), followFeedUrl()).items.first;
    var relayed = 0;
    await pump(tester, FollowFeedCard(feed, onRelay: () => relayed++));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('活动：周末联机开黑'), findsOneWidget);
    expect(find.textContaining('测试会员乙 发表于'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // No delete without its callback.
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    await tester.tap(find.text(t.spacePage.follow.relay));
    await tester.pumpAndSettle();
    expect(relayed, 1);
  });

  testWidgets('a member of a follow list: the follow link as a button, the remark when the forum offers it', (
    tester,
  ) async {
    final users = parseFollowListPage(_doc('follow_following')).items;
    offlineImages();
    final friend = users.firstWhere((e) => e.uid == 35);
    var toggled = 0;
    await pump(tester, FollowUserTile(friend, onToggleFollow: () => toggled++, onRemark: () {}));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('老朋友'), findsOneWidget);
    expect(find.text(t.spacePage.follow.unfollow), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.text(t.spacePage.follow.unfollow));
    await tester.pumpAndSettle();
    expect(toggled, 1);

    // Another member's list: nothing to press.
    final row = parseFollowListPage(_doc('follow_relation_mutual')).items.single;
    await pump(tester, FollowUserTile(row));
    await tester.pump();
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('the relay dialog: the note within what the forum takes, a reply needs one', (tester) async {
    final feed = parseFollowFeedPage(_doc('feed_follow'), followFeedUrl()).items[1];
    late BuildContext context;
    await pump(
      tester,
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox.shrink();
        },
      ),
    );
    // Nothing is sent: the dialog is cancelled.
    final closed = showRelayDialog(context, session: _session, feed: feed);
    await tester.pumpAndSettle();
    FilledButton send() => tester.widget<FilledButton>(find.byType(FilledButton));
    // Checked as the forum's form: a reply without a note is nothing to post.
    expect(send().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '字' * 47);
    await tester.pump();
    expect(find.text('141 / 140'), findsOneWidget);
    expect(send().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '字' * 46);
    await tester.pump();
    expect(send().onPressed, isNotNull);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(await closed, isFalse);
  });

  testWidgets('a record lays out on a narrow screen; the dialog counts as the forum does', (tester) async {
    offlineImages();
    final doing = parseDoingListPage(_doc('doing_all')).items.firstWhere((e) => e.doid == 3);
    var opened = 0;
    await pump(tester, DoingCard(doing, onReplies: () => opened++));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('${doing.replyCount}'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    expect(opened, 1);

    late BuildContext context;
    await pump(
      tester,
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox.shrink();
        },
      ),
    );
    final typed = showDoingTextDialog(context, icon: Icons.edit_note_outlined, title: 'title', send: 'send');
    await tester.pumpAndSettle();
    FilledButton send() => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(send().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '长' * 101);
    await tester.pump();
    expect(find.text('202 / 200'), findsOneWidget);
    expect(send().onPressed, isNull);
    await tester.enterText(find.byType(TextField), ' 今天也是元气满满 ');
    await tester.pump();
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();
    expect(await typed, '今天也是元气满满');
  });

  testWidgets('the replies of a record: a page, then more; a guest only reads', (tester) async {
    offlineImages();
    final doing = parseDoingListPage(_doc('doing_all')).items.firstWhere((e) => e.doid == 3);
    final asked = <String>[];
    final repository = DoingRepository(
      get: (url) async {
        asked.add(url);
        return right(_answer(url.contains('page_c=2') ? _json('doing_comments_p2') : _text('doing_comments.xml'), url));
      },
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: DoingRepliesSheet(doing: doing, session: null, onChanged: () {}, repository: repository),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(asked, hasLength(1));
    expect(find.text('剧场版好看吗？<i>x</i>'), findsOneWidget);
    // No session: nothing to reply with, nothing to delete.
    expect(find.byIcon(Icons.reply_outlined), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    await tester.scrollUntilVisible(find.text(t.spacePage.doing.moreReplies), 300);
    await tester.tap(find.text(t.spacePage.doing.moreReplies));
    await tester.pumpAndSettle();
    expect(asked, hasLength(2));
    expect(asked.last, contains('page_c=2'));
    expect(find.text(t.spacePage.doing.moreReplies), findsNothing);
  });
}
