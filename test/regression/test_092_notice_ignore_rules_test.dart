import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:universal_html/parsing.dart';

/// Server-side notice ignore rules (Discuz `filter_note`): metadata from the notice's own ignore link, adding a rule
/// through the forum's ignore form and removing one through the full privacy filter form, failing closed on any page
/// that is not exactly the expected one.
///
/// The pages below follow the Discuz source (spacecp_privacy / spacecp_common ignore); they are not a recording of
/// the live TSDM deployment.
const _me = 1000;
const _other = 2000;
const _troll = 3000;

/// A forum holding the privacy filter state of one account.
class _Forum implements HttpClientAdapter {
  _Forum({required this.checked, this.pageUid = _me});

  /// Checked filter checkbox names, e.g. `privacy[filter_note][post|3000]`.
  Set<String> checked;

  /// Uid rendered in the page header.
  int pageUid;

  /// Replace the privacy page.
  String? privacyPageOverride;

  /// Replace the ignore form.
  String? ignoreFormOverride;

  /// Fail POST requests at the transport level.
  bool failPost = false;

  /// Accept a POST but do not change anything.
  bool ignoreWrites = false;

  /// Apply a POST and answer it with a redirect, like Discuz `showmessage` with `msgforward` quick.
  bool redirectWrites = false;

  final posts = <({Uri uri, Map<String, String> form})>[];

  /// What each POST handed to the client as its data: the Android client only takes a string map.
  final postData = <Object?>[];
  final gets = <Uri>[];

  static const allBoxes = [
    'privacy[filter_icon][1003]',
    'privacy[filter_gid][2]',
    'privacy[filter_gid][3]',
    'privacy[filter_note][post|3000]',
    'privacy[filter_note][friend|0]',
    'privacy[filter_note][post|0]',
  ];

  String privacyPage() {
    final boxes = [
      for (final name in {...allBoxes, ...checked})
        if (checked.contains(name) || !name.contains('filter_note'))
          '<label><input type="checkbox" name="$name" value="1"${checked.contains(name) ? ' checked' : ''} />$name</label>',
    ].join('\n');
    return '''
<html><head><title>隐私筛选</title></head><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$pageUid">me</a></strong></p></div>
<form method="post" autocomplete="off" action="home.php?mod=spacecp&amp;ac=privacy&amp;op=filter">
<input type="hidden" name="formhash" value="abcd1234" />
$boxes
<button type="submit" name="privacy2submit" value="true">保存</button>
</form></body></html>''';
  }

  static String ignoreForm({String type = 'post', int author = _troll}) =>
      '''
<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[<h3 class="flb"><em>屏蔽</em></h3>
<form method="post" autocomplete="off" id="ignoreform_x" name="ignoreform_x" action="home.php?mod=spacecp&ac=common&op=ignore&type=$type">
<input type="hidden" name="referer" value="home.php?mod=space&do=notice">
<input type="hidden" name="ignoresubmit" value="true" />
<input type="hidden" name="formhash" value="abcd1234" />
<input type="hidden" name="handlekey" value="noticeignore" />
<div class="c"><p><label><input type="radio" name="authorid" value="$author" checked="checked" />屏蔽该用户</label></p>
<p><label><input type="radio" name="authorid" value="0" />屏蔽所有人</label></p></div>
<p class="o pns"><button type="submit" name="ignoresubmitbtn" value="true" class="pn pnc"><strong>确定</strong></button></p>
</form>]]></root>''';

  static ResponseBody _html(String body) => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final q = uri.queryParameters;
    if (options.method == 'GET') {
      gets.add(uri);
      if (q['ac'] == 'privacy' && q['op'] == 'filter') {
        return _html(privacyPageOverride ?? privacyPage());
      }
      if (q['ac'] == 'common' && q['op'] == 'ignore') {
        return _html(ignoreFormOverride ?? ignoreForm(type: q['type']!, author: int.parse(q['authorid']!)));
      }
      return _html('<html></html>');
    }
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)));
    }
    final form = Uri.splitQueryString(body);
    posts.add((uri: uri, form: form));
    postData.add(options.data);
    if (failPost) {
      throw DioException.connectionError(requestOptions: options, reason: 'reset');
    }
    if (!ignoreWrites) {
      if (q['ac'] == 'privacy') {
        checked = form.keys.where((k) => k.contains('[filter_')).toSet();
      } else if (q['ac'] == 'common' && q['op'] == 'ignore') {
        checked = {...checked, 'privacy[filter_note][${q['type']}|${form['authorid']}]'};
      }
    }
    if (redirectWrites) {
      return ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': ['home.php?mod=spacecp&ac=privacy&op=filter'],
        },
      );
    }
    return _html('<html><body><div id="messagetext" class="alert_right"><p>操作成功</p></div></body></html>');
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every write with the forum's error message and changes nothing.
final class _RefusingForum extends _Forum {
  _RefusingForum({required super.checked});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      return super.fetch(options, requestStream, cancelFuture);
    }
    posts.add((uri: options.uri, form: const {}));
    return _Forum._html('<html><body><div id="messagetext" class="alert_error"><p>没有权限</p></div></body></html>');
  }
}

