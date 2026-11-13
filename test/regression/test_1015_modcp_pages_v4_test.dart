/// The remaining pages of the moderation panel read from the forum's app API (plugin 4.0.0, `tsdmv=4`,
/// `modcp_pages_v4`; G2): the moderation queue and the new members (42), banning and editing a member (43), the IP bans
/// (44), the recycle bins (45), the forum rules (46) and the announcements (47).
///
/// * Asked as a page (`tsdmapp=json&tsdmv=4&nodoc=1`) only once `status` lists it; otherwise the web page exactly as
///   before, one request.
/// * The recorded answer and web page of the same page (an administrator, uid 32, and a moderator, uid 70, on the test
///   forum) give the same model: the rows, the texts the page prints (times in the page's format), the fields sent
///   back, the forums, the menu.
/// * The panel's login (`error: modcp_login`) is its login form; the plugin's "no permission" (`modcp_noperm`) reads
///   the web page for the forum's words; a message is the refusal in its words.
/// * A change of a page of the API is posted with `tsdmv=4` and told as spec section 8 says, never by `ok` alone: the
///   key of a write result; the page drawn again by its `result`, `updated` or what it still lists (a thread restored
///   that was not in the bin is `ok 1` and still listed: not done).
///
/// Fixtures `test/data/tsdmapp/v4/g2_modcp_*` (the web pages cut to the panel), cleaned; lists the test forum has none
/// of are synthetic, in the shapes of spec 4.0.0 section 4.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_v4.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/parsing.dart';

import 'tsdmapp_v4_fake.dart';

const _admin = 32;
const _mod = 70;

Map<String, dynamic> _json(String name) => v4Json('g2_modcp_$name.json');

String _html(String name) => v4Raw('g2_modcp_$name.html');

/// A deep copy of fixture [name] changed by [change].
Map<String, dynamic> _changed(String name, void Function(Map<String, dynamic> json) change) {
  final json = jsonDecode(jsonEncode(_json(name))) as Map<String, dynamic>;
  change(json);
  return json;
}

final class _Log {
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];
}

ModerateResponse _ok(Object? data) => (statusCode: 200, data: data);

Future<Either<AppException, ModerateResponse>> Function(String) _getter(_Log log, Object? api, Object? web) =>
    (url) async {
      log.gets.add(url);
      final data = Uri.parse(url).queryParameters['tsdmv'] == '4' ? api : web;
      return data == null ? left(HttpRequestFailedException(null)) : right(_ok(data));
    };

Future<Either<AppException, ModerateResponse>> Function(String, Map<String, String>) _poster(
  _Log log,
  Object? posted,
) => (url, body) async {
  log.posts.add((url, body));
  return posted == null ? left(HttpRequestFailedException(null)) : right(_ok(posted));
};

ModcpRepository _repo(_Log log, {Object? api, Object? web, Object? posted, int uid = _admin}) => ModcpRepository(
  get: _getter(log, api, web),
  post: _poster(log, posted),
  currentUid: () => uid,
);

ModerateRepository _moderate(_Log log, {Object? api, Object? web, Object? posted, int uid = _admin}) =>
    ModerateRepository(get: _getter(log, api, web), post: _poster(log, posted), currentUid: () => uid);

T _ready<T>(Either<AppException, ModcpAnswer<T>> answer) => switch (answer) {
  Right(value: ModcpReady(:final value)) => value,
  final other => throw StateError('not ready: $other'),
};

T _right<T>(Either<AppException, T> value) => value.getOrElse((e) => throw StateError('$e'));

bool _asksV4(String url) => Uri.parse(url).queryParameters['tsdmv'] == '4';

Map<String, Object?> _bin(RecycleBinList b) => {
  'fid': b.fid,
  'forums': b.forums,
  'items': [
    for (final e in b.items)
      '${e.id}|${e.title}|${e.author}|${e.authorUid}|${e.time}|${e.tid}|${e.reason}|${e.replies}|${e.views}',
  ],
  'fields': b.fields,
  'canDelete': b.canDelete,
  'hasNext': b.hasNext,
};

