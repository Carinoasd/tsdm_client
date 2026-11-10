/// The moderator's panel, second part: the members (looked up by name or UID, banned from posting or visiting, the
/// profile edited, the banned IPs), the new members waiting for approval, the rules of the forums and the
/// announcements; the tiles of the panel shown as the panel's menu offers them.
///
/// The fixtures `test/data/modcp/{menu,member,ipban,review,rules,announcement}_*` are the test forum's pages and
/// answers (Discuz! X5, plugin tsdmapp 3.7.0) to a moderator (版主), a super moderator and an administrator, cut to
/// the main column and the panel's menu as the other fixtures of the panel, and scrubbed (the accounts renamed, the
/// form hashes, uids and times faked, the forum's address `192.0.2.1`):
///
/// * `menu_moderator.html`, `menu_supermod.html`: the panel's first page, its menu (a moderator: 禁止用户 and 版块编辑
///   only; a super moderator: 禁止 IP, 编辑用户 and 公告 too);
/// * `member_ban_*`: the 禁止用户 page: its search form alone, a name not found (the caption says why), a member of a
///   group that can not be banned (the panel's message), a member banned from visiting with the record of it (lift
///   it, or ban from posting), a member in a normal group to a super moderator (ban from posting or visiting) and to a
///   moderator (ban from posting only); `member_ban_result.json` the plugin's answer to lifting the ban;
/// * `member_edit*`: the 编辑用户 window with a self-introduction and a signature, the caption for staff, the answer to
///   saving it, and the panel's login answered to a save after its session ended (nothing saved);
/// * `ipban_*`: the 禁止 IP list (an IP of the account's, one of an administrator's: not deletable), the page drawn
///   again after adding one (no line printed), after an IP refused (`not-an-ip`) and a range refused, after deleting
///   (the administrator's still listed: the forum keeps it without a word), the moderator's refusal, and the login
///   answered to an add after the session ended;
/// * `review_*`: the new members waiting (registered on the test forum with manual approval on, names `mr_*`; one
///   reason holds `<b>` and `&`, which the panel escapes twice), the plugin's answers to approving one and to a uid
///   that is not waiting, and the list after approving one and deleting another;
/// * `rules_*`: the 版块编辑 rules to an administrator (editable), to a super moderator of a forum not allowing it
///   (locked, the forum's note), the answer to the administrator's save, the answer to the super moderator's save
///   (版规更新成功 printed, the rules kept), and a forum the moderator does not moderate (an empty column);
/// * `announcement_*`: the 公告 list (an administrator's announcement: not deletable to the super moderator), the list
///   after adding one, the forum's refusals (empty, not a link), the form of one, the form after saving it (what was
///   sent) and read again, one not found, the list after deleting one, and the moderator's refusal.
///
/// The panel ends its session after an hour idle: the lists' operations (`moderate[]`, `delete[]`) then fail with a
/// 503, the others answer its login form; nothing is done either way, nothing is sent again.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/announcements_page.dart';
import 'package:tsdm_client/features/moderate/view/forum_rules_page.dart';
import 'package:tsdm_client/features/moderate/view/member_review_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_members_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/modcp';
const _uid = 31;

String _text(String name) => File('$_dir/$name').readAsStringSync();

/// A fixture as dio hands it: a JSON answer decoded, a page as text.
Object? _data(String name) => name.endsWith('.json') ? jsonDecode(_text(name)) : _text(name);

ModerateResponse _ok(Object? data) => (statusCode: 200, data: data);

T _ready<T>(Either<AppException, ModcpAnswer<T>> answer) => switch (answer) {
  Right(value: ModcpReady(:final value)) => value,
  final other => throw StateError('not ready: $other'),
};

ModcpMemberLookup _ban(String name, {String? html}) =>
    _ready(ModcpRepository.memberLookupOf(html ?? _text(name), uid: _uid));