NetClientProvider _clientOf(_Forum forum) =>
    NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() {
    getIt
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver());
  });

  tearDown(getIt.reset);

  const repo = NoticeIgnoreRepository();

  group('Cloudflare background script versus interstitial', () {
    test('captured normal page containing background JS passes the page guard', () {
      final raw = File('test/data/favorite_forum_list_empty_x5.html').readAsStringSync();
      expect(raw, contains('/cdn-cgi/challenge-platform/scripts/jsd/main.js'));
      expect(() => checkForumPage(parseHtmlDocument(raw), expectedUid: _me, requireIdentity: false), returnsNormally);
    });

    test('background JS on a valid privacy page loads rules', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]'});
      forum.privacyPageOverride = forum.privacyPage().replaceFirst(
        '</body>',
        '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script></body>',
      );
      final result = await repo.fetchRules(_clientOf(forum), uid: _me);
      expect(result.isSuccess, isTrue, reason: '${result.failure}');
      expect(result.rules!.map((e) => e.key), ['post|3000']);
      expect(forum.posts, isEmpty);
    });

    for (final marker in [
      '<title>Just a moment...</title>',
      '<form id="challenge-form"></form>',
      '<script src="/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1"></script>',
      '<script>window._cf_chl_opt = {};</script>',
    ]) {
      test('real challenge is refused: $marker', () async {
        final forum = _Forum(checked: {})..privacyPageOverride = '<html><head>$marker</head><body></body></html>';
        final result = await repo.fetchRules(_clientOf(forum), uid: _me);
        expect(result.failure, NoticeIgnoreFailure.challenge);
        expect(forum.posts, isEmpty);
      });
    }
  });

  group('notice metadata', () {
    test('type and author come from the ignore link of real notice pages', () {
      NoticeV2 first(String file) =>
          Notice.toV2(NotificationV2.noticeNodes(parseHtmlDocument(File('test/data/$file').readAsStringSync())).first)!;

      final post = first('notice_read_x5.html');
      expect(post.ignoreType, 'post');
      expect(post.authorId, 1000);
      final friend = first('notice_friend_request_x5.html');
      expect(friend.ignoreType, 'friend');
      expect(friend.authorId, 1000);
    });

    test('malformed, external or other operations give no metadata', () {
      NoticeIgnoreTarget? parse(String href) => NoticeIgnoreTarget.tryParse(href);
      expect(parse('home.php?mod=spacecp&amp;ac=common&amp;op=ignore&amp;authorid=7&amp;type=post'), isNotNull);
      expect(parse('https://evil.example/home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=post'), isNull);
      expect(parse('//evil.example/home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=post'), isNull);
      expect(parse('home.php?mod=spacecp&ac=friend&op=ignore&authorid=7&type=post'), isNull);
      // System notices (author 0) carry a valid ignore link for everybody, see test_094.
      expect(parse('home.php?mod=spacecp&ac=common&op=ignore&authorid=0&type=system')?.hasUserAuthor, isFalse);
      expect(parse('home.php?mod=spacecp&ac=common&op=ignore&authorid=-1&type=post'), isNull);
      expect(parse('home.php?mod=spacecp&ac=common&op=ignore&authorid=x&type=post'), isNull);
      expect(parse('evilhome.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=post'), isNull);
      expect(parse('x/home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=post'), isNull);
      expect(
        parse('https://www.tsdm39.com:8443/home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=post'),
        isNull,
      );
      expect(parse('https://u@www.tsdm39.com/home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=post'), isNull);
      expect(parse('home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=%E0%A4%A'), isNull);
      expect(parse('home.php?mod=spacecp&ac=common&op=ignore&authorid=7&type=po%27st'), isNull);
      expect(parse('home.php?mod=spacecp&ac=common&op=ignore&authorid=7'), isNull);
      expect(parse('javascript:alert(1)'), isNull);
    });

    test('a notice without ignore link has no author, the body is never used', () {
      final doc = parseHtmlDocument('''
<div class="nts"><dl class="cl" notice="5" id="notice_5">
<dt><span class="xg1 xw0"><span title="2026-9-5 17:38">now</span></span></dt>
<dd class="ntc_body"><a href="home.php?mod=space&uid=3000">troll</a> did something</dd></dl></div>''');
      final n = Notice.toV2(NotificationV2.noticeNodes(doc).single)!;
      expect(n.authorId, isNull);
      expect(n.ignoreType, isNull);
    });
  });

  group('rules', () {
    test('lists only checked notice rules', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]', 'privacy[filter_icon][1003]'});
      final result = await repo.fetchRules(_clientOf(forum), uid: _me);
      expect(result.isSuccess, isTrue);
      expect(result.rules!.map((e) => e.key), ['post|3000']);
      expect(forum.posts, isEmpty);
    });

    test('removing one rule keeps every other checked filter and hidden field', () async {
      final forum = _Forum(
        checked: {
          'privacy[filter_icon][1003]',
          'privacy[filter_gid][2]',
          'privacy[filter_note][post|3000]',
          'privacy[filter_note][friend|0]',
        },
      );
      final result = await repo.removeRule(
        _clientOf(forum),
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      expect(result.isSuccess, isTrue, reason: '${result.failure}');
      expect(forum.posts, hasLength(1));
      final sent = forum.posts.single;
      expect(sent.uri.queryParameters, containsPair('op', 'filter'));
      expect(sent.form['formhash'], 'abcd1234');
      expect(sent.form['privacy2submit'], 'true');
      expect(
        sent.form.keys.where((k) => k.contains('[filter_')).toSet(),
        {'privacy[filter_icon][1003]', 'privacy[filter_gid][2]', 'privacy[filter_note][friend|0]'},
      );
      expect(forum.checked, isNot(contains('privacy[filter_note][post|3000]')));
      expect(result.rules!.map((e) => e.key), ['friend|0']);
    });

    test('removing a rule that is not there sends nothing', () async {
      final forum = _Forum(checked: {'privacy[filter_icon][1003]'});
      final result = await repo.removeRule(
        _clientOf(forum),
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      expect(result.failure, NoticeIgnoreFailure.ruleNotFound);
      expect(forum.posts, isEmpty);
    });

    test('a write the forum did not apply is reported as unknown, not success', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]'})..ignoreWrites = true;
      final result = await repo.removeRule(
        _clientOf(forum),
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      expect(result.failure, NoticeIgnoreFailure.unknownAfterSubmit);
    });

    test('writes are posted as a string map, the only body the Android client sends', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]', 'privacy[filter_icon][1003]'});
      final client = _clientOf(forum);
      final removed = await repo.removeRule(
        client,
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      final added = await repo.addRule(
        client,
        uid: _me,
        target: const NoticeIgnoreTarget(type: 'friend', authorId: _troll),
        everybody: false,
      );
      expect(removed.isSuccess, isTrue, reason: '${removed.failure}');
      expect(added.isSuccess, isTrue, reason: '${added.failure}');
      expect(forum.postData, hasLength(2));
      expect(forum.postData, everyElement(isA<Map<String, String>>()));
    });

    test('a write answered with a redirect is verified like any other answer', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]', 'privacy[filter_icon][1003]'})
        ..redirectWrites = true;
      final client = _clientOf(forum);
      final removed = await repo.removeRule(
        client,
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      expect(removed.isSuccess, isTrue, reason: '${removed.failure}');
      expect(removed.rules, isEmpty);
      expect(forum.checked, {'privacy[filter_icon][1003]'});

      final added = await repo.addRule(
        client,
        uid: _me,
        target: const NoticeIgnoreTarget(type: 'post', authorId: _troll),
        everybody: true,
      );
      expect(added.isSuccess, isTrue, reason: '${added.failure}');
      expect(added.rules!.map((e) => e.key), ['post|0']);
      expect(forum.posts, hasLength(2));
    });

    test('a field repeated with another value can not be posted as a map and is refused', () {
      expect(formDataOf(const [('a', '1'), ('b', '2'), ('a', '1')]), {'a': '1', 'b': '2'});
      expect(formDataOf(const [('a', '1'), ('a', '2')]), isNull);
    });

    test('a transport error after sending is unknown and never retried', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]'})..failPost = true;
      final result = await repo.removeRule(
        _clientOf(forum),
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      expect(result.failure, NoticeIgnoreFailure.unknownAfterSubmit);
      expect(forum.posts, hasLength(1));
    });

    group('fails closed without writing', () {
      Future<(NoticeIgnoreResult, _Forum)> removeOn(String? page, {int pageUid = _me}) async {
        final forum = _Forum(checked: {'privacy[filter_note][post|3000]'}, pageUid: pageUid)
          ..privacyPageOverride = page;
        final result = await repo.removeRule(
          _clientOf(forum),
          uid: _me,
          rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
        );
        return (result, forum);
      }

      final valid = _Forum(checked: {'privacy[filter_note][post|3000]'}).privacyPage();

      final cases = <String, (String?, int, NoticeIgnoreFailure)>{
        'page of another account': (null, _other, NoticeIgnoreFailure.accountMismatch),
        'guest page': (
          '<html><body><form id="lsform" action="member.php?mod=logging"></form></body></html>',
          _me,
          NoticeIgnoreFailure.notLoggedIn,
        ),
        'cloudflare': (
          '<html><head><title>Just a moment...</title></head><body></body></html>',
          _me,
          NoticeIgnoreFailure.challenge,
        ),
        'forum error': (
          '<html><body><div id="um"><strong class="vwmy"><a href="home.php?mod=space&uid=1000">me</a></strong></div> '
              '<div class="alert_error">没有权限</div></body></html>',
          _me,
          NoticeIgnoreFailure.forumError,
        ),
        'no formhash': (
          valid.replaceFirst('name="formhash" value="abcd1234"', 'name="x" value="y"'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'external action': (
          valid.replaceFirst('action="home.php?', 'action="https://evil.example/home.php?'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'two forms': (
          valid.replaceFirst('</body>', '${RegExp(r'<form[\s\S]*</form>').stringMatch(valid)}</body>'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'action on another port': (
          valid.replaceFirst('action="home.php?', 'action="https://www.tsdm39.com:8443/home.php?'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'action with user info': (
          valid.replaceFirst('action="home.php?', 'action="https://x@www.tsdm39.com/home.php?'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'action on a look-alike script': (
          valid.replaceFirst('action="home.php?', 'action="evilhome.php?'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'wrong submit flag only': (
          valid.replaceFirst('name="privacy2submit"', 'name="privacysubmit"'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'conflicting save buttons': (
          valid.replaceFirst('</form>', '<button type="submit" name="privacy2submit" value="other">x</button></form>'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'multiple select': (
          valid.replaceFirst(
            '</form>',
            '<select name="s" multiple><option value="1" selected>1</option></select></form>',
          ),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'cut off page': (valid.substring(0, valid.indexOf('</form>')), _me, NoticeIgnoreFailure.unknownForm),
        'malformed action': (
          valid.replaceFirst('action="home.php?', 'action="home.php?%E0%A4%A&amp;'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'no submit': (valid.replaceFirst('name="privacy2submit"', ''), _me, NoticeIgnoreFailure.unknownForm),
        'unknown field': (
          valid.replaceFirst('</form>', '<input type="file" name="f" /></form>'),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
        'no current account in header': (
          valid.replaceFirst(RegExp('<div id="um">.*?</div>'), ''),
          _me,
          NoticeIgnoreFailure.unknownForm,
        ),
      };
      for (final MapEntry(key: name, value: (page, uid, failure)) in cases.entries) {
        test(name, () async {
          final (result, forum) = await removeOn(page, pageUid: uid);
          expect(result.failure, failure);
          expect(forum.posts, isEmpty);
        });
      }
    });

    test('adding a rule for this author and for everybody', () async {
      final forum = _Forum(checked: {'privacy[filter_icon][1003]'});
      const target = NoticeIgnoreTarget(type: 'post', authorId: _troll);
      final one = await repo.addRule(_clientOf(forum), uid: _me, target: target, everybody: false);
      expect(one.isSuccess, isTrue, reason: '${one.failure}');
      expect(forum.posts.single.form['authorid'], '$_troll');
      expect(forum.posts.single.form['formhash'], 'abcd1234');
      expect(forum.posts.single.uri.queryParameters['type'], 'post');
      expect(one.rules!.map((e) => e.key), contains('post|3000'));

      final all = await repo.addRule(_clientOf(forum), uid: _me, target: target, everybody: true);
      expect(all.isSuccess, isTrue);
      expect(forum.posts.last.form['authorid'], '0');
      // Unrelated filters untouched.
      expect(forum.checked, contains('privacy[filter_icon][1003]'));
    });

    test('a rule that is already there is reported as applied without sending anything', () async {
      final forum = _Forum(checked: {'privacy[filter_note][post|3000]'});
      final result = await repo.addRule(
        _clientOf(forum),
        uid: _me,
        target: const NoticeIgnoreTarget(type: 'post', authorId: _troll),
        everybody: false,
      );
      expect(result.isSuccess, isTrue);
      expect(result.alreadyApplied, isTrue);
      expect(forum.posts, isEmpty);
    });

    test('an explicit refusal of the forum is never reported as success', () async {
      final forum = _RefusingForum(checked: {'privacy[filter_note][post|3000]'});
      final result = await repo.removeRule(
        _clientOf(forum),
        uid: _me,
        rule: const NoticeIgnoreRule(type: 'post', authorId: _troll),
      );
      expect(result.isSuccess, isFalse);
      expect(result.failure, NoticeIgnoreFailure.forumError);
      expect(forum.posts, hasLength(1));
    });

    test('system notices (author 0) can be ignored for everybody only', () async {
      final forum = _Forum(checked: {});
      const target = NoticeIgnoreTarget(type: 'system', authorId: 0);
      final one = await repo.addRule(_clientOf(forum), uid: _me, target: target, everybody: false);
      expect(one.failure, NoticeIgnoreFailure.ruleNotFound);
      expect(forum.posts, isEmpty);
      final all = await repo.addRule(_clientOf(forum), uid: _me, target: target, everybody: true);
      expect(all.isSuccess, isTrue, reason: '${all.failure}');
      expect(forum.posts.single.form['authorid'], '0');
      expect(forum.posts.single.form['ignoresubmit'], 'true');
      expect(forum.checked, contains('privacy[filter_note][system|0]'));
    });

    test('the upstream ignore form (hidden ignoresubmit plus feedignoresubmit button) sends the operation flag', () {
      const raw = '''
<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[<form method="post" autocomplete="off" id="ignoreform_1" name="ignoreform_1" action="home.php?mod=spacecp&ac=common&op=ignore&type=post&id=">
<input type="hidden" name="handlekey" value="noticeignore" />
<input type="hidden" name="ignoresubmit" value="true" />
<input type="hidden" name="formhash" value="synthetic" />
<input type="hidden" name="referer" value="home.php">
<p><label><input type="radio" name="authorid" id="authorid1" value="3000" checked="checked" />a</label></p>
<p><label><input type="radio" name="authorid" id="authorid0" value="0" />b</label></p>
<p class="o pns"><button type="submit" name="feedignoresubmit" value="true" class="pn pnc"><strong>ok</strong></button></p>
</form>]]></root>''';
      final form = parseNoticeIgnoreForm(
        raw,
        target: const NoticeIgnoreTarget(type: 'post', authorId: _troll),
        expectedUid: _me,
      );
      final names = form.fields.map((e) => e.$1).toList();
      expect(names.where((e) => e == 'ignoresubmit'), hasLength(1));
      expect(names, isNot(contains('feedignoresubmit')));
      expect(form.action.toString(), startsWith('https://www.tsdm39.com/home.php?'));
    });

    test('adding fails closed on a form for another author or type, or another account', () async {
      const target = NoticeIgnoreTarget(type: 'post', authorId: _troll);
      final wrongAuthor = _Forum(checked: {})..ignoreFormOverride = _Forum.ignoreForm(author: 4000);
      expect(
        (await repo.addRule(_clientOf(wrongAuthor), uid: _me, target: target, everybody: false)).failure,
        NoticeIgnoreFailure.ruleNotFound,
      );
      final wrongType = _Forum(checked: {})..ignoreFormOverride = _Forum.ignoreForm(type: 'friend');
      expect(
        (await repo.addRule(_clientOf(wrongType), uid: _me, target: target, everybody: false)).failure,
        NoticeIgnoreFailure.unknownForm,
      );
      final otherAccount = _Forum(checked: {}, pageUid: _other);
      expect(
        (await repo.addRule(_clientOf(otherAccount), uid: _me, target: target, everybody: false)).failure,
        NoticeIgnoreFailure.accountMismatch,
      );
      for (final f in [wrongAuthor, wrongType, otherAccount]) {
        expect(f.posts, isEmpty);
      }
    });
  });
}
