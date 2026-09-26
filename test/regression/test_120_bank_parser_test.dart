import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:universal_html/parsing.dart';

// Synthetic markup reproduces only the observed plugin structure; no real account data is retained.
const _directory = '''
<a href="plugin.php?id=bank_ane:bank">Community bank in site header</a>
<table id="ttt"><thead class="colplural"><tr><td colspan="3"><h2>银行列表</h2></td></tr></thead>
<tbody>
<tr><td>logo</td><td><span>银行名称</span>: <span>Example Bank</span><br>
<span>银行行长</span>: <span>Example Manager</span>,<br><span>银行简介</span>: Example description</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=1"><em>进入银行</em></a><br><span>(已开户)</span></td></tr>
<tr><td>logo</td><td>银行名称: Another Bank<br>银行行长: Example<br>银行简介: Second description</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=2">进入银行</a></td></tr>
</tbody></table>
''';

const _form = '''
<form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="1">
<input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="synthetic-token">
<input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass">
<button type="submit" name="banksubmit" value="true">提交</button>
</form>
''';

String _savings({String form = _form}) =>
    '''
<div class="tbn"><h2>账户信息</h2><ul><li><span><b>4321</b> (银行货币)</span><font color="red">示例币:</font></li></ul></div>
<table id="ttt"><thead class="colplural"><tr><td><h2>活期储蓄</h2></td></tr></thead><tbody>
<tr><td class="footoperation">您当前的存款金额为 200 ，活期利率为0.1‰，计息时间从2026-01-01开始。</td></tr>
<tr><td>$form</td></tr>
<tr><td><form><p>您当前可得利息 3 <a href="plugin.php?id=bank_ane:bank&amp;action=unknown">手动结息</a></p></form></td></tr>
<tr><td class="footoperation">注意事项</td></tr><tr><td><p>利率可能变化。</p><p>存取款时自动结息。</p></td></tr>
</tbody></table>
''';

String _logs({bool empty = false, String? next}) =>
    '''
<table id="ttt"><thead class="colplural"><tr><td><h2>理财日志</h2></td></tr></thead><tbody>
<tr><td>My and received tabs</td></tr><tr><td>Filters</td></tr><tr><td>
<table id="ttt"><tbody>
${empty ? '<tr><td colspan="3"><center>还没有相关数据。</center></td></tr>' : '''
<tr><td>Info: 示例存款 10 示例币</td><td>Time: 2026-01-01 12:34:56</td><td>Ip: 192.0.2.123</td></tr>
<tr><td>Info: 示例取款 2 示例币</td><td>Time: 2026-01-02 12:34:56</td><td>Ip: 2001:db8::1</td></tr>
'''}
</tbody></table>
</td></tr><tr><td><div class="pg">${next == null ? '' : '<a class="nxt" href="$next">下一页</a>'}</div></td></tr>
</tbody></table>
''';

BankSavings _parseSavings(String html) => parseBankSavings(parseHtmlDocument(html), bankId: 1);