ModcpMemberLookup _edit(String name) => _ready(ModcpRepository.memberLookupOf(_text(name), uid: _uid, edit: true));

IpBanList _ipBans(String name) => parseIpBanList(parseHtmlDocument(_text(name)), uid: _uid)!;

MemberReviewList _review(String name) => parseMemberReview(parseHtmlDocument(_text(name)), uid: _uid)!;

ForumRules _rules(String name) => parseForumRules(parseHtmlDocument(_text(name)), uid: _uid)!;

AnnouncementList _announcements(String name) => parseAnnouncements(parseHtmlDocument(_text(name)), uid: _uid)!;

Translations get t => LocaleSettings.instance.currentTranslations;

/// A transport answering each url with the fixture the test gives (by the end of the url), and keeping what was asked
/// and posted.
final class _Forum {
  _Forum(this.pages, {this.postAnswer});

  final Map<String, String> pages;

  ModerateResponse Function(String url, Map<String, String> body)? postAnswer;

  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  ModcpRepository repository({int Function()? currentUid}) => ModcpRepository(
    get: (url) async {
      gets.add(url);
      for (final MapEntry(:key, :value) in pages.entries) {
        if (url.endsWith(key)) {
          return right(_ok(_data(value)));
        }
      }
      return left(HttpRequestFailedException(404));
    },
    post: (url, body) async {
      posts.add((url, body));
      return right(postAnswer!(url, body));
    },
    currentUid: currentUid ?? () => _uid,
  );
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('the menu', () {
    test("a moderator's and a super moderator's", () {
      final moderator = modcpMenuOf(parseHtmlDocument(_text('menu_moderator.html')))!;
      expect(moderator.canBanMember, isTrue);
      expect(moderator.canEditForum, isTrue);
      expect(moderator.canBanIp, isFalse);
      expect(moderator.canEditMember, isFalse);
      expect(moderator.canAnnounce, isFalse);
      final supermod = modcpMenuOf(parseHtmlDocument(_text('menu_supermod.html')))!;
      expect(
        [supermod.canBanMember, supermod.canBanIp, supermod.canEditMember, supermod.canEditForum, supermod.canAnnounce],
        everyElement(isTrue),
      );
    });

    test('read on the login form too, unless the session is asked', () async {
      final forum = _Forum({'action=home': 'ipban_session_ended.html'});
      final menu = await forum.repository().fetchMenu().run();
      expect(_ready(menu).canBanIp, isTrue);
      final loggedIn = await forum.repository().fetchMenu(loggedIn: true).run();
      expect(loggedIn.getRight().toNullable(), isA<ModcpNeedsLogin<ModcpMenu>>());
    });
  });

