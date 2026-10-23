/// The forum's app API, plugin 2.6.0: the result of a write as JSON (`type: result`, `schema: 13`).
///
/// Every form the app posts ([NetClientProvider.postForm], the multipart one too) carries `tsdmapp=json`
/// ([withTsdmAppJsonWrite]), as do the AJAX dialogs read for a write (the favorite dialogs, the add-friend and approval
/// forms, the rate, report, purchase and quick reply windows). The plugin then answers what the forum answered as one
/// JSON object ([tsdmAppWriteResultOf]): the handler call of an AJAX `showmessage` (`handle`), the 提示信息 page
/// (`message`), a redirect (`redirect`) or a page (`page`, the document cut as the JSON mode cuts one). Every reader
/// of such an answer tries the result first and parses the forum's own answer as before when there is none: an older
/// plugin, no plugin, or plugin 2.6.0 answering the forum's own output when its classifier failed. The fixtures
/// `write_v13_*.json` are the plugin's real answers; `write_v13_*.orig.txt` what the forum answered the same request
/// without the parameter: for every switched reader both give the same outcome, except the two answers the forum's
/// own output cannot tell (a favorite and a reply posted without AJAX, which the app never does), pinned as they are.
///
/// The forum is asked its AJAX requests (`inajax=1`) with `X-Requested-With: XMLHttpRequest`, as its own scripts do:
/// a forum verifying them (`ajaxvalidate`) answers a GET without the header the whole page.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/features/checkin/utils/parse_checkin.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/parse_add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_approve_friend.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/submission_result.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/profile/repository/edit_user_profile_repository.dart';
import 'package:tsdm_client/features/profile/repository/switch_user_group_repository.dart';
import 'package:tsdm_client/features/purchase/models/models.dart';
import 'package:tsdm_client/features/purchase/repository/purchase_repository.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/post_report_fixtures.dart';
import 'poll_fixtures.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String path) => File(path).readAsStringSync();

/// The plugin's answer of the sample [name].
Map<String, dynamic> _json(String name) => jsonDecode(_raw('$_dir/write_v13_$name.json')) as Map<String, dynamic>;

/// What the forum answered the same request without the parameter: status, headers and body.
typedef _Orig = ({int status, String contentType, String? location, String body});

_Orig _orig(String name) {
  final text = _raw('$_dir/write_v13_$name.orig.txt');
  final blank = RegExp(r'\r?\n\r?\n').firstMatch(text)!;
  final head = text.substring(0, blank.start).split(RegExp(r'\r?\n'));
  String? header(String field) => head
      .skip(1)
      .where((l) => l.toLowerCase().startsWith('${field.toLowerCase()}:'))
      .map((l) => l.substring(field.length + 1).trim())
      .firstOrNull;
  return (
    status: int.parse(head.first.substring('HTTP '.length)),
    contentType: header('Content-Type') ?? 'text/html; charset=utf-8',
    location: header('Location'),
    body: text.substring(blank.end),
  );
}

/// A `page` result the plugin would answer the AJAX fragment [xml] with: the content of its CDATA as the document.
Map<String, dynamic> _page(String xml) => {
  'ok': 1,
  'api': 1,
  'time': 1792523400,
  'uid': 35,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'page',
  'message': '',
  'message_key': '',
  'url': '',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
  'document': unwrapAjax(xml),
};

/// A `handle` result built from the sample [base] with [changes].
Map<String, dynamic> _handle(String base, Map<String, Object?> changes) => {..._json(base), ...changes};

/// The forum's error hook of [handle] with [text], as the forum prints it in an AJAX answer.
String _errorAjax(String handle, String text, {String values = '{}'}) {
  final call = "if(typeof errorhandle_$handle=='function') {errorhandle_$handle('$text', $values);}";
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<root><![CDATA[$text<script type="text/javascript" reload="1">$call</script>]]></root>';
}

/// The forum's success hook of [handle] with [url], [text] and [values].
String _succeedAjax(String handle, String url, String text, {String values = '{}'}) {
  final call = "if(typeof succeedhandle_$handle=='function') {succeedhandle_$handle('$url', '$text', $values);}";
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<root><![CDATA[<script type="text/javascript" reload="1">$call</script>]]></root>';
}

/// One answer of the fake forum.
typedef _Answer = ({String body, int status, Map<String, List<String>> headers});

/// The plugin's JSON answer, served as `application/json` (dio decodes it into a map, as in the app).
_Answer _api(Map<String, dynamic> json) => (
  body: jsonEncode(json),
  status: 200,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

/// The forum's own answer of a sample.
_Answer _web(_Orig orig) => (
  body: orig.body,
  status: orig.status,
  headers: {
    Headers.contentTypeHeader: [orig.contentType],
    if (orig.location != null) 'location': [orig.location!],
  },
);

/// The forum's AJAX answer [xml].
_Answer _ajax(String xml) => (
  body: xml,
  status: 200,
  headers: {
    Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
  },
);

/// One request the fake forum saw.
typedef _Request = ({String method, Uri uri, Map<String, dynamic> headers, String body});

/// A forum answering every request with [answer] and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Forum.always(_Answer answer) : this((_) => answer);

  final _Answer Function(_Request request) answer;
  final requests = <_Request>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      body = utf8.decode(bytes, allowMalformed: true);
    }
    final request = (method: options.method, uri: options.uri, headers: options.headers, body: body);
    requests.add(request);
    final a = answer(request);
    return ResponseBody.fromString(a.body, a.status, headers: a.headers);
  }

  @override
  void close({bool force = false}) {}
}

/// A client of [forum], with the interceptors of the app.
NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(() => _client(forum));

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

/// The id the forum's own answer [body] names in [pattern] (the forum numbers every sample anew).
String _idIn(String body, String pattern) => RegExp(pattern).firstMatch(body)!.group(1)!;

AppException _left<T>(Either<AppException, T> either) => either.fold((e) => e, (v) => throw StateError('right: $v'));

bool _asksJson(_Request r) => r.uri.queryParameters['tsdmapp'] == 'json';

bool _asksLean(_Request r) => r.uri.queryParameters.containsKey('nodoc');

bool _ajaxHeader(_Request r) => r.headers['X-Requested-With'] == 'XMLHttpRequest';

