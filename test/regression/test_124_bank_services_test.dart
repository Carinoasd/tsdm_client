import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/bank_service_fixtures.dart';

BankServiceData parseService(String html, BankService service) =>
    parseBankService(parseHtmlDocument(html), service, bankId: service.global ? null : 1);

Future<BankCubit> serviceCubit(BankRepository repository, BankService service, {int? Function()? uid}) async {
  final cubit = BankCubit(currentUid: uid ?? () => 1000, repository: () => repository);
  addTearDown(cubit.close);
  await cubit.load();
  // No savings data is needed to load term deposits or any other service.
  await cubit.selectBank(cubit.state.banks.single);
  await cubit.loadService(service);
  expect(cubit.state.serviceData, isNotNull);
  return cubit;
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('all service read URLs exclude state-changing operations', () {
    for (final service in BankService.values) {
      final uri = Uri.parse(bankServiceUrl(service, bankId: 1));
      expect(uri.queryParameters.containsKey('op'), isFalse);
      expect(uri.queryParameters.containsKey('banksubmit'), isFalse);
      expect(uri.queryParameters['mode'], service.global ? 'other' : null);
    }
    expect(() => bankServiceUrl(BankService.term), throwsFormatException);
  });

  for (final service in BankService.values.where((service) => !service.global)) {
    test('${service.name} uses only the actual form fields and accepts a fresh CSRF token', () {
      final data = parseService(bankServiceFixture(service), service);
      expect(data.forms, hasLength(1));
      expect(data.unsupportedForms, isFalse);
      final form = data.forms.single;
      final body = form.body(bankServiceInput(form));
      expect(body['bankid'], '1');
      expect(body['banksubmit'], 'true');
      final fresh = parseService(bankServiceFixture(service, token: 'new-synthetic-token'), service).forms.single;
      expect(form.matches(fresh), isTrue);
      expect(fresh.body(bankServiceInput(fresh))['formhash'], 'new-synthetic-token');
    });
  }

  test('term records render without any current-savings data and preserve the record context', () {
    final form = bankServiceFormFixture(
      BankService.term,
      operation: 'out',
      record: true,
      extraHidden: '<input type="hidden" name="fixid" value="7">',
    );
    final data = parseService(
      bankServiceFixture(
        BankService.term,
        form: '',
        records: '<tr><td>本金100；期限30天；到期2026-10-01</td><td>$form</td></tr>',
      ),
      BankService.term,
    );
    expect(data.blocks.any((block) => block.text.contains('本金100')), isTrue);
    expect(data.forms, hasLength(1));
    expect(data.forms.single.context, contains('本金100'));
    expect(data.forms.single.body(bankServiceInput(data.forms.single))['fixid'], '7');
    final changed = parseService(
      bankServiceFixture(
        BankService.term,
        form: '',
        records: '<tr><td>本金100；期限30天；到期2026-10-01</td><td>${form.replaceAll('value="7"', 'value="8"')}</td></tr>',
      ),
      BankService.term,
    );
    expect(data.forms.single.matches(changed.forms.single), isFalse);
  });

  test('loan repayment and cancellation require a labelled server form with a record identifier', () {
    for (final operation in ['back', 'del']) {
      final form = bankServiceFormFixture(
        BankService.loans,
        operation: operation,
        record: true,
        extraHidden: '<input type="hidden" name="lenid" value="8">',
      ).replaceAll('支取', operation == 'back' ? '还款' : '取消申请');
      final data = parseService(
        bankServiceFixture(BankService.loans, form: '', records: '<tr><td>贷款100；待处理</td><td>$form</td></tr>'),
        BankService.loans,
      );
      expect(data.forms.single.hidden['op'], operation);
      expect(data.forms.single.hidden['lenid'], '8');
    }
  });

  test('unknown, wrong-bank, disabled, foreign and unexpected-field forms stay read-only', () {
    final source = bankServiceFormFixture(BankService.term);
    final variants = [
      source.replaceFirst('value="1"', 'value="2"'),
      source.replaceFirst('action="plugin.php', 'action="https://evil.invalid/plugin.php'),
      source.replaceFirst('method="post"', 'method="get"'),
      source.replaceFirst('name="banknum"', 'name="banknum" disabled'),
      source.replaceFirst('name="daynum"', 'name="unknown"'),
      source.replaceFirst('value="fix"', 'value="pas"'),
      source.replaceFirst('value="1"', ''),
      source.replaceFirst('</form>', '<input name="redirect" value="https://evil.invalid"></form>'),
    ];
    for (final html in variants) {
      final data = parseService(bankServiceFixture(BankService.term, form: html), BankService.term);
      expect(data.forms, isEmpty, reason: html);
      expect(data.unsupportedForms, isTrue);
    }
  });

  test('amount, duration, recipient and password confirmation preserve the exact user input', () {
    final term = parseService(bankServiceFixture(BankService.term), BankService.term).forms.single;
    for (final value in ['0', '-1', '1.5', '1e3', ' 100', '9999999999999999999']) {
      expect(() => term.body({...bankServiceInput(term), 'banknum': value}), throwsFormatException);
    }
    expect(() => term.body({...bankServiceInput(term), 'daynum': '29'}), throwsFormatException);
    final remittance = parseService(bankServiceFixture(BankService.remittance), BankService.remittance).forms.single;
    expect(() => remittance.body({...bankServiceInput(remittance), 'banknum': '9'}), throwsFormatException);
    expect(() => remittance.body({...bankServiceInput(remittance), 'touser': 'someone\nelse'}), throwsFormatException);
    final account = parseService(bankServiceFixture(BankService.account), BankService.account).forms.single;
    expect(() => account.body({...bankServiceInput(account), 'newbankpass2': 'different'}), throwsFormatException);
  });

  test('transfer fee uses exact ceiling arithmetic even above JavaScript integer precision', () {
    final data = parseService(bankServiceFixture(BankService.remittance, rate: '0.3'), BankService.remittance);
    expect(data.estimatedFee('1'), '1');
    expect(data.estimatedFee('10000'), '3');
    expect(data.estimatedFee('999999999999999999'), '300000000000000');
    expect(data.estimatedFee('1.5'), isNull);
  });

  test('disabled exchange shows the server reason instead of an empty account or an invented form', () {
    final data = parseService(
      bankDocument('<div id="messagetext" class="alert_error">银行暂时不允许积分买卖，请返回。</div>'),
      BankService.exchange,
    );
    expect(data.unavailable, contains('不允许积分买卖'));
    expect(data.forms, isEmpty);
  });

  test('rankings include the second outer table, without duplicate nested rows', () {
    final html = bankDocument(
      '<table id="ttt"><tr><td><h2>财富排行</h2></td></tr>'
      '<tr><td><table id="ttt"><tr><td>User A</td><td>100</td></tr></table></td></tr></table>'
      '<table id="ttt"><tr><td><table id="ttt"><tr><td>Bank B</td><td>20</td></tr></table></td></tr></table>',
    );
    final data = parseService(html, BankService.ranking);
    expect(data.blocks.map((block) => block.text), ['User A\n100', 'Bank B\n20']);
  });

  test('new bank password fields are redacted from every log representation', () {
    for (final field in ['bankpass2', 'newbankpass', 'newbankpass2']) {
      for (final raw in [
        '$field=super-secret&x=1',
        '{$field: super-secret}',
        '<input value="super-secret" name="$field">',
      ]) {
        expect(redactSensitive(raw), isNot(contains('super-secret')));
      }
    }
  });

  test('service submission uses the bound repository, fresh hash and exactly one POST on timeout', () async {
    var posts = 0;
    var token = 'old-synthetic-token';
    Map<String, String>? submitted;
    final repo = BankRepository(
      getPage: (url) async => Uri.parse(url).queryParameters['action'] == 'fix'
          ? bankServiceFixture(BankService.term, token: token)
          : bankDirectoryFixture(),
      postForm: (_, body) async {
        posts++;
        submitted = Map.of(body);
        throw TimeoutException('Synthetic timeout after receiving body');
      },
    );
    final cubit = await serviceCubit(repo, BankService.term);
    final expected = cubit.state.serviceData!;
    token = 'fresh-synthetic-token';
    final form = expected.forms.single;
    await cubit.submitService(expected: expected, form: form, values: bankServiceInput(form));
    expect(posts, 1);
    expect(submitted!['formhash'], token);
    expect(cubit.state.unconfirmed, isTrue);
    await cubit.refresh();
    expect(posts, 1);
    expect(cubit.state.unconfirmed, isTrue);
  });

  for (final change in ['account', 'bank', 'fee', 'record', 'form']) {
    test('$change changes before submission prevent any POST', () async {
      var changed = false;
      var posts = 0;
      int? uid = 1000;
      final repo = BankRepository(
        getPage: (url) async {
          if (Uri.parse(url).queryParameters['action'] != 'chg') return bankDirectoryFixture();
          var html = bankServiceFixture(
            BankService.remittance,
            bankId: changed && change == 'bank' ? 2 : 1,
            rate: changed && change == 'fee' ? '3' : '2',
          );
          if (changed && change == 'record') html = html.replaceFirst('当前汇款', '更改了规则：当前汇款');
          if (changed && change == 'form') html = html.replaceFirst('name="touser"', 'name="unsupported"');
          return html;
        },
        postForm: (_, _) async {
          posts++;
          return '';
        },
      );
      final cubit = await serviceCubit(repo, BankService.remittance, uid: () => uid);
      final expected = cubit.state.serviceData!;
      final form = expected.forms.single;
      changed = true;
      if (change == 'account') uid = 1001;
      await cubit.submitService(expected: expected, form: form, values: bankServiceInput(form));
      expect(posts, 0);
    });
  }

  test('double tap and navigation during service POST never issue another transaction', () async {
    final pending = Completer<String>();
    var posts = 0;
    final repo = BankRepository(
      getPage: (url) async => Uri.parse(url).queryParameters['action'] == 'fix'
          ? bankServiceFixture(BankService.term)
          : bankDirectoryFixture(),
      postForm: (_, _) {
        posts++;
        return pending.future;
      },
    );
    final cubit = await serviceCubit(repo, BankService.term);
    final data = cubit.state.serviceData!;
    final form = data.forms.single;
    final first = cubit.submitService(expected: data, form: form, values: bankServiceInput(form));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.submitting, isTrue);
    await cubit.submitService(expected: data, form: form, values: bankServiceInput(form));
    await cubit.loadService(BankService.account);
    expect(posts, 1);
    pending.complete('Response');
    await first;
    expect(cubit.state.service, BankService.term);
  });
}
