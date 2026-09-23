import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/repository/approve_friend_repository.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/approve_friend_link.dart';
import 'package:tsdm_client/features/friend/utils/parse_add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_approve_friend.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

/// GitHub #102: approve a pending friend request inside the app.
///
/// The notice's "批准申请" link loads the approval form (`add2submit`, radio groups), which is not the add-friend form
/// (`addsubmit`, a group select and a note). Fixtures were captured on 2026-09-06 with the two test accounts
/// (uids 1000/1001, Alice/Bob); every other page here is synthetic. No real forum is contacted.
String _data(String name) => File('test/data/$name').readAsStringSync();

const _alice = 1000;
const _noticeLink = 'home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice';

String _ajax(String html) => '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[$html]]></root>';

/// The captured approval form with [from] replaced by [to].
String _formWith(String from, String to) {
  final raw = _data('friend_accept_form_x5.xml');
  expect(raw, contains(from), reason: 'fixture changed: $from');
  return raw.replaceFirst(from, to);
}

ApproveFriendFailure? _rejection(void Function() parse) {
  try {
    parse();
  } on ApproveFriendRejected catch (e) {
    return e.failure;
  }
  return null;
}

/// One answer of the fake forum.
final class _Answer {
  const _Answer(this.body, {this.status = 200, this.headers = const {}}) : offline = false;

  const _Answer.offline() : body = '', status = 0, headers = const {}, offline = true;

  final String body;
  final int status;
  final Map<String, List<String>> headers;
  final bool offline;
}

/// Records every request and answers with [answer].
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  List<RequestOptions> get posts => requests.where((e) => e.method == 'POST').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    if (a.offline) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
        ...a.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) => NetClientProvider.buildNoCookie(
  dio: Dio()..httpClientAdapter = forum,
  cookie: CookieProvider.buildEmpty(),
);

/// Query of [uri] without the `mobile=no` every forum request gets.
Map<String, String> _query(Uri uri) => Map.of(uri.queryParameters)..remove('mobile');

/// Handle key of the captured approval form and answer, replaced by what the request carried.
const _capturedHandleKey = 'afrfriendhk_1001';

