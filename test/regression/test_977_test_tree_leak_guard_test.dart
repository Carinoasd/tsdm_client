// No trace of the local test forum in `test/` (this repo is public).
//
// Fixtures recorded on the local Discuz test site carry it in places a plain search misses: the site name, its
// address inside a base64 `REPORTURL`, its cookie prefix (`cookiepre`), an escaped home path. This test
// reads every text file under `test/` (plain, JSON / HTML / URL escapes undone, base64 runs decoded) and fails on:
// - the test site's name, in either script;
// - the loopback address and the docker bridge gateway;
// - `localhost` used as a host (after `//` or `@`, or followed by a port);
// - an absolute path under the home directory root;
// - the account name the test runs under (`$USER`, skipped on CI and for generic accounts like `runner`);
// - the test accounts' name prefix;
// - a Discuz cookie prefix other than the live forum's `Ystv_2132_` (or the `xxxx_2132_` placeholder).
//
// Before pushing a new or re-recorded fixture:
// 1. Replace the site name with 「测试论坛」, the site address with `https://forum.test` (or `https://www.tsdm39.com`
//    where a forum URL is expected, e.g. inside the base64 `REPORTURL`), the cookie prefix with `Ystv_2132_`, and the
//    uid / formhash / posttime with the fake values of the existing fixtures (uid 31, formhash `f1f2f3f4`, posttime
//    `1700000000`; see `test/data/tsdmapp/post_v16_newthread.json`). Never commit a password, a real cookie or a
//    real formhash.
// 2. Run this test: `~/.local/bin/ftest test/regression/test_977_test_tree_leak_guard_test.dart`. Each finding is
//    printed as `path:line rule (how it was found)`.
// 3. Only when a hit is really needed (a loopback server of the test, an input the test feeds on purpose), add it to
//    `_allowed` below with the reason. Entries are per file, rule and a piece of the line, never a whole file.
//
// The needles below are built from char codes and pieces so that this file does not trip itself.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _ip(List<int> parts) => parts.join('.');

final _rules = <String, RegExp>{
  'site name': RegExp(
    [
      [0x6AFB, 0x82B1], // site name, traditional
      [0x6A31, 0x82B1], // site name, simplified
      [0x4E8C, 0x6B21, 0x5143, 0x8AD6, 0x58C7],
      [0x4E8C, 0x6B21, 0x5143, 0x8BBA, 0x575B],
    ].map(String.fromCharCodes).join('|'),
  ),
  'loopback address': RegExp(RegExp.escape(_ip([127, 0, 0, 1]))),
  'docker gateway': RegExp(RegExp.escape(_ip([172, 17, 0, 1]))),
  'localhost host': RegExp(
    '(?://|@)local'
    r'host\b|\blocal'
    r'host:\d',
    caseSensitive: false,
  ),
  'home path': RegExp(
    r'(?<![\w.~-])/ho'
    r'me/[^/\s'
    "'"
    r'"\\]+',
  ),
  'test account prefix': RegExp(
    r'\bAg'
    'Test',
  ),
  'cookie prefix': RegExp(
    r'\b(?!Ystv_|xxxx_)[A-Za-z0-9]{4}_21'
    '32_',
  ),
};

/// The account the test runs under, unless it says nothing about a person (CI runners, containers).
RegExp? _accountRule() {
  final env = Platform.environment;
  if (env['CI'] != null || env['GITHUB_ACTIONS'] != null) {
    return null;
  }
  final name = env['USER'] ?? env['LOGNAME'] ?? env['USERNAME'];
  const generic = {'runner', 'root', 'user', 'ubuntu', 'vscode', 'codespace', 'builder', 'flutter', 'test', 'admin'};
  if (name == null || name.length < 4 || generic.contains(name.toLowerCase())) {
    return null;
  }
  return RegExp('\\b${RegExp.escape(name)}\\b', caseSensitive: false);
}

/// One hit that is needed, with why.
final class _Allowed {
  const _Allowed(this.path, this.rule, this.lineContains, this.reason);

  final String path;
  final String rule;
  final String lineContains;
  final String reason;
}