String _outcome(Either<AppException, ModcpWriteOutcome> outcome) => switch (outcome) {
  Right(value: ModcpWriteDone(:final count)) => 'done($count)',
  Right(value: ModcpWriteNotDone(:final remaining)) => 'notDone($remaining)',
  Right(value: ModcpWriteRefused(:final message)) => 'refused($message)',
  Right(value: ModcpWriteSessionEnded()) => 'sessionEnded',
  Right(value: ModcpWriteUnknown()) => 'unknown',
  Left(:final value) => 'failed(${value.runtimeType})',
};

Map<String, Object?> _result(String key, {int ok = 1, String message = '', int uid = _admin}) => {
  'ok': ok,
  'type': 'result',
  'schema': 13,
  'kind': 'message',
  'uid': uid,
  'message': message,
  'message_key': key,
};

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('recycle bins (45)', () {
    for (final (name, kind) in [('rb_2', RecycleBinKind.threads), ('rbp_2', RecycleBinKind.posts)]) {
      test('${kind.name}: the answer and the web page give the same bin, one request', () async {
        knowV4Status();
        final log = _Log();
        final api = _ready(
          await _repo(log, api: _json(name), web: _html(name)).fetchRecycleBin(kind, fid: 2).run(),
        );
        final web = parseRecycleBin(parseHtmlDocument(_html(name)), kind, fid: 2, uid: _admin)!;
        expect(_bin(api), _bin(web));
        expect(api.items, isNotEmpty);
        expect(api.v4, isTrue);
        expect(log.gets.single, contains('tsdmv=4'));
      });
    }

    test('no forum chosen: the forums only, either way', () async {
      knowV4Status();
      final api = _ready(
        await _repo(_Log(), api: _json('rb_0')).fetchRecycleBin(RecycleBinKind.threads).run(),
      );
      final web = parseRecycleBin(parseHtmlDocument(_html('rb_0')), RecycleBinKind.threads, fid: 0, uid: _admin)!;
      expect(api.fid, 0);
      expect(api.forums, web.forums);
    });

    test('restoring: told by what the bin drawn again still lists (ok 1 for a thread not restored)', () async {
      knowV4Status();
      final list = _ready(
        await _repo(_Log(), api: _json('rb_2')).fetchRecycleBin(RecycleBinKind.threads, fid: 2).run(),
      );
      final first = list.items.first.id;
      final gone = _changed('rb_2', (json) => (json['threads'] as List).removeAt(0));
      final kept = _changed('rb_2', (json) => json['message_key'] = 'modcp_recyclebin_list_succeed');
      for (final (posted, expected) in [(gone, RecycleBinDone), (kept, RecycleBinNotDone)]) {
        final log = _Log();
        final outcome = await _repo(
          log,
          posted: posted,
        ).submitRecycleBin(list, RecycleBinAction.restore, [first]).run();
        expect(_right(outcome).runtimeType, expected);
        final (url, body) = log.posts.single;
        expect(_asksV4(url), isTrue);
        expect(body, containsPair('op', 'restore'));
        expect(body, containsPair('moderate[0]', first));
      }
    });
  });

  group('members (43)', () {
    test('ban: the same member, record, choices and window either way', () async {
      knowV4Status();
      final log = _Log();
      final api = _ready(
        await _repo(log, api: _json('ban_77'), web: _html('ban_77')).lookupMember(const ModcpMemberQuery.uid(77)).run(),
      );
      final web = parseMemberBanPage(parseHtmlDocument(_html('ban_77')), uid: _admin)!;
      final a = api.member!;
      final w = web.member!;
      expect(a.memberUid, w.memberUid);
      expect(a.username, w.username);
      expect(a.status, w.status);
      expect(
        [for (final c in a.crimes) '${c.action}|${c.time}|${c.reason}|${c.operator}'],
        [
          for (final c in w.crimes) '${c.action}|${c.time}|${c.reason}|${c.operator}',
        ],
      );
      expect(
        [for (final c in a.choices) '${c.value}|${c.label}'],
        [for (final c in w.choices) '${c.value}|${c.label}'],
      );
      expect(a.form.fields, w.form.fields);
      expect(a.form.banned, w.form.banned);
      expect(a.body(a.choices.first, days: 3, reason: 'r'), w.body(w.choices.first, days: 3, reason: 'r'));
      // The menu of the API leaves the other plugins' entries out: what the app looks at is the same.
      expect(web.menu.entries.containsAll(api.menu.entries), isTrue);
      for (final can in [
        (ModcpMenu m) => m.canBanMember,
        (ModcpMenu m) => m.canEditMember,
        (ModcpMenu m) => m.canBanIp,
        (ModcpMenu m) => m.canEditForum,
        (ModcpMenu m) => m.canAnnounce,
        (ModcpMenu m) => m.has('forumaccess'),
      ]) {
        expect(can(api.menu), can(web.menu));
      }
      expect(log.gets, hasLength(1));
    });

    test('edit: the same window either way', () async {
      knowV4Status();
      final api = _ready(
        await _repo(_Log(), api: _json('edit_77')).lookupMember(const ModcpMemberQuery.uid(77), edit: true).run(),
      );
      final web = parseMemberEditPage(parseHtmlDocument(_html('edit_77')), uid: _admin)!;
      expect(api.edit!.fields, web.edit!.fields);
      expect(api.edit!.username, web.edit!.username);
      expect(api.edit!.bio, web.edit!.bio);
      expect(api.edit!.signature, web.edit!.signature);
      expect(api.edit!.v4, isTrue);
    });

    test("not found: no member, the note; staff: the forum's message", () async {
      knowV4Status();
      final missing = _ready(
        await _repo(_Log(), api: _json('ban_nouser')).lookupMember(const ModcpMemberQuery.name('x')).run(),
      );
      expect(missing.member, isNull);
      expect(missing.note, t.modcp.memberNotFound);
      final staff = await _repo(_Log(), api: _json('ban_staff')).lookupMember(const ModcpMemberQuery.uid(33)).run();
      expect((_right(staff) as ModcpRefused).message, '您不能直接禁止该用户');
    });

    test('a banned member: its state with the day the ban ends, the lifting offered', () {
      final json = _changed('ban_77', (json) {
        json['member'] = <String, dynamic>{
          ...json['member'] as Map<String, dynamic>,
          'status': 'banpost',
          'status_text': '禁止发言',
          'banexpiry': 1796140800,
        };
        (json['ban'] as Map)['choices'] = [
          {'value': '0', 'label': '正常状态', 'checked': 1},
          {'value': '5', 'label': '禁止访问', 'checked': 0},
        ];
      });
      final member = memberLookupFromApi(json, uid: _admin)!.member!;
      expect(member.status, '禁止发言 ( ${t.modcp.validUntil(date: '2026-12-2')} )');
      expect(member.form.banned, isTrue);
    });

    test('ban and edit sent with tsdmv=4, told by the key', () async {
      knowV4Status();
      final member = _ready(
        await _repo(_Log(), api: _json('ban_77')).lookupMember(const ModcpMemberQuery.uid(77)).run(),
      ).member!;
      for (final (posted, expected) in [
        (_result('modcp_member_ban_succeed', message: '用户禁止成功'), 'done(1)'),
        (_result('admin_reason_invalid', ok: 0, message: '请填写操作理由'), 'refused(请填写操作理由)'),
        // Done in words without the key: not told a success.
        (_result(''), 'refused()'),
        (_result('modcp_member_ban_succeed', uid: _mod), 'failed(IdentityChangedException)'),
      ]) {
        final log = _Log();
        final outcome = await _repo(log, posted: posted).submitMemberBan(member, member.choices.first, days: 3).run();
        expect(_outcome(outcome), expected);
        expect(_asksV4(log.posts.single.$1), isTrue);
      }
      final edit = _ready(
        await _repo(_Log(), api: _json('edit_77')).lookupMember(const ModcpMemberQuery.uid(77), edit: true).run(),
      ).edit!;
      final log = _Log();
      final edited = await _repo(
        log,
        posted: _result('members_edit_succeed'),
      ).submitMemberEdit(edit, bio: 'a', signature: 'b').run();
      expect(_outcome(edited), 'done(1)');
      expect(log.posts.single.$2, containsPair('bionew', 'a'));
    });

    test("the floor's ban window (author column) from the page of the API", () async {
      knowV4Status();
      final log = _Log();
      final window = await _moderate(log, api: _json('ban_77')).fetchMemberBanWindow(77).run();
      final form = (_right(window) as MemberBanWindowReady).form;
      expect(form.v4, isTrue);
      expect(form.fields, MemberBanForm.parse(parseHtmlDocument(_html('ban_77')), memberUid: 77, uid: _admin)!.fields);
      for (final (posted, expected) in [
        (_result('modcp_member_ban_succeed'), MemberBanDone),
        (_result('admin_nopermission', ok: 0, message: '没有权限'), MemberBanRefused),
        ({'ok': 0, 'error': 'modcp_login', 'uid': _admin, 'formhash': 'f1f2f3f4'}, MemberBanSessionEnded),
      ]) {
        final sent = _Log();
        final outcome = await _moderate(sent, posted: posted).submitMemberBan(form, days: 1).run();
        expect(_right(outcome).runtimeType, expected);
        expect(_asksV4(sent.posts.single.$1), isTrue);
      }
    });
  });

  group('IP bans (44)', () {
    Map<String, dynamic> listed(List<Map<String, Object?>> list, {String error = '', int added = 0}) =>
        _changed('ipban', (json) {
          json['list'] = list;
          json['result'] = {'error': error.isEmpty ? 0 : 1, 'error_key': error, 'added': added, 'deleted': 0};
        });
    const ban = {
      'id': 5,
      'ip': '203.0.113.7',
      'location': 'LAN',
      'admin': 'ag_mid',
      'dateline': 1794511524,
      'expiration': 1795116324,
      'can_delete': 1,
    };

    test('the same (empty) list either way; a ban as the page prints it', () async {
      knowV4Status();
      final api = _ready(await _repo(_Log(), api: _json('ipban')).fetchIpBans().run());
      final web = parseIpBanList(parseHtmlDocument(_html('ipban')), uid: _admin)!;
      expect(api.entries, isEmpty);
      expect(web.entries, isEmpty);
      expect(api.formHash, web.formHash);
      expect(api.addBody('203.0.113.7', 3), web.addBody('203.0.113.7', 3));
      final entry = ipBanListFromApi(listed([ban]), uid: _admin)!.entries.single;
      expect(
        '${entry.id}|${entry.ip}|${entry.admin}|${entry.start}|${entry.end}|${entry.deletable}',
        [
          '5|203.0.113.7|ag_mid|2026-11-13|2026-11-20|true',
        ].single,
      );
    });

    test('adding: done by result.added, refused by result.error_key whatever ok says', () async {
      knowV4Status();
      final list = _ready(await _repo(_Log(), api: _json('ipban')).fetchIpBans().run());
      for (final (posted, expected) in [
        (listed([ban], added: 1), 'done(1)'),
        (listed([], error: 'format'), 'refused(${t.modcp.ipBanFormat})'),
        (listed([], error: 'cidr'), 'refused(${t.modcp.ipBanCidr})'),
        (listed([], error: 'exists'), 'refused(${t.modcp.ipBanExists})'),
        ({'ok': 0, 'error': 'modcp_login', 'uid': _admin, 'formhash': 'f1f2f3f4'}, 'sessionEnded'),
        ({'ok': 0, 'error': 'modcp_noperm', 'uid': _admin, 'formhash': 'f1f2f3f4'}, 'refused()'),
        // No result, but the list holds the new ban: done; no result and nothing new: not known.
        (
          _changed('ipban', (json) {
            json.remove('result');
            json['list'] = [ban];
          }),
          'done(1)',
        ),
        (_changed('ipban', (json) => json.remove('result')), 'unknown'),
      ]) {
        final log = _Log();
        final outcome = await _repo(log, posted: posted).addIpBan(list, '203.0.113.7', 3).run();
        expect(_outcome(outcome), expected);
        expect(_asksV4(log.posts.single.$1), isTrue);
      }
    });

    test('deleting: done when the page drawn again lists none of them', () async {
      knowV4Status();
      final list = ipBanListFromApi(listed([ban]), uid: _admin)!;
      expect(_outcome(await _repo(_Log(), posted: listed([])).deleteIpBans(list, ['5']).run()), 'done(1)');
      expect(_outcome(await _repo(_Log(), posted: listed([ban])).deleteIpBans(list, ['5']).run()), 'notDone([5])');
    });

    test("no permission: the web page's words; the panel's login: its login form", () async {
      knowV4Status();
      final log = _Log();
      final refused = await _repo(
        log,
        api: _json('ipban_mod'),
        web: _html('ipban_mod'),
        uid: _mod,
      ).fetchIpBans().run();
      expect(_right(refused), isA<ModcpRefused<IpBanList>>());
      expect((_right(refused) as ModcpRefused).message, isNotEmpty);
      expect(log.gets, hasLength(2));
      expect(_asksV4(log.gets.last), isFalse);

      final login = _Log();
      final needs = await _repo(login, api: _json('login'), web: _html('login'), uid: 33).fetchIpBans().run();
      final web = ModcpRepository.answerOf<IpBanList>(_html('login'), uid: 33, read: (_, _) => null);
      expect((_right(needs) as ModcpNeedsLogin).formHash, (_right(web) as ModcpNeedsLogin).formHash);
      expect(login.gets, hasLength(1));
    });

    test('flag off: the web page asked as before', () async {
      for (final status in [
        null,
        v4Status({
          'modcp_pages_v4': <String>['member'],
        }),
      ]) {
        TsdmAppApi.reset();
        if (status != null) {
          knowV4Status(status);
        }
        final log = _Log();
        final list = _ready(await _repo(log, web: _html('ipban')).fetchIpBans().run());
        expect(list.v4, isFalse);
        expect(log.gets, [IpBanList.url]);
      }
    });

    test("another account's answer is refused", () async {
      knowV4Status();
      final answer = await _repo(_Log(), api: _json('ipban'), uid: _mod).fetchIpBans().run();
      expect(answer.getLeft().toNullable(), isA<IdentityChangedException>());
    });
  });

  group('forum rules (46)', () {
    for (final (name, uid) in [('rules_2', _admin), ('rules_2_mod', _mod)]) {
      test('$name: the same rules either way', () async {
        knowV4Status();
        final api = _ready(await _repo(_Log(), api: _json(name), uid: uid).fetchForumRules(fid: 2).run());
        final web = parseForumRules(parseHtmlDocument(_html(name)), uid: uid)!;
        expect(api.fid, web.fid);
        expect(api.rules, web.rules);
        expect(api.editable, web.editable);
        expect(api.formHash, web.formHash);
        expect(api.note.isEmpty, web.note.isEmpty);
        expect(api.body('x'), web.body('x'));
      });
    }

    test('saving: done by updated, refused when the rules can not be changed', () async {
      knowV4Status();
      final rules = _ready(await _repo(_Log(), api: _json('rules_2')).fetchForumRules(fid: 2).run());
      final updated = _changed('rules_2', (json) {
        json['updated'] = 1;
        json['rules'] = '[b]x[/b]';
      });
      final locked = _changed('rules_2_mod', (json) => json['uid'] = _admin);
      for (final (posted, expected) in [
        (updated, 'done(1)'),
        (locked, 'refused(${t.modcp.rulesLocked})'),
        (_json('rules_2'), 'unknown'),
      ]) {
        final log = _Log();
        expect(_outcome(await _repo(log, posted: posted).saveForumRules(rules, '[b]x[/b]').run()), expected);
        expect(_asksV4(log.posts.single.$1), isTrue);
        expect(log.posts.single.$2, containsPair('rulesnew', '[b]x[/b]'));
      }
    });
  });

  group('announcements (47)', () {
    const item = {
      'id': 3,
      'author': 'ag_mid',
      'subject': '公告一',
      'type': 1,
      'displayorder': 0,
      'starttime': 1794511524,
      'endtime': 0,
      'editable': 0,
    };

    test('the same list and new form either way; a row as the page prints it', () async {
      knowV4Status();
      final api = _ready(await _repo(_Log(), api: _json('ann')).fetchAnnouncements().run());
      final web = parseAnnouncements(parseHtmlDocument(_html('ann')), uid: _admin)!;
      expect(api.items, isEmpty);
      expect(api.formHash, web.formHash);
      final a = api.blank!;
      final w = web.blank!;
      expect(
        [a.id, a.formHash, a.subject, a.type, a.start, a.end, a.message, a.displayOrder],
        [
          w.id,
          w.formHash,
          w.subject,
          w.type,
          w.start,
          w.end,
          w.message,
          w.displayOrder,
        ],
      );
      final row = announcementsFromApi(
        _changed('ann', (json) => json['list'] = [item]),
        uid: _admin,
      )!.items.single;
      // Another's announcement: the row as the page shows it (`editable` is no permission, only the page's state).
      expect(
        '${row.id}|${row.subject}|${row.type}|${row.start}|${row.end}|${row.deletable}',
        [
          '3|公告一|${t.modcp.typeLink}|2026-11-13|-|false',
        ].single,
      );
    });

    test('adding: done by result.added; a refusal is the write result in its words', () async {
      knowV4Status();
      final list = _ready(await _repo(_Log(), api: _json('ann')).fetchAnnouncements().run());
      final added = _changed('ann', (json) {
        json['list'] = [item];
        json['result'] = {'added': 1, 'edited': 0, 'deleted': 0};
      });
      for (final (posted, expected) in [
        (added, 'done(1)'),
        (_result('modcp_ann_empty', ok: 0, message: '请输入公告标题和内容'), 'refused(请输入公告标题和内容)'),
        (_json('ann'), 'refused()'),
        // The page drawn again without a word of the result: not known, never told refused (no second post).
        (_changed('ann', (json) => json.remove('result')), 'unknown'),
      ]) {
        final log = _Log();
        final outcome = await _repo(log, posted: posted)
            .submitAnnouncement(
              list.blank!,
              subject: 's',
              type: AnnouncementType.text,
              start: '2026-11-13',
              end: '',
              message: 'm',
            )
            .run();
        expect(_outcome(outcome), expected);
        expect(_asksV4(log.posts.single.$1), isTrue);
      }
    });

    test('deleting: done when the list drawn again holds none of them', () async {
      knowV4Status();
      final list = announcementsFromApi(_changed('ann', (json) => json['list'] = [item]), uid: _admin)!;
      expect(_outcome(await _repo(_Log(), posted: _json('ann')).deleteAnnouncements(list, ['3']).run()), 'done(1)');
    });
  });

  group('every page: flag off, another account, a stale flag', () {
    final members = _changed('q_threads_2', (json) {
      json['op'] = 'members';
      json['fid'] = 0;
      json['members'] = <Object?>[];
    });
    final editing = _changed('ann', (json) {
      json['op'] = 'edit';
      json['list'] = null;
      (json['form'] as Map<String, dynamic>)['id'] = 3;
    });
    final pages =
        <(String, Map<String, dynamic>, String, Future<Either<AppException, Object?>> Function(_Log, Object?, int))>[
          (
            'recycle bin',
            _json('rb_2'),
            RecycleBinList.url(RecycleBinKind.threads, fid: 2),
            (log, api, uid) =>
                _repo(log, api: api, web: '', uid: uid).fetchRecycleBin(RecycleBinKind.threads, fid: 2).run(),
          ),
          (
            'recycle bin of replies',
            _json('rbp_2'),
            RecycleBinList.url(RecycleBinKind.posts, fid: 2),
            (log, api, uid) =>
                _repo(log, api: api, web: '', uid: uid).fetchRecycleBin(RecycleBinKind.posts, fid: 2).run(),
          ),
          (
            'ban',
            _json('ban_77'),
            const ModcpMemberQuery.uid(77).url('ban'),
            (log, api, uid) =>
                _repo(log, api: api, web: '', uid: uid).lookupMember(const ModcpMemberQuery.uid(77)).run(),
          ),
          (
            'edit',
            _json('edit_77'),
            const ModcpMemberQuery.uid(77).url('edit'),
            (log, api, uid) =>
                _repo(log, api: api, web: '', uid: uid).lookupMember(const ModcpMemberQuery.uid(77), edit: true).run(),
          ),
          (
            'IP bans',
            _json('ipban'),
            IpBanList.url,
            (log, api, uid) => _repo(log, api: api, web: '', uid: uid).fetchIpBans().run(),
          ),
          (
            'new members',
            members,
            MemberReviewList.url(),
            (log, api, uid) => _repo(log, api: api, web: '', uid: uid).fetchMemberReview().run(),
          ),
          (
            'rules',
            _json('rules_2'),
            ForumRules.url(fid: 2),
            (log, api, uid) => _repo(log, api: api, web: '', uid: uid).fetchForumRules(fid: 2).run(),
          ),
          (
            'announcements',
            _json('ann'),
            AnnouncementList.url,
            (log, api, uid) => _repo(log, api: api, web: '', uid: uid).fetchAnnouncements().run(),
          ),
          (
            'an announcement',
            editing,
            AnnouncementForm.url(3),
            (log, api, uid) => _repo(log, api: api, web: '', uid: uid).fetchAnnouncement(3).run(),
          ),
          (
            'the queue of threads',
            _json('q_threads_2'),
            ModerateQueueList.url(ModerateQueueKind.threads, fid: 2),
            (log, api, uid) =>
                _moderate(log, api: api, web: '', uid: uid).fetchQueue(ModerateQueueKind.threads, fid: 2).run(),
          ),
          (
            'the queue of replies',
            _json('q_replies_2'),
            ModerateQueueList.url(ModerateQueueKind.replies, fid: 2),
            (log, api, uid) =>
                _moderate(log, api: api, web: '', uid: uid).fetchQueue(ModerateQueueKind.replies, fid: 2).run(),
          ),
          (
            'the forums of the queue',
            _json('q_threads_2'),
            ModerateQueueList.url(ModerateQueueKind.threads, fid: 0),
            (log, api, uid) => _repo(log, api: api, web: '', uid: uid).fetchQueueForums().run(),
          ),
          (
            "a floor author's ban",
            _json('ban_77'),
            MemberBanForm.windowUrl(77),
            (log, api, uid) => _moderate(log, api: api, web: '', uid: uid).fetchMemberBanWindow(77).run(),
          ),
        ];
    for (final (label, api, url, call) in pages) {
      test('$label: read from the API; flag off as before; another account refused; a stale flag forgotten', () async {
        knowV4Status();
        final read = _Log();
        expect((await call(read, api, _admin)).isRight(), isTrue);
        expect(read.gets.map(_asksV4), [true], reason: label);

        TsdmAppApi.reset();
        final before = _Log();
        await call(before, api, _admin);
        expect(before.gets, [url], reason: label);

        knowV4Status();
        final other = _Log();
        final refused = await call(other, <String, dynamic>{...api, 'uid': _mod}, _admin);
        expect(refused.getLeft().toNullable(), isA<IdentityChangedException>(), reason: label);
        expect(other.gets, hasLength(1));

        final stale = _Log();
        await call(stale, {'ok': 1, 'type': 'modcp_home', 'schema': 39, 'uid': _admin}, _admin);
        expect(stale.gets, hasLength(2), reason: label);
        expect(stale.gets.last, url, reason: label);
        expect(TsdmAppApi.pluginInfo.value?.v4, isNull, reason: label);
      });
    }
  });

  group('the moderation queue (42)', () {
    for (final (name, kind) in [
      ('q_threads_2', ModerateQueueKind.threads),
      ('q_replies_2', ModerateQueueKind.replies),
    ]) {
      test('${kind.name}: the same (empty) list either way', () async {
        knowV4Status();
        final log = _Log();
        final answer = await _moderate(log, api: _json(name)).fetchQueue(kind, fid: 2).run();
        final api = (_right(answer) as ModerateQueueReady).page;
        final web = parseModerateQueue(parseHtmlDocument(_html(name)), kind, fid: 2, uid: _admin)!;
        expect(api.items, isEmpty);
        expect(api.fields, web.fields);
        expect(api.hasNext, web.hasNext);
        expect(log.gets.single, contains('tsdmv=4'));
      });
    }

    test('a waiting thread as the panel prints it, posted with tsdmv=4 and told by the key', () async {
      knowV4Status();
      final json = _changed('q_threads_2', (json) {
        json['count'] = 1;
        json['items'] = [
          {
            'id': 9203364,
            'tid': 9203364,
            'pid': 22427,
            'fid': 2,
            'thread_subject': '待审主题',
            'subject': '',
            'authorid': 38,
            'author': 'ag_t02',
            'dateline': 1794511524,
            'message': '第一行\n第二行',
          },
        ];
      });
      final page =
          (_right(await _moderate(_Log(), api: json).fetchQueue(ModerateQueueKind.threads, fid: 2).run())
                  as ModerateQueueReady)
              .page;
      final item = page.items.single;
      expect(
        '${item.id}|${item.subject}|${item.author}|${item.authorUid}|${item.time}|${item.message}',
        [
          '9203364|待审主题|ag_t02|38|2026-11-13 03:25|第一行\n第二行',
        ].single,
      );
      expect(page.fields, {'formhash': 'f1f2f3f4', 'filter': '0', 'fid': '2'});
      final log = _Log();
      final outcome = await _moderate(
        log,
        posted: _result('modcp_mod_succeed'),
      ).submitQueue(page, ModerateQueueAction.validate, item).run();
      expect(_right(outcome), isA<ModerateSucceeded>());
      expect(_asksV4(log.posts.single.$1), isTrue);
      String told(Either<AppException, ModerateOutcome> o) => switch (o) {
        Right(value: ModerateSucceeded()) => 'ok',
        Right(value: ModerateRefused(:final message)) => 'refused($message)',
        Left(:final value) => 'failed(${value.runtimeType})',
      };
      for (final (posted, expected) in [
        (_result('modcp_mod_succeed', uid: _mod), 'failed(IdentityChangedException)'),
        (_result('modcp_noaction', ok: 0, message: '请选择操作'), 'refused(请选择操作)'),
        (_result(''), 'refused()'),
        ({'ok': 0, 'error': 'modcp_login', 'uid': _admin, 'formhash': 'f1f2f3f4'}, 'refused()'),
      ]) {
        final sent = await _moderate(
          _Log(),
          posted: posted,
        ).submitQueue(page, ModerateQueueAction.validate, item).run();
        expect(told(sent), expected);
      }
    });

    test('new members: a row as the panel prints it; the list read again after the verdict', () async {
      knowV4Status();
      final members = _changed('q_threads_2', (json) {
        json['op'] = 'members';
        json['fid'] = 0;
        json['items'] = null;
        json['members'] = [
          {
            'uid': 120,
            'username': 'newbie',
            'regdate': 1794511524,
            'regip': '198.51.100.4',
            'email': '',
            'message': '想加入',
            'submittimes': 1,
            'submitdate': 1794511524,
            'admin': '',
            'moddate': 0,
            'can_delete': 1,
          },
        ];
      });
      final list = _ready(await _repo(_Log(), api: members).fetchMemberReview().run());
      final row = list.items.single;
      expect(
        '${row.id}|${row.username}|${row.regDate}|${row.regIp}|${row.reason}|${row.canDelete}',
        [
          '120|newbie|2026-11-13 03:25|198.51.100.4|想加入|true',
        ].single,
      );
      final emptied = _changed('q_threads_2', (json) {
        json['op'] = 'members';
        json['members'] = <Object?>[];
      });
      final log = _Log();
      final outcome = await _repo(
        log,
        api: emptied,
        posted: _result('modcp_mod_succeed'),
      ).submitMemberReview(list, MemberReviewAction.validate, ['120']).run();
      expect(_outcome(outcome), 'done(1)');
      expect(_asksV4(log.posts.single.$1), isTrue);
      expect(log.gets.single, contains('tsdmv=4'));
      final refused = await _repo(
        _Log(),
        posted: _result('modcp_moduser_invalid', ok: 0, message: '无效'),
      ).submitMemberReview(list, MemberReviewAction.validate, ['120']).run();
      expect(_outcome(refused), 'refused(无效)');
    });
  });

  test('the texts of times follow the page formats', () {
    expect(modcpTimeText(1794511524, 8, 'Y-n-j'), '2026-11-13');
    expect(modcpTimeText(1790810466, 8, 'Y-n-j H:i'), '2026-10-1 07:21');
    expect(modcpTimeText(1790810466, 8, 'Y-m-d H:i:s'), '2026-10-01 07:21:06');
    expect(modcpTimeText(0, 8, 'Y-n-j'), '');
  });
}
