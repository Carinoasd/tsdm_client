/// The forum bank's term deposits list each record with a link (`op=out&noid=…`) to the forum's own confirmation
/// page, which holds the withdrawal form (the record, the bank password): the app found no form on the list and could
/// not withdraw a term deposit.
///
/// 1. the record's link becomes its withdrawal, with the record's text; a link of another bank, operation or a loan's
///    repayment (run on the link itself) is left to the website;
/// 2. withdrawing reads the confirmation page and sends the form it serves, once; a reason the page gives instead
///    or a form for another record sends nothing;
/// 3. the page reads the confirmation page before the dialog: its notice is shown with the record, a reason it gives
///    instead ends there.
///
/// Synthetic pages after the bank plugin's own templates; nothing is sent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/features/bank/view/bank_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/bank_service_fixtures.dart';

/// One term record row, as the plugin prints it.
String _record(int noid, {String href = '', String label = '支取'}) =>
    '''
<tr><td>存款数目: 100天使币&nbsp;&nbsp;
定期利率: 3‰&nbsp;&nbsp;
开始时间: 2026-09-01&nbsp;&nbsp;
到期时间: 2026-10-01&nbsp;&nbsp;
当前利息: 9天使币
</td>
<td width="40" align="center">[<a href="${href.isEmpty ? 'plugin.php?id=bank_ane:bank&bankid=1&action=fix&op=out&noid=$noid' : href}"><em class="xw0 xi1">$label</em></a>]</td>
</tr>''';

/// The withdrawal confirmation page for [noid].
String _confirmation(int noid, {String extra = ''}) => bankDocument('''
<div class="mainbox"><table id="ttt" cellspacing="0" cellpadding="0" width="100%">
<thead class="colplural"><tr><td align="center"><h2>定期储蓄</h2></td></tr></thead>
<tr><td>
<form action="plugin.php?id=bank_ane:bank" name="name" method="post" onSubmit="return validate(this)">
<input type="hidden" name="bankid" value="1" />
<input type="hidden" name="action" value="fix" />
<input type="hidden" name="op" value="out" />
<input type="hidden" name="noid" value="$noid" />$extra
<p align="center"><br />确定要支取这笔定期存款吗？<br /><br />
银行密码: <input type="password" class="pt" name="bankpass" size="15" />&nbsp;&nbsp;
<button type="submit" name="banksubmit" value="true" class="pn"><strong>提 交</strong></button><br /><br /></p>
</form>
</td></tr>
</table></div>''');