const _allowed = <_Allowed>[
  _Allowed(
    'test/regression/proxy_provider_refresh_test.dart',
    'loopback address',
    "var server = '",
    'a proxy setting value the test feeds the provider; nothing connects to it',
  ),
  _Allowed(
    'test/regression/proxy_provider_refresh_test.dart',
    'loopback address',
    "    server = '",
    'the changed proxy setting value; nothing connects to it',
  ),
  _Allowed(
    'test/regression/test_035_cloudflare_email_test.dart',
    'localhost host',
    "'alice@",
    'an address without a dot in the domain, which the decoder must reject',
  ),
  _Allowed(
    'test/regression/test_214_thread_page_api_test.dart',
    'loopback address',
    'for (final needle in [',
    'needles of the older per-fixture leak check',
  ),
  _Allowed(
    'test/regression/test_214_thread_page_api_test.dart',
    'test account prefix',
    'for (final needle in [',
    'needles of the older per-fixture leak check',
  ),
  _Allowed(
    'test/regression/test_960_log_redaction_pipeline_test.dart',
    'loopback address',
    "const line = 'login from",
    'a log line the redaction must leave as it is (a loopback proxy is not personal)',
  ),
];

final class _Finding {
  _Finding(this.path, this.line, this.rule, this.how, this.text);

  final String path;
  final int line;
  final String rule;
  final String how;
  final String text;

  @override
  String toString() {
    final snippet = text.length > 160 ? '${text.substring(0, 160)}...' : text;
    return '$path:$line $rule ($how): ${snippet.trim()}';
  }
}

final _percentRun = RegExp('(?:%[0-9A-Fa-f]{2})+');
final _unicodeEscape = RegExp(r'\\u([0-9A-Fa-f]{4})');
final _decimalEntity = RegExp('&#([0-9]{1,7});');
final _hexEntity = RegExp('&#[xX]([0-9A-Fa-f]{1,6});');
final _base64Run = RegExp('[A-Za-z0-9+/_-]{16,}={0,2}');

