import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker/talker.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/login_device/login_device_identity.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_client.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/redacting_talker.dart';

/// P17: no secret reaches a log, whatever the channel.
///
/// The app's own logger ([buildRedactingTalker]: the console output, the lines of the log file, the history the debug
/// page shows and exports) takes requests, answers and exceptions carrying every kind of secret the app handles, sent
/// through the real forum client ([NetClientProvider.build] and its interceptors) and the WebDAV client; nothing of a
/// secret is in any of the three outputs, while the methods, paths, actions, statuses and field names still are.
/// Then every kind once more in each of the shapes a log line can carry it (a request, an answer, an exception), the
/// line format of the log files ([formatLogLine], the background isolates' too) and the redaction of a log written
/// by an older version ([redactLogText]). No live request, no real account.

// ---------------------------------------------------------------------------------------------------------------------
// Secrets: each one distinct, so a leak tells which kind leaked.

const _loginPassword = 'Login pass 7c1@x';
const _loginAnswer = 'Kyoto LoginAnswer 3f';
const _adminPassword = 'AdminPw-9d2e';
const _adminAnswer = 'AdminAnswer-5b7a';
const _adminToken = 'adm1nT0ken0123456789abcdef';
const _deviceId = '1b4e28ba-2fa1-41d2-883f-0016d3cca427';
const _authCookie = 'a7Fk2%09QxAuthCookieZ';
const _saltCookie = 'Sa1tKeyCk8';
const _sidCookie = 'S1dCookieQ4';
const _stCookie = 'StSign9a7c';
const _formHash = 'f0e1d2c3';
const _webdavUser = 'davuser.secret';
const _webdavPassword = 'DavPass-31x!';
const _digestResponse = 'DigestResp6629fae4';
const _email = 'alice.secret@example.org';
const _newEmail = 'new.mailbox@example.net';
const _seccode = 'QK7P';
const _secanswer = 'SecAnswer-88';
const _secverify = 'SecVerify-0217';
const _oldPassword = 'OldPw-41aa';
const _newPassword = 'NewPw-52bb';
const _newAnswer = 'NewAnswer-63cc';
const _syncDocument = '{"drafts":[{"text":"SyncDraft-74dd"}]}';
const _pmText = 'PrivateMessage-85ee hello';
const _replyText = 'ReplyBody-96ff quote';
const _subjectText = 'ThreadSubject-07gg';

/// Every secret value above (the questionid is a choice, not a secret value of its own).
const _secrets = <String, String>{
  'login password': _loginPassword,
  'login security answer': _loginAnswer,
  'admin password': _adminPassword,
  'admin security answer': _adminAnswer,
  'admin token': _adminToken,
  'device id': _deviceId,
  'forum cookie auth': _authCookie,
  'forum cookie saltkey': _saltCookie,
  'forum cookie sid': _sidCookie,
  'forum cookie other': _stCookie,
  'formhash': _formHash,
  'webdav user': _webdavUser,
  'webdav password': _webdavPassword,
  'webdav digest': _digestResponse,
  'email': _email,
  'new email': _newEmail,
  'captcha': _seccode,
  'secqaa answer': _secanswer,
  'captcha check': _secverify,
  'old password': _oldPassword,
  'new password': _newPassword,
  'new security answer': _newAnswer,
  'sync document': 'SyncDraft-74dd',
  'private message': 'PrivateMessage-85ee',
  'reply body': 'ReplyBody-96ff',
  'thread subject': 'ThreadSubject-07gg',
};

/// The forms a secret can take in a log: as it is, url-encoded (form bodies, queries), base64 (basic authentication).
List<String> _formsOf(String secret) => {
  secret,
  Uri.encodeQueryComponent(secret),
  Uri.encodeComponent(secret),
  base64Encode(utf8.encode(secret)),
}.toList();

final String _webdavBasic = base64Encode(utf8.encode('$_webdavUser:$_webdavPassword'));

// ---------------------------------------------------------------------------------------------------------------------
// What the logger wrote.

