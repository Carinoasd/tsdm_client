/// The wall of a member's space and the greetings (打招呼), as measured on the test site (Discuz! X5, plugin 3.7.0):
///
/// * a wall is `home.php?mod=space&uid=N&do=wall[&page=P]`, twenty messages a page, newest first, in the comment list
///   of the blogs (`home/space_comment_li`): the forum prints the delete link (`c_CID_delete`) to the author, the owner
///   and a moderator of comments, the reply link (`c_CID_reply`) on the owner's own wall only, to the named messages of
///   others; `&cid=C` (the link of a wall notice) shows that message only;
/// * every post goes as the website's popups send it (`inajax=1`, the `handlekey`), and the app API answers it as the
///   popup's handler (`kind: handle`, `alert` `right` or `error`);
/// * a message is posted to `home.php?mod=spacecp&ac=comment` (`id` the owner, `idtype=uid`, `commentsubmit`,
///   `quickcomment`), answered `do_success` "操作成功" with `values.cid`; a reply adds `cid` and goes, quoted, to the
///   wall of the message's author (`note_wall_reply_success`: "已经回复到NAME的留言板"); posting again within 15 seconds
///   is `operating_too_fast`; a delete is `op=delete&cid=C` with `deletesubmit`, `do_success`, refused
///   `no_privilege_comment_del` to another, `comments_do_not_exist` once gone;
/// * the privacy of the wall (`privacy.view.wall`) prints "抱歉！由于 NAME 的隐私设置，您不能访问当前内容"; the wall
///   switched off (`wallstatus`) prints the 提示信息 "抱歉，留言板功能尚未开启" (the fixture is that page's
///   `showmessage` structure, captured from the switched off records module, with the wall's words);
/// * the poke form `home.php?mod=spacecp&ac=poke&op=send|reply&uid=N` offers the greetings (`iconid`, 0 the plain
///   one) and a note the forum cuts to 30 (`cutstr`), answered `poke_success`; greeting back (`op=reply`) removes the
///   greeting received; the form refuses the account itself (`not_to_their_own_greeted`) and asks a guest to log in;
/// * the greetings received are `home.php?mod=spacecp&ac=poke`, the latest of each member; `op=ignore&uid=N` with
///   `ignoresubmit` ignores one, without `uid` all of them (`has_been_hailed_overlooked`).
///
/// The fixtures (`test/data/space_social/`) are the test site's pages, cut to their content, the accounts and the site
/// renamed, the form hash and the time replaced.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_social_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/widgets/space_social_widgets.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/space_social';

String _text(String name) => File('$_dir/$name').readAsStringSync();

SpaceListPage<SpaceBlogComment> _wall(String name) => parseSpaceWallPage(parseHtmlDocument(_text('$name.html')));

Response<dynamic> _ok(Object? data, String url) => Response<dynamic>(
  requestOptions: RequestOptions(path: url),
  statusCode: 200,
  data: data,
);

/// A transport recording what goes out.
final class _Transport {
  _Transport({this.uid = 31});

  int? uid;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  Object? page;
  Object? Function(String url, Map<String, String> body) postAnswer = (_, _) => null;
  bool failPost = false;

  SpaceSocialRepository repository() => SpaceSocialRepository.withTransport(
    currentUid: () => uid,
    getPage: (url) async {
      gets.add(url);
      return right(_ok(page, url));
    },
    sendForm: (url, body) async {
      posts.add((url, body));
      if (failPost) return left(HttpRequestFailedException(null));
      return right(_ok(postAnswer(url, body), url));
    },
  );
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the wall', () {
    test("another member's wall: the messages, the delete link on the viewer's own, no reply", () {
      final page = _wall('wall_other');
      expect(page.items, hasLength(20));
      expect(page.nextPageUrl, '$baseUrl/home.php?mod=space&uid=35&do=wall&page=2');
      expect(page.session?.uid, 31);
      expect(page.session?.formHash, 'f1f2f3f4');
      expect(page.canPost, isTrue);
      expect(page.message, isNull);
      final own = page.items.where((e) => e.uid == 31).toList();
      expect(own, isNotEmpty);
      expect(own.every((e) => e.canDelete), isTrue);
      expect(page.items.where((e) => e.uid != 31).every((e) => !e.canDelete), isTrue);
      expect(page.items.every((e) => !e.canReply), isTrue);
      final first = page.items.first;
      expect(first.author, '测试会员甲');
      expect(first.time, isNotNull);
      expect(first.avatarUrl, startsWith('https://forum.test/'));
    });