void main() {
  test('bank URL builder exposes only supported read-only pages', () {
    final directory = Uri.parse(bankPageUrl());
    expect(directory.origin, baseUrl);
    expect(directory.path, '/plugin.php');
    expect(directory.queryParameters, {'id': 'bank_ane:bank'});
    expect(Uri.parse(bankPageUrl(bankId: 2, action: 'cur')).queryParameters, {
      'id': 'bank_ane:bank',
      'bankid': '2',
      'action': 'cur',
    });
    expect(Uri.parse(bankPageUrl(bankId: 2, action: 'log', received: true, page: 3)).queryParameters, {
      'id': 'bank_ane:bank',
      'bankid': '2',
      'action': 'log',
      'show': '1',
      'page': '3',
    });
    expect(() => bankPageUrl(bankId: 0), throwsFormatException);
    expect(() => bankPageUrl(action: 'cur'), throwsFormatException);
    expect(() => bankPageUrl(bankId: 1, action: 'withdraw'), throwsFormatException);
    expect(() => bankPageUrl(bankId: 1, action: 'log', page: 0), throwsFormatException);
    expect(() => bankPageUrl(received: true), throwsFormatException);
    expect(() => bankPageUrl(bankId: 1, action: 'cur', page: 2), throwsFormatException);
  });

  test('directory scopes entries to the bank table and keeps account status', () {
    final parsed = parseBankDirectory(parseHtmlDocument(_directory));
    expect(parsed.banks.map((bank) => bank.id), [1, 2]);
    expect(parsed.banks.first.name, 'Example Bank');
    expect(parsed.banks.first.description, 'Example description');
    expect(parsed.banks.first.hasAccount, isTrue);
    expect(parsed.banks.last.hasAccount, isFalse);
    expect(parsed.banks.clear, throwsUnsupportedError);
  });

  for (final unsafe in [
    'https://evil.example/plugin.php?id=bank_ane:bank&amp;bankid=1',
    'http://www.tsdm39.com/plugin.php?id=bank_ane:bank&amp;bankid=1',
    'plugin.php?id=bank_ane:bank&amp;bankid=1&amp;action=cur',
    'plugin.php?id=bank_ane:bank&amp;bankid=1&amp;bankid=2',
    'plugin.php?id=bank_ane:bank&amp;bankid=-1',
  ]) {
    test('directory rejects unsafe destination $unsafe', () {
      final html = _directory.replaceFirst('plugin.php?id=bank_ane:bank&amp;bankid=1', unsafe);
      expect(() => parseBankDirectory(parseHtmlDocument(html)), throwsFormatException);
    });
  }

  test('savings preserves rates and date text without inferring a rate period', () {
    final parsed = _parseSavings(_savings());
    expect(parsed.bankId, 1);
    expect(parsed.summary, '您当前的存款金额为 200 ，活期利率为0.1‰，计息时间从2026-01-01开始。');
    expect(parsed.interest, '您当前可得利息 3');
    expect(parsed.notices, '利率可能变化。\n存取款时自动结息。');
    expect(parsed.currency, '示例币');
    expect(parsed.walletBalance, '4321');
    expect(parsed.form, isNotNull);
  });

  test('validated form retains only actual safe fields and builds a transient string-valued body', () {
    final form = _parseSavings(_savings()).form!;
    expect(Uri.parse(form.action).queryParameters, {'id': 'bank_ane:bank'});
    expect(form.bankId, 1);
    expect(form.fields, {'bankid': '1', 'action': 'cur', 'formhash': 'synthetic-token', 'banksubmit': 'true'});
    expect(() => form.fields['bankid'] = '2', throwsUnsupportedError);
    final deposit = form.body(BankOperation.deposit, '123', 'synthetic-password');
    expect(deposit, {
      ...form.fields,
      'banknum': '123',
      'op': 'in',
      'bankpass': 'synthetic-password',
    });
    final withdrawal = form.body(BankOperation.withdraw, '7', 'different-password');
    expect(withdrawal['op'], 'out');
    expect(withdrawal['bankpass'], 'different-password');
    expect(form.fields.containsKey('bankpass'), isFalse);
    deposit['bankid'] = '2';
    expect(form.fields['bankid'], '1');
  });

  test('amount validation avoids decimal, signed, zero, whitespace and oversized numbers', () {
    final form = _parseSavings(_savings()).form!;
    for (final amount in ['', '0', '-1', '+1', '1.2', '1e3', ' 1', '1 ', '1\n', '01', '１', '1000000000000000000']) {
      expect(form.accepts(amount), isFalse, reason: amount);
      expect(() => form.body(BankOperation.deposit, amount, 'password'), throwsFormatException, reason: amount);
    }
    expect(form.accepts('1'), isTrue);
    expect(form.accepts('999999999999999999'), isTrue);
    expect(() => form.body(BankOperation.withdraw, '1', ''), throwsFormatException);
  });

  test('missing or mismatched hidden bank identity never gets invented', () {
    final variants = [
      _form.replaceAll('<input type="hidden" name="bankid" value="1">', ''),
      _form.replaceAll('<input type="hidden" name="action" value="cur">', ''),
      _form.replaceAll('name="bankid" value="1"', 'name="bankid" value="2"'),
      _form.replaceAll('name="action" value="cur"', 'name="action" value="fix"'),
      _form.replaceAll('name="bankid" value="1"', 'name="bankid" value=""'),
      _form.replaceAll('name="action" value="cur"', 'name="action" value=""'),
    ];
    for (final form in variants) {
      final parsed = _parseSavings(_savings(form: form));
      expect(parsed.form, isNull);
      expect(parsed.summary, isNotEmpty);
    }
  });

  test('only the observed POST form destination is accepted', () {
    for (final action in [
      'https://evil.example/plugin.php?id=bank_ane:bank',
      'http://www.tsdm39.com/plugin.php?id=bank_ane:bank',
      '//evil.example/plugin.php?id=bank_ane:bank',
      'plugin.php?id=bank_ane:bank&amp;action=cur',
      'plugin.php?id=bank_ane:bank&amp;id=other',
      'plugin.php?id=other',
      'member.php?id=bank_ane:bank',
      '',
    ]) {
      expect(
        _parseSavings(
          _savings(form: _form.replaceAll('action="plugin.php?id=bank_ane:bank"', 'action="$action"')),
        ).form,
        isNull,
        reason: action,
      );
    }
    expect(_parseSavings(_savings(form: _form.replaceAll('method="post"', 'method="get"'))).form, isNull);
  });

  test('ambiguous, disabled, incomplete or changed control structures stay read-only', () {
    final variants = [
      '$_form$_form',
      _form.replaceAll('</form>', '<input type="hidden" name="bankid" value="1"></form>'),
      _form.replaceAll('type="text" name="banknum"', 'type="hidden" name="banknum"'),
      _form.replaceAll('name="banknum"', 'name="banknum" disabled'),
      _form.replaceAll('name="banknum"', 'name="banknum" readonly'),
      _form.replaceAll('name="bankpass"', 'name="bankpass" disabled'),
      _form.replaceAll('name="banksubmit"', 'name="banksubmit" disabled'),
      _form.replaceAll('value="out"', 'value="in"'),
      _form.replaceAll('type="radio"', 'type="checkbox"'),
      _form.replaceAll('name="banksubmit" value="true"', 'name="banksubmit" value="unknown"'),
      _form.replaceAll('value="synthetic-token"', 'value=""'),
      _form.replaceAll('</form>', '<input name="unrecognised-required-field"></form>'),
      _form.replaceAll('value="synthetic-token"', 'value="synthetic-token" disabled'),
      _form.replaceAll(
        '<input type="text" name="banknum">',
        '<fieldset disabled><input type="text" name="banknum"></fieldset>',
      ),
    ];
    for (final form in variants) {
      expect(_parseSavings(_savings(form: form)).form, isNull, reason: form);
    }
  });

  test('a form with no server formhash does not gain a guessed token', () {
    final form = _form.replaceAll('<input type="hidden" name="formhash" value="synthetic-token">', '');
    final parsed = _parseSavings(_savings(form: form)).form!;
    expect(parsed.fields.containsKey('formhash'), isFalse);
  });

  test('unknown currency cannot produce an actionable transaction form', () {
    final parsed = _parseSavings(_savings().replaceAll('<font color="red">示例币:</font>', ''));
    expect(parsed.currency, isEmpty);
    expect(parsed.summary, isNotEmpty);
    expect(parsed.form, isNull);
  });

  test('nested duplicate table ids produce each log record once and discard the IP column', () {
    final parsed = parseBankLogs(parseHtmlDocument(_logs()), bankId: 1, received: false, page: 1);
    expect(parsed.entries, hasLength(2));
    expect(parsed.entries.first.message, '示例存款 10 示例币');
    expect(parsed.entries.first.time, '2026-01-01 12:34:56');
    expect(parsed.entries.map((entry) => '${entry.message} ${entry.time}').join(), isNot(contains('192.0.2.123')));
    expect(parsed.entries.map((entry) => '${entry.message} ${entry.time}').join(), isNot(contains('2001:db8::1')));
    expect(parsed.hasNext, isFalse);
    expect(parsed.entries.clear, throwsUnsupportedError);
  });

  test('only an explicit empty log section becomes an empty list', () {
    final parsed = parseBankLogs(parseHtmlDocument(_logs(empty: true)), bankId: 1, received: false, page: 1);
    expect(parsed.entries, isEmpty);
    final changed = _logs(empty: true).replaceAll('还没有相关数据。', 'Unexpected server response');
    expect(() => parseBankLogs(parseHtmlDocument(changed), bankId: 1, received: false, page: 1), throwsFormatException);
    final unrelatedEmpty = changed.replaceAll('My and received tabs', 'My and received tabs 还没有相关数据。');
    expect(
      () => parseBankLogs(parseHtmlDocument(unrelatedEmpty), bankId: 1, received: false, page: 1),
      throwsFormatException,
    );
  });

  test('real bank pagination inside the records table is not a malformed transaction', () {
    final html = _logs().replaceFirst(
      '</tbody></table>',
      '<tr><td colspan="3"><div class="pg"><strong>1</strong>'
          '<a href="plugin.php?id=bank_ane:bank&amp;bankid=1&amp;action=log&amp;show=0&amp;page=2">下一页</a>'
          '</div></td></tr></tbody></table>',
    );
    final logs = parseBankLogs(parseHtmlDocument(html), bankId: 1, received: false, page: 1);
    expect(logs.entries, hasLength(2));
    expect(logs.hasNext, isTrue);
  });

  test('empty bank response with line breaks and center element remains empty', () {
    final html = _logs(empty: true).replaceFirst(
      '<center>还没有相关数据。</center>',
      '<br><br><center>还没有相关数据。</center><br><br><br>',
    );
    expect(parseBankLogs(parseHtmlDocument(html), bankId: 1, received: true, page: 1).entries, isEmpty);
  });

  test('pagination is restricted to the same bank, tab, action and next numeric page', () {
    const next = 'plugin.php?id=bank_ane:bank&amp;bankid=1&amp;action=log&amp;show=0&amp;page=2';
    expect(
      parseBankLogs(parseHtmlDocument(_logs(next: next)), bankId: 1, received: false, page: 1).hasNext,
      isTrue,
    );
    for (final invalid in [
      next.replaceAll('bankid=1', 'bankid=2'),
      next.replaceAll('show=0', 'show=1'),
      next.replaceAll('page=2', 'page=3'),
      next.replaceAll('action=log', 'action=cur'),
      '$next&amp;banksubmit=true',
      '$next&amp;page=3',
      'https://evil.example/$next',
      next.replaceAll('plugin.php', 'member.php'),
    ]) {
      expect(
        parseBankLogs(parseHtmlDocument(_logs(next: invalid)), bankId: 1, received: false, page: 1).hasNext,
        isFalse,
        reason: invalid,
      );
    }
    expect(
      parseBankLogs(
        parseHtmlDocument(_logs(next: next.replaceAll('show=0', 'show=1'))),
        bankId: 1,
        received: true,
        page: 1,
      ).hasNext,
      isTrue,
    );
  });

  test('login, error, challenge and changed markup never look like empty bank data', () {
    for (final html in [
      '<form id="loginform">Please log in</form>',
      '<div id="messagetext" class="alert_error">Permission denied</div>',
      '<script>var challenge = true;</script>',
      '<table id="ttt"><tr><td>Unrecognised markup</td></tr></table>',
    ]) {
      final document = parseHtmlDocument(html);
      expect(() => parseBankDirectory(document), throwsFormatException);
      expect(() => parseBankSavings(document, bankId: 1), throwsFormatException);
      expect(() => parseBankLogs(document, bankId: 1, received: false, page: 1), throwsFormatException);
    }
    expect(
      () => _parseSavings(_savings().replaceAll('您当前的存款金额为', 'Unrecognised balance format')),
      throwsFormatException,
    );
  });
}