final _console = <String>[];
final _fileLines = <String>[];

/// Everything the three outputs of the logger hold.
String _allOutput() => [
  ..._console,
  ..._fileLines,
  ...talker.history.map((e) => e.generateTextMessage()),
].join('\n');

/// Expect no form of any secret in [output] (or only those of [kinds]).
void _expectNoSecret(String output, {Iterable<String>? kinds, String? reason}) {
  final checked = kinds == null ? _secrets : {for (final k in kinds) k: _secrets[k]!};
  for (final MapEntry(key: kind, value: secret) in checked.entries) {
    // A secret with spaces must not leak in part either: each longer word of it is looked for too.
    final words = secret.split(' ').where((w) => w.length >= 6 && w != secret);
    for (final form in [..._formsOf(secret), ...words]) {
      expect(output, isNot(contains(form)), reason: '${reason ?? ''} $kind leaked as "$form"');
    }
  }
  expect(output, isNot(contains(_webdavBasic)), reason: '${reason ?? ''} webdav basic credentials leaked');
}

// ---------------------------------------------------------------------------------------------------------------------
// A forum answering the requests of the test.

/// One request as the adapter received it: proves the secrets were really sent, and so went through the client.
typedef _Sent = ({String method, Uri uri, Map<String, dynamic> headers, String body});

final class _Forum implements HttpClientAdapter {
  final sent = <_Sent>[];

  static ResponseBody _text(String body, int status, {Map<String, List<String>> headers = const {}}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          ...headers,
        },
      );

  static ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await requestStream.forEach(bytes.addAll);
    }
    sent.add((method: options.method, uri: options.uri, headers: Map.of(options.headers), body: utf8.decode(bytes)));
    final query = options.uri.queryParameters;
    final path = options.uri.path;
    switch ((path, query['mod'] ?? query['id'], query['action'] ?? query['ac'])) {
      case ('/member.php', 'logging', 'login') when options.method == 'GET':
        // The login page: session cookies, the form hash, the account's email.
        return _text(
          '<form><input type="hidden" name="formhash" value="$_formHash" /></form><p>$_email</p>',
          200,
          headers: {
            'set-cookie': [
              'Ystv_2132_auth=$_authCookie; path=/; httponly',
              'Ystv_2132_saltkey=$_saltCookie; expires=Wed, 21 Oct 2026 07:28:00 GMT; path=/',
              'Ystv_2132_sid=$_sidCookie; path=/',
            ],
          },
        );
      case ('/member.php', 'logging', 'login'):
        // A failing login answers with an error page echoing the form (as a broken theme might).
        return _text('<p>error</p><input name="password" value="$_loginPassword"><p>$_email</p>', 500);
      case ('/misc.php', 'secqaa', 'check'):
        // The connection drops: dart:io names the url in the exception.
        throw HttpException('Connection closed before full header was received', uri: options.uri);
      case ('/plugin.php', 'tsdmapp', 'admin'):
        return _json({'ok': 0, 'error': 'forbidden', 'token': _adminToken, 'formhash': _formHash}, 403);
      case ('/plugin.php', 'tsdmapp', 'notify'):
        return _json({'ok': 0, 'error': 'device_revoked', 'uid': 31, 'device': _deviceId}, 200);
      case ('/plugin.php', 'tsdmapp', 'sync'):
        return _json({'ok': 0, 'error': 'too_large', 'data': _syncDocument, 'formhash': _formHash}, 413);
      case ('/home.php', 'spacecp', 'profile'):
        throw const SocketException('Connection reset by peer');
      default:
        return _text('<p>ok</p>', 200);
    }
  }

  @override
  void close({bool force = false}) {}
}