  group('members', () {
    test('the search form alone, a name not found, staff', () {
      expect(_ban('member_ban_search.html').member, isNull);
      // Asked without a member: the caption asks for one.
      expect(_ban('member_ban_search.html').note, startsWith('请首先输入用户名或者 UID'));
      expect(_ban('member_ban_notfound.html').note, '该用户不存在或被冻结，请重新输入');
      expect(
        ModcpRepository.memberLookupOf(_text('member_ban_staff.html'), uid: _uid).getRight().toNullable(),
        isA<ModcpRefused<ModcpMemberLookup>>().having((e) => e.message, 'message', '您不能直接禁止该用户'),
      );
      expect(_edit('member_edit_staff.html').note, '管理面板无权操作该用户');
    });

    test('a member banned from visiting: the state, the record, lift or ban from posting', () {
      final lookup = _ban('member_ban_visit.html');
      final member = lookup.member!;
      expect(member.memberUid, 101);
      expect(member.username, 'mr_alpha');
      expect(member.status, startsWith('禁止访问'));
      expect(member.crimes.single.action, '禁止访问');
      expect(member.crimes.single.reason, '測試禁止訪問');
      expect(member.crimes.single.operator, '测试超版');
      expect([for (final c in member.choices) (c.value, c.label)], [('0', '正常状态'), ('4', '禁止发言')]);
      expect(member.form.banned, isTrue);
      expect(lookup.menu.canEditMember, isTrue);
    });

    test("the choices follow the account's group", () {
      expect(_ban('member_ban_supermod.html').member!.choices.map((e) => e.value), ['4', '5']);
      expect(_ban('member_ban_moderator.html').member!.choices.map((e) => e.value), ['4']);
    });

    test('the ban body: the choice, its days, the reason typed (never the signature the window prints there)', () {
      final html = _text('member_ban_supermod.html').replaceFirst(
        RegExp('<textarea name="reason"([^>]*)></textarea>'),
        '<textarea name="reason" class="pt">[b]签名[/b]</textarea>',
      );
      final member = _ban('', html: html).member!;
      final visit = member.choices.firstWhere((e) => e.value == '5');
      expect(member.body(visit, days: 3, reason: ' 广告 '), {
        'formhash': 'f1f2f3f4',
        'username': '',
        'uid': '102',
        'bannew': '5',
        'banexpirynew': '3',
        'reason': '广告',
        'bansubmit': 'true',
      });
      final forever = member.body(member.choices.first);
      expect(forever['banexpirynew'], '');
      expect(forever['reason'], '');
    });

    test('the edit window: both texts, always sent back', () {
      final form = _edit('member_edit.html').edit!;
      expect(form.memberUid, 101);
      expect(form.username, 'mr_alpha');
      expect(form.bio, isNotEmpty);
      expect(form.signature, contains('[b]'));
      final body = form.body(bio: form.bio, signature: '');
      expect(body['bionew'], form.bio);
      expect(body['signaturenew'], '');
      expect(body.containsKey('clearavatar'), isFalse);
      expect(form.body(bio: '', signature: '', clearAvatar: true)['clearavatar'], '1');
    });

    test('a ban sent once, the forum words the result', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_data('member_ban_result.json')));
      final member = _ban('member_ban_visit.html').member!;
      final outcome = await forum.repository().submitMemberBan(member, member.choices.first, reason: '解除').run();
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteDone>().having((e) => e.message, 'message', '用户资料成功更新'),
      );
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$1, contains('op=ban'));
      expect(forum.posts.single.$1, contains('tsdmapp=json'));
      expect(forum.posts.single.$2, containsPair('bannew', '0'));
    });

    test("an edit saved; the panel's login answered: nothing saved", () async {
      final form = _edit('member_edit.html').edit!;
      final saved = _Forum({}, postAnswer: (_, _) => _ok(_data('member_edit_result.json')));
      expect(
        (await saved.repository().submitMemberEdit(form, bio: '', signature: '').run()).getRight().toNullable(),
        isA<ModcpWriteDone>(),
      );
      final ended = _Forum({}, postAnswer: (_, _) => _ok(_data('member_edit_session_ended.json')));
      expect(
        (await ended.repository().submitMemberEdit(form, bio: '', signature: '').run()).getRight().toNullable(),
        isA<ModcpWriteSessionEnded>(),
      );
    });

    test('never sent once the account changed', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_data('member_ban_result.json')));
      final member = _ban('member_ban_visit.html').member!;
      final outcome = await forum.repository(currentUid: () => 99).submitMemberBan(member, member.choices.first).run();
      expect(outcome.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(forum.posts, isEmpty);
    });
  });

  group('banned IPs', () {
    test('the list: the account deletes its own only', () {
      final list = _ipBans('ipban_list.html');
      expect(
        [for (final e in list.entries) (e.id, e.ip, e.deletable)],
        [
          ('3', '192.0.2.200', false),
          ('1', '192.0.2.55', true),
        ],
      );
      expect(list.entries.last.admin, '测试超版');
      expect(list.message, isEmpty);
      expect(list.addBody('192.0.2.9 ', 7), {
        'formhash': 'f1f2f3f4',
        'ipnew': '192.0.2.9',
        'validitynew': '7',
        'ipbansubmit': 'true',
      });
      expect(list.deleteBody(['1']).keys, isNot(contains(startsWith('expirationnew'))));
      expect(
        ModcpRepository.memberLookupOf(_text('ipban_noperm.html'), uid: _uid).getRight().toNullable(),
        isA<ModcpRefused<ModcpMemberLookup>>().having((e) => e.message, 'message', contains('抱歉，您无此权限')),
      );
    });

    test('added: a new ban of it listed, though the panel says nothing', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('ipban_add_result.html')));
      final outcome = await forum.repository().addIpBan(_ipBans('ipban_list.html'), '203.0.113.9', 7).run();
      expect(outcome.getRight().toNullable(), isA<ModcpWriteDone>());
      expect(forum.posts, hasLength(1));
    });

    test("refused: the panel's line", () async {
      for (final (name, words) in [
        ('ipban_add_error.html', '请输入标准 IP 地址'),
        ('ipban_add_cidr.html', '新增 IP 地址失败，该 IP 地址范围包含您目前的 IP'),
      ]) {
        final forum = _Forum({}, postAnswer: (_, _) => _ok(_text(name)));
        final outcome = await forum.repository().addIpBan(_ipBans('ipban_list.html'), 'not-an-ip', 7).run();
        expect(outcome.getRight().toNullable(), isA<ModcpWriteRefused>().having((e) => e.message, 'message', words));
      }
    });

    test("deleted: what is still listed was not done (another admin's)", () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('ipban_delete_result.html')));
      final outcome = await forum.repository().deleteIpBans(_ipBans('ipban_add_result.html'), ['4', '3']).run();
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteNotDone>().having((e) => e.remaining, 'remaining', ['3']).having((e) => e.done, 'done', 1),
      );
    });

    test('the session ended: its login (nothing done), or a 503, never sent again', () async {
      final login = _Forum({}, postAnswer: (_, _) => _ok(_text('ipban_session_ended.html')));
      expect(
        (await login.repository().addIpBan(_ipBans('ipban_list.html'), '192.0.2.99', 1).run()).getRight().toNullable(),
        isA<ModcpWriteSessionEnded>(),
      );
      final failed = _Forum({}, postAnswer: (_, _) => (statusCode: 503, data: 'System Error'));
      final outcome = await failed.repository().deleteIpBans(_ipBans('ipban_list.html'), ['1']).run();
      expect(outcome.getLeft().toNullable(), isA<HttpRequestFailedException>());
      expect(failed.posts, hasLength(1));
    });
  });

  group('new members', () {
    test('the list: name, time, IP, reason as the panel prints it', () {
      final list = _review('review_list.html');
      expect(list.items.map((e) => e.username), ['mr_golf', 'mr_delta', 'mr_foxtrot', 'mr_bravo', 'mr_charlie']);
      final delta = list.items[1];
      expect(delta.id, '91');
      expect(delta.regDate, '2026-11-10 11:30');
      expect(delta.regIp, '192.0.2.1');
      // The forum escapes the reason twice: shown as the website shows it.
      expect(delta.reason, '多行理由&lt;b&gt;粗&lt;/b&gt; &amp; 符號');
      expect(list.items.every((e) => e.canDelete), isTrue);
      expect(list.formHash, 'f1f2f3f4');
      expect(list.body(MemberReviewAction.ignore, ['91', '92'], reason: ' 不符 '), {
        'formhash': 'f1f2f3f4',
        'filter': '0',
        'modact': 'ignore',
        'modsubmit': '1',
        'moderate[0]': '91',
        'moderate[1]': '92',
        'reason': '不符',
      });
    });

    test('approved: the list read again no longer has it; one still waiting was not done', () async {
      final forum = _Forum(
        {'op=members&filter=0': 'review_after.html'},
        postAnswer: (_, _) => _ok(_data('review_result.json')),
      );
      final list = _review('review_list.html');
      final done = await forum.repository().submitMemberReview(list, MemberReviewAction.validate, ['93']).run();
      expect(done.getRight().toNullable(), isA<ModcpWriteDone>().having((e) => e.count, 'count', 1));
      expect(forum.posts.single.$1, contains('op=members'));
      final partly = await forum.repository().submitMemberReview(list, MemberReviewAction.validate, ['93', '91']).run();
      expect(partly.getRight().toNullable(), isA<ModcpWriteNotDone>().having((e) => e.remaining, 'remaining', ['91']));
    });

    test("refused in the forum's words: the list not read again; a 503 not sent again", () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_data('review_invalid.json')));
      final outcome = await forum.repository().submitMemberReview(
        _review('review_list.html'),
        MemberReviewAction.validate,
        ['87'],
      ).run();
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteRefused>().having((e) => e.message, 'message', '审核失败, 尚未找到相应的用户'),
      );
      expect(forum.gets, isEmpty);
      final failed = _Forum({}, postAnswer: (_, _) => (statusCode: 503, data: 'System Error'));
      final lost = await failed.repository().submitMemberReview(
        _review('review_list.html'),
        MemberReviewAction.delete,
        ['92'],
      ).run();
      expect(lost.getLeft().toNullable(), isA<HttpRequestFailedException>());
      expect(failed.posts, hasLength(1));
      expect(failed.gets, isEmpty);
    });
  });

  group('rules', () {
    test('editable, locked with the forum note, a forum not moderated', () {
      final editable = _rules('rules_editable.html');
      expect(editable.fid, 9);
      expect(editable.editable, isTrue);
      expect(editable.forums.length, greaterThan(1));
      final locked = _rules('rules_readonly.html');
      expect(locked.editable, isFalse);
      expect(locked.rules, '[b]版主改的規則[/b]');
      expect(locked.note, '抱歉，您所在的用户组不允许修改版规！');
      expect(_rules('rules_notmoderated.html').fid, 0);
      expect(editable.body('x'), {'formhash': 'f1f2f3f4', 'fid': '9', 'rulesnew': 'x', 'editsubmit': 'true'});
    });

    test('saved: the editor drawn again holds it', () async {
      const text = '[b]本版規則[/b]\r\n1. 不要洗版\r\n[url=https://example.com]說明[/url]';
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('rules_saved.html')));
      final outcome = await forum.repository().saveForumRules(_rules('rules_editable.html'), text).run();
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteDone>().having((e) => e.message, 'message', contains('版规更新成功')),
      );
      // The forum turns some BBCode around (a tab to spaces, `[s]`, lists): its line tells.
      final turned = await forum.repository().saveForumRules(_rules('rules_editable.html'), '[s]x[/s]').run();
      expect(turned.getRight().toNullable(), isA<ModcpWriteDone>());
      // The editor drawn again without the line nor the text: nothing tells.
      final silent = _Forum({}, postAnswer: (_, _) => _ok(_text('rules_editable.html')));
      final unknown = await silent.repository().saveForumRules(_rules('rules_editable.html'), 'x').run();
      expect(unknown.getRight().toNullable(), isA<ModcpWriteUnknown>());
    });

    test('版规更新成功 printed, the rules kept: refused with the note', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('rules_denied.html')));
      final outcome = await forum.repository().saveForumRules(_rules('rules_readonly.html'), '不會生效').run();
      expect(
        outcome.getRight().toNullable(),
        isA<ModcpWriteRefused>().having((e) => e.message, 'message', '抱歉，您所在的用户组不允许修改版规！'),
      );
    });
  });

  group('announcements', () {
    test("the list: the others' not deletable; the blank form's dates", () {
      final list = _announcements('announcement_list.html');
      expect([for (final e in list.items) (e.id, e.deletable)], [('4', false), ('3', true)]);
      expect(list.items.first.author, '测试管理员');
      expect(list.blank!.id, 0);
      expect(list.blank!.start, isNotEmpty);
      final body = list.deleteBody(['3']);
      expect(body, {'formhash': 'f1f2f3f4', 'delete[0]': '3', 'submit': 'true'});
      expect(
        ModcpRepository.memberLookupOf(_text('announcement_noperm.html'), uid: _uid).getRight().toNullable(),
        isA<ModcpRefused<ModcpMemberLookup>>(),
      );
    });

    test('the form of one; one not found', () {
      final form = parseAnnouncementForm(parseHtmlDocument(_text('announcement_edit.html')), id: 5, uid: _uid)!;
      expect(form.subject, '第二則公告');
      expect(form.type, AnnouncementType.text);
      expect(form.message, '[b]內容[/b]\n第二行');
      expect(form.body(subject: 'a', type: AnnouncementType.link, start: '', end: '', message: 'https://x\n'), {
        'formhash': 'f1f2f3f4',
        'id': '5',
        'displayorder': '0',
        'subject': 'a',
        'type': '1',
        'starttime': '',
        'endtime': '',
        'message[0]': '',
        'message[1]': 'https://x',
        'submit': 'true',
      });
      expect(form.submitUrl, endsWith('op=edit'));
      expect(
        ModcpRepository.answerOf(
          _text('announcement_edit_notfound.html'),
          uid: _uid,
          read: (doc, uid) => parseAnnouncementForm(doc, id: 999, uid: uid),
        ).getRight().toNullable(),
        isA<ModcpRefused<AnnouncementForm>>().having((e) => e.message, 'message', '抱歉，该公告已删除或您没有权限编辑它'),
      );
    });

    test('added: a new one listed; refused in its words', () async {
      final blank = _announcements('announcement_list.html').blank!;
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('announcement_add_result.html')));
      final outcome = await forum
          .repository()
          .submitAnnouncement(
            blank,
            subject: '第二則公告',
            type: AnnouncementType.text,
            start: '2026-11-10',
            end: '2026-12-10',
            message: '[b]內容[/b]\n第二行',
            known: {'4', '3'},
          )
          .run();
      expect(outcome.getRight().toNullable(), isA<ModcpWriteDone>());
      expect(forum.posts.single.$1, endsWith('op=add'));
      for (final (name, words) in [
        ('announcement_add_empty.html', '您必须输入公告标题和内容'),
        ('announcement_add_urlerror.html', '网址链接无效'),
      ]) {
        final refused = _Forum({}, postAnswer: (_, _) => _ok(_text(name)));
        final answer = await refused
            .repository()
            .submitAnnouncement(
              blank,
              subject: 'x',
              type: AnnouncementType.link,
              start: '',
              end: '',
              message: 'example.com',
              known: {'4', '3'},
            )
            .run();
        expect(answer.getRight().toNullable(), isA<ModcpWriteRefused>().having((e) => e.message, 'message', words));
      }
    });

    test('edited: the form read again holds what was sent', () async {
      final form = parseAnnouncementForm(parseHtmlDocument(_text('announcement_edit.html')), id: 5, uid: _uid)!;
      Future<Either<AppException, ModcpWriteOutcome>> edit(String after) =>
          _Forum(
                {'op=edit&id=5': after},
                postAnswer: (_, _) => _ok(_text('announcement_edit_result.html')),
              )
              .repository()
              .submitAnnouncement(
                form,
                subject: '第二則公告（改）',
                type: AnnouncementType.text,
                start: '2026-11-11',
                end: '2026-12-31',
                message: '改過的內容',
              )
              .run();
      expect((await edit('announcement_edit_after.html')).getRight().toNullable(), isA<ModcpWriteDone>());
      expect((await edit('announcement_edit.html')).getRight().toNullable(), isA<ModcpWriteRefused>());
    });

    test('the dates compared where the forum keeps them as sent', () {
      final form = parseAnnouncementForm(parseHtmlDocument(_text('announcement_edit_after.html')), id: 5, uid: _uid)!;
      bool holds(String start, String end) => form.holds(
        subject: '第二則公告（改）',
        type: AnnouncementType.text,
        message: '改過的內容',
        start: start,
        end: end,
        today: DateTime(2026, 11, 9),
      );
      expect(holds('2026-11-11', '2026-12-31'), isTrue);
      expect(holds('2026-11-12', '2026-12-31'), isFalse);
      expect(holds('2026-11-11', '2027-01-31'), isFalse);
      // A start not after today, an end before the start: the forum sets its own.
      expect(holds('2026-11-01', '2026-11-05'), isTrue);
      // Tomorrow is within the day of margin: not compared, whatever the form holds.
      expect(holds('2026-11-10', '2026-12-31'), isTrue);
    });

    test('deleted: no longer listed', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('announcement_delete_result.html')));
      final list = _announcements('announcement_add_result.html');
      final outcome = await forum.repository().deleteAnnouncements(list, ['5']).run();
      expect(outcome.getRight().toNullable(), isA<ModcpWriteDone>());
      expect(forum.posts.single.$2.keys.where((e) => e.startsWith('order')), isEmpty);
    });
  });

  group('pages', () {
    testWidgets("the panel's tiles: as the menu offers them, all when it could not be read", (tester) async {
      await _pumpPage(
        tester,
        ModeratorPanelPage(key: UniqueKey(), repository: _Forum({'action=home': 'menu_moderator.html'}).repository()),
      );
      for (final key in ['modcp-queue', 'modcp-members', 'modcp-member-review', 'modcp-rules']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('modcp-announcements')), findsNothing);

      await _pumpPage(
        tester,
        ModeratorPanelPage(key: UniqueKey(), repository: _Forum({'action=home': 'menu_supermod.html'}).repository()),
      );
      expect(find.byKey(const ValueKey('modcp-announcements')), findsOneWidget);

      await _pumpPage(tester, ModeratorPanelPage(key: UniqueKey(), repository: _Forum({}).repository()));
      for (final key in ['modcp-members', 'modcp-rules', 'modcp-announcements']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a member looked up by name, banned from posting once, looked up again', (tester) async {
      final forum = _Forum(
        {'action=home': 'menu_supermod.html', 'op=ban&username=mr_alpha': 'member_ban_visit.html'},
        postAnswer: (_, _) => _ok(_data('member_ban_result.json')),
      );
      await _pumpPage(tester, ModcpMembersPage(repository: forum.repository()));
      expect(find.byKey(const ValueKey('modcp-ipban')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('modcp-member-query')), 'mr_alpha');
      await tester.tap(find.byKey(const ValueKey('modcp-member-search')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byKey(const ValueKey('modcp-member-101')), matching: find.text('mr_alpha')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('modcp-ban-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-member-edit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modcp-ban-4')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-ban-reason')), '广告');
      await tester.tap(find.byKey(const ValueKey('modcp-ban-confirm')));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$2, containsPair('bannew', '4'));
      expect(forum.posts.single.$2, containsPair('banexpirynew', '1'));
      expect(forum.posts.single.$2, containsPair('reason', '广告'));
      expect(forum.gets.where((e) => e.endsWith('username=mr_alpha')), hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a moderator: no banned IPs, no profile editing', (tester) async {
      final forum = _Forum({'action=home': 'menu_moderator.html', 'op=ban&uid=102': 'member_ban_moderator.html'});
      await _pumpPage(tester, ModcpMembersPage(repository: forum.repository()));
      expect(find.byKey(const ValueKey('modcp-ipban')), findsNothing);
      await tester.tap(find.text(t.modcp.byUid));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('modcp-member-query')), '102');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-ban-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-ban-5')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-member-edit')), findsNothing);
    });

    testWidgets('a member the ban page refuses: still found on the edit page, its refusal shown', (tester) async {
      final forum = _Forum({
        'action=home': 'menu_supermod.html',
        'op=ban&uid=101': 'member_ban_staff.html',
        'op=edit&uid=101': 'member_edit.html',
      });
      await _pumpPage(tester, ModcpMembersPage(repository: forum.repository()));
      await tester.tap(find.text(t.modcp.byUid));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('modcp-member-query')), '101');
      await tester.tap(find.byKey(const ValueKey('modcp-member-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-member-edit')), findsOneWidget);
      expect(find.textContaining('您不能直接禁止该用户'), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-ban-4')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('modcp-member-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-edit-signature')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('new members: pick, approve with a reason, the list read again', (tester) async {
      final forum = _Forum(
        {'op=members&filter=0': 'review_list.html'},
        postAnswer: (_, _) => _ok(_data('review_result.json')),
      );
      await _pumpPage(tester, MemberReviewPage(repository: forum.repository()));
      expect(find.text('mr_golf'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modcp-review-93')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('modcp-review-validate')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-reason')), '欢迎');
      await tester.tap(find.byKey(const ValueKey('modcp-reason-confirm')));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$2, containsPair('modact', 'validate'));
      expect(forum.posts.single.$2, containsPair('moderate[0]', '93'));
      expect(forum.posts.single.$2, containsPair('reason', '欢迎'));
      // Still listed by the fixture: told not done.
      expect(find.text(t.modcp.notDone(count: 1)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rules not told saved: read again, what was typed kept', (tester) async {
      final forum = _Forum(
        {'op=editforum': 'rules_editable.html', 'op=editforum&fid=9': 'rules_editable.html'},
        postAnswer: (_, _) => _ok(_text('rules_editable.html')),
      );
      await _pumpPage(tester, ForumRulesPage(repository: forum.repository()));
      await tester.enterText(find.byKey(const ValueKey('modcp-rules')), '新的规则');
      await tester.tap(find.byKey(const ValueKey('modcp-rules-save')));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(find.text(t.moderate.batch.unknown), findsOneWidget);
      // Read again by the forum's id, the text typed still there.
      expect(forum.gets.last, endsWith('op=editforum&fid=9'));
      expect(find.text('新的规则'), findsOneWidget);
    });

    testWidgets("a profile not saved (the panel's login): read again, what was typed kept", (tester) async {
      final forum = _Forum(
        {'op=edit&uid=101': 'member_edit.html'},
        postAnswer: (_, _) => _ok(_data('member_edit_session_ended.json')),
      );
      await _pumpPage(tester, MemberEditPage(memberUid: 101, repository: forum.repository()));
      await tester.enterText(find.byKey(const ValueKey('modcp-edit-signature')), '新签名');
      await tester.tap(find.byKey(const ValueKey('modcp-edit-save')));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(forum.gets, hasLength(2));
      expect(find.text('新签名'), findsOneWidget);
    });

    testWidgets('locked rules: read only, the forum note, no saving', (tester) async {
      final forum = _Forum({'op=editforum': 'rules_readonly.html'});
      await _pumpPage(tester, ForumRulesPage(repository: forum.repository()));
      expect(find.text('[b]版主改的規則[/b]'), findsOneWidget);
      expect(find.text('抱歉，您所在的用户组不允许修改版规！'), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-rules-save')), findsNothing);
      expect(find.byKey(const ValueKey('modcp-switch-forum')), findsOneWidget);
    });

    testWidgets("announcements: the others' can not be picked", (tester) async {
      final forum = _Forum({'action=announcement': 'announcement_list.html'});
      await _pumpPage(tester, AnnouncementsPage(repository: forum.repository()));
      expect(find.text('管理員的公告'), findsOneWidget);
      final boxes = tester.widgetList<Checkbox>(
        find.descendant(of: find.byKey(const ValueKey('modcp-announcement-4')), matching: find.byType(Checkbox)),
      );
      expect(boxes.single.onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('modcp-announcement-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-announcement-subject')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