/// A forum that, like Discuz, builds the approval form around the `handlekey` and `from` of the GET (empty when the
/// request carried none) and answers a post with the success handler of the posted `handlekey` and `from`.
_Answer _popupForum(RequestOptions o) {
  const esc = HtmlEscape();
  if (o.method == 'GET') {
    final q = o.uri.queryParameters;
    final form = _formWith('name="from" value=""', 'name="from" value="${esc.convert(q['from'] ?? '')}"');
    return _Answer(form.replaceAll(_capturedHandleKey, esc.convert(q['handlekey'] ?? '')));
  }
  final data = o.data as Map;
  final raw = _data('friend_accept_result_x5.xml');
  expect(raw, contains("'from':''"), reason: 'fixture changed: from');
  return _Answer(
    raw.replaceAll(_capturedHandleKey, '${data['handlekey']}').replaceFirst("'from':''", "'from':'${data['from']}'"),
  );
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() => getIt.registerSingleton<NetErrorSaver>(NetErrorSaver()));

  tearDown(() async => getIt.reset());

  group('notice link', () {
    test('the link of the captured notice is recognized with its uid', () {
      expect(_data('notice_friend_request_x5.html'), contains('href="$_noticeLink"'));
      expect(friendApprovalUidOfUrl(_noticeLink), _alice);
      expect(friendApprovalUidOfUrl(_noticeLink.prependHost()), _alice, reason: 'as the notice card dispatches it');
      expect(friendApprovalUidOfUrl('/$_noticeLink'), _alice);
      expect(friendApprovalUidOfUrl('http://tsdm39.com/$_noticeLink'), _alice);
      expect(friendApprovalUidOfUrl(_noticeLink.replaceAll('&', '&amp;')), _alice);
      expect(
        friendApprovalUidOfUrl('https://www.tsdm39.com/home.php?from=notice&uid=7&op=add&ac=friend&mod=spacecp'),
        7,
      );
    });

    for (final (reason, url) in [
      ('foreign host', 'https://evil.example/$_noticeLink'),
      ('look-alike host', 'https://www.tsdm39.com.evil.example/$_noticeLink'),
      ('explicit port', 'https://www.tsdm39.com:8443/$_noticeLink'),
      ('user info', 'https://user@www.tsdm39.com/$_noticeLink'),
      ('protocol relative foreign host', '//evil.example/$_noticeLink'),
      ('other scheme', 'ftp://www.tsdm39.com/$_noticeLink'),
      ('javascript', 'javascript:alert(1)//$_noticeLink'),
      ('sub path', 'https://www.tsdm39.com/x/$_noticeLink'),
      ('path after script', 'https://www.tsdm39.com/home.php/x?mod=spacecp&ac=friend&op=add&uid=1000&from=notice'),
      ('other script', 'evilhome.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice'),
      ('profile add-friend link', 'home.php?mod=spacecp&ac=friend&op=add&uid=1000'),
      ('from elsewhere', 'home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=space'),
      ('other operation', 'home.php?mod=spacecp&ac=friend&op=ignore&uid=1000&from=notice'),
      ('zero uid', 'home.php?mod=spacecp&ac=friend&op=add&uid=0&from=notice'),
      ('negative uid', 'home.php?mod=spacecp&ac=friend&op=add&uid=-1&from=notice'),
      ('leading zero uid', 'home.php?mod=spacecp&ac=friend&op=add&uid=01000&from=notice'),
      ('text uid', 'home.php?mod=spacecp&ac=friend&op=add&uid=abc&from=notice'),
      ('repeated uid', 'home.php?mod=spacecp&ac=friend&op=add&uid=1000&uid=1001&from=notice'),
      ('extra parameter', 'home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice&handlekey=x'),
      ('bad encoding', 'home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice%zz'),
    ]) {
      test('is not recognized: $reason', () => expect(friendApprovalUidOfUrl(url), isNull));
    }

    test('the request urls are the notice popup (as ajax) and its canonical submit url', () {
      // The notice link as common.js showWindow(..., 'get') loads it: infloat and the link id as handle key.
      expect(_data('notice_friend_request_x5.html'), contains('id="afr_1000"'));
      final form = Uri.parse(approveFriendFormUrl(_alice));
      expect(form.origin, 'https://www.tsdm39.com');
      expect(form.path, '/home.php');
      expect(form.queryParameters, {
        'mod': 'spacecp',
        'ac': 'friend',
        'op': 'add',
        'uid': '1000',
        'from': 'notice',
        'infloat': 'yes',
        'handlekey': 'afr_1000',
        'inajax': '1',
      });
      final submit = Uri.parse(approveFriendSubmitUrl(_alice));
      expect(submit.origin, 'https://www.tsdm39.com');
      expect(submit.path, '/home.php');
      expect(submit.queryParameters, {'mod': 'spacecp', 'ac': 'friend', 'op': 'add', 'uid': '1000', 'inajax': '1'});
      expect(submit.queryParameters, isNot(contains('handlekey')), reason: 'the handle key is posted as served');
    });
  });

  group('approval form', () {
    test('the captured form: member, groups, checked group and the hidden fields as served', () {
      final form = parseApproveFriendForm(_data('friend_accept_form_x5.xml'), targetUid: _alice) as ApproveFriendForm;
      expect(form.targetUid, _alice);
      expect(form.targetName, 'Alice');
      expect(form.groups.map((g) => g.gid), ['0', '1', '2', '3', '4', '5', '6', '7']);
      expect(form.groups.map((g) => g.name), ['其他', '通过本站认识', '通过活动认识', '通过朋友认识', '亲人', '同事', '同学', '不认识']);
      expect(form.selectedGid, '1');
      expect(form.fields, [
        ('referer', 'https://www.tsdm39.com/forum.php'),
        ('add2submit', 'true'),
        // Served empty although the link said from=notice: kept as served.
        ('from', ''),
        ('handlekey', 'afrfriendhk_1001'),
        ('formhash', 'XXXXXXXX'),
      ]);
    });

    test('without a checked group the first one is preselected', () {
      final form = parseApproveFriendForm(_formWith('value="1" checked', 'value="1"'), targetUid: _alice);
      expect((form as ApproveFriendForm).selectedGid, '0');
    });

    test("the forum's refusal comes back as its message", () {
      final raw = _ajax(
        "<script type=\"text/javascript\" reload=\"1\">if(typeof errorhandle_afr_1000=='function') "
        "{errorhandle_afr_1000('你们已成为好友', {});}</script>",
      );
      final result = parseApproveFriendForm(raw, targetUid: _alice);
      expect((result as ApproveFriendRefused).message, '你们已成为好友');
    });

    for (final (reason, raw, failure) in <(String, String Function(), ApproveFriendFailure)>[
      ('the add-friend form', () => _data('friend_add_form_x5.xml'), ApproveFriendFailure.unknownForm),
      (
        'a formhash alone',
        () => _ajax('<input type="hidden" name="formhash" value="XXXXXXXX" />'),
        ApproveFriendFailure.unknownForm,
      ),
      ('an empty answer', () => _ajax(''), ApproveFriendFailure.unknownForm),
      (
        'a form sending to another host',
        () => _formWith('action="home.php?', 'action="https://evil.example/home.php?'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a form sending to another port',
        () => _formWith('action="home.php?', 'action="https://www.tsdm39.com:8443/home.php?'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a form sending to another script',
        () => _formWith('action="home.php?', 'action="forum.php?'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a form for another member',
        () => _formWith('op=add&amp;uid=1000"', 'op=add&amp;uid=1001"'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a form naming another member',
        () => _formWith('mod=space&amp;uid=1000', 'mod=space&amp;uid=1001'),
        ApproveFriendFailure.unknownForm,
      ),
      ('a get form', () => _formWith('method="post"', 'method="get"'), ApproveFriendFailure.unknownForm),
      (
        'no add2submit',
        () => _formWith('name="add2submit" value="true"', 'name="other" value="true"'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'an addsubmit next to add2submit',
        () => _formWith(
          '<input type="hidden" name="from"',
          '<input type="hidden" name="addsubmit" value="true" /><input type="hidden" name="from"',
        ),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a note field',
        () => _formWith('<div class="c">', '<div class="c"><textarea name="note"></textarea>'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a group select',
        () => _formWith('<div class="c">', '<div class="c"><select name="gid"><option value="1">x</option></select>'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'an unknown hidden field',
        () => _formWith('<div class="c">', '<div class="c"><input type="hidden" name="extra" value="1" />'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'no formhash',
        () => _formWith('name="formhash" value="XXXXXXXX"', 'name="formhash" value=""'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'no handle key',
        () => _formWith('name="handlekey" value="afrfriendhk_1001"', 'name="handlekey" value=""'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a radio of another name',
        () => _formWith('name="gid"', 'name="other"'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'no group',
        () => _data('friend_accept_form_x5.xml').replaceAll(RegExp('<input type="radio"[^>]*>'), ''),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'two checked groups',
        () => _formWith('id="group_0" value="0"', 'id="group_0" value="0" checked'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'two forms',
        () => _formWith('</form>', '</form><form method="post" action="home.php"></form>'),
        ApproveFriendFailure.unknownForm,
      ),
      (
        'a challenge',
        () => '<html><head><title>Just a moment...</title></head><body><div id="challenge-stage"></div></body></html>',
        ApproveFriendFailure.challenge,
      ),
      (
        'the login page',
        () => '<html><body><form id="lsform" action="member.php?mod=logging"></form></body></html>',
        ApproveFriendFailure.notLoggedIn,
      ),
      ('a normal page', () => _data('notice_friend_request_x5.html'), ApproveFriendFailure.unknownForm),
    ]) {
      test('stops before posting on $reason', () {
        expect(_rejection(() => parseApproveFriendForm(raw(), targetUid: _alice)), failure);
      });
    }
  });

  group('approval answer', () {
    const handleKey = 'afrfriendhk_1001';

    test("the captured answer is a success with the forum's message", () {
      final result = parseApproveFriendResult(
        _data('friend_accept_result_x5.xml'),
        handleKey: handleKey,
        targetUid: _alice,
      );
      expect(result.success, isTrue);
      expect(result.message, '您已和Alice成为好友');
    });

    test('a refusal is not a success and keeps the message', () {
      final result = parseApproveFriendResult(
        _ajax("<script>errorhandle_$handleKey('抱歉，对方的好友请求不存在', {});</script>"),
        handleKey: handleKey,
        targetUid: _alice,
      );
      expect(result.success, isFalse);
      expect(result.message, '抱歉，对方的好友请求不存在');
    });

    for (final (reason, raw, uid, failure) in <(String, String Function(), int, ApproveFriendFailure)>[
      (
        'a success of another form',
        () => _data('friend_accept_result_x5.xml').replaceAll(handleKey, 'addfriendhk_1000'),
        _alice,
        ApproveFriendFailure.unknownAfterSubmit,
      ),
      (
        'a success for another member',
        () => _data('friend_accept_result_x5.xml'),
        1001,
        ApproveFriendFailure.unknownAfterSubmit,
      ),
      (
        'a notice dialog without the success handler',
        () => _ajax("<script>showDialog('您已和Alice成为好友', 'notice');</script>"),
        _alice,
        ApproveFriendFailure.unknownAfterSubmit,
      ),
      ('an empty answer', () => _ajax(''), _alice, ApproveFriendFailure.unknownAfterSubmit),
      ('a normal page', () => _data('notice_friend_request_x5.html'), _alice, ApproveFriendFailure.unknownAfterSubmit),
      (
        'a challenge',
        () => '<html><head><title>Just a moment...</title></head><body></body></html>',
        _alice,
        ApproveFriendFailure.challenge,
      ),
      (
        'the login page',
        () => '<html><body><div id="messagelogin"></div></body></html>',
        _alice,
        ApproveFriendFailure.notLoggedIn,
      ),
    ]) {
      test('is never a success: $reason', () {
        expect(_rejection(() => parseApproveFriendResult(raw(), handleKey: handleKey, targetUid: uid)), failure);
      });
    }
  });

  group('repository', () {
    const repository = ApproveFriendRepository();

    Future<ApproveFriendForm> loadForm(_Forum forum) async {
      final result = await repository.fetchForm(_client(forum), targetUid: _alice);
      return result.getOrElse((l) => fail('form not loaded: $l')) as ApproveFriendForm;
    }

    test('loads the notice operation as ajax and posts exactly the served fields with the chosen group', () async {
      final forum = _Forum(
        (o) => _Answer(_data(o.method == 'GET' ? 'friend_accept_form_x5.xml' : 'friend_accept_result_x5.xml')),
      );
      final form = await loadForm(forum);
      final get = forum.requests.single;
      expect(get.method, 'GET');
      expect(get.uri.origin, 'https://www.tsdm39.com');
      expect(get.uri.path, '/home.php');
      expect(_query(get.uri), {
        'mod': 'spacecp',
        'ac': 'friend',
        'op': 'add',
        'uid': '1000',
        'from': 'notice',
        'infloat': 'yes',
        'handlekey': 'afr_1000',
        'inajax': '1',
      });

      final result = await repository.approve(_client(forum), form: form, gid: '3');
      expect(result, isA<Right<ApproveFriendFailure, AddFriendResult>>());
      final answer = result.getOrElse((l) => fail('$l'));
      expect(answer.success, isTrue);
      expect(answer.message, '您已和Alice成为好友');

      final post = forum.posts.single;
      expect(post.uri.origin, 'https://www.tsdm39.com');
      expect(post.uri.path, '/home.php');
      expect(_query(post.uri), {'mod': 'spacecp', 'ac': 'friend', 'op': 'add', 'uid': '1000', 'inajax': '1'});
      expect(post.contentType, startsWith('application/x-www-form-urlencoded'));
      expect(post.data, {
        'referer': 'https://www.tsdm39.com/forum.php',
        'add2submit': 'true',
        'from': '',
        'handlekey': 'afrfriendhk_1001',
        'formhash': 'XXXXXXXX',
        'gid': '3',
      });
      expect((post.data as Map).keys, isNot(anyOf(contains('addsubmit'), contains('note'))));
    });

    test('a forum keying the form on the request: the bare link fails, the popup url approves once', () async {
      // Before the fix the form was read without infloat/handlekey: the forum serves an empty handle key.
      const bareUrl = 'https://www.tsdm39.com/home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice&inajax=1';
      final bare = _Forum(_popupForum);
      final bareAnswer = (await _client(bare).get(bareUrl).run()).getOrElse((l) => fail('$l')).data as String;
      expect(bareAnswer, contains('name="handlekey" value=""'));
      expect(_rejection(() => parseApproveFriendForm(bareAnswer, targetUid: _alice)), ApproveFriendFailure.unknownForm);
      expect(bare.posts, isEmpty);

      final forum = _Forum(_popupForum);
      final form = await loadForm(forum);
      expect(_query(forum.requests.single.uri), containsPair('handlekey', 'afr_1000'));
      expect(form.field('handlekey'), 'afr_1000');
      expect(form.field('from'), 'notice');

      final result = await repository.approve(_client(forum), form: form, gid: form.selectedGid);
      final answer = result.getOrElse((l) => fail('$l'));
      expect(answer.success, isTrue);
      expect(answer.message, '您已和Alice成为好友');
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.data, {
        'referer': 'https://www.tsdm39.com/forum.php',
        'add2submit': 'true',
        'from': 'notice',
        'handlekey': 'afr_1000',
        'formhash': 'XXXXXXXX',
        'gid': '1',
      });
    });

    test('a group the form did not offer is never posted', () async {
      final forum = _Forum((_) => _Answer(_data('friend_accept_form_x5.xml')));
      final form = await loadForm(forum);
      final result = await repository.approve(_client(forum), form: form, gid: '99');
      expect(result, left<ApproveFriendFailure, AddFriendResult>(ApproveFriendFailure.unknownForm));
      expect(forum.posts, isEmpty);
    });

    test('the add-friend form served instead is refused before anything is posted', () async {
      final forum = _Forum((_) => _Answer(_data('friend_add_form_x5.xml')));
      final result = await repository.fetchForm(_client(forum), targetUid: _alice);
      expect(result, left<ApproveFriendFailure, ApproveFriendFormResult>(ApproveFriendFailure.unknownForm));
      expect(forum.posts, isEmpty);
    });

    test('a challenge answering the form read is reported, nothing is posted', () async {
      final forum = _Forum(
        (_) => const _Answer(
          '<html><head><title>Just a moment...</title></head></html>',
          status: 403,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
      );
      final result = await repository.fetchForm(_client(forum), targetUid: _alice);
      expect(result, left<ApproveFriendFailure, ApproveFriendFormResult>(ApproveFriendFailure.challenge));
      expect(forum.posts, isEmpty);
    });

    test('an offline form read is a network failure', () async {
      final forum = _Forum((_) => const _Answer.offline());
      final result = await repository.fetchForm(_client(forum), targetUid: _alice);
      expect(result, left<ApproveFriendFailure, ApproveFriendFormResult>(ApproveFriendFailure.network));
    });

    for (final (reason, answer, failure) in <(String, _Answer, ApproveFriendFailure)>[
      ('an answer that is not understood', _Answer(_ajax('<p>?</p>')), ApproveFriendFailure.unknownAfterSubmit),
      ('a lost answer', const _Answer.offline(), ApproveFriendFailure.unknownAfterSubmit),
      ('a server error', const _Answer('', status: 500), ApproveFriendFailure.unknownAfterSubmit),
      (
        'a challenge',
        const _Answer(
          '<html><head><title>Just a moment...</title></head></html>',
          status: 403,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
        ApproveFriendFailure.challenge,
      ),
    ]) {
      test('the approval is posted once and $reason is not a success', () async {
        final forum = _Forum((_) => _Answer(_data('friend_accept_form_x5.xml')));
        final form = await loadForm(forum);
        forum.answer = (_) => answer;
        final result = await repository.approve(_client(forum), form: form, gid: form.selectedGid);
        expect(result, left<ApproveFriendFailure, AddFriendResult>(failure));
        expect(forum.posts, hasLength(1), reason: 'never retried');
      });
    }
  });

  group('ordinary add friend is unchanged', () {
    test('the add-friend form and urls still parse as before', () {
      final form = parseAddFriendForm(_data('friend_add_form_x5.xml'));
      expect(form, isA<AddFriendForm>());
      expect(
        FriendRepository.addFriendFormUrl('1001'),
        contains('ac=friend&op=add&uid=1001&handlekey=addfriendhk_1001&inajax=1'),
      );
      expect(FriendRepository.addFriendSubmitUrl('1001'), endsWith('ac=friend&op=add&uid=1001&inajax=1'));
      // The profile's add-friend link is not an approval.
      expect(friendApprovalUidOfUrl('home.php?mod=spacecp&ac=friend&op=add&uid=1001'), isNull);
    });
  });
}