const _reply = ReplyParameters(fid: '2', tid: '9199849', postTime: '1792523300', formHash: 'f1f2f3f4', subject: '');

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('A. decoding a write result', () {
    test('a handle: the hook, its key, values, message key and verdict; its document is never read', () {
      final result = tsdmAppWriteResultOf(_json('reply_ok'))!;
      expect(result.kind, TsdmAppWriteKind.handle);
      expect(result.ok, isTrue);
      expect(result.succeeded, isTrue);
      expect(result.login, isFalse);
      expect(result.isError, isFalse);
      expect(result.alert, 'right');
      expect(result.handleKey, 'fastpost');
      expect(result.messageKey, 'post_reply_succeed');
      expect(result.message, startsWith('非常感谢，回复发布成功'));
      expect(result.url, 'forum.php?mod=viewthread&tid=9199849&pid=4750&page=1&extra=#pid4750');
      expect(result.values, {'fid': '2', 'tid': '9199849', 'pid': '4750', 'from': '', 'sechash': ''});
      expect(result.uid, 35);
      expect(result.formHash, 'f1f2f3f4');
      // The fixture carries a garbage `document` on purpose: a handle has none.
      expect(_json('reply_ok')['document'], contains('garbage'));
      expect(result.documentHtml, isEmpty);
      expect(result.head, isEmpty);
      // Read as a page, a handle is the forum's message page: the success class, the message, the link.
      final text = result.document.querySelector('div#messagetext.alert_right > p')?.innerText.trim();
      expect(text, result.message);
      expect(result.document.querySelector('div#messagetext p.alert_btnleft a')?.attributes['href'], result.url);
      expect(result.document.querySelector('div#messagelogin'), isNull);
      expect(result.document.querySelector('div#messagetext')?.innerText, isNot(contains('garbage')));
    });

    test('the error hook: not ok, the refusal, the values of the flood control', () {
      final result = tsdmAppWriteResultOf(_json('reply_dup'))!;
      expect(result.kind, TsdmAppWriteKind.handle);
      expect(result.ok, isFalse);
      expect(result.succeeded, isFalse);
      expect(result.isError, isTrue);
      expect(result.messageKey, 'post_flood_ctrl');
      expect(result.values, {'floodctrl': '15'});
      expect(result.url, isEmpty);
      expect(result.document.querySelector('div#messagetext.alert_error > p')?.innerText.trim(), result.message);
      expect(result.document.querySelector('p.alert_btnleft'), isNull);
      // The error hook the forum shows as a success (the report) is a success.
      final report = tsdmAppWriteResultOf(_json('report_ok'))!;
      expect(report.kind, TsdmAppWriteKind.handle);
      expect(report.alert, 'right');
      expect(report.succeeded, isTrue);
      expect(report.messageKey, 'report_succeed');
      expect(report.handleKey, 'miscreport');
      // A note (the friend request sent) is a success too; the second request is the refusal.
      expect(tsdmAppWriteResultOf(_json('friend_add'))!.alert, 'info');
      expect(tsdmAppWriteResultOf(_json('friend_add'))!.succeeded, isTrue);
      expect(tsdmAppWriteResultOf(_json('friend_again'))!.succeeded, isFalse);
      expect(tsdmAppWriteResultOf(_json('friend_again'))!.messageKey, 'waiting_for_the_other_test');
    });

    test('a message page: the refusal and the success, read as the forum printed them', () {
      final refused = tsdmAppWriteResultOf(_json('reply_msg_error'))!;
      expect(refused.kind, TsdmAppWriteKind.message);
      expect(refused.ok, isFalse);
      expect(refused.isError, isTrue);
      expect(refused.messageKey, 'thread_nonexistence');
      expect(refused.handleKey, isEmpty);
      expect(refused.values, isEmpty);
      expect(refused.document.querySelector('div#messagetext.alert_error > p')?.innerText.trim(), refused.message);
      final ok = tsdmAppWriteResultOf(_json('favorite_msg'))!;
      expect(ok.kind, TsdmAppWriteKind.message);
      expect(ok.succeeded, isTrue);
      expect(ok.alert, 'right');
      expect(ok.messageKey, 'favorite_do_success');
      expect(ok.url, 'https://www.tsdm39.com/./');
      expect(ok.document.querySelector('div#messagetext.alert_right p.alert_btnleft a')?.attributes['href'], ok.url);
      expect(ok.document.querySelector('head script')?.text, contains("discuz_uid = '35'"));
      // The login prompt: not ok, the login box of the forum's page.
      final login = tsdmAppWriteResultOf({...ok.json, 'ok': 0, 'login': 1, 'alert': 'info', 'message': '请先登录'})!;
      expect(login.login, isTrue);
      expect(login.succeeded, isFalse);
      expect(login.document.querySelector('div#messagelogin'), isNotNull);
      expect(login.document.querySelector('div#messagetext.alert_info > p')?.innerText.trim(), '请先登录');
    });

    test('the reason to show: the message of the forum, the "log in first" of the app, or nothing; never a field', () {
      expect(tsdmAppWriteResultOf(_json('reply_dup'))!.reason, '抱歉，您两次发表间隔少于 15 秒，请稍候再发表');
      final login = tsdmAppWriteResultOf({..._json('reply_msg_error'), 'message': '', 'login': 1, 'alert': 'info'})!;
      expect(login.reason, t.general.needLogin);
      expect(login.reason, isNotEmpty);
      // With a message the forum's words win, login or not.
      expect(tsdmAppWriteResultOf({..._json('reply_msg_error'), 'login': 1})!.reason, startsWith('抱歉'));
      for (final name in ['reply_redirect', 'page_case', 'profile_msg', 'checkin']) {
        expect(tsdmAppWriteResultOf(_json(name))!.reason, isEmpty, reason: name);
      }
    });

    test('tsdmAppAnswerText: text as it is, nothing as empty, JSON encoded back, never toString', () {
      expect(tsdmAppAnswerText('<root/>'), '<root/>');
      expect(tsdmAppAnswerText(null), isEmpty);
      expect(tsdmAppAnswerText({'ok': 1, 'a': 'b'}), '{"ok":1,"a":"b"}');
      expect(tsdmAppAnswerText([1, 2]), '[1,2]');
      expect(tsdmAppAnswerText(_json('reply_ok')), isNot(startsWith('{ok:')));
    });

    test('a redirect: the target, the key of the forward', () {
      final result = tsdmAppWriteResultOf(_json('reply_redirect'))!;
      expect(result.kind, TsdmAppWriteKind.redirect);
      expect(result.succeeded, isTrue);
      expect(result.alert, isEmpty);
      expect(result.message, isEmpty);
      expect(result.messageKey, 'post_reply_succeed');
      expect(result.url, 'forum.php?mod=viewthread&tid=9199849&pid=4752&page=1&extra=#pid4752');
      expect(
        result.document.querySelector('div#messagetext.alert_right p.alert_btnleft a')?.attributes['href'],
        result.url,
      );
    });

    test('a page: the document as the plugin cut it, wrapped as the JSON mode wraps a page', () {
      final form = tsdmAppWriteResultOf(_json('page_case'))!;
      expect(form.kind, TsdmAppWriteKind.page);
      expect(form.ok, isTrue);
      expect(form.message, isEmpty);
      expect(form.documentHtml, contains('<form id="rateform"'));
      expect(
        form.document.querySelector('div#wp form#rateform input[name="formhash"]')?.attributes['value'],
        'f1f2f3f4',
      );
      expect(
        form.document.querySelector('form#rateform input[name="pid"]')?.attributes['value'],
        matches(RegExp(r'^\d+$')),
      );
      expect(form.html, contains('<div id="wp" class="wp">'));
      final profile = tsdmAppWriteResultOf(_json('profile_msg'))!;
      expect(profile.kind, TsdmAppWriteKind.page);
      expect(profile.documentHtml, contains("parent.show_success('')"));
      expect(profile.head, isEmpty);
      final checkin = tsdmAppWriteResultOf(_json('checkin'))!;
      expect(checkin.document.querySelector('div#dsu_ps_msg')?.innerText, contains('签到成功'));
      // A page the forum answered with an error status is not ok, but still a page.
      expect(tsdmAppWriteResultOf({...profile.json, 'ok': 0})!.succeeded, isFalse);
      expect(tsdmAppWriteResultOf({...profile.json, 'ok': 0})!.kind, TsdmAppWriteKind.page);
    });

    test("nothing else is a result: the forum's own answers, other JSON answers, text that is not JSON", () {
      // The forum's own answers: the AJAX fragment, the page, the redirect's empty body, the 503 of a bad form hash.
      for (final name in ['reply_ok', 'reply_dup', 'favorite_msg', 'reply_redirect', 'page_case', 'formhash_bad']) {
        expect(tsdmAppWriteResultOf(_orig(name).body), isNull, reason: name);
      }
      // The JSON mode answers of a page (plugin 2.x) and the API's own answers.
      expect(tsdmAppWriteResultOf({'ok': 1, 'api': 1, 'type': 'forum', 'schema': 2, 'document': ''}), isNull);
      expect(tsdmAppWriteResultOf({'ok': 0, 'error': 'message', 'message': 'x', 'login': 1}), isNull);
      expect(tsdmAppWriteResultOf({'ok': 1, 'version': '2.6.0', 'formhash': 'f1f2f3f4'}), isNull);
      // A result of a kind this app does not know, a result that is not an object.
      expect(tsdmAppWriteResultOf({'ok': 1, 'type': 'result', 'schema': 13, 'kind': 'future'}), isNull);
      expect(tsdmAppWriteResultOf([1, 2]), isNull);
      expect(tsdmAppWriteResultOf(null), isNull);
      expect(tsdmAppWriteResultOf(''), isNull);
      expect(tsdmAppWriteResultOf('{"ok":1,"type":"result","kind":'), isNull, reason: 'malformed JSON');
      expect(tsdmAppWriteResultOf('<root><![CDATA[{"ok":1}]]></root>'), isNull);
      // The same answer as text (a client that did not decode it) is a result as well.
      expect(tsdmAppWriteResultOf(jsonEncode(_json('reply_ok')))?.kind, TsdmAppWriteKind.handle);
      expect(tsdmAppWriteResultOf(' ${jsonEncode(_json('rate_dup'))}')?.messageKey, 'thread_rate_duplicate');
    });

    test('withTsdmAppJsonWrite: the parameter once, on AJAX urls too, before the fragment, never nodoc', () {
      const ajax = '$baseUrl/forum.php?mod=misc&action=rate&tid=1&pid=2&infloat=yes&handlekey=rate&inajax=1';
      expect(withTsdmAppJsonWrite(ajax), '$ajax&tsdmapp=json');
      expect(withTsdmAppJsonWrite('$baseUrl/forum.php'), '$baseUrl/forum.php?tsdmapp=json');
      expect(withTsdmAppJsonWrite('$baseUrl/forum.php?'), '$baseUrl/forum.php?tsdmapp=json');
      expect(
        withTsdmAppJsonWrite('$baseUrl/home.php?mod=space&do=pm#last'),
        '$baseUrl/home.php?mod=space&do=pm&tsdmapp=json#last',
      );
      expect(withTsdmAppJsonWrite(withTsdmAppJsonWrite(ajax)), '$ajax&tsdmapp=json');
      expect(withTsdmAppJsonWrite(withTsdmAppJson('$baseUrl/forum.php')), '$baseUrl/forum.php?tsdmapp=json&nodoc=1');
      expect(Uri.parse(withTsdmAppJsonWrite(ajax)).queryParameters, isNot(contains('nodoc')));
      // The JSON mode of a page still leaves an AJAX url alone.
      expect(withTsdmAppJson(ajax), ajax);
      expect(
        compareTsdmAppVersions(expectedTsdmAppVersion, '2.6.0'),
        greaterThanOrEqualTo(0),
        reason: 'the write results came with 2.6.0',
      );
    });

    test('tsdmAppWriteAnswerHtml: the page of a result, text as it is', () {
      expect(tsdmAppWriteAnswerHtml(_orig('reply_ok').body), _orig('reply_ok').body);
      expect(tsdmAppWriteAnswerHtml('<html></html>'), '<html></html>');
      expect(tsdmAppWriteAnswerHtml(null), isEmpty);
      final message = tsdmAppWriteAnswerHtml(_json('reply_msg_error'));
      expect(
        parseHtmlDocument(message).querySelector('div#messagetext.alert_error > p')?.innerText.trim(),
        '抱歉，指定的主题不存在或已被删除或正在被审核',
      );
      final page = tsdmAppWriteAnswerHtml(_json('checkin'));
      expect(parseHtmlDocument(page).querySelector('div#wp div#dsu_ps_msg'), isNotNull);
      // The forum's 提示信息 of a plugin's form (the medal and title tools, the title shop, the bank) read from it.
      final formResult = parseFormResult(message);
      expect(formResult.success, isFalse);
      expect(formResult.message, parseFormResult(_orig('reply_msg_error').body).message);
      expect(parseFormResult(tsdmAppWriteAnswerHtml(_json('favorite_msg'))).success, isTrue);
    });
  });

  group('B. the choke point: every form posted asks for the result', () {
    test('postForm carries tsdmapp=json (no nodoc) and the AJAX header on an AJAX url; not when told not to', () async {
      final forum = _Forum.always(_ajax(_orig('reply_ok').body));
      final client = _client(forum);
      await client.postForm(formatReplyThreadUrl('2', '9199849'), data: {'message': 'hi'}).run();
      await client.postForm('$baseUrl/home.php?mod=spacecp&ac=profile&op=base', data: {'x': '1'}).run();
      await client.postForm(formatReplyThreadUrl('2', '9199849'), data: {'message': 'hi'}, tsdmAppJson: false).run();
      await client.postMultipartForm('$baseUrl/home.php?mod=spacecp&ac=profile&op=base', data: {'x': '1'}).run();
      await client.postMultipartForm('$baseUrl/home.php?mod=spacecp', data: {'x': '1'}, tsdmAppJson: false).run();
      expect(forum.requests.map((r) => r.method).toSet(), {'POST'});
      expect(forum.requests.map(_asksJson), [true, true, false, true, false]);
      expect(forum.requests.map(_asksLean), everyElement(isFalse));
      expect(forum.requests.map(_ajaxHeader), [true, false, true, false, false]);
      // The form body is not touched.
      expect(forum.requests.first.body, 'message=hi');
      expect(forum.requests.first.uri.queryParameters['inajax'], '1');
    });

    test("the plugin's own API is posted as it is", () async {
      final forum = _Forum.always(_api({'ok': 1, 'api': 1, 'version': '2.6.0', 'time': 1792523400, 'uid': 35}));
      final answer = await TsdmAppApi.post(_client(forum), 'seen', {'formhash': 'f1f2f3f4', 'notice': '1'});
      expect(answer?['ok'], 1);
      expect(forum.requests.single.uri.queryParameters['action'], 'seen');
      expect(_asksJson(forum.requests.single), isFalse);
    });

    test('a GET asks the AJAX header only on an AJAX url, and never asks for the result by itself', () async {
      final forum = _Forum.always(_ajax(_orig('reply_ok').body));
      final client = _client(forum);
      await client.get('$baseUrl/misc.php?mod=getatuser&inajax=1').run();
      await client.get('$baseUrl/forum.php?mod=viewthread&tid=1').run();
      await client
          .get(
            '$baseUrl/forum.php?mod=misc&action=rate&inajax=1',
            options: Options(headers: {'X-Requested-With': 'other'}),
          )
          .run();
      expect(forum.requests.map(_ajaxHeader), [true, false, false]);
      expect(forum.requests[2].headers['X-Requested-With'], 'other', reason: 'a header set by the caller is kept');
      expect(forum.requests.map(_asksJson), everyElement(isFalse));
    });
  });

  group('C. the reply', () {
    test('a reply stored, from the hook (an older plugin) and from the result', () async {
      final origPid = _idIn(_orig('reply_ok').body, r'[?&]pid=(\d+)');
      for (final (answer, pid) in [(_api(_json('reply_ok')), '4750'), (_web(_orig('reply_ok')), origPid)]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final posted = _right(
          await const ReplyRepository().replyToThread(replyParameters: _reply, replyMessage: 'hi').run(),
        );
        expect(posted, (pid: pid, page: 1));
        final request = forum.requests.single;
        expect(request.method, 'POST');
        expect(_asksJson(request), isTrue);
        expect(_asksLean(request), isFalse);
        expect(_ajaxHeader(request), isTrue);
        expect(Uri.splitQueryString(request.body)['message'], 'hi');
        await getIt.unregister<NetClientProvider>();
      }
    });

    test(
      "a reply refused: the flood control, the guest, the thread gone, with the forum's reason either way",
      () async {
        const reasons = {
          'reply_dup': '抱歉，您两次发表间隔少于 15 秒，请稍候再发表',
          'reply_guest': '抱歉，您尚未登录，没有权限在该版块回帖',
          'reply_msg_error': '抱歉，指定的主题不存在或已被删除或正在被审核',
        };
        for (final MapEntry(key: name, value: reason) in reasons.entries) {
          for (final answer in [_api(_json(name)), _web(_orig(name))]) {
            _use(_Forum.always(answer));
            final failure = _left(
              await const ReplyRepository().replyToThread(replyParameters: _reply, replyMessage: 'hi').run(),
            );
            expect(failure, isA<ReplyToThreadResultFailedException>(), reason: name);
            expect(failure.message, reason, reason: name);
            await getIt.unregister<NetClientProvider>();
          }
        }
      },
    );

    test(
      'a reply the forum answered with a redirect: stored, with the new post; the redirect itself fails as ever',
      () async {
        _use(_Forum.always(_api(_json('reply_redirect'))));
        final posted = _right(
          await const ReplyRepository().replyToThread(replyParameters: _reply, replyMessage: 'hi').run(),
        );
        expect(posted, (pid: '4752', page: 1));
        await getIt.unregister<NetClientProvider>();
        // Without the plugin a 301 of a POST is the failed request it always was (the thread is read again later).
        _use(_Forum.always(_web(_orig('reply_redirect'))));
        expect(
          _left(await const ReplyRepository().replyToThread(replyParameters: _reply, replyMessage: 'hi').run()),
          isA<HttpHandshakeFailedException>(),
        );
      },
    );

    test('a reply to a floor: the window read as a page result, then the hook', () async {
      final window = _raw('test/data/reply_window_x5.xml');
      for (final (windowAnswer, resultAnswer, pid) in [
        (_api(_page(window)), _api(_json('reply_ok')), '4750'),
        (_ajax(window), _web(_orig('reply_ok')), _idIn(_orig('reply_ok').body, r'[?&]pid=(\d+)')),
      ]) {
        final forum = _Forum((r) => r.method == 'GET' ? windowAnswer : resultAnswer);
        _use(forum);
        final posted = _right(
          await const ReplyRepository()
              .replyToPost(
                replyParameters: _reply,
                replyAction:
                    'forum.php?mod=post&action=reply&fid=2&tid=9199849&reppost=4743&extra=page%3D1&page=1&usesig=1&replyuid=35',
                replyMessage: 'hi',
              )
              .run(),
        );
        expect(posted, (pid: pid, page: 1));
        expect(forum.requests.map((r) => r.method), ['GET', 'POST']);
        expect(forum.requests.map(_asksJson), [true, true]);
        expect(forum.requests.map(_ajaxHeader), [true, true]);
        final form = Uri.splitQueryString(forum.requests.last.body);
        expect(form['formhash'], isNotEmpty);
        expect(form['reppid'], isNotEmpty);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test("the window refused in the result: no form, the forum's reason", () async {
      _use(_Forum.always(_api(_json('reply_guest'))));
      final failure = _left(
        await const ReplyRepository()
            .replyToPost(
              replyParameters: _reply,
              replyAction: 'forum.php?mod=post&action=reply&fid=2&tid=9199849&reppost=4743',
              replyMessage: 'hi',
            )
            .run(),
      );
      expect(failure, isA<ReplyToPostFetchParameterFailedException>());
    });

    test('a private message sent, or refused with the reason', () async {
      final refused = _handle('pm_ok', {
        'ok': 0,
        'alert': 'error',
        'message': '抱歉，对方拒绝接收私信',
        'message_key': '',
        'url': '',
        'values': <String, Object?>{},
        'handlekey': 'showmsg_38',
      });
      final refusedAjax = _errorAjax('showmsg_38', '抱歉，对方拒绝接收私信');
      for (final (answer, sent) in [
        (_api(_json('pm_ok')), true),
        (_web(_orig('pm_ok')), true),
        (_api(refused), false),
        (_ajax(refusedAjax), false),
      ]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final result = await const ReplyRepository().replyPersonalMessage('38', {
          'message': 'hi',
          'formhash': 'f1f2f3f4',
        }).run();
        if (sent) {
          _right(result);
        } else {
          final failure = _left(result);
          expect(failure, isA<ReplyPersonalMessageFailedException>());
          expect(failure.message, '抱歉，对方拒绝接收私信');
        }
        expect(_asksJson(forum.requests.single), isTrue);
        expect(_ajaxHeader(forum.requests.single), isTrue);
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group('D. the rate', () {
    const target = '$baseUrl/forum.php?mod=misc&action=rate&tid=9199849&pid=4743';

    test('the rate window: the form of a page result, as from the fragment', () async {
      for (final answer in [_api(_json('page_case')), _web(_orig('page_case'))]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final info = _right(await RateRepository().fetchInfo(pid: '4743', rateTarget: target).run());
        expect(info.formHash, 'f1f2f3f4');
        expect(info.tid, '9199849');
        expect(info.scoreList.map((e) => e.name), ['威望', '天使币']);
        expect(info.defaultReasonList, hasLength(5));
        final request = forum.requests.single;
        expect(request.method, 'GET');
        expect(_asksJson(request), isTrue);
        expect(_asksLean(request), isFalse);
        expect(_ajaxHeader(request), isTrue);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test("the window refused: the forum's reason from the hook", () async {
      _use(
        _Forum.always(_api(_handle('rate_dup', {'message': '抱歉，您没有权限评分', 'message_key': 'thread_rate_nopermission'}))),
      );
      final failure = _left(await RateRepository().fetchInfo(pid: '4743', rateTarget: target).run());
      expect(failure, isA<RateInfoWithErrorException>());
      expect(failure.message, '抱歉，您没有权限评分');
    });

    test('a rate taken, a rate refused, either way', () async {
      for (final (answer, reason) in [
        (_api(_json('rate_ok')), null),
        (_web(_orig('rate_ok')), null),
        (_api(_json('rate_dup')), '抱歉，您不能对同一个帖子重复评分'),
        (_web(_orig('rate_dup')), '抱歉，您不能对同一个帖子重复评分'),
      ]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final result = await RateRepository().rate({
          'formhash': 'f1f2f3f4',
          'tid': '9199849',
          'pid': '4743',
          'score2': '10',
        }).run();
        if (reason == null) {
          _right(result);
        } else {
          final failure = _left(result);
          expect(failure, isA<RateFailedException>().having((e) => e.reason, 'reason', reason));
        }
        expect(_asksJson(forum.requests.single), isTrue);
        expect(forum.requests.single.uri.queryParameters['ratesubmit'], 'yes');
        await getIt.unregister<NetClientProvider>();
      }
    });
    test(
      'without a message: no reason (the page says its own), the login prompt, a page read as the fragment',
      () async {
        const formData = {'formhash': 'f1f2f3f4', 'tid': '9199849', 'pid': '4743', 'score2': '10'};
        Future<Either<AppException, void>> rate(Map<String, dynamic> answer) async {
          _use(_Forum.always(_api(answer)));
          final result = await RateRepository().rate(formData).run();
          await getIt.unregister<NetClientProvider>();
          return result;
        }

        final bare = _handle('rate_dup', {'message': '', 'message_key': ''});
        expect(_left(await rate(bare)), isA<RateFailedException>().having((e) => e.reason, 'reason', isEmpty));
        expect(
          _left(await rate({...bare, 'login': 1})),
          isA<RateFailedException>().having((e) => e.reason, 'reason', t.general.needLogin),
        );
        // A page is read as the forum's fragment would be: a refusal in it, or a success.
        _right(await rate(_page('<root><![CDATA[<div class="c">ok</div>]]></root>')));
        expect(
          _left(await rate(_page(_errorAjax('rate', '抱歉，您的天使币不足，无法评分')))),
          isA<RateFailedException>().having((e) => e.reason, 'reason', '抱歉，您的天使币不足，无法评分'),
        );
        expect(
          _left(await rate({..._page('<root><![CDATA[<div></div>]]></root>'), 'ok': 0})),
          isA<RateFailedException>(),
        );
        // The window refused without a message: the form is not understood, as before.
        _use(_Forum.always(_api(bare)));
        expect(
          _left(
            await RateRepository().fetchInfo(pid: '4743', rateTarget: '$baseUrl/forum.php?mod=misc&action=rate').run(),
          ),
          isA<RateInfoInvalidDivCNode>(),
        );
      },
    );
  });

  group('E. the favorites', () {
    test('the answers of the forms: added with the favid, already there, removed, gone', () {
      expect(
        parseFavoriteAddResult(_json('favorite_add')),
        isA<FavoriteAdded>().having((e) => e.favid, 'favid', '524'),
      );
      final origFavid = _idIn(_orig('favorite_add').body, r"'favid':'(\d+)'");
      expect(
        parseFavoriteAddResult(_orig('favorite_add').body),
        isA<FavoriteAdded>().having((e) => e.favid, 'favid', origFavid),
      );
      expect(parseFavoriteAddResult(_json('favorite_repeat')), isA<FavoriteAlreadyExists>());
      expect(parseFavoriteAddResult(_orig('favorite_repeat').body), isA<FavoriteAlreadyExists>());
      // Intentionally different: the same favorite posted without `inajax` is answered the forum's whole 提示信息
      // page. The forum's own answer has no hook there, so the old parser can only report the page's text as a
      // failure; the app API's result tells the success (`message`, alert right) without the favid (no hook values).
      // The app always posts the favorite with `inajax=1`, so this answer does not reach it.
      expect(parseFavoriteAddResult(_json('favorite_msg')), isA<FavoriteAdded>().having((e) => e.favid, 'favid', null));
      expect(parseFavoriteAddResult(_orig('favorite_msg').body), isA<FavoriteAddFailed>());
      final refused = _handle('favorite_repeat', {'message': '抱歉，您没有权限收藏', 'message_key': ''});
      expect(
        parseFavoriteAddResult(refused),
        isA<FavoriteAddFailed>().having((e) => e.message, 'message', '抱歉，您没有权限收藏'),
      );
      expect(
        parseFavoriteAddResult(_errorAjax('favoritethread', '抱歉，您没有权限收藏')),
        isA<FavoriteAddFailed>().having((e) => e.message, 'message', '抱歉，您没有权限收藏'),
      );
      expect(parseFavoriteRemoveResult(_json('favorite_del')).removed, isTrue);
      expect(parseFavoriteRemoveResult(_orig('favorite_del').body).removed, isTrue);
      final gone = _handle('favorite_repeat', {
        'message': '抱歉，您指定的收藏不存在',
        'message_key': 'favorite_nonexistence',
        'handlekey': 'favdelete',
      });
      expect(parseFavoriteRemoveResult(gone).removed, isTrue);
      expect(parseFavoriteRemoveResult(gone).message, '抱歉，您指定的收藏不存在');
      expect(parseFavoriteRemoveResult(_errorAjax('favdelete', '抱歉，您指定的收藏不存在')).removed, isTrue);
      expect(parseFavoriteRemoveResult(_json('favorite_repeat')).removed, isFalse);
    });

    test('the dialogs: the form of a page result, none in a notice', () {
      final xml = _raw('test/data/favorite_add_form_x5.xml');
      final fromFragment = parseFavoriteForm(xml)!;
      final fromResult = parseFavoriteForm(_page(xml))!;
      expect(fromResult, fromFragment);
      expect(fromResult.formHash, isNotEmpty);
      expect(parseFavoriteForm(_json('favorite_repeat')), isNull);
      expect(parseFavoriteForm(_orig('favorite_repeat').body), isNull);
      expect(parseFavoriteForm(_raw('test/data/favorite_add_dialog_repeat_x5.xml')), isNull);
    });

    test('adding a thread: the dialog and the form, both asked for the result', () async {
      final dialog = _raw('test/data/favorite_add_form_x5.xml');
      for (final (dialogAnswer, formAnswer, favid) in [
        (_api(_page(dialog)), _api(_json('favorite_add')), '524'),
        (_ajax(dialog), _web(_orig('favorite_add')), _idIn(_orig('favorite_add').body, r"'favid':'(\d+)'")),
      ]) {
        final forum = _Forum((r) => r.method == 'GET' ? dialogAnswer : formAnswer);
        _use(forum);
        final repository = FavoriteRepository();
        final result = _right(await repository.addFavorite(tid: '9199845', description: 'note').run());
        expect(result, isA<FavoriteAdded>().having((e) => e.favid, 'favid', favid));
        expect(forum.requests.map((r) => r.method), ['GET', 'POST']);
        expect(forum.requests.map(_asksJson), [true, true]);
        expect(forum.requests.map(_ajaxHeader), [true, true]);
        expect(forum.requests.first.uri.queryParameters['inajax'], '1');
        expect(Uri.splitQueryString(forum.requests.last.body)['description'], 'note');
        await repository.dispose();
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group('F. the friends', () {
    test('the request sent (a note) and refused, either way', () {
      for (final answer in [_json('friend_add'), _orig('friend_add').body]) {
        final result = parseAddFriendResult(answer);
        expect(result.success, isTrue);
        expect(result.message, '好友请求已发送，请等待对方验证');
      }
      for (final answer in [_json('friend_again'), _orig('friend_again').body]) {
        final result = parseAddFriendResult(answer);
        expect(result.success, isFalse);
        expect(result.message, '正在等待验证');
      }
    });

    test("a result without a message: the forum's page text or the app's own words, never the kind", () {
      final bare = {'message': '', 'message_key': '', 'url': ''};
      final sent = parseAddFriendResult(_handle('friend_add', bare));
      expect(sent.success, isTrue);
      expect(sent.message, t.friendPage.addFriend.sent);
      final refused = parseAddFriendResult(_handle('friend_again', bare));
      expect(refused.success, isFalse);
      expect(refused.message, t.friendPage.addFriend.failed);
      expect(parseAddFriendResult({..._json('reply_redirect'), 'ok': 0}).message, t.friendPage.addFriend.failed);
      expect(parseAddFriendResult(_handle('friend_again', {...bare, 'login': 1})).message, t.general.needLogin);
      final window = parseAddFriendForm(_handle('friend_again', bare));
      expect(window, isA<AddFriendRefused>().having((e) => e.message, 'message', t.friendPage.addFriend.failed));
      // A page without a form and without text: the app's words, not the decoded answer.
      final empty = parseAddFriendForm(_page('<root><![CDATA[<div></div>]]></root>'));
      expect(empty, isA<AddFriendRefused>().having((e) => e.message, 'message', t.friendPage.addFriend.failed));
      for (final result in [sent, refused]) {
        expect(result.message, isNot(anyOf('handle', 'message', 'redirect', 'page')));
      }
    });

    test('the add-friend form of a page result, the refusal in the window', () {
      final xml = _raw('test/data/friend_add_form_x5.xml');
      final fromFragment = parseAddFriendForm(xml) as AddFriendForm;
      final fromResult = parseAddFriendForm(_page(xml)) as AddFriendForm;
      expect(fromResult.formHash, fromFragment.formHash);
      expect(fromResult.groups.map((g) => g.gid), fromFragment.groups.map((g) => g.gid));
      expect(fromResult.selectedGid, fromFragment.selectedGid);
      expect(fromResult.targetName, fromFragment.targetName);
      expect(
        parseAddFriendForm(_json('friend_again')),
        isA<AddFriendRefused>().having((e) => e.message, 'message', '正在等待验证'),
      );
      expect(
        parseAddFriendForm(_orig('friend_again').body),
        isA<AddFriendRefused>().having((e) => e.message, 'message', '正在等待验证'),
      );
    });

    test('sending the request: the form and the result, both asked for the result', () async {
      final forum = _Forum(
        (r) => r.method == 'GET' ? _api(_page(_raw('test/data/friend_add_form_x5.xml'))) : _api(_json('friend_add')),
      );
      _use(forum);
      final form = _right(await const FriendRepository().fetchAddFriendForm('38').run()) as AddFriendForm;
      final result = _right(await const FriendRepository().addFriend(uid: '38', formHash: form.formHash).run());
      expect(result.success, isTrue);
      expect(forum.requests.map(_asksJson), [true, true]);
      expect(forum.requests.map(_ajaxHeader), [true, true]);
    });

    test('the approval form of a page result, checked as the fragment is; the refusal', () {
      final xml = _raw('test/data/friend_accept_form_x5.xml');
      final fromFragment = parseApproveFriendForm(xml, targetUid: 1000) as ApproveFriendForm;
      final fromResult = parseApproveFriendForm(_page(xml), targetUid: 1000) as ApproveFriendForm;
      expect(fromResult.fields, fromFragment.fields);
      expect(fromResult.groups.map((g) => (g.gid, g.name)), fromFragment.groups.map((g) => (g.gid, g.name)));
      expect(fromResult.selectedGid, fromFragment.selectedGid);
      expect(fromResult.targetName, fromFragment.targetName);
      // Another member's form is refused from the result as from the fragment.
      expect(() => parseApproveFriendForm(_page(xml), targetUid: 1001), throwsA(isA<ApproveFriendRejected>()));
      // The forum's refusal, the login prompt, and a result without a form or a message.
      final refused = _handle('friend_again', {'message': '抱歉，该申请已不存在', 'handlekey': 'afrfriendhk_1001'});
      expect(
        parseApproveFriendForm(refused, targetUid: 1000),
        isA<ApproveFriendRefused>().having((e) => e.message, 'message', '抱歉，该申请已不存在'),
      );
      expect(
        parseApproveFriendForm(_errorAjax('afrfriendhk_1001', '抱歉，该申请已不存在'), targetUid: 1000),
        isA<ApproveFriendRefused>(),
      );
      expect(
        () => parseApproveFriendForm({...refused, 'login': 1}, targetUid: 1000),
        throwsA(isA<ApproveFriendRejected>().having((e) => e.failure, 'failure', ApproveFriendFailure.notLoggedIn)),
      );
      expect(
        () => parseApproveFriendForm(_json('reply_redirect'), targetUid: 1000),
        throwsA(isA<ApproveFriendRejected>()),
      );
    });

    test('the approval result: only the hook of this form, for this member', () {
      final fragment = _raw('test/data/friend_accept_result_x5.xml');
      final result = _handle('friend_add', {
        'message': '您已和Alice成为好友',
        'message_key': '',
        'url': 'https://www.tsdm39.com/forum.php',
        'handlekey': 'afrfriendhk_1001',
        'values': {'username': 'Alice', 'uid': '1000', 'from': ''},
      });
      for (final answer in [result, fragment]) {
        final approved = parseApproveFriendResult(answer, handleKey: 'afrfriendhk_1001', targetUid: 1000);
        expect(approved.success, isTrue);
        expect(approved.message, '您已和Alice成为好友');
        expect(
          () => parseApproveFriendResult(answer, handleKey: 'afrfriendhk_1002', targetUid: 1000),
          throwsA(isA<ApproveFriendRejected>()),
        );
        expect(
          () => parseApproveFriendResult(answer, handleKey: 'afrfriendhk_1001', targetUid: 1001),
          throwsA(isA<ApproveFriendRejected>()),
        );
      }
      final refused = parseApproveFriendResult(
        _handle('friend_again', {'handlekey': 'afrfriendhk_1001'}),
        handleKey: 'afrfriendhk_1001',
        targetUid: 1000,
      );
      expect(refused.success, isFalse);
      expect(refused.message, '正在等待验证');
      expect(
        parseApproveFriendResult(
          _errorAjax('afrfriendhk_1001', '正在等待验证'),
          handleKey: 'afrfriendhk_1001',
          targetUid: 1000,
        ).success,
        isFalse,
      );
      expect(
        () => parseApproveFriendResult(_json('page_case'), handleKey: 'afrfriendhk_1001', targetUid: 1000),
        throwsA(isA<ApproveFriendRejected>()),
      );
    });
  });

  group('G. the report', () {
    final form = parsePostReportForm(reportFormAjax(), target: reportTarget);
    const handle = 'miscreport$reportPid';

    test('the dialog of a page result is the same form', () {
      final fromResult = parsePostReportForm(jsonEncode(_page(reportFormAjax())), target: reportTarget);
      expect(fromResult.action, form.action);
      expect(fromResult.hidden, form.hidden);
      expect(fromResult.reasons, form.reasons);
      // The forum's refusal and the login prompt in the window.
      expect(
        () => parsePostReportForm(
          jsonEncode(_handle('report_ok', {'ok': 0, 'alert': 'error', 'message': '抱歉，您没有权限举报', 'handlekey': handle})),
          target: reportTarget,
        ),
        throwsA(isA<PostReportFailure>().having((e) => e.message, 'message', '抱歉，您没有权限举报')),
      );
      expect(
        () => parsePostReportForm(
          jsonEncode(
            _handle('report_ok', {'ok': 0, 'login': 1, 'alert': 'error', 'message': '请先登录', 'handlekey': handle}),
          ),
          target: reportTarget,
        ),
        throwsA(isA<PostReportFailure>().having((e) => e.problem, 'problem', PostReportProblem.notLoggedIn)),
      );
    });

    test('the report stored, refused or unknown, either way', () {
      final stored = _handle('report_ok', {'handlekey': handle});
      expect(
        parsePostReportResult(jsonEncode(stored), form: form),
        isA<PostReportSucceeded>().having((e) => e.message, 'message', '举报成功'),
      );
      // The real answers of the sampled report, with the handle key of this form (the sample was sent with
      // `miscreport`): the same success either way.
      final origSuccess = _orig('report_ok').body.replaceAll('miscreport', handle);
      expect(origSuccess, contains("errorhandle_$handle('举报成功 ', {})"));
      expect(
        parsePostReportResult(origSuccess, form: form),
        isA<PostReportSucceeded>().having((e) => e.message, 'message', '举报成功'),
      );
      expect(
        parsePostReportResult(successAjax(text: '举报成功 '), form: form),
        isA<PostReportSucceeded>().having((e) => e.message, 'message', '举报成功'),
      );
      final refused = _handle('report_ok', {
        'ok': 0,
        'alert': 'error',
        'message': '您已经举报过',
        'message_key': 'report_repeat',
        'handlekey': handle,
      });
      expect(
        parsePostReportResult(jsonEncode(refused), form: form),
        isA<PostReportRejected>()
            .having((e) => e.message, 'message', '您已经举报过')
            .having((e) => e.notLoggedIn, 'notLoggedIn', isFalse),
      );
      expect(
        parsePostReportResult(rejectionAjax(text: '您已经举报过'), form: form),
        isA<PostReportRejected>().having((e) => e.message, 'message', '您已经举报过'),
      );
      expect(
        parsePostReportResult(jsonEncode({...refused, 'login': 1}), form: form),
        isA<PostReportRejected>().having((e) => e.notLoggedIn, 'notLoggedIn', isTrue),
      );
      // Another form's hook, a success with values, a page: unknown, as ever.
      expect(parsePostReportResult(jsonEncode(_json('report_ok')), form: form), isA<PostReportUnknown>());
      expect(parsePostReportResult(successAjax(handle: 'miscreport1'), form: form), isA<PostReportUnknown>());
      expect(
        parsePostReportResult(
          jsonEncode({
            ...stored,
            'values': {'rid': '1'},
          }),
          form: form,
        ),
        isA<PostReportUnknown>(),
      );
      expect(parsePostReportResult(jsonEncode(_json('page_case')), form: form), isA<PostReportUnknown>());
      expect(parsePostReportResult(jsonEncode(_json('reply_msg_error')), form: form), isA<PostReportUnknown>());
    });
  });

  group('H. the check-in', () {
    test("the check-in plugin's window as a page result, the forum's message as its text", () {
      for (final name in ['checkin', 'checkin_again']) {
        final fromResult = parseCheckinResponseMessage(_json(name));
        final fromFragment = parseCheckinResponseMessage(_orig(name).body);
        expect(fromResult, isNotNull, reason: name);
        expect(
          fromResult!.replaceAll(RegExp('[0-9]'), ''),
          fromFragment!.replaceAll(RegExp('[0-9]'), ''),
          reason: name,
        );
      }
      expect(parseCheckinResponseMessage(_json('checkin')), contains('签到成功'));
      expect(parseCheckinResponseMessage(_json('checkin_again')), '您今日已经签到，请明天再来！');
      expect(parseCheckinResponseMessage(_handle('reply_guest', {'message': '您需要先登录才能继续本操作'})), '您需要先登录才能继续本操作');
      expect(parseCheckinResponseMessage(_errorAjax('qwindow', '您需要先登录才能继续本操作')), '您需要先登录才能继续本操作');
    });

    test('a whole page (not the AJAX fragment) is read, not thrown on', () {
      // The xml parser throws a state error (not an exception) on a whole html page.
      expect(() => parseXmlDocument(_orig('reply_msg_error').body), throwsStateError);
      expect(() => parseCheckinResponseMessage(_orig('reply_msg_error').body), returnsNormally);
      expect(() => parseCheckinResponseMessage(_orig('favorite_msg').body), returnsNormally);
    });

    /// A forum whose check-in API says the check-in is open (with the form hash) and answers the post with [post].
    _Forum checkinForum(_Answer post) => _Forum((r) {
      if (r.uri.queryParameters['id'] == 'tsdmapp:api') {
        return _api({
          'ok': 1,
          'api': 1,
          'time': 1792523400,
          'installed': 1,
          'checked_today': 0,
          'can_checkin': 1,
          'window': {'enabled': 1, 'start_hour': 1, 'end_hour': 23, 'open_now': 1},
          'day_start': 1792512000,
          'last_time': 0,
          'days': 3,
          'month_days': 1,
          'formhash': 'f1f2f3f4',
        });
      }
      return post;
    });

    test('doCheckin: the result of the post, either way; a result no reader knows is told as text', () async {
      Future<CheckinResult> run(_Answer post) =>
          doCheckin(_client(checkinForum(post)), CheckinFeeling.happy, 'hi').run();
      expect(await run(_api(_json('checkin'))), isA<CheckinResultSuccess>());
      expect(await run(_web(_orig('checkin'))), isA<CheckinResultSuccess>());
      expect(await run(_api(_json('checkin_again'))), isA<CheckinResultAlreadyChecked>());
      expect(await run(_web(_orig('checkin_again'))), isA<CheckinResultAlreadyChecked>());
      // The login prompt of the app API is the expired session.
      final login = {..._json('reply_msg_error'), 'message': '', 'login': 1, 'alert': 'info'};
      expect(await run(_api(login)), isA<CheckinResultNotAuthorized>());
      // A page without the window's text: the text of the page, never the decoded answer.
      final empty = await run(_api({..._json('checkin'), 'document': '<script>hideWindow("qwindow");</script>'}));
      expect(empty, isA<CheckinResultOtherError>().having((e) => e.message, 'message', isNot(contains('{'))));
      expect((empty as CheckinResultOtherError).message, isNot(contains('kind')));
    });
  });

  group('I. the profile', () {
    final profile = UserProfile.fromForm(
      parseHtmlDocument(_raw('test/data/profile_edit_form_x5.html')).querySelector('form[target="frame_profile"]')!,
    )!;

    test('saved: the frame script as a page result; refused: the message', () async {
      for (final (answer, saved) in [
        (_api(_json('profile_msg')), true),
        (_web(_orig('profile_msg')), true),
        (_api(_json('reply_msg_error')), false),
        (_web(_orig('reply_msg_error')), false),
        (
          _api({
            ..._json('profile_msg'),
            'ok': 0,
            'document': "<script type=\"text/javascript\">parent.show_error('签名太长');</script>",
          }),
          false,
        ),
      ]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final result = await EditUserProfileRepository().uploadProfile(profile).run();
        if (saved) {
          _right(result);
        } else {
          expect(_left(result), isA<EditUserProfileUploadFailed>());
        }
        expect(forum.requests.single.method, 'POST');
        expect(_asksJson(forum.requests.single), isTrue);
        expect(forum.requests.single.uri.queryParameters['op'], 'base');
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('switching the user group: the hook either way', () async {
      final taken = _handle('rate_ok', {
        'handlekey': 'switchgrouphk',
        'message': '操作成功',
        'message_key': 'do_success',
        'url': '$baseUrl/?mod=spacecp&ac=usergroup&do=expiry',
      });
      final refused = _handle('rate_dup', {
        'handlekey': 'switchgrouphk',
        'message': '抱歉，您不能切换到该用户组',
        'message_key': '',
      });
      const refusedAjax =
          '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="alert_error">抱歉，您不能切换到该用户组</div>]]></root>';
      for (final (answer, reason) in [
        (_api(taken), null),
        (_ajax(_succeedAjax('switchgrouphk', '$baseUrl/?mod=spacecp&ac=usergroup&do=expiry', '操作成功 ')), null),
        (_api(refused), '抱歉，您不能切换到该用户组'),
        (_ajax(refusedAjax), '抱歉，您不能切换到该用户组'),
      ]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final result = await SwitchUserGroupRepository().submitSwitchRequest(3, 'f1f2f3f4').run();
        if (reason == null) {
          _right(result);
        } else {
          final failure = _left(result);
          expect(failure, isA<SwitchUserGroupFailed>());
          expect(failure.message, reason);
        }
        expect(_asksJson(forum.requests.single), isTrue);
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group('J. a new thread, an edited post, a new poll', () {
    Response<dynamic> response(Object? data, {int status = 200}) =>
        Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: status);

    test('parseSubmissionResult: the redirect, the success page, a refusal, a page', () {
      expect(
        parseSubmissionResult(response(_json('reply_redirect')), expectedTid: '9199849'),
        '$baseUrl/forum.php?mod=viewthread&tid=9199849',
      );
      expect(parseSubmissionResult(response(_json('reply_redirect')), expectedTid: '1'), isNull);
      expect(
        parseSubmissionResult(
          response({..._json('reply_redirect'), 'ok': 0, 'login': 1, 'url': 'member.php?mod=logging&action=login'}),
        ),
        isNull,
      );
      final success = {..._json('favorite_msg'), 'url': 'forum.php?mod=viewthread&tid=9199850'};
      expect(parseSubmissionResult(response(success)), '$baseUrl/forum.php?mod=viewthread&tid=9199850');
      expect(parseSubmissionResult(response(_json('reply_msg_error'))), isNull);
      expect(parseSubmissionResult(response(_json('page_case'))), isNull);
      expect(parseSubmissionResult(response(_orig('reply_msg_error').body)), isNull);
      // The forum's own answers as ever: the redirect by its location, the page by its posts.
      final redirected = Response<dynamic>(
        requestOptions: RequestOptions(),
        data: '',
        statusCode: 301,
        headers: Headers.fromMap({
          'location': [_orig('reply_redirect').location!],
        }),
      );
      expect(
        parseSubmissionResult(redirected, expectedTid: '9199849'),
        '$baseUrl/forum.php?mod=viewthread&tid=9199849',
      );
      expect(
        parseSubmissionResult(response(threadPage(tid: 9199849))),
        '$baseUrl/forum.php?mod=viewthread&tid=9199849',
      );
      // A whole page as the plugin cuts it: the blocks as the document, the page head beside them.
      final cut = {
        ..._json('page_case'),
        'document': '<div id="postlist"><div id="post_1"></div></div>',
        'head': '<link href="$baseUrl/forum.php?mod=viewthread&tid=9199849" rel="canonical" />',
      };
      expect(parseSubmissionResult(response(cut)), '$baseUrl/forum.php?mod=viewthread&tid=9199849');
    });

    test("editing a post: the redirect result, the forum's redirect, the refusal either way", () async {
      final location = _orig('reply_redirect').location!;
      for (final (answer, reason) in <(SyncEither<Response<dynamic>>, String?)>[
        (right(response(_json('reply_redirect'))), null),
        (
          left(
            HttpHandshakeFailedException(
              '301',
              statusCode: 301,
              headers: Headers.fromMap({
                'location': [location],
              }),
            ),
          ),
          null,
        ),
        (right(response(_json('reply_msg_error'))), '抱歉，指定的主题不存在或已被删除或正在被审核'),
        (right(response(_orig('reply_msg_error').body)), '抱歉，指定的主题不存在或已被删除或正在被审核'),
      ]) {
        final urls = <String>[];
        final repository = PostEditRepository.withTransport(
          currentUid: () => 35,
          getPage: (url) async => left(HttpRequestFailedException(500)),
          sendForm: (url, body) async {
            urls.add(url);
            return answer;
          },
        );
        final result = await repository
            .postEditedContent(
              formHash: 'f1f2f3f4',
              postTime: '1792523300',
              delattachop: '0',
              wysiwyg: '0',
              fid: '2',
              tid: '9199849',
              pid: '4750',
              page: '1',
              threadType: null,
              threadTitle: null,
              data: 'edited',
              options: const {},
              save: '',
              perm: null,
              price: null,
            )
            .run();
        if (reason == null) {
          _right(result);
        } else {
          expect(_left(result), isA<PostEditFailedToUploadResult>().having((e) => e.errorText, 'errorText', reason));
        }
        expect(urls.single, contains('editsubmit=yes'));
      }
    });

    test('a new poll: the redirect result verified by its thread, the refusal either way', () async {
      const draft = PollDraft(
        subject: 'Synthetic poll',
        message: '',
        options: ['Alpha', 'Beta'],
        maxChoices: '1',
        expiry: '',
        visibleAfterVote: false,
        publicVoters: false,
        threadType: null,
        extraOptions: [],
      );
      final location = _orig('reply_redirect').location!;
      for (final (answer, outcome, reason) in <(SyncEither<Response<dynamic>>, PollCreateOutcome, String?)>[
        (right(response(_json('reply_redirect'))), PollCreateOutcome.unconfirmed, null),
        (right(pollResponse('', status: 301, location: location)), PollCreateOutcome.unconfirmed, null),
        (right(response(_json('reply_msg_error'))), PollCreateOutcome.rejected, '抱歉，指定的主题不存在或已被删除或正在被审核'),
        (right(response(_orig('reply_msg_error').body)), PollCreateOutcome.rejected, '抱歉，指定的主题不存在或已被删除或正在被审核'),
      ]) {
        final gets = <String>[];
        final repository = PollCreateRepository.withTransport(
          currentUid: () => 1000,
          getPage: (url) async {
            gets.add(url);
            // The thread itself cannot be read here: the redirect's target is verified, never trusted.
            return url.contains('viewthread') ? left(HttpRequestFailedException(500)) : right(pollResponse(pollForm()));
          },
          sendForm: (url, body) async => answer,
        );
        final form = (await repository.fetchForm('4')).form!;
        final result = await repository.submit(form, validatePollDraft(draft, form).submission!);
        expect(result.outcome, outcome);
        expect(result.message, reason);
        if (outcome == PollCreateOutcome.unconfirmed) {
          expect(result.tid, '9199849');
          expect(gets.last, contains('viewthread&tid=9199849'));
        }
      }
    });
  });

  group('K. the purchase', () {
    test('the dialog of a page result, as from the fragment; the notice', () async {
      final xml = _raw('test/data/pay_dialog_x5.xml');
      for (final answer in [_api(_page(xml)), _ajax(xml)]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final info = _right(await PurchaseRepository().fetchPurchaseConfirmInfo(tid: '9199849', pid: '4743').run());
        expect(info.formHash, isNotEmpty);
        expect(info.handleKey, 'pay');
        expect(info.price, isNotNull);
        expect(_asksJson(forum.requests.single), isTrue);
        expect(_ajaxHeader(forum.requests.single), isTrue);
        await getIt.unregister<NetClientProvider>();
      }
      // A whole page instead of the dialog (the xml parser throws a state error on it) is read, not thrown on: the
      // page's first form (the search box) is no purchase form, as before for a page.
      _use(_Forum.always(_web(_orig('reply_msg_error'))));
      expect(
        _left(await PurchaseRepository().fetchPurchaseConfirmInfo(tid: '9199849', pid: '4743').run()),
        isA<PurchaseInfoIncompleteException>(),
      );
      await getIt.unregister<NetClientProvider>();
      _use(_Forum.always(_api(_handle('rate_dup', {'handlekey': 'pay', 'message': '抱歉，您已经购买过了'}))));
      expect(
        _left(await PurchaseRepository().fetchPurchaseConfirmInfo(tid: '9199849', pid: '4743').run()),
        isA<PurchaseInfoInvalidNoticeException>(),
      );
    });

    test('bought or not, either way', () async {
      final bought = _handle('rate_ok', {
        'handlekey': 'pay',
        'message': '购买成功，现在将转入主题页',
        'message_key': 'thread_pay_succeed',
        'url': 'forum.php?mod=viewthread&tid=9199849',
      });
      final refused = _handle('rate_dup', {'handlekey': 'pay', 'message': '抱歉，您的天使币不足', 'message_key': ''});
      for (final (answer, ok) in [
        (_api(bought), true),
        (_ajax(_succeedAjax('pay', 'forum.php?mod=viewthread&tid=9199849', '购买成功，现在将转入主题页')), true),
        (_api(refused), false),
        (_ajax(_errorAjax('pay', '抱歉，您的天使币不足')), false),
      ]) {
        final forum = _Forum.always(answer);
        _use(forum);
        final result = await PurchaseRepository()
            .purchase(
              const PurchaseConfirmInfo(
                author: null,
                price: null,
                authorProfit: null,
                coinsLast: null,
                formHash: 'f1f2f3f4',
                referer: '$baseUrl/forum.php',
                tid: '9199849',
                handleKey: 'pay',
              ),
            )
            .run();
        if (ok) {
          _right(result);
        } else {
          expect(_left(result), isA<PurchaseActionFailedException>());
        }
        expect(_asksJson(forum.requests.single), isTrue);
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group("L. the forum's page of a result, for the readers that check it", () {
    test('the blocking forms: a refusal, the login prompt, a plain answer', () {
      final refusedResult = tsdmAppWriteResultOf(_json('reply_msg_error'))!;
      final fromResult = forumPageProblem(refusedResult.document, expectedUid: 35, requireIdentity: false);
      final fromPage = forumPageProblem(
        parseHtmlDocument(unwrapAjax(_orig('reply_msg_error').body)),
        expectedUid: 35,
        requireIdentity: false,
      );
      expect(fromResult?.failure, NoticeIgnoreFailure.forumError);
      expect(fromPage?.failure, NoticeIgnoreFailure.forumError);
      expect(fromResult?.message, '抱歉，指定的主题不存在或已被删除或正在被审核');
      // The forum's page carries the script of its "go back" link in the same box: the message comes first.
      expect(fromPage?.message, startsWith(fromResult!.message!));
      final login = tsdmAppWriteResultOf({..._json('reply_msg_error'), 'login': 1, 'alert': 'info'})!;
      expect(
        forumPageProblem(login.document, expectedUid: 35, requireIdentity: false)?.failure,
        NoticeIgnoreFailure.notLoggedIn,
      );
      expect(
        forumPageProblem(
          tsdmAppWriteResultOf(_json('favorite_add'))!.document,
          expectedUid: 35,
          requireIdentity: false,
        ),
        isNull,
      );
      expect(
        forumPageProblem(
          tsdmAppWriteResultOf(_json('reply_redirect'))!.document,
          expectedUid: 35,
          requireIdentity: false,
        ),
        isNull,
      );
      // The error hook of a form (the forum's `alert_error` of the fragment) is a refusal as well.
      expect(
        forumPageProblem(
          tsdmAppWriteResultOf(_json('friend_again'))!.document,
          expectedUid: 35,
          requireIdentity: false,
        )?.failure,
        NoticeIgnoreFailure.forumError,
      );
      expect(
        forumPageProblem(
          parseHtmlDocument(unwrapAjax(_orig('favorite_repeat').body)),
          expectedUid: 35,
          requireIdentity: false,
        )?.failure,
        NoticeIgnoreFailure.forumError,
      );
    });
  });

  group('M. the antitheft challenge', () {
    test('a form answered the challenge, wrapped in a page result, is not replayed and not a result', () async {
      final challenge = _raw('test/data/antitheft/1034162.html');
      for (final answer in [
        _api({..._json('page_case'), 'document': challenge, 'head': ''}),
        (
          body: challenge,
          status: 200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        ),
      ]) {
        final forum = _Forum.always(answer);
        final result = await _client(
          forum,
        ).postForm(formatReplyThreadUrl('2', '9199849'), data: {'message': 'hi'}).run();
        expect(_left(result), isA<AntitheftChallengedRequestException>());
        expect(forum.requests, hasLength(1), reason: 'never replayed');
      }
      // A page result that is not the challenge goes through.
      final forum = _Forum.always(_api(_json('page_case')));
      _right(await _client(forum).postForm(formatReplyThreadUrl('2', '9199849'), data: {'message': 'hi'}).run());
    });
  });
}
