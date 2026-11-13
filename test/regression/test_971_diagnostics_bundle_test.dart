import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:tsdm_client/features/diagnostics/diagnostics_bundle.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// P16: the diagnostics bundle. What it holds (the facts of the app, the recent logs of the app and of the
/// background service), how much of the logs (days, bytes, cut at line ends), and that no secret is in it: the log
/// lines are those an older version wrote before redaction (the samples of test_960, each kind once), the settings
/// carry the account, a proxy with credentials and texts of the user.

// ---------------------------------------------------------------------------------------------------------------------
// Secrets and old log lines, as in test_960_log_redaction_pipeline_test.dart.

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

final _oldLines = <String, String>{
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

/// A line as an older version wrote it, unredacted.
String old(String level, String message) => '[$level] | 12:00:00 000ms | $message';

// ---------------------------------------------------------------------------------------------------------------------

/// Settings, the account and other values a bundle must not tell among them.
const _settingsAccount = 'AccountNameZq81';
const _settingsProxy = 'http://proxyuser:ProxyPw77@10.9.8.7:8080';
const _settingsCheckin = 'CheckinText-Zx31';
const _settingsPhrases = 'QuickPhrase-Lm42';
const _settingsDownloadDir = '/Users/RealName/Downloads';

final _settings = <String, Object?>{
  'loginUsername': _settingsAccount,
  'loginUid': 778899,
  'loginEmail': _email,
  'netClientProxy': _settingsProxy,
  'netClientUseProxy': true,
  'checkinMessage': _settingsCheckin,
  'checkinFeeling': 'kx',
  'editorQuickPhrases': _settingsPhrases,
  'attachmentDownloadDirectory': _settingsDownloadDir,
  'windowPosition': 'Offset(1, 2)',
  'locale': 'zh-TW',
  'themeMode': 2,
  'textScaleFactor': 1.15,
  'enableBackgroundMessageService': true,
  'crossDeviceSync': false,
  'threadFloorInteractionMode': 'tapToOpen',
  'homeLayout': 'x' * 100,
};

const _plugin = TsdmAppPluginInfo(version: '3.9.0', api: 3, nodoc: true, preview: true, device: true, admin: false);

String _info({String deviceModel = 'Xiaomi 23078RKD5C', DateTime? now}) => composeDiagnosticsInfo(
  appVersion: '1.55.0+170.abcdef12 (3700) (2026-11-13)',
  buildMode: 'release',
  platform: 'android',
  osVersion: 'Linux 5.10 #1 SMP PREEMPT\nAndroid 14',
  deviceModel: deviceModel,
  locale: 'zh_TW, app zh-TW',
  display: '1080x2400 @2.75',
  plugin: _plugin,
  settings: _settings,
  now: now ?? _now,
);

final _now = DateTime(2026, 11, 13, 15, 4, 5);

String _day(DateTime d) => '${d.year}${'${d.month}'.padLeft(2, '0')}${'${d.day}'.padLeft(2, '0')}';

/// The files of [zip], by name, as text.
Map<String, String> _unzip(Uint8List zip) => {
  for (final f in ZipDecoder().decodeBytes(zip).files)
    if (f.isFile) f.name: utf8.decode(f.content),
};

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_diag_'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String name, String text) => File(path.join(dir.path, name)).writeAsStringSync(text);

  DiagnosticsRequest request({DiagnosticsLimits limits = const DiagnosticsLimits(), String? info}) =>
      DiagnosticsRequest(info: info ?? _info(), logDir: dir.path, now: _now, limits: limits);

  group('what it holds', () {
    test('the facts, the app logs and the background service logs of the recent days', () {
      final today = _day(_now);
      final yesterday = _day(_now.subtract(const Duration(days: 1)));
      write('tsdm_client_$today.log', '[info] | 15:00:00 000ms | today\n');
      write('tsdm_client_$yesterday.log', '[info] | 10:00:00 000ms | yesterday\n');
      write('tsdm_client_bg_$today.log', '[info] | 15:01:00 000ms | background poll\n');
      // Not taken: older than the days of the bundle, a day to come, another file, a folder.
      write('tsdm_client_${_day(_now.subtract(const Duration(days: 5)))}.log', 'too old\n');
      write('tsdm_client_${_day(_now.add(const Duration(days: 1)))}.log', 'tomorrow\n');
      write('tsdm_client_20261399.log', 'not a day\n');
      write('notes.txt', 'other\n');
      Directory(path.join(dir.path, 'tsdm_client_$today.log.d')).createSync();

      final files = _unzip(buildDiagnosticsBundle(request()));
      expect(files.keys.toSet(), {
        diagnosticsInfoName,
        'logs/tsdm_client_$today.log',
        'logs/tsdm_client_$yesterday.log',
        'logs/tsdm_client_bg_$today.log',
      });
      expect(files['logs/tsdm_client_$today.log'], contains('today'));
      expect(files['logs/tsdm_client_bg_$today.log'], contains('background poll'));
      expect(files.values.join(), isNot(contains('too old')));
      expect(files.values.join(), isNot(contains('tomorrow')));

      final info = files[diagnosticsInfoName]!;
      expect(info, contains('app: 1.55.0+170.abcdef12 (3700) (2026-11-13) (release)'));
      expect(info, contains('platform: android'));
      expect(info, contains('os: Linux 5.10 #1 SMP PREEMPT Android 14'));
      expect(info, contains('device: Xiaomi 23078RKD5C'));
      expect(info, contains('locale: zh_TW, app zh-TW'));
      expect(info, contains('display: 1080x2400 @2.75'));
      expect(info, contains('forum plugin: 3.9.0, api 3, nodoc 1, preview 1, device 1, admin 0'));
      expect(info, contains('time: 2026-11-13T15:04:05'));
      expect(info, contains('  themeMode: 2'));
      expect(info, contains('  locale: zh-TW'));
      expect(info, contains('  textScaleFactor: 1.15'));
      expect(info, contains('  enableBackgroundMessageService: true'));
      expect(info, contains('  netClientUseProxy: true'));
      expect(info, contains('  threadFloorInteractionMode: tapToOpen'));
      // A long text is never told, only its length.
      expect(info, contains('  homeLayout: <100 chars>'));
      expect(info, contains('logs:\n'));
      expect(info, contains('  tsdm_client_$today.log: '));
      expect(info, contains('  tsdm_client_bg_$today.log: '));
    });

    test('no logs: the facts alone', () {
      final files = _unzip(buildDiagnosticsBundle(request()));
      expect(files.keys, [diagnosticsInfoName]);
      expect(files[diagnosticsInfoName], contains('logs:\n  -'));
    });

    test('a missing log folder: the facts alone', () {
      final files = _unzip(
        buildDiagnosticsBundle(DiagnosticsRequest(info: _info(), logDir: path.join(dir.path, 'none'), now: _now)),
      );
      expect(files.keys, [diagnosticsInfoName]);
    });

    test('no device model, no unknown plugin: said so, not made up', () {
      final info = composeDiagnosticsInfo(
        appVersion: '1',
        buildMode: 'release',
        platform: 'windows',
        osVersion: '"Windows 11 Pro" 10.0 (Build 26100)',
        deviceModel: '',
        locale: 'en_US, app en',
        display: '-',
        plugin: null,
        settings: const {},
        now: _now,
      );
      expect(info, isNot(contains('device:')));
      expect(info, contains('forum plugin: unknown'));
      expect(info, contains('settings:\n'));
    });

    test('the settings told are settings of the app', () {
      // A renamed setting would silently drop out of the bundles.
      final names = SettingsKeys.values.map((k) => EnumName(k).name).toSet();
      for (final name in diagnosticSettingNames) {
        expect(names, contains(name), reason: name);
      }
      for (final left in [
        'loginUsername',
        'loginUid',
        'loginEmail',
        'netClientProxy',
        'checkinFeeling',
        'checkinMessage',
        'editorQuickPhrases',
        'attachmentDownloadDirectory',
      ]) {
        expect(diagnosticSettingNames, isNot(contains(left)));
      }
      expect(diagnosticSettingsSummary(_settings).map((e) => e.$1), isNot(contains('windowPosition')));
    });

    test('built in another isolate', () async {
      write('tsdm_client_${_day(_now)}.log', '[info] | 15:00:00 000ms | from a background isolate\n');
      final files = _unzip(await compute(buildDiagnosticsBundle, request()));
      expect(files['logs/tsdm_client_${_day(_now)}.log'], contains('from a background isolate'));
    });
  });

  group('how much of the logs', () {
    /// [count] numbered lines of about 100 bytes, the oldest first.
    String numbered(String tag, int count) => [
      for (var i = 0; i < count; i++) '[info] | 12:00:00 000ms | $tag line ${'$i'.padLeft(5, '0')} ${'x' * 60}\n',
    ].join();

    test('the newest lines of the newest days, within the bytes, cut at line ends', () {
      final today = _day(_now);
      final yesterday = _day(_now.subtract(const Duration(days: 1)));
      final twoDaysAgo = _day(_now.subtract(const Duration(days: 2)));
      write('tsdm_client_$today.log', numbered('today', 30));
      write('tsdm_client_$yesterday.log', numbered('yesterday', 100));
      write('tsdm_client_$twoDaysAgo.log', numbered('two days ago', 100));
      write('tsdm_client_bg_$today.log', numbered('bg', 100));

      const limits = DiagnosticsLimits(appLogBytes: 6000, backgroundLogBytes: 2000);
      final files = _unzip(buildDiagnosticsBundle(request(limits: limits)));

      final todayLog = files['logs/tsdm_client_$today.log']!;
      final yesterdayLog = files['logs/tsdm_client_$yesterday.log']!;
      final bgLog = files['logs/tsdm_client_bg_$today.log']!;
      // Today whole, the newest part of yesterday, nothing of the day before.
      expect(todayLog, numbered('today', 30));
      expect(files.containsKey('logs/tsdm_client_$twoDaysAgo.log'), isFalse);
      expect(utf8.encode(todayLog).length + utf8.encode(yesterdayLog).length, lessThanOrEqualTo(6000));
      expect(utf8.encode(bgLog).length, lessThanOrEqualTo(2000));
      for (final cut in [yesterdayLog, bgLog]) {
        expect(cut, isNotEmpty);
        // Whole lines only, the newest one last.
        expect(cut.split('\n').where((l) => l.isNotEmpty), everyElement(startsWith('[info] | 12:00:00 000ms | ')));
        expect(cut, endsWith('line 00099 ${'x' * 60}\n'));
      }
      final info = files[diagnosticsInfoName]!;
      expect(info, contains('tsdm_client_$yesterday.log: ${utf8.encode(yesterdayLog).length} of 10'));
      expect(info, contains('(newest part)'));
    });

    test('a secret across the cut: its line is dropped, not left without its name', () {
      final secretLine = old('info', 'POST member.php formhash=x&password=${Uri.encodeQueryComponent(_loginPassword)}');
      final text = '${numbered('a', 50)}$secretLine\n${numbered('b', 20)}';
      write('tsdm_client_${_day(_now)}.log', text);
      final tail = utf8.encode(numbered('b', 20)).length;
      // Every budget around the secret line.
      for (var budget = tail - 20; budget < tail + secretLine.length + 40; budget += 3) {
        final files = _unzip(
          buildDiagnosticsBundle(request(limits: DiagnosticsLimits(appLogBytes: budget, backgroundLogBytes: 0))),
        );
        final log = files['logs/tsdm_client_${_day(_now)}.log'] ?? '';
        _expectNoSecret(log, kinds: ['login password'], reason: 'budget $budget');
        expect(utf8.encode(log).length, lessThanOrEqualTo(budget));
      }
    });

    test('the defaults: 3 days, 4 MB of the app, 1 MB of the background service', () {
      const limits = DiagnosticsLimits();
      expect(limits.days, 3);
      expect(limits.appLogBytes, 4 * 1024 * 1024);
      expect(limits.backgroundLogBytes, 1024 * 1024);
    });
  });

  group('no secret in it', () {
    test('every kind of the old log lines, the account and the user texts of the settings', () {
      final logText = _oldLines.values.join('\n');
      final today = _day(_now);
      write('tsdm_client_$today.log', '$logText\n');
      write('tsdm_client_bg_$today.log', '$logText\n');
      final yesterday = _day(_now.subtract(const Duration(days: 1)));
      write('tsdm_client_$yesterday.log', '$logText\n');
      // The facts may carry one too (an exception text in a device name, an old plugin answer): redacted as well.
      final info = '${_info()}note: ${_oldLines['admin token']}\n';
      final zip = buildDiagnosticsBundle(request(info: info));
      final files = _unzip(zip);
      expect(files['logs/tsdm_client_$today.log']!.split('\n').where((l) => l.isNotEmpty), hasLength(_oldLines.length));
      final all = files.values.join('\n');
      _expectNoSecret(all);
      for (final secret in [
        _settingsAccount,
        '778899',
        'ProxyPw77',
        'proxyuser',
        '10.9.8.7',
        _settingsCheckin,
        _settingsPhrases,
        'RealName',
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
      // Nor in the raw bytes of the zip (an entry stored uncompressed, a name).
      final raw = latin1.decode(zip, allowInvalid: true);
      for (final secret in [_loginPassword, _adminToken, _authCookie, _settingsAccount]) {
        expect(raw, isNot(contains(secret)));
      }
      // Redaction shortens the lines, it does not cut the file: the day before is still there.
      expect(files[diagnosticsInfoName], isNot(contains('newest part')));
      expect(files.keys, contains('logs/tsdm_client_$yesterday.log'));
      expect(all, contains(redactionMask));
      expect(all, contains('12:00:00'));
    });

    test('every kind is covered', () => expect(_oldLines.keys.toSet(), _secrets.keys.toSet()));
  });
}