/// A logger interceptor printing whole requests and answers, as a debugging session might add: put after the app's
/// own, it shows that even a full dump of the headers and bodies leaves no secret in a log.
final class _DumpInterceptor extends Interceptor with LoggerMixin {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    debug('request ${options.method} ${options.uri} headers=${options.headers} data=${options.data}');
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    debug('answer ${response.statusCode} ${response.requestOptions.uri}\n${response.headers}body=${response.data}');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    error(
      'failed ${err.requestOptions.method} ${err.requestOptions.uri} headers=${err.requestOptions.headers} '
      'data=${err.requestOptions.data} answer=${err.response?.data}',
      err,
      err.stackTrace,
    );
    handler.next(err);
  }
}

/// A log entry made outside the talker methods, whose text has a field of its own.
final class _HttpLog extends TalkerLog {
  _HttpLog(super.message, this.headers) : super(logLevel: LogLevel.info);

  final Map<String, String> headers;

  @override
  String generateTextMessage({TimeFormat timeFormat = TimeFormat.timeAndSeconds}) =>
      '${super.generateTextMessage(timeFormat: timeFormat)} headers=$headers';
}

final class _Repository with LoggerMixin {}

void main() {
  setUpAll(() {
    talker = buildRedactingTalker(console: _console.add, writeLine: _fileLines.add);
  });

  setUp(() {
    _console.clear();
    _fileLines.clear();
    talker.cleanHistory();
  });

  group('the whole pipeline', () {
    late _Forum forum;
    late NetClientProvider client;

    setUp(() {
      getIt
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver());
      LoginDeviceIdentity.id = _deviceId;
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.9.0', api: 16, nodoc: true, device: true);
      forum = _Forum();
      final dio = Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum;
      client = NetClientProvider.build(dio: dio);
      dio.interceptors.add(_DumpInterceptor());
    });

    tearDown(() async {
      LoginDeviceIdentity.reset();
      TsdmAppApi.pluginInfo.value = null;
      await getIt.reset();
    });

    test('requests, answers and failures carrying every secret leave none in any output', () async {
      final repo = _Repository();
      Future<void> send(AsyncEither<Response<dynamic>> request, String what) async {
        final result = await request.run();
        // As the repositories do with a failure: handled, or put in a line.
        if (result.getLeft().toNullable() case final failure?) {
          talker.handle(failure, StackTrace.current, 'while $what');
          repo.error('$what failed: $failure');
        }
      }

      // The login page sets the session cookies; every later request sends them.
      await send(client.get('$baseUrl/member.php?mod=logging&action=login'), 'login page');
      await send(
        client.postForm(
          '$baseUrl/member.php?mod=logging&action=login&loginsubmit=yes&inajax=1',
          data: {
            'formhash': _formHash,
            'username': 'Alice',
            'password': _loginPassword,
            'questionid': '3',
            'answer': _loginAnswer,
          },
          tsdmAppJson: false,
        ),
        'login',
      );
      // The security question check of a post form: the answer is in the query.
      await send(
        client.get('$baseUrl/misc.php?mod=secqaa&action=check&inajax=1&idhash=qS0&secverify=$_secverify'),
        'secqaa check',
      );
      await send(
        client.postForm(
          '$baseUrl/plugin.php?id=tsdmapp&action=admin&op=login',
          data: {
            'formhash': _formHash,
            'admintoken': _adminToken,
            'password': _adminPassword,
            'questionid': '2',
            'answer': _adminAnswer,
          },
          headers: {'X-Tsdmapp-Admin': _adminToken},
        ),
        'admin login',
      );
      await send(client.get('$baseUrl/plugin.php?id=tsdmapp&action=notify&tsdmapp_device=$_deviceId'), 'notify');
      await send(
        client.postForm(
          '$baseUrl/plugin.php?id=tsdmapp&action=sync&formhash=$_formHash',
          data: {'formhash': _formHash, 'data': _syncDocument},
        ),
        'sync push',
      );
      await send(
        client.postForm(
          '$baseUrl/forum.php?mod=post&action=reply&tid=1&replysubmit=yes',
          data: {
            'formhash': _formHash,
            'subject': _subjectText,
            'message': _replyText,
            'seccodeverify': _seccode,
            'secanswer': _secanswer,
          },
        ),
        'reply',
      );
      await send(
        client.postForm(
          '$baseUrl/home.php?mod=spacecp&ac=pm&op=send&touid=5&pmid=0',
          data: {'formhash': _formHash, 'message': _pmText},
        ),
        'private message',
      );
      await send(
        client.postForm(
          '$baseUrl/home.php?mod=spacecp&ac=profile&op=password',
          data: {
            'formhash': _formHash,
            'oldpassword': _oldPassword,
            'newpassword': _newPassword,
            'newpassword2': _newPassword,
            'emailnew': _newEmail,
            'questionidnew': '4',
            'answernew': _newAnswer,
          },
        ),
        'password change',
      );

      // WebDAV: its own bare client; a failing check is logged as the backup repository does.
      final webdav = WebdavClient(
        baseUrl: Uri.parse('https://$_webdavUser:$_webdavPassword@dav.example.com/dav/'),
        username: _webdavUser,
        password: _webdavPassword,
        dio: Dio()..httpClientAdapter = forum,
      );
      repo.info('webdav: backing up to ${webdav.baseUrl}');
      final check = await webdav.check();
      repo.warning('webdav: check answered $check');

      // A log entry made with logCustom.
      talker.logCustom(
        _HttpLog('custom POST /forum.php formhash=$_formHash', {'Cookie': 'Ystv_2132_auth=$_authCookie'}),
      );

      // The secrets were really sent: the outputs below could have carried them.
      final sentText = forum.sent.map((s) => '${s.method} ${s.uri} ${s.headers} ${s.body}').join('\n');
      for (final secret in [_loginPassword, _adminToken, _deviceId, _authCookie, _secverify, _pmText, _webdavBasic]) {
        expect(
          sentText.contains(secret) || sentText.contains(Uri.encodeQueryComponent(secret)),
          isTrue,
          reason: secret,
        );
      }
      expect(forum.sent.any((s) => '${s.headers['cookie']}'.contains(_authCookie)), isTrue);
      expect(forum.sent.any((s) => s.headers['X-Tsdmapp-Device'] == _deviceId), isTrue);

      final console = _console.join('\n');
      final file = _fileLines.join();
      final history = talker.history.map((e) => e.generateTextMessage()).join('\n');
      for (final (name, output) in [('console', console), ('log file', file), ('history', history)]) {
        expect(output, contains(redactionMask), reason: name);
        _expectNoSecret(output, reason: name);
        // What a log is for stays.
        for (final kept in [
          'POST',
          'GET',
          '/member.php',
          'action=login',
          'mod=secqaa',
          'secverify=',
          'action=admin',
          'X-Tsdmapp-Admin',
          'X-Tsdmapp-Device',
          'tsdmapp_device=',
          'action=sync',
          'action=reply',
          'tid=1',
          'ac=pm',
          'op=password',
          'formhash',
          'password',
          'answer',
          'oldpassword',
          'newpassword',
          'emailnew',
          'seccodeverify',
          'secanswer',
          'message',
          'subject',
          'cookie',
          '500',
          '403',
          '413',
          'dav.example.com',
        ]) {
          expect(output, contains(kept), reason: '$name lost "$kept"');
        }
      }
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // Each kind of secret in each shape: a request, an answer, an exception.

  /// A request carrying [secret] as [field] in the query, the headers and the body (a form and JSON).
  RequestOptions requestWith(String field, String secret, {String path = '/forum.php'}) => RequestOptions(
    method: 'POST',
    baseUrl: baseUrl,
    path: '$path?mod=x&$field=${Uri.encodeQueryComponent(secret)}',
    headers: {field: secret, 'accept': '*/*'},
    data: {field: secret, 'tid': '1'},
  );

  /// Log [options] as a request, an answer echoing it and the exception of its failure, through every channel.
  void logAllShapes(RequestOptions options, {Map<String, List<String>> answerHeaders = const {}, Object? answer}) {
    final response = Response<dynamic>(
      requestOptions: options,
      statusCode: 500,
      headers: Headers.fromMap(answerHeaders),
      data: answer ?? jsonEncode(options.data),
    );
    final exception = DioException(
      requestOptions: options,
      response: response,
      type: DioExceptionType.badResponse,
      message: 'failed ${options.uri} with ${options.data}',
      error: HttpException('closed', uri: options.uri),
    );
    final repo = _Repository();
    // The request.
    talker
      ..debug('${options.method} ${options.uri} headers=${options.headers} data=${options.data}')
      ..info('form: ${Transformer.urlEncodeMap(options.data as Map<String, dynamic>)}');
    // The answer.
    repo.warning('answered ${response.statusCode}:\n${response.headers}body=${response.data}');
    // The exception.
    talker.handle(exception, StackTrace.current, 'request failed');
    repo
      ..error('request failed: $exception', exception)
      ..handleRaw(exception, StackTrace.current);
    talker.log('raw: ${exception.message}', logLevel: LogLevel.critical, exception: exception.error);
  }

  final kinds = <String, ({RequestOptions request, Map<String, List<String>> headers, Object? answer, String name})>{
    'login password': (
      request: requestWith('password', _loginPassword, path: '/member.php'),
      headers: const {},
      answer: null,
      name: 'password',
    ),
    'login security answer': (
      request: requestWith('answer', _loginAnswer, path: '/member.php'),
      headers: const {},
      answer: null,
      name: 'answer',
    ),
    'admin password': (
      request: requestWith('password', _adminPassword, path: '/plugin.php'),
      headers: const {},
      answer: null,
      name: 'password',
    ),
    'admin security answer': (
      request: requestWith('answer', _adminAnswer, path: '/plugin.php'),
      headers: const {},
      answer: null,
      name: 'answer',
    ),
    'admin token': (
      request: requestWith('admintoken', _adminToken, path: '/plugin.php')..headers['X-Tsdmapp-Admin'] = _adminToken,
      headers: const {},
      answer: '{"ok":1,"token":"$_adminToken","expires":600}',
      name: 'admintoken',
    ),
    'device id': (
      request: requestWith('tsdmapp_device', _deviceId, path: '/plugin.php')..headers['X-Tsdmapp-Device'] = _deviceId,
      headers: const {},
      answer: '{"ok":0,"error":"device_revoked","uid":31,"device":"$_deviceId"}',
      name: 'tsdmapp_device',
    ),
    'forum cookie auth': (
      request: requestWith('Ystv_2132_auth', _authCookie)..headers['Cookie'] = 'Ystv_2132_auth=$_authCookie; a=1',
      headers: {
        'set-cookie': ['Ystv_2132_auth=$_authCookie; path=/', 'Ystv_2132_lastvisit=1; path=/'],
      },
      answer: null,
      name: 'Ystv_2132_auth',
    ),
    'forum cookie saltkey': (
      request: requestWith('Ystv_2132_saltkey', _saltCookie),
      headers: {
        'set-cookie': ['Ystv_2132_lastvisit=1; expires=Wed, 21 Oct 2026 07:28:00 GMT, Ystv_2132_saltkey=$_saltCookie'],
      },
      answer: null,
      name: 'Ystv_2132_saltkey',
    ),
    'forum cookie sid': (
      request: requestWith('Ystv_2132_sid', _sidCookie),
      headers: {
        'set-cookie': ['Ystv_2132_sid=$_sidCookie; path=/'],
      },
      answer: null,
      name: 'Ystv_2132_sid',
    ),
    'forum cookie other': (
      request: RequestOptions(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/home.php?mod=space',
        headers: {'Cookie': 'Ystv_2132_lastvisit=1; Ystv_2132_st_t=31|1700000000|$_stCookie'},
        data: <String, dynamic>{'tid': '1'},
      ),
      headers: {
        'set-cookie': ['Ystv_2132_st_t=31|1700000000|$_stCookie; path=/'],
      },
      answer: '',
      name: 'Cookie',
    ),
    'formhash': (
      request: requestWith('formhash', _formHash),
      headers: const {},
      answer: '<input type="hidden" value="$_formHash" name="formhash" />',
      name: 'formhash',
    ),
    'webdav user': (
      request: RequestOptions(
        method: 'PROPFIND',
        path: 'https://$_webdavUser:$_webdavPassword@dav.example.com/dav/',
        headers: {'Authorization': 'Basic $_webdavBasic'},
        data: {'user': 'Basic $_webdavBasic'},
      ),
      headers: const {},
      answer: 'auth Basic $_webdavBasic refused',
      name: 'Authorization',
    ),
    'webdav password': (
      request: RequestOptions(
        method: 'PUT',
        path: 'https://dav.example.com/dav/backup.db',
        headers: {'authorization': 'Basic $_webdavBasic', 'webdav_password': _webdavPassword},
        data: {'webdavPassword': _webdavPassword},
      ),
      headers: const {},
      answer: '{"password":"$_webdavPassword"}',
      name: 'webdavPassword',
    ),
    'webdav digest': (
      request: RequestOptions(
        method: 'PROPFIND',
        path: 'https://dav.example.com/dav/',
        headers: {'Authorization': 'Digest username="dav", realm="dav", response="$_digestResponse"'},
        data: <String, dynamic>{'depth': '1'},
      ),
      headers: const {},
      answer: '',
      name: 'Authorization',
    ),
    'email': (
      request: requestWith('email', _email),
      headers: const {},
      answer: '<p>Bound to $_email</p>',
      name: 'email',
    ),
    'new email': (
      request: requestWith('emailnew', _newEmail),
      headers: const {},
      answer: '{"emailnew":"$_newEmail"}',
      name: 'emailnew',
    ),
    'captcha': (
      request: requestWith('seccodeverify', _seccode),
      headers: const {},
      answer: null,
      name: 'seccodeverify',
    ),
    'secqaa answer': (
      request: requestWith('secanswer', _secanswer),
      headers: const {},
      answer: null,
      name: 'secanswer',
    ),
    'captcha check': (
      request: requestWith('secverify', _secverify, path: '/misc.php'),
      headers: const {},
      answer: null,
      name: 'secverify',
    ),
    'old password': (
      request: requestWith('oldpassword', _oldPassword, path: '/home.php'),
      headers: const {},
      answer: null,
      name: 'oldpassword',
    ),
    'new password': (
      request: requestWith('newpassword2', _newPassword, path: '/home.php'),
      headers: const {},
      answer: null,
      name: 'newpassword2',
    ),
    'new security answer': (
      request: requestWith('answernew', _newAnswer, path: '/home.php'),
      headers: const {},
      answer: null,
      name: 'answernew',
    ),
    'sync document': (
      request: requestWith('data', _syncDocument, path: '/plugin.php'),
      headers: const {},
      answer: '{"ok":1,"updated":1700000000,"data":${jsonEncode(_syncDocument)}}',
      name: 'data',
    ),
    'private message': (
      request: requestWith('message', _pmText, path: '/home.php'),
      headers: const {},
      answer: '{"pmmessage":"he said \\"$_pmText\\" twice","touid":5}',
      name: 'message',
    ),
    'reply body': (
      request: requestWith('message', _replyText),
      headers: const {},
      answer: null,
      name: 'message',
    ),
    'thread subject': (
      request: requestWith('subject', _subjectText),
      headers: const {},
      answer: null,
      name: 'subject',
    ),
  };

  test('every kind of secret is listed once', () {
    expect(kinds.keys.toSet(), _secrets.keys.toSet());
  });

  group('each kind, as a request, an answer and an exception', () {
    for (final MapEntry(key: kind, value: c) in kinds.entries) {
      test(kind, () {
        final secret = _secrets[kind]!;
        // The inputs do carry the secret.
        final input = '${c.request.uri} ${c.request.headers} ${c.request.data} ${c.headers} ${c.answer}';
        expect(
          _formsOf(secret).any(input.contains) || input.contains(_webdavBasic),
          isTrue,
          reason: 'the case must carry its secret',
        );

        logAllShapes(c.request, answerHeaders: c.headers, answer: c.answer);

        final output = _allOutput();
        _expectNoSecret(output, kinds: [kind]);
        expect(output, contains(c.name));
        expect(output, contains(c.request.method));
        expect(output, contains(c.request.uri.path));
        expect(output, contains('500'));
        expect(output, contains('DioException'));
      });
    }
  });

  // -------------------------------------------------------------------------------------------------------------------
  // The log files.

  group('the line format of the log files', () {
    test('an entry built outside the talker methods is redacted as it is written', () {
      final entries = <TalkerData>[
        TalkerLog(
          'POST /member.php password=${Uri.encodeQueryComponent(_loginPassword)}&answer=${Uri.encodeQueryComponent(_loginAnswer)}',
          logLevel: LogLevel.info,
        ),
        TalkerException(
          Exception('X-Tsdmapp-Admin: $_adminToken'),
          message: 'device $_deviceId failed: {"device":"$_deviceId","formhash":"$_formHash"}',
        ),
        TalkerError(ArgumentError('Cookie: Ystv_2132_auth=$_authCookie'), message: 'mail $_email'),
        // Prose naming a secret field: the next word goes.
        TalkerLog('saved admintoken: $_adminToken for 600 s, client secret: $_formHash'),
      ];
      final lines = entries.map(formatLogLine).join();
      _expectNoSecret(lines);
      expect(lines, contains('/member.php'));
      expect(lines, contains('X-Tsdmapp-Admin'));
      expect(lines.split('\n').where((l) => l.isNotEmpty), isNotEmpty);
    });

    test('the observer of the app and of the background isolates writes those lines', () {
      final written = <String>[];
      final observer = RedactingLogObserver(written.add);
      final log = TalkerLog('sync push formhash=$_formHash&data=${Uri.encodeQueryComponent(_syncDocument)}');
      observer
        ..onLog(log)
        ..onException(TalkerException(Exception('secverify=$_secverify')))
        ..onError(TalkerError(StateError('emailnew=$_newEmail')));
      expect(written, hasLength(3));
      expect(written.first, formatLogLine(log));
      expect(written.every((l) => l.endsWith('\n')), isTrue);
      _expectNoSecret(written.join(), kinds: ['formhash', 'sync document', 'captcha check', 'new email']);
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // Logs written by an older version, before redaction: shown and exported only through redactLogText.

  group('a log written before', () {
    /// A line as an older version wrote it, unredacted.
    String old(String level, String message) => '[$level] | 12:00:00 000ms | $message';

    final lines = <String, String>{
      'login password': old('info', 'POST member.php formhash=x&password=${Uri.encodeQueryComponent(_loginPassword)}'),
      'login security answer': old('debug', '{questionid: 3, answer: $_loginAnswer, username: Alice}'),
      'admin password': old('debug', '{"op":"login","password":"$_adminPassword"}'),
      'admin security answer': old('debug', 'op=login&questionid=2&answer=$_adminAnswer'),
      'admin token': old('debug', 'headers: {X-Tsdmapp-Admin: $_adminToken, accept: */*}'),
      'device id': old('debug', 'X-Tsdmapp-Device: $_deviceId'),
      'forum cookie auth': old('debug', 'build cookie: {Ystv_2132_auth: $_authCookie, Ystv_2132_lastvisit: 1}'),
      'forum cookie saltkey': old('debug', 'set-cookie: [Ystv_2132_saltkey=$_saltCookie; path=/, a=1]'),
      'forum cookie sid': old('debug', 'Cookie: Ystv_2132_sid=$_sidCookie; Ystv_2132_lastvisit=1'),
      'forum cookie other': old('debug', 'headers: {cookie: [Ystv_2132_st_t=31|1700000000|$_stCookie], accept: */*}'),
      'formhash': old('error', '<input type="hidden" name="formhash" value="$_formHash" />'),
      'webdav user': old('info', 'webdav: https://$_webdavUser:x@dav.example.com/dav/'),
      'webdav password': old('debug', 'Authorization: Basic $_webdavBasic'),
      'webdav digest': old('debug', 'authorization: Digest username="dav", response="$_digestResponse"'),
      'email': old('debug', 'bound email $_email'),
      'new email': old('debug', 'emailnew=${Uri.encodeQueryComponent(_newEmail)}&formhash=x'),
      'captcha': old('debug', 'seccodeverify=$_seccode&seccodehash=cS0'),
      'secqaa answer': old('debug', 'secqaahash=qS0&secanswer=$_secanswer'),
      'captcha check': old('error', 'misc.php?mod=secqaa&action=check&idhash=qS0&secverify=$_secverify'),
      'old password': old('debug', 'oldpassword=$_oldPassword'),
      'new password': old('debug', '{newpassword: $_newPassword, newpassword2: $_newPassword}'),
      'new security answer': old('debug', 'answernew=$_newAnswer&questionidnew=4'),
      'sync document': old('debug', '{"ok":1,"data":${jsonEncode(_syncDocument)}}'),
      'private message': old('debug', 'pm send: {"message":"$_pmText","touid":"5"}'),
      'reply body': old('debug', 'message=${Uri.encodeQueryComponent(_replyText)}&replysubmit=yes'),
      'thread subject': old('debug', '{subject: $_subjectText, fid: 2}'),
    };

    test('every kind is covered', () => expect(lines.keys.toSet(), _secrets.keys.toSet()));

    for (final MapEntry(key: kind, value: line) in lines.entries) {
      test(kind, () {
        expect(_formsOf(_secrets[kind]!).any(line.contains) || line.contains(_webdavBasic), isTrue);
        final out = redactLogText(line);
        _expectNoSecret(out, kinds: [kind]);
        expect(out, contains('12:00:00'));
        expect(out, contains(redactionMask));
      });
    }

    test('a whole file at once, twice changes nothing more', () {
      final file = lines.values.join('\n');
      final once = redactLogText(file);
      _expectNoSecret(once);
      expect(redactLogText(once), once);
      expect(once.split('\n'), hasLength(lines.length));
    });

    test('emails and IP addresses as asked', () {
      const line = 'login from 203.0.113.77 via proxy 127.0.0.1:7890, mail $_email, version 1.54.1.169x';
      expect(
        redactLogText(line),
        'login from 203.0.x.x via proxy 127.0.x.x:7890, mail $redactionMask, version 1.54.1.169x',
      );
      expect(redactLogText(line, maskEmail: false, ip: IpRedaction.keep), line);
      expect(
        redactLogText(line, ip: IpRedaction.mask),
        'login from $redactionMask via proxy $redactionMask:7890, mail $redactionMask, version 1.54.1.169x',
      );
      // An address that is not one stays.
      expect(redactLogText('999.1.2.3 and 1.2.3'), '999.1.2.3 and 1.2.3');
      // Secret fields stay redacted whatever the email setting.
      expect(redactLogText('emailnew=$_newEmail', maskEmail: false), 'emailnew=$redactionMask');
    });
  });

  group('what a log is for stays', () {
    test('names, paths, statuses and harmless values are not redacted', () {
      for (final line in [
        'GET https://www.tsdm39.com/forum.php?mod=viewthread&tid=1264928&authorid=5&page=2 answered 200 in 120 ms',
        'drop request of a previous account or session: GET /forum.php',
        'the forum answered a message: ok',
        'check passed: true',
        'failed to build chat message: author not found',
        'avatar@2x.png not found',
        'removing gzip encoding in request: POST https://www.tsdm39.com/forum.php?mod=post&action=reply&tid=1',
        'device register refused: busy',
      ]) {
        expect(redactSensitive(line), line);
      }
    });
  });
}