/// Undoes the escapes fixtures come with: JSON (`\/`, `\uXXXX`), HTML numeric entities, URL percent-encoding.
String _unescape(String s) {
  var ret = s.replaceAll(r'\/', '/');
  ret = ret.replaceAllMapped(_unicodeEscape, (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
  ret = ret.replaceAllMapped(_decimalEntity, (m) => _charOrSelf(int.parse(m[1]!), m[0]!));
  ret = ret.replaceAllMapped(_hexEntity, (m) => _charOrSelf(int.parse(m[1]!, radix: 16), m[0]!));
  return ret.replaceAllMapped(_percentRun, (m) {
    final bytes = [for (var i = 1; i < m[0]!.length; i += 3) int.parse(m[0]!.substring(i, i + 2), radix: 16)];
    return utf8.decode(bytes, allowMalformed: true);
  });
}

String _charOrSelf(int code, String self) => code <= 0x10FFFF ? String.fromCharCode(code) : self;

/// Text a base64 run stands for, or null when it is not base64 of UTF-8 text.
String? _decodeBase64(String run) {
  var s = run.replaceAll('-', '+').replaceAll('_', '/');
  s = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  try {
    return utf8.decode(base64.decode(s));
  } on FormatException {
    return null;
  }
}

Iterable<String> _rulesHit(String text, Map<String, RegExp> rules) =>
    rules.entries.where((e) => e.value.hasMatch(text)).map((e) => e.key);

List<_Finding> _scanFile(String path, String content, Map<String, RegExp> rules) {
  final findings = <_Finding>[];
  final lines = const LineSplitter().convert(content);
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final hit = <String>{};
    void add(String rule, String how) {
      if (hit.add('$rule/$how')) {
        findings.add(_Finding(path, i + 1, rule, how, raw));
      }
    }

    for (final rule in _rulesHit(raw, rules)) {
      add(rule, 'plain');
    }
    final unescaped = _unescape(raw);
    if (unescaped != raw) {
      for (final rule in _rulesHit(unescaped, rules)) {
        if (!hit.contains('$rule/plain')) {
          add(rule, 'escaped');
        }
      }
    }
    for (final m in _base64Run.allMatches(unescaped)) {
      final decoded = _decodeBase64(m[0]!);
      if (decoded == null) {
        continue;
      }
      for (final rule in _rulesHit(_unescape(decoded), rules)) {
        add(rule, 'base64 ${m[0]!.length > 24 ? '${m[0]!.substring(0, 24)}...' : m[0]}');
      }
    }
  }
  return findings;
}

const _binaryExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.avif', '.bmp', '.ico', '.sqlite', '.db', '.zip'};

/// Tracked text files under `test/`; the drift migration files `Makefile.dart` writes are skipped (git ignores them).
List<File> _testFiles() {
  final files = <File>[];
  for (final entity in Directory('test').listSync(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final path = entity.path.replaceAll(r'\', '/');
    if (path.startsWith('test/data/generated_migrations/')) {
      continue;
    }
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && _binaryExtensions.contains(path.substring(dot).toLowerCase())) {
      continue;
    }
    files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

void main() {
  group('helpers', () {
    final rules = {..._rules};
    String hits(String text) => _scanFile('x', text, rules).map((f) => '${f.rule}|${f.how.split(' ').first}').join(',');

    test('each rule fires on what it is for and stays quiet on look-alikes', () {
      expect(hits(String.fromCharCodes([0x6AFB, 0x82B1, 0x2606])), 'site name|plain');
      expect(hits('see ${_ip([127, 0, 0, 1])}:8080'), 'loopback address|plain');
      expect(hits('via ${_ip([172, 17, 0, 1])}'), 'docker gateway|plain');
      expect(hits('http://local${'host'}:8080/x'), 'localhost host|plain');
      expect(hits('only on HTTPS or local${'host'}'), isEmpty);
      expect(hits("File('/ho${'me'}/alice/x')"), 'home path|plain');
      expect(hits("import 'package:a/features/ho${'me'}/view.dart';"), isEmpty);
      expect(hits('user Ag${'Test'}3'), 'test account prefix|plain');
      expect(hits("cookiepre = 'RrRm_21${'32'}_'"), 'cookie prefix|plain');
      expect(hits("cookiepre = 'Ystv_21${'32'}_', s_21${'32'}_auth"), isEmpty);
    });

    test('escaped and encoded forms are found too', () {
      final ip = _ip([127, 0, 0, 1]);
      expect(
        hits(
          r'"path":"\/ho'
          r'me\/alice\/x"',
        ),
        'home path|escaped',
      );
      expect(hits('u=${Uri.encodeComponent('http://$ip/forum.php')}'), 'loopback address|plain');
      final name = String.fromCharCodes([0x6AFB, 0x82B1]);
      expect(hits('t=${Uri.encodeComponent(name)}'), 'site name|escaped');
      expect(
        hits(
          jsonEncode(name).replaceAllMapped(RegExp('[^\x00-\x7f]'), (m) {
            return '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}';
          }),
        ),
        'site name|escaped',
      );
      expect(hits('&#${0x6AFB};&#x${0x82B1.toRadixString(16)};'), 'site name|escaped');
      final reportUrl = base64.encode(utf8.encode('http://$ip/forum.php?mod=viewthread&tid=1'));
      expect(hits("REPORTURL = '$reportUrl'"), 'loopback address|base64');
      expect(hits("REPORTURL = '${reportUrl.replaceAll('/', r'\/')}'"), 'loopback address|base64');
      final clean = base64.encode(utf8.encode('https://www.tsdm39.com/forum.php?mod=viewthread&tid=1'));
      expect(hits("REPORTURL = '$clean'"), isEmpty);
    });
  });

  test('no trace of the test site, the machine or its account under test/', () {
    final rules = {..._rules, 'account name': ?_accountRule()};
    final findings = <_Finding>[];
    for (final file in _testFiles()) {
      final String content;
      try {
        content = file.readAsStringSync();
      } on FileSystemException {
        continue; // not UTF-8 text
      }
      findings.addAll(_scanFile(file.path.replaceAll(r'\', '/'), content, rules));
    }

    final used = <_Allowed>{};
    final left = <_Finding>[];
    for (final f in findings) {
      final allowed = _allowed.where((a) => a.path == f.path && a.rule == f.rule && f.text.contains(a.lineContains));
      if (allowed.isEmpty) {
        left.add(f);
      } else {
        used.addAll(allowed);
      }
    }
    expect(left, isEmpty, reason: 'Scrub these (see the head of this file):\n${left.join('\n')}');
    expect(
      _allowed.where((a) => !used.contains(a)).map((a) => '${a.path} ${a.rule} "${a.lineContains}"'),
      isEmpty,
      reason: 'allow-list entries that match nothing any more; remove them',
    );
  });
}
