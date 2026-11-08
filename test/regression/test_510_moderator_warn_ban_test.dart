/// A moderator bans the author of a floor from posting (the moderation panel's 禁止用户), sees the floors warned, and
/// is offered only the floor operations the forum offers the account.
///
/// The fixtures `test/data/moderate/member_ban_*` and `thread_*` are the test forum's answers to a moderator (Discuz!
/// X5 with plugin tsdmapp 3.4.0), scrubbed: the panel's ban page `forum.php?mod=modcp&action=member&op=ban&uid=UID`
/// cut to its main column for a member in good standing and for a banned one, its refusal of a member of a special
/// group, the answers to a ban sent (with `tsdmapp=json`: the success, the refusal, the panel's login form after its
/// session ended; without: the 提示信息 page); a warned floor of the web page and the same floor of the app API's
/// thread answer; the moderator's floor menu `div#mdly` of the thread page.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/floor_moderate_dialog.dart';
import 'package:tsdm_client/features/moderate/widgets/member_ban_dialog.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/moderate';
const _member = 42;
const _uid = 31;
const _fid = 10;

String _text(String name) => File('$_dir/$name').readAsStringSync();

Object? _data(String name) {
  final text = _text(name);
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

ModerateResponse _ok(Object? data) => (statusCode: 200, data: data);

Either<AppException, MemberBanWindow> _windowOf(String name, {int member = _member, int uid = _uid}) =>
    ModerateRepository.memberBanWindowOf(_data(name), memberUid: member, uid: uid);

MemberBanForm _window(String name) => switch (_windowOf(name)) {
  Right(value: MemberBanWindowReady(:final form)) => form,
  final other => throw StateError('no window: $other'),
};

Either<AppException, MemberBanOutcome> _outcomeOf(String name, {int uid = _uid}) =>
    ModerateRepository.memberBanOutcomeOf(_data(name), uid: uid);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('ban window', () {
    test('a member in good standing: the ban from posting, for some days or for ever', () {
      final form = _window('member_ban_form.html');
      expect(form.banned, isFalse);
      expect(form.uid, _uid);
      // The hidden fields of the window, not the uid box of the panel's search form before it.
      expect(form.fields, {'formhash': 'f1f2f3f4', 'username': '', 'uid': '42'});
      expect(form.body(days: 3, reason: ' 灌水 '), {
        'formhash': 'f1f2f3f4',
        'username': '',
        'uid': '42',
        'bannew': '4',
        'banexpirynew': '3',
        'reason': '灌水',
        'bansubmit': 'true',
      });
      expect(form.body()['banexpirynew'], '');
      expect(memberBanDays, [1, 3, 7, 30, null]);
    });

    test('a banned member: lifting the ban, no days', () {
      final form = _window('member_ban_form_banned.html');
      expect(form.banned, isTrue);
      final body = form.body(days: 7, reason: '解除');
      expect(body['bannew'], '0');
      expect(body['banexpirynew'], '');
      expect(body['reason'], '解除');
    });

    test('the window of another member is no window of this one', () {
      expect(_windowOf('member_ban_form.html', member: 43).getRight().toNullable(), isA<MemberBanWindowRefused>());
    });

    test('neither the ban nor its lifting offered: no window', () {
      final html = _text('member_ban_form.html').replaceAll(RegExp('<label for="bannew_4"[^\n]*</label>'), '');
      expect(
        ModerateRepository.memberBanWindowOf(html, memberUid: _member, uid: _uid).getRight().toNullable(),
        isA<MemberBanWindowRefused>(),
      );
    });

    test('the panel refuses a member of a special group in its words', () {
      final answer = _windowOf('member_ban_illegal.html').getRight().toNullable();
      expect(answer, isA<MemberBanWindowRefused>());
      expect((answer! as MemberBanWindowRefused).message, '您不能直接禁止该用户');
    });

    test('the panel asks the password, or refuses an account that has no access', () {
      final login = _windowOf('queue_login.html').getRight().toNullable();
      expect(login, isA<MemberBanNeedsLogin>());
      expect((login! as MemberBanNeedsLogin).formHash, 'f1f2f3f4');
      final refused = _windowOf('queue_noaccess.html').getRight().toNullable();
      expect((refused! as MemberBanWindowRefused).message, contains('没有权限访问管理面板'));
    });

    test('a page served to another account', () {
      expect(_windowOf('member_ban_form.html', uid: 35).getLeft().toNullable(), isA<IdentityChangedException>());
    });
  });

  group('ban verdict', () {
    test('the app API: success and refusal are told by the alert, not by a message key (there is none)', () {
      final done = _outcomeOf('member_ban_result_succeed.json').getRight().toNullable();
      expect(done, isA<MemberBanDone>());
      expect((done! as MemberBanDone).message, '用户资料成功更新');
      final refused = _outcomeOf('member_ban_result_refused.json').getRight().toNullable();
      expect((refused! as MemberBanRefused).message, '您不能直接禁止该用户');
    });

    test('the panel login form after its session ended is never a success, though the plugin calls it ok', () {
      final json = _data('member_ban_result_login.json')! as Map<String, dynamic>;
      expect(json['ok'], 1);
      final answer = _outcomeOf('member_ban_result_login.json').getRight().toNullable();
      expect(answer, isA<MemberBanSessionEnded>());
      expect((answer! as MemberBanSessionEnded).formHash, 'f1f2f3f4');
    });

    test('a page that is no login form is a refusal without words', () {
      final json = _data('member_ban_result_login.json')! as Map<String, dynamic>;
      final page = {...json, 'document': '<div class="mn"><p>?</p></div>'};
      expect(ModerateRepository.memberBanOutcomeOf(page, uid: _uid).getRight().toNullable(), isA<MemberBanRefused>());
    });

    test('a redirect back to the ban page is a success; elsewhere is not', () {
      final json = _data('member_ban_result_succeed.json')! as Map<String, dynamic>;
      final back = {...json, 'kind': 'redirect', 'message': '', 'alert': ''};
      expect(ModerateRepository.memberBanOutcomeOf(back, uid: _uid).getRight().toNullable(), isA<MemberBanDone>());
      final away = {...back, 'url': 'forum.php?mod=modcp&action=home'};
      expect(ModerateRepository.memberBanOutcomeOf(away, uid: _uid).getRight().toNullable(), isA<MemberBanRefused>());
    });

    test('without the plugin: the 提示信息 page, by its class', () {
      expect(_outcomeOf('member_ban_result_succeed.html').getRight().toNullable(), isA<MemberBanDone>());
      final refused = _outcomeOf('member_ban_illegal.html').getRight().toNullable();
      expect((refused! as MemberBanRefused).message, '您不能直接禁止该用户');
      expect(_outcomeOf('queue_login.html').getRight().toNullable(), isA<MemberBanSessionEnded>());
    });

    test('an answer for another account', () {
      expect(
        _outcomeOf('member_ban_result_succeed.json', uid: 35).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
      expect(
        _outcomeOf('member_ban_result_succeed.html', uid: 35).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
    });
  });

  group('ban requests', () {
    test('the window is asked for the member; the ban is posted once with the app API asked', () async {
      final gets = <String>[];
      final posts = <(String, Map<String, String>)>[];
      final repo = ModerateRepository(
        get: (url) async {
          gets.add(url);
          return right(_ok(_data('member_ban_form.html')));
        },
        post: (url, body) async {
          posts.add((url, body));
          return right(_ok(_data('member_ban_result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      final window = await repo.fetchMemberBanWindow(_member).run();
      expect(gets.single, endsWith('forum.php?mod=modcp&action=member&op=ban&uid=42'));
      final form = (window.getRight().toNullable()! as MemberBanWindowReady).form;
      final outcome = await repo.submitMemberBan(form, days: 30, reason: '广告').run();
      expect(outcome.getRight().toNullable(), isA<MemberBanDone>());
      expect(posts.single.$1, contains('mod=modcp&action=member&op=ban'));
      expect(posts.single.$1, contains('tsdmapp=json'));
      expect(posts.single.$2['banexpirynew'], '30');
      expect(posts.single.$2['bannew'], '4');
    });

    test('nothing is posted once the account changed; a redirect answered is a success', () async {
      var uid = _uid;
      var posted = 0;
      final repo = ModerateRepository(
        get: (_) async => right(_ok(_data('member_ban_form.html'))),
        post: (_, _) async {
          posted++;
          return right((statusCode: 302, data: ''));
        },
        currentUid: () => uid,
      );
      final form = _window('member_ban_form.html');
      expect((await repo.submitMemberBan(form).run()).getRight().toNullable(), isA<MemberBanDone>());
      uid = 35;
      expect((await repo.submitMemberBan(form).run()).getLeft().toNullable(), isA<IdentityChangedException>());
      expect(posted, 1);
    });
  });

  group('floors', () {
    test('the web page: the warned mark of the header and the ban link of the author column', () {
      final doc = parseHtmlDocument(_text('thread_floor_warned.html'));
      final post = Post.fromPostNode(doc.querySelector('div#post_7654321')!, 1)!;
      expect(post.warned, isTrue);
      expect(post.banAuthorUid, _member);

      final plain = _text('thread_floor_warned.html')
          .replaceAll(RegExp(r'<a href="forum.php\?mod=misc&amp;action=viewwarning[^>]*></a>'), '')
          .replaceAll(RegExp(r'<a href="forum.php\?mod=modcp&amp;action=member&amp;op=ban[^>]*>禁止</a>'), '');
      final other = Post.fromPostNode(parseHtmlDocument(plain).querySelector('div#post_7654321')!, 1)!;
      expect(other.warned, isFalse);
      expect(other.banAuthorUid, isNull);
    });

    test('the app API: the ban link of the author column; no warned mark (the answer does not tell)', () {
      final floor = _data('thread_floor_api.json')! as Map<String, dynamic>;
      final post = Post.fromApi(floor, tid: '1234567', fid: _fid, viewerUid: _uid, page: 1);
      expect(post.banAuthorUid, _member);
      expect(post.warned, isFalse);
    });

    test("an administrator's ban link to the admin center names the floor's author", () {
      final column = parseHtmlDocument(
        '<td class="pls"><p><a href="admin.php?action=members&operation=ban&username=%E6%B5%8B&frames=yes">禁止</a></p></td>',
      ).body;
      expect(memberBanUidIn(column, authorUid: 42), 42);
      expect(memberBanUidIn(column), isNull);
      final other = parseHtmlDocument(
        '<p><a href="https://example.com/forum.php?mod=modcp&action=member&op=ban&uid=9">x</a></p>',
      );
      expect(memberBanUidIn(other.body, authorUid: 42), isNull);
    });

    test('the floor operations offered are those of the moderator floor menu', () {
      final doc = parseHtmlDocument(_text('thread_floor_menu.html'));
      expect(floorModerateOfferedIn(doc), ['warn', 'banpost', 'delpost']);
      expect(floorModerateOfferedIn(parseHtmlDocument('<p></p>')), isNull);

      expect(floorModerateActionsFor(first: false), [
        FloorModerateAction.warn,
        FloorModerateAction.ban,
        FloorModerateAction.delete,
      ]);
      expect(floorModerateActionsFor(first: false, offered: ['banpost', 'delpost']), [
        FloorModerateAction.ban,
        FloorModerateAction.delete,
      ]);
      expect(floorModerateActionsFor(first: true, offered: ['warn', 'banpost', 'delpost']), [
        FloorModerateAction.warn,
        FloorModerateAction.ban,
      ]);
    });
  });

  group('dialog', () {
    Future<void> open(
      WidgetTester tester,
      ModerateRepository repo, {
      void Function({required bool done})? onClosed,
    }) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    final done = await showMemberBanDialog(context, memberUid: _member, fid: _fid, repository: repo);
                    onClosed?.call(done: done);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the days chosen are sent, once; the dialog stays until the answer', (tester) async {
      final answer = Completer<Either<AppException, ModerateResponse>>();
      final posts = <Map<String, String>>[];
      final repo = ModerateRepository(
        get: (_) async => right(_ok(_data('member_ban_form.html'))),
        post: (_, body) {
          posts.add(body);
          return answer.future;
        },
        currentUid: () => _uid,
      );
      bool? closed;
      await open(tester, repo, onClosed: ({required done}) => closed = done);
      expect(find.text(t.moderate.banMember), findsOneWidget);
      for (final days in [1, 3, 7, 30]) {
        expect(find.text(t.moderate.banDays(days: days)), findsOneWidget);
      }
      await tester.tap(find.text(t.moderate.banDays(days: 7)));
      await tester.enterText(find.byType(TextField), '刷屏');
      await tester.tap(find.text(t.general.ok));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(MemberBanDialog), findsOneWidget);
      answer.complete(right(_ok(_data('member_ban_result_succeed.json'))));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(posts.single['banexpirynew'], '7');
      expect(posts.single['reason'], '刷屏');
    });

    testWidgets('a banned member: lifting it, no days to choose', (tester) async {
      final repo = ModerateRepository(
        get: (_) async => right(_ok(_data('member_ban_form_banned.html'))),
        post: (_, _) async => right(_ok(_data('member_ban_result_succeed.json'))),
        currentUid: () => _uid,
      );
      await open(tester, repo);
      expect(find.text(t.moderate.unbanMember), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets('the panel asks the password: given, the window follows', (tester) async {
      var loggedIn = false;
      final posts = <(String, Map<String, String>)>[];
      final repo = ModerateRepository(
        get: (_) async => right(_ok(_data(loggedIn ? 'member_ban_form.html' : 'queue_login.html'))),
        post: (url, body) async {
          posts.add((url, body));
          loggedIn = true;
          return right((statusCode: 302, data: ''));
        },
        currentUid: () => _uid,
      );
      await open(tester, repo);
      expect(find.text(t.moderate.panelLogin), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'secret');
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single.$1, endsWith('forum.php?mod=modcp&action=login'));
      expect(posts.single.$2['cppwd'], 'secret');
      expect(find.text(t.moderate.banMember), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(memberBanDays.length));
    });
  });
}
