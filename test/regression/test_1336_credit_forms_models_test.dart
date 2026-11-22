/// The transfer (`credit_transfer`, schema 72) and the exchange (`credit_exchange`, schema 73) forms of plugin 4.1.0
/// read from their answers, and what an amount gives and leaves, as the forum computes it (`credit_base.php`).
///
/// * Transfer: the member receives `floor(amount × (1 - tax))`; an amount above `balance - min_balance`, or one that
///   leaves nothing after the tax, is not sent.
/// * Exchange: the amount is what is received of the target; the source pays `amount × to.ratio / from.ratio ×
///   (1 + tax)`, rounded up when the target's ratio is below the source's and down otherwise (on the test forum, tax
///   20 %: 5 天使币 from 威望 (ratio 1 / 5) cost 2; 1 精灵 from 天使币 (2 / 1) cost 2). A source must keep
///   `min_balance`. A credit without a ratio is in neither menu (the forum would divide by 0).
/// * The bodies carry the fields the forum's form serves and the fields of the page; nothing else.
///
/// Fixtures: the answers of the test forum (cleaned).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/points/models/credit_forms.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

CreditTransferForm _transfer([Map<String, Object?> changes = const {}]) =>
    CreditTransferForm.fromJson({...v4Json('credit_transfer_v72.json'), ...changes}, uid: _uid)!;

CreditExchangeForm _exchange([Map<String, Object?> changes = const {}]) =>
    CreditExchangeForm.fromJson({...v4Json('credit_exchange_v73.json'), ...changes}, uid: _uid)!;

ExchangeCredit _credit(List<ExchangeCredit> menu, int id) => menu.firstWhere((e) => e.id == id);