    test('the own wall: reply and delete on the messages of others', () {
      final page = _wall('wall_own');
      expect(page.session?.uid, 35);
      expect(page.items, hasLength(20));
      expect(page.items.every((e) => e.canDelete), isTrue);
      expect(page.items.where((e) => e.uid != 35).every((e) => e.canReply), isTrue);
      expect(page.nextPageUrl, contains('page=2'));
      final last = _wall('wall_own_p2');
      expect(last.items, isNotEmpty);
      expect(last.nextPageUrl, isNull);
      expect(last.items.map((e) => e.cid).toSet().intersection(page.items.map((e) => e.cid).toSet()), isEmpty);
    });

    test('a message plain text stays as typed: line breaks, no html', () {
      final page = _wall('wall_own');
      final typed = page.items.firstWhere((e) => e.message.text!.contains('第二則'));
      expect(typed.message.innerHtml, contains('<br>'));
      expect(typed.message.querySelector('b'), isNull);
    });

    test('the one message of a notice', () {
      final page = _wall('wall_cid');
      expect(page.items.map((e) => e.cid), [30]);
      expect(page.nextPageUrl, isNull);
      expect(page.items.single.canReply, isTrue);
    });

    test('a guest reads the wall and gets no message box', () {
      final page = _wall('wall_guest');
      expect(page.items, isNotEmpty);
      expect(page.session, isNull);
      expect(page.canPost, isFalse);
      expect(page.items.every((e) => !e.canDelete && !e.canReply), isTrue);
    });

    test("the privacy notice and the switched off wall are the forum's words", () {
      final privacy = _wall('wall_privacy');
      expect(privacy.items, isEmpty);
      expect(privacy.message, '抱歉！由于 测试会员乙 的隐私设置，您不能访问当前内容');
      expect(spaceModuleSwitchedOff(privacy.message), isFalse);
      final off = _wall('wall_off');
      expect(off.items, isEmpty);
      expect(off.message, '抱歉，留言板功能尚未开启');
      expect(off.needLogin, isFalse);
      expect(spaceModuleSwitchedOff(off.message), isTrue);
      expect(spaceModuleSwitchedOff('抱歉，好友功能尚未开启'), isTrue);
    });