BankServiceData _term(String records) => parseBankService(
  parseHtmlDocument(bankServiceFixture(BankService.term, records: records)),
  BankService.term,
  bankId: 1,
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. the term list', () {
    test("each record's withdrawal link becomes its withdrawal, with the record's text", () {
      final data = _term(_record(7) + _record(9));
      expect(data.unsupportedForms, isFalse);
      final withdrawals = data.forms.where((form) => form.operation == 'out').toList();
      expect(withdrawals, hasLength(2));
      final form = withdrawals.first;
      expect(form.inputs, [BankInput.password]);
      expect(form.hidden, {'bankid': '1', 'action': 'fix', 'op': 'out', 'noid': '7'});
      expect(form.context, contains('存款数目: 100'));
      expect(form.context, isNot(contains('[支取]')));
      expect(form.label, '支取');
      expect(Uri.parse(form.confirmUrl!).queryParameters, {
        'id': 'bank_ane:bank',
        'bankid': '1',
        'action': 'fix',
        'op': 'out',
        'noid': '7',
      });
      expect(form.matches(withdrawals.last), isFalse, reason: 'another record');
      expect(data.forms.where((form) => form.operation == 'in'), hasLength(1), reason: 'the deposit form stays');
    });

    test('a link of another bank, operation or record id, or an extra parameter, is left to the website', () {
      for (final href in [
        'plugin.php?id=bank_ane:bank&bankid=2&action=fix&op=out&noid=7',
        'plugin.php?id=bank_ane:bank&bankid=1&action=fix&op=del&noid=7',
        'plugin.php?id=bank_ane:bank&bankid=1&action=fix&op=out&noid=x',
        'plugin.php?id=bank_ane:bank&bankid=1&action=fix&op=out&noid=7&formhash=1',
        'plugin.php?id=bank_ane:bank&bankid=1&action=len&op=out&noid=7',
      ]) {
        final data = _term(_record(7, href: href));
        expect(data.forms.where((form) => form.operation == 'out'), isEmpty, reason: href);
        expect(data.unsupportedForms, isTrue, reason: href);
      }
    });

    test("a loan's repayment or cancellation link runs on the link itself: left to the website", () {
      for (final op in ['gb', 'gu']) {
        final data = parseBankService(
          parseHtmlDocument(
            bankServiceFixture(
              BankService.loans,
              records: _record(8, href: 'plugin.php?id=bank_ane:bank&bankid=1&action=len&op=$op&noid=8', label: '还款'),
            ),
          ),
          BankService.loans,
          bankId: 1,
        );
        expect(data.forms.where((form) => form.hidden.containsKey('noid')), isEmpty);
        expect(data.unsupportedForms, isTrue, reason: op);
      }
    });
  });

  group('2. withdrawing', () {
    late List<String> reads;
    late List<Map<String, String>> posts;
    late String Function(int noid) confirmation;

    Future<BankCubit> cubit() async {
      final repo = BankRepository(
        getPage: (url) async {
          reads.add(url);
          final query = Uri.parse(url).queryParameters;
          if (query['action'] != 'fix') return bankDirectoryFixture();
          if (query['op'] == 'out') return confirmation(int.parse(query['noid']!));
          return bankServiceFixture(BankService.term, records: _record(7) + _record(9));
        },
        postForm: (url, body) async {
          posts.add(Map.of(body));
          return '';
        },
      );
      final cubit = BankCubit(currentUid: () => 1000, repository: () => repo);
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.selectBank(cubit.state.banks.single);
      await cubit.loadService(BankService.term);
      return cubit;
    }

    setUp(() {
      reads = [];
      posts = [];
      confirmation = _confirmation;
    });

    Future<BankCubit> withdraw(int noid) async {
      final controller = await cubit();
      final data = controller.state.serviceData!;
      final form = data.forms.singleWhere((form) => form.hidden['noid'] == '$noid');
      await controller.submitService(expected: data, form: form, values: {'bankpass': 'synthetic-password'});
      return controller;
    }

    test("reads the record's confirmation page and sends the form it serves, once", () async {
      confirmation = (noid) => _confirmation(noid, extra: '<input type="hidden" name="formhash" value="fresh" />');
      final controller = await withdraw(9);
      expect(reads.where((url) => Uri.parse(url).queryParameters['op'] == 'out'), hasLength(1));
      expect(Uri.parse(reads.firstWhere((url) => url.contains('op=out'))).queryParameters['noid'], '9');
      expect(posts, [
        {
          'bankid': '1',
          'action': 'fix',
          'op': 'out',
          'noid': '9',
          'formhash': 'fresh',
          'bankpass': 'synthetic-password',
          'banksubmit': 'true',
        },
      ]);
      expect(controller.state.unconfirmed, isTrue);
      expect(controller.state.serviceData, isNotNull, reason: 'the list is read again');
    });

    test('a reason the page gives instead is shown, nothing sent', () async {
      confirmation = (_) => bankDocument('<div id="messagetext"><p>这笔定期存款尚未到期</p></div>');
      final controller = await withdraw(7);
      expect(posts, isEmpty);
      expect(controller.state.serviceData!.unavailable, contains('尚未到期'));
      expect(controller.state.failed, isFalse);
      expect(controller.state.unconfirmed, isFalse);
    });

    test('the notice read before the dialog is the one checked when sending', () async {
      final controller = await cubit();
      final data = controller.state.serviceData!;
      final form = data.forms.singleWhere((form) => form.hidden['noid'] == '7');
      final page = await controller.readConfirmation(data, form);
      expect(page, (notice: '确定要支取这笔定期存款吗？', reason: ''));
      expect(posts, isEmpty);
      confirmation = (noid) => _confirmation(noid).replaceFirst('确定要支取', '提前支取不计利息，确定要支取');
      await controller.submitService(
        expected: data,
        form: form,
        values: {'bankpass': 'synthetic-password'},
        notice: page!.notice,
      );
      expect(posts, isEmpty);
      expect(controller.state.failed, isTrue);
    });

    test('a page for another record, bank or with another field sends nothing', () async {
      for (final page in [
        (int noid) => _confirmation(noid + 1),
        (int noid) => _confirmation(noid).replaceFirst('name="bankid" value="1"', 'name="bankid" value="2"'),
        (int noid) => _confirmation(noid, extra: '<input type="text" class="pt" name="banknum" />'),
        (int noid) => _confirmation(noid).replaceFirst('name="op" value="out"', 'name="op" value="in"'),
      ]) {
        posts.clear();
        confirmation = page;
        final controller = await withdraw(7);
        expect(posts, isEmpty);
        expect(controller.state.failed, isTrue);
        expect(controller.state.unconfirmed, isFalse);
      }
    });
  });

  group('3. the page', () {
    late List<Map<String, String>> posts;
    late String Function(int noid) confirmation;

    Future<void> pump(WidgetTester tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final repo = BankRepository(
        getPage: (url) async {
          final query = Uri.parse(url).queryParameters;
          if (query['action'] != 'fix') return bankDirectoryFixture();
          if (query['op'] == 'out') return confirmation(int.parse(query['noid']!));
          return bankServiceFixture(BankService.term, records: _record(7));
        },
        postForm: (url, body) async {
          posts.add(Map.of(body));
          return '';
        },
      );
      final cubit = BankCubit(currentUid: () => 1000, repository: () => repo);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: BankPage(controller: cubit)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bank-1')));
      await tester.pumpAndSettle();
      await cubit.loadService(BankService.term);
      await tester.pumpAndSettle();
      final action = find.widgetWithText(FilledButton, '支取');
      await tester.scrollUntilVisible(action, 160, scrollable: find.byType(Scrollable).first);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    setUp(() {
      posts = [];
      confirmation = _confirmation;
    });

    testWidgets("the page's notice is shown with the record, then the form it serves is sent", (tester) async {
      await pump(tester);
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.textContaining('存款数目: 100')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('确定要支取这笔定期存款吗？')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('bank-input-bankpass')), 'synthetic-password');
      await tester.tap(find.byKey(const ValueKey('bank-service-continue')));
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('bank-service-confirm')));
      await tester.pumpAndSettle();
      expect(posts.single['noid'], '7');
      expect(posts.single['op'], 'out');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a reason the page gives instead is shown, without a password field', (tester) async {
      confirmation = (_) => bankDocument('<div id="messagetext"><p>这笔定期存款尚未到期</p></div>');
      await pump(tester);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('尚未到期')), findsOneWidget);
      expect(find.byKey(const ValueKey('bank-input-bankpass')), findsNothing);
      expect(posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