void main() {
  group('transfer', () {
    test('the page: the credit, the balance, the limit and the tax', () {
      final form = _transfer();
      expect(form.uid, _uid);
      expect((form.credit.id, form.credit.title), (2, '天使币'));
      expect(form.minBalance, 1000);
      expect(form.maxAmount, form.balance - 1000);
      expect((form.tax, form.taxText), (0.2, '20.00%'));
      expect(_transfer({'balance': 900}).maxAmount, 0, reason: 'below the minimum: nothing to transfer');
    });

    test('what the member receives, and what is not sent', () {
      final form = _transfer({'balance': 1576, 'min_balance': 1000});
      expect(
        [
          for (final n in [1, 2, 5, 10, 576]) form.received(n),
        ],
        [0, 1, 4, 8, 460],
      );
      expect(form.problemOf(0), CreditTransferProblem.amount);
      expect(form.problemOf(-3), CreditTransferProblem.amount);
      expect(form.problemOf(1), CreditTransferProblem.nothingReceived);
      expect(form.problemOf(577), CreditTransferProblem.balance);
      expect(form.problemOf(576), isNull);
      expect(form.problemOf(2), isNull);
    });

    test('the body: the served fields, the page fields, nothing else', () {
      final body = _transfer().body(to: '测试会员', amount: 10, message: '谢谢', password: 'secret');
      expect(body, {
        'formhash': 'f1f2f3f4',
        'transfersubmit': 'true',
        'handlekey': 'transfercredit',
        'to': '测试会员',
        'transferamount': '10',
        'transfermessage': '谢谢',
        'password': 'secret',
      });
    });

    test('an answer without the credit or the formhash is no form', () {
      expect(CreditTransferForm.fromJson({...v4Json('credit_transfer_v72.json'), 'credit': null}, uid: _uid), isNull);
      final json = v4Json('credit_transfer_v72.json');
      ((json['submit'] as Map)['fields'] as Map).remove('formhash');
      expect(CreditTransferForm.fromJson(json, uid: _uid), isNull);
    });
  });

  group('exchange', () {
    test('the menus: the credits with a ratio, the balances, the limit', () {
      final form = _exchange();
      expect([for (final c in form.to) (c.id, c.ratio)], [(2, 1), (6, 2)]);
      expect([for (final c in form.from) (c.id, c.ratio)], [(1, 5), (2, 1), (6, 2)]);
      expect(form.minBalance, 100);
      expect(form.balanceOf(_credit(form.from, 1)), isPositive);
      expect(form.usable, isTrue);
      final noRatio = _exchange({
        'from': [
          {'id': 3, 'title': '宣传', 'unit': '', 'ratio': 0},
          {'id': 2, 'title': '天使币', 'unit': '', 'ratio': 1},
        ],
      });
      expect([for (final c in noRatio.from) c.id], [2]);
      expect(_exchange({'to': <Object>[]}).usable, isFalse);
      expect(
        _exchange({
          'to': [
            {'id': 2, 'title': '天使币', 'unit': '', 'ratio': 1},
          ],
          'from': [
            {'id': 2, 'title': '天使币', 'unit': '', 'ratio': 1},
          ],
        }).usable,
        isFalse,
        reason: 'one credit on both sides',
      );
    });

    test("what it costs: the forum's formula and its rounding", () {
      final form = _exchange();
      final prestige = _credit(form.from, 1);
      final coin = _credit(form.to, 2);
      final spirit = _credit(form.to, 6);
      // Measured on the test forum.
      expect(form.cost(coin, prestige, 5), 2, reason: 'ceil(1 / 5 × 5 × 1.2) = ceil(1.2)');
      expect(form.cost(spirit, _credit(form.from, 2), 1), 2, reason: 'floor(2 / 1 × 1 × 1.2) = floor(2.4)');
      expect(form.cost(coin, prestige, 1), 1, reason: 'ceil(0.24)');
      expect(form.cost(coin, _credit(form.from, 6), 3), 2, reason: 'ceil(1 / 2 × 3 × 1.2) = ceil(1.8)');
      final decimal = _exchange({
        'to': [
          {'id': 2, 'title': '天使币', 'unit': '', 'ratio': 1.5},
        ],
        'tax': 0,
      });
      expect(form.cost(decimal.to.single, prestige, 10), 4, reason: 'ceil(1.5 / 5 × 10 × 1.2) = ceil(3.6)');
      expect(decimal.cost(decimal.to.single, prestige, 10), 3, reason: 'ceil(1.5 / 5 × 10) = ceil(3.0)');
    });

    test('what is not sent', () {
      final form = _exchange({
        'credits': [
          {'id': 1, 'title': '威望', 'unit': '', 'icon': '', 'value': 154},
          {'id': 2, 'title': '天使币', 'unit': '', 'icon': '', 'value': 1566},
          {'id': 6, 'title': '精灵', 'unit': '', 'icon': '', 'value': 3},
        ],
      });
      final prestige = _credit(form.from, 1);
      final coin = _credit(form.to, 2);
      expect(form.problemOf(coin, _credit(form.from, 2), 5), CreditExchangeProblem.same);
      expect(form.problemOf(coin, prestige, 0), CreditExchangeProblem.amount);
      // 154 - ceil(1 / 5 × 220 × 1.2) = 154 - 53 = 101: enough; 154 - ceil(55.2) = 98: not.
      expect(form.problemOf(coin, prestige, 220), isNull);
      expect(form.problemOf(coin, prestige, 230), CreditExchangeProblem.balance);
      expect(form.problemOf(coin, _credit(form.from, 6), 1), CreditExchangeProblem.balance, reason: '3 of 精灵');
    });

    test('the body: the served fields, the menus by id, nothing else', () {
      final form = _exchange();
      final body = form.body(target: _credit(form.to, 6), source: _credit(form.from, 2), amount: 3, password: 'pw');
      expect(body, {
        'formhash': 'f1f2f3f4',
        'operation': 'exchange',
        'exchangesubmit': 'true',
        'outi': '',
        'tocredits': '6',
        'fromcredits': '2',
        'exchangeamount': '3',
        'password': 'pw',
      });
    });
  });
}