    test('a switched off module is noted once', () {
      addTearDown(() => spaceModulesOff.value = const {});
      var changes = 0;
      void listener() => changes++;
      spaceModulesOff.addListener(listener);
      addTearDown(() => spaceModulesOff.removeListener(listener));
      markSpaceModuleOff(SpaceModule.wall);
      markSpaceModuleOff(SpaceModule.wall);
      expect(spaceModulesOff.value, {SpaceModule.wall});
      expect(changes, 1);
    });
  });

  group('wall writes', () {
    const session = SpaceSession(uid: 31, formHash: 'f1f2f3f4');

    test('a message, posted once as the quick message box sends it', () async {
      final net = _Transport()..postAnswer = (_, _) => _text('result_wall_posted.json');
      final result = await net.repository().postWall(session, 35, '  你好\n第二行 ');
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(result.message, '操作成功');
      final (url, body) = net.posts.single;
      expect(url, SpaceSocialRepository.commentSubmitUrl);
      expect(url, contains('inajax=1'));
      expect(body, {
        'formhash': 'f1f2f3f4',
        'id': '35',
        'idtype': 'uid',
        'commentsubmit': 'true',
        'message': '你好\n第二行',
        'quickcomment': 'true',
        'handlekey': 'qcwall_35',
      });
    });

    test("a reply names the message and tells the forum's words", () async {
      final net = _Transport(uid: 35)..postAnswer = (_, _) => _text('result_wall_replied.json');
      final result = await net.repository().postWall(
        const SpaceSession(uid: 35, formHash: 'f1f2f3f4'),
        35,
        '回覆',
        replyTo: 58,
      );
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(result.message, '已经回复到测试会员丙的留言板');
      final (_, body) = net.posts.single;
      expect(body['cid'], '58');
      expect(body['id'], '35');
      expect(body.containsKey('quickcomment'), isFalse);
      expect(body['handlekey'], 'replycommenthk_58');
    });

    test('refusals are the forum words, sent once', () async {
      final net = _Transport()..postAnswer = (_, _) => _text('result_wall_too_fast.json');
      final fast = await net.repository().postWall(session, 35, 'x');
      expect(fast.outcome, SpaceWriteOutcome.rejected);
      expect(fast.message, '抱歉，两次发布操作太快，请等待 15 秒再试');
      net.postAnswer = (_, _) => _text('result_wall_delete_denied.json');
      final denied = await net.repository().deleteWall(session, 6);
      expect(denied.outcome, SpaceWriteOutcome.rejected);
      expect(denied.message, '抱歉，您没有权限删除此评论');
      final (url, body) = net.posts.last;
      expect(url, '$baseUrl/home.php?mod=spacecp&ac=comment&op=delete&cid=6&inajax=1');
      expect(body, {'formhash': 'f1f2f3f4', 'deletesubmit': 'true', 'handlekey': 'delcommenthk_6'});
      net.postAnswer = (_, _) => _text('result_wall_deleted.json');
      expect((await net.repository().deleteWall(session, 58)).outcome, SpaceWriteOutcome.done);
      net.postAnswer = (_, _) => _text('result_wall_delete_missing.json');
      final gone = await net.repository().deleteWall(session, 58);
      expect(gone.outcome, SpaceWriteOutcome.rejected);
      expect(gone.message, '抱歉，您指定的评论不存在');
      expect(net.posts, hasLength(4));
    });

    test('nothing is sent for another account; a failed request is not sent again', () async {
      final net = _Transport();
      final repo = net.repository();
      expect(
        (await repo.postWall(const SpaceSession(uid: 35, formHash: 'f1f2f3f4'), 35, 'x')).outcome,
        SpaceWriteOutcome.identityChanged,
      );
      net.uid = 35;
      expect((await repo.deleteWall(session, 1)).outcome, SpaceWriteOutcome.identityChanged);
      expect(net.posts, isEmpty);
      net
        ..uid = 31
        ..failPost = true;
      expect((await repo.postWall(session, 35, 'x')).outcome, SpaceWriteOutcome.unconfirmed);
      expect(net.posts, hasLength(1));
      repo.invalidate();
      net.failPost = false;
      expect((await repo.postWall(session, 35, 'x')).outcome, SpaceWriteOutcome.identityChanged);
      expect(net.posts, hasLength(1));
    });

    test("without the app API: the popup's handlers", () async {
      final net = _Transport()..postAnswer = (_, _) => _text('ajax_wall_posted.xml');
      final posted = await net.repository().postWall(session, 35, 'x');
      expect(posted.outcome, SpaceWriteOutcome.done);
      expect(posted.message, '操作成功');
      net.postAnswer = (_, _) => _text('ajax_poke_form_self.xml');
      final refused = await net.repository().postWall(session, 35, 'x');
      expect(refused.outcome, SpaceWriteOutcome.rejected);
      expect(refused.message, '不能向自己打招呼');
      net.postAnswer = (_, _) => '<html></html>';
      expect((await net.repository().postWall(session, 35, 'x')).outcome, SpaceWriteOutcome.unconfirmed);
    });
  });

  group('greetings', () {
    test('the form: the greetings the forum offers, the one it checked, the member greeted', () {
      final page = parsePokeForm(parseHtmlDocument(_text('poke_form.html')), reply: false);
      final form = page.form!;
      expect(form.uid, 31);
      expect(form.targetUid, 35);
      expect(form.targetName, '测试会员乙');
      expect(form.formHash, 'f1f2f3f4');
      expect(form.icons, hasLength(14));
      expect(form.icons.first.id, '0');
      expect(form.icons.first.label, '不用动作');
      expect(form.icons.first.imageUrl, isNull);
      expect(form.icons[2].label, '握个手');
      expect(form.icons[2].imageUrl, '$baseUrl/static/image/poke/wgs.gif');
      expect(form.selected, '3');
    });

    test('the form refused: the account itself, a guest', () {
      final self = parsePokeForm(parseHtmlDocument(_text('poke_form_self.html')), reply: false);
      expect(self.form, isNull);
      expect(self.message, '不能向自己打招呼');
      expect(self.needLogin, isFalse);
      final guest = parsePokeForm(parseHtmlDocument(_text('poke_form_guest.html')), reply: false);
      expect(guest.form, isNull);
      expect(guest.needLogin, isTrue);
    });

    test('loading the form: for the account it was served to only', () async {
      final net = _Transport()..page = _text('poke_form.html');
      final repo = net.repository();
      final load = await repo.loadPokeForm(35);
      expect(load.kind, SpaceFormLoadKind.ready);
      expect(net.gets.single, startsWith('$baseUrl/home.php?mod=spacecp&ac=poke&op=send&uid=35'));
      expect(net.gets.single, contains('tsdmapp=json'));
      net.page = _text('poke_form_self.html');
      final self = await repo.loadPokeForm(31);
      expect(self.kind, SpaceFormLoadKind.denied);
      expect(self.message, '不能向自己打招呼');
      net.page = _text('poke_form_guest.html');
      expect((await repo.loadPokeForm(35)).kind, SpaceFormLoadKind.loginRequired);
      final other = _Transport(uid: 33)..page = _text('poke_form.html');
      expect((await other.repository().loadPokeForm(35)).kind, SpaceFormLoadKind.identityChanged);
      expect(net.posts, isEmpty);
    });

    test('a greeting, and one back, sent once', () async {
      final net = _Transport()
        ..page = _text('poke_form.html')
        ..postAnswer = (_, _) => _text('result_poke_sent.json');
      final repo = net.repository();
      final form = (await repo.loadPokeForm(35)).form!;
      final result = await repo.sendPoke(form, '2', ' 你好 ');
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(result.message, '已发送，测试会员乙下次访问时会收到通知');
      final (url, body) = net.posts.single;
      expect(url, '$baseUrl/home.php?mod=spacecp&ac=poke&op=send&uid=35&inajax=1');
      expect(body, {
        'formhash': 'f1f2f3f4',
        'pokesubmit': 'true',
        'iconid': '2',
        'note': '你好',
        'from': '',
        'handlekey': 'propokehk_35',
      });
      final back = (await repo.loadPokeForm(35, reply: true)).form!;
      expect(back.reply, isTrue);
      expect(net.gets.last, startsWith('$baseUrl/home.php?mod=spacecp&ac=poke&op=reply&uid=35'));
      net.postAnswer = (_, _) => _text('result_poke_replied.json');
      expect((await repo.sendPoke(back, '0', '')).outcome, SpaceWriteOutcome.done);
      expect(net.posts.last.$1, '$baseUrl/home.php?mod=spacecp&ac=poke&op=reply&uid=35&inajax=1');
      expect(net.posts.last.$2['handlekey'], 'pokereply');
      net.postAnswer = (_, _) => _text('result_poke_self.json');
      final self = await repo.sendPoke(form, '1', '');
      expect(self.outcome, SpaceWriteOutcome.rejected);
      expect(self.message, '不能向自己打招呼');
      net.uid = 33;
      expect((await repo.sendPoke(form, '1', '')).outcome, SpaceWriteOutcome.identityChanged);
      expect(net.posts, hasLength(3));
    });

    test('the greetings received: who, the greeting, when; the session of the list', () {
      final page = parseReceivedPokePage(parseHtmlDocument(_text('poke_list.html')));
      expect(page.items.map((e) => e.uid), [33, 31]);
      final hug = page.items.first;
      expect(hug.username, '测试会员丙');
      expect(hug.time, '11-10 12:12');
      expect(hug.content.text, contains('拥抱, 说: SOCIAL 抱一下'));
      expect(hug.content.text, isNot(contains('12:12')));
      expect(hug.content.querySelector('img')?.attributes['src'], 'static/image/poke/yb.gif');
      expect(page.items.last.avatarUrl, 'https://forum.test/data/avatar/000/00/00/31_avatar_small.jpg');
      expect(page.session?.uid, 35);
      expect(page.session?.formHash, 'f1f2f3f4');
      expect(page.message, isNull);
      final empty = parseReceivedPokePage(parseHtmlDocument(_text('poke_list_empty.html')));
      expect(empty.items, isEmpty);
      expect(empty.message, isNull);
      expect(empty.needLogin, isFalse);
      expect(empty.session?.uid, 35);
    });

    test('ignore one, ignore all', () async {
      final net = _Transport(uid: 35)..postAnswer = (_, _) => _text('result_poke_ignored.json');
      final repo = net.repository();
      const session = SpaceSession(uid: 35, formHash: 'f1f2f3f4');
      final one = await repo.ignorePokes(session, uid: 33);
      expect(one.outcome, SpaceWriteOutcome.done);
      expect(one.message, '招呼已忽略');
      expect(net.posts.single.$1, '$baseUrl/home.php?mod=spacecp&ac=poke&op=ignore&uid=33&inajax=1');
      expect(net.posts.single.$2, {'formhash': 'f1f2f3f4', 'ignoresubmit': 'true', 'handlekey': 'pokeignore'});
      net.postAnswer = (_, _) => _text('result_poke_ignored_all.json');
      expect((await repo.ignorePokes(session)).outcome, SpaceWriteOutcome.done);
      expect(net.posts.last.$1, '$baseUrl/home.php?mod=spacecp&ac=poke&op=ignore&inajax=1');
      expect(net.posts.last.$2['handlekey'], 'allignore');
    });
  });

  group('links and notices', () {
    test('a wall link opens the wall tab, with its one message', () {
      final route = 'home.php?mod=space&uid=35&do=wall&cid=30&goto=new#comment_30_li'.prependHost().parseUrlToRoute();
      expect(route?.screenPath, ScreenPaths.space);
      expect(route?.queryParameters, {'uid': '35', 'tab': 'wall', 'cid': '30'});
      final own = '$baseUrl/home.php?mod=space&do=wall'.parseUrlToRoute();
      expect(own?.screenPath, ScreenPaths.space);
      expect(own?.queryParameters, {'tab': 'wall'});
      expect('$baseUrl/home.php?mod=space&uid=35&do=wall&from=space'.parseUrlToRoute()?.queryParameters, {
        'uid': '35',
        'tab': 'wall',
      });
    });

    test('the links of a poke notice open the greetings received; a greeting to a member, their profile', () {
      for (final op in ['', '&op=reply&uid=33&from=notice', '&op=ignore&uid=33&from=notice']) {
        expect('$baseUrl/home.php?mod=spacecp&ac=poke$op'.parseUrlToRoute()?.screenPath, ScreenPaths.spacePokes);
      }
      final send = '$baseUrl/home.php?mod=spacecp&ac=poke&op=send&uid=31'.parseUrlToRoute();
      expect(send?.screenPath, ScreenPaths.profile);
      expect(send?.queryParameters, {'uid': '31'});
    });

    test('a tap on a wall notice opens its message, on a poke notice the greetings received', () {
      final notices = (jsonDecode(_text('notices.json')) as List<dynamic>).cast<Map<String, dynamic>>();
      NoticeInfo info(Map<String, dynamic> n) => NoticeInfo.of(
        NoticeV2(
          id: 1,
          timestamp: 1700000000,
          data: n['note'] as String,
          ignoreType: n['type'] as String,
          authorId: n['authorid'] as int,
          fromIdType: n['from_idtype'] as String,
        ),
      );
      final wallNotice = notices.firstWhere((e) => e['type'] == 'wall');
      final wall = info(wallNotice);
      expect(wall.kind, NoticeKind.wall);
      final url = noticeTapUrlOf(wall, wallNotice['note'] as String);
      expect(url, '$baseUrl/home.php?mod=space&uid=35&do=wall&cid=57&goto=new#comment_57_li');
      expect(url!.parseUrlToRoute()?.queryParameters, {'uid': '35', 'tab': 'wall', 'cid': '57'});

      final pokeNotice = notices.firstWhere((e) => e['type'] == 'poke');
      final poke = info(pokeNotice);
      expect(poke.kind, NoticeKind.poke);
      expect(noticeTapUrlOf(poke, pokeNotice['note'] as String)?.parseUrlToRoute()?.screenPath, ScreenPaths.spacePokes);

      // A friend notice still opens the friend's profile.
      const friendBody = '<a href="home.php?mod=space&uid=33">测试会员丙</a> 和您成为了好友';
      final friend = NoticeInfo.of(
        const NoticeV2(id: 3, timestamp: 1700000000, data: friendBody, ignoreType: 'friend', authorId: 33),
      );
      expect(noticeTapUrlOf(friend, friendBody), '$baseUrl/home.php?mod=space&uid=33');
    });
  });

  testWidgets('a message of the wall lays out with its actions at the end of the line, a long name cut', (
    tester,
  ) async {
    final comment = _wall('wall_own').items.first;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: SpaceBlogCommentTile(
                SpaceBlogComment(
                  cid: comment.cid,
                  author: '很长很长很长很长很长很长很长很长很长很长的名字',
                  message: comment.message,
                  time: comment.time,
                ),
                trailing: const Icon(Icons.more_vert, key: ValueKey('actions')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final actions = tester.getRect(find.byKey(const ValueKey('actions')));
    expect(actions.right, closeTo(320, 0.5));
    expect(find.text(comment.time!), findsOneWidget);
  });

  testWidgets('a dialog opened from the menu of a message stays open once the menu is closed', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: WallMessageActions(
                  onReply: () async => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(title: Text('reply')),
                  ),
                  onDelete: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.reply_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('reply'), findsOneWidget);
  });
}
