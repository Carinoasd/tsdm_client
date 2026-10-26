/// The forum bank's term deposits list each record with a link (`op=out&noid=…`) to the forum's own confirmation
/// page, which holds the withdrawal form (the record, the bank password): the app found no form on the list and could
/// not withdraw a term deposit.
///
/// 1. the record's link becomes its withdrawal, with the record's text; a link of another bank, operation or record
///    is left to the website; a loan's repayment and cancellation (run on the link itself) are left to the website
///    with their own note; a link in a bank's notice is only text;
/// 2. withdrawing reads the confirmation page and sends the form it serves, once, and keeps the forum's reply; a
///    reason the forum gives instead, a page that changed (another record, another notice, the record's terms) sends
///    nothing and shows the page as it is now;
/// 3. the page reads the confirmation page before the dialog, showing the wait: its notice is shown with the record, a
///    reason it gives instead ends there, a failed read says so (not "unsupported"); the forum's reply is shown.
///
/// Pages after the bank plugin's own templates and language strings (`fix_outform`, `var_error`, `pass_error`);
/// nothing is sent.
library;

import 'dart:async';

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
String _record(int noid, {String href = '', String label = '支取', String accrual = '0'}) =>
    '''
<tr><td>存款数目: 100天使币&nbsp;&nbsp;
定期利率: 3‰&nbsp;&nbsp;
开始时间: 2026-09-01 12:00&nbsp;&nbsp;
到期时间: 2026-10-01 12:00&nbsp;&nbsp;
当前利息: $accrual天使币
</td>
<td width="40" align="center">[<a href="${href.isEmpty ? 'plugin.php?id=bank_ane:bank&bankid=1&action=fix&op=out&noid=$noid' : href}"><em class="xw0 xi1">$label</em></a>]</td>
</tr>''';

/// The plugin's notice on the confirmation page (`fix_outform`), as it fills it in.
const _notice = '您当前准备支取定期的金额为100天使币，存入时间2026-09-01 12:00，到期时间2026-10-01 12:00，可得利息0天使币';

/// The withdrawal confirmation page for [noid].
String _confirmation(int noid, {String extra = '', String notice = _notice}) => bankDocument('''
<div class="mainbox"><table id="ttt" cellspacing="0" cellpadding="0" width="100%">
<thead class="colplural"><tr><td align="center"><h2>定期储蓄</h2></td></tr></thead>
<tr><td>
<form action="plugin.php?id=bank_ane:bank" name="name" method="post" onSubmit="return validate(this)">
<input type="hidden" name="bankid" value="1" />
<input type="hidden" name="action" value="fix" />
<input type="hidden" name="op" value="out" />
<input type="hidden" name="noid" value="$noid" />$extra
<p align="center"><br />$notice<br /><br />
银行密码: <input type="password" class="pt" name="bankpass" size="15" />&nbsp;&nbsp;
<button type="submit" name="banksubmit" value="true" class="pn"><strong>提  交</strong></button><br /><br /></p>
</form>
</td></tr>
</table></div>''');

/// The forum's message page (showmessage), as the bank answers a record that is gone or a wrong password.
String _message(String text) => bankDocument('''
<div id="messagetext" class="alert_error"><p>$text</p>
<p class="alert_btnleft"><a href="javascript:history.back()">[ 点击这里返回上一页 ]</a></p></div>''');

BankServiceData _page(BankService service, String records) => parseBankService(
  parseHtmlDocument(bankServiceFixture(service, records: records)),
  service,
  bankId: 1,
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. the term list', () {
    test("each record's withdrawal link becomes its withdrawal, with the record's text", () {
      final data = _page(BankService.term, _record(7) + _record(9));
      expect(data.unsupportedForms, isFalse);
      expect(data.webOnlyRecords, isFalse);
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
        final data = _page(BankService.term, _record(7, href: href));
        expect(data.forms.where((form) => form.operation == 'out'), isEmpty, reason: href);
        expect(data.unsupportedForms, isTrue, reason: href);
      }
    });

    test("a loan's repayment or cancellation runs on the link itself: left to the website with its own note", () {
      for (final (op, label) in [('gb', '还贷'), ('gu', '取消')]) {
        final data = _page(
          BankService.loans,
          _record(8, href: 'plugin.php?id=bank_ane:bank&bankid=1&action=len&op=$op&noid=8', label: label),
        );
        expect(data.forms.where((form) => form.hidden.containsKey('noid')), isEmpty);
        expect(data.webOnlyRecords, isTrue, reason: op);
        expect(data.unsupportedForms, isFalse, reason: 'the loan application form still works');
        expect(data.forms.where((form) => form.operation == 'try'), hasLength(1));
      }
    });

    test("a link in a bank's notice (the manager's BBCode) is only text", () {
      final data = _page(
        BankService.hall,
        '''
<tr><td><a href="plugin.php?id=bank_ane:bank&bankid=1&action=len&op=gb&noid=1" target="_blank">点此还贷</a></td></tr>''',
      );
      expect(data.unsupportedForms, isFalse);
      expect(data.webOnlyRecords, isFalse);
      expect(data.forms, hasLength(1), reason: 'opening an account');
    });
  });

  group('2. withdrawing', () {
    late List<String> reads;
    late List<Map<String, String>> posts;
    late String Function(int noid) confirmation;
    late String list;
    late String answer;

    Future<BankCubit> cubit() async {
      final repo = BankRepository(
        getPage: (url) async {
          reads.add(url);
          final query = Uri.parse(url).queryParameters;
          if (query['action'] != 'fix') return bankDirectoryFixture();
          if (query['op'] == 'out') return confirmation(int.parse(query['noid']!));
          return bankServiceFixture(BankService.term, records: list);
        },
        postForm: (url, body) async {
          posts.add(Map.of(body));
          return answer;
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
      list = _record(7) + _record(9);
      answer = '';
    });

    Future<BankCubit> withdraw(int noid, {void Function()? before}) async {
      final controller = await cubit();
      final data = controller.state.serviceData!;
      final form = data.forms.singleWhere((form) => form.hidden['noid'] == '$noid');
      before?.call();
      await controller.submitService(expected: data, form: form, values: {'bankpass': 'synthetic-password'});
      return controller;
    }

    test("reads the record's confirmation page and sends the form it serves, once, keeping the reply", () async {
      confirmation = (noid) => _confirmation(noid, extra: '<input type="hidden" name="formhash" value="fresh" />');
      answer = bankDocument(
        '''
<div id="messagetext" class="alert_right"><p>恭喜您，操作成功。</p>
<p class="alert_btnleft"><a href="plugin.php?id=bank_ane:bank&amp;bankid=1&amp;action=fix">如果您的浏览器没有自动跳转，请点击此链接</a></p></div>''',
      );
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
      expect(controller.state.reply, '恭喜您，操作成功。');
      expect(controller.state.serviceData, isNotNull, reason: 'the list is read again');
      await controller.refresh();
      expect(controller.state.reply, isEmpty, reason: 'the reply belongs to the transaction just sent');
      expect(controller.state.unconfirmed, isTrue);
    });

    test("a wrong bank password: the forum's reply is kept, still unconfirmed", () async {
      answer = _message('银行密码错误，请返回修改。');
      final controller = await withdraw(7);
      expect(posts, hasLength(1));
      expect(controller.state.reply, '银行密码错误，请返回修改。');
      expect(controller.state.unconfirmed, isTrue);
    });

    test('a reason the forum gives instead (the record is gone) is shown, nothing sent', () async {
      confirmation = (_) => _message('参数传递错误，请返回。');
      final controller = await withdraw(7);
      expect(posts, isEmpty);
      expect(controller.state.serviceData!.unavailable, '参数传递错误，请返回。');
      expect(controller.state.serviceData!.forms.where((form) => form.confirmUrl != null), hasLength(2));
      expect(controller.state.failed, isFalse);
      expect(controller.state.serviceChanged, isFalse);
      expect(controller.state.unconfirmed, isFalse);
    });

    test('the notice read before the dialog is the one checked when sending', () async {
      final controller = await cubit();
      final data = controller.state.serviceData!;
      final form = data.forms.singleWhere((form) => form.hidden['noid'] == '7');
      final page = await controller.readConfirmation(data, form);
      expect(page, (notice: _notice, reason: ''));
      expect(posts, isEmpty);
      confirmation = (noid) => _confirmation(noid, notice: _notice.replaceFirst('可得利息0', '可得利息9'));
      await controller.submitService(
        expected: data,
        form: form,
        values: {'bankpass': 'synthetic-password'},
        notice: page!.notice,
      );
      expect(posts, isEmpty);
      expect(controller.state.serviceChanged, isTrue);
      expect(controller.state.failed, isFalse);
      expect(controller.state.serviceData, isNotNull, reason: 'the page as it is now');
    });

    test("the record's terms changing (its interest once due) sends nothing and shows the page as it is now", () async {
      final controller = await withdraw(7, before: () => list = _record(7, accrual: '9') + _record(9));
      expect(posts, isEmpty);
      expect(reads.where((url) => url.contains('op=out')), isEmpty);
      expect(controller.state.serviceChanged, isTrue);
      expect(controller.state.failed, isFalse);
      expect(controller.state.serviceData!.blocks.any((block) => block.text.contains('当前利息: 9')), isTrue);
      // The page shown is current: withdrawing from it goes on as usual.
      final data = controller.state.serviceData!;
      await controller.submitService(
        expected: data,
        form: data.forms.singleWhere((form) => form.hidden['noid'] == '7'),
        values: {'bankpass': 'synthetic-password'},
      );
      expect(posts.single['noid'], '7');
      expect(controller.state.serviceChanged, isFalse);
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
        expect(controller.state.serviceChanged, isTrue);
        expect(controller.state.failed, isFalse);
        expect(controller.state.unconfirmed, isFalse);
      }
    });
  });

  group('3. the page', () {
    late List<Map<String, String>> posts;
    late Future<String> Function(int noid) confirmation;
    late String answer;

    Future<void> pump(WidgetTester tester, {AppLocale locale = AppLocale.en, bool settle = true}) async {
      // Outside the test's fake clock: switching the locale loads it for real.
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final repo = BankRepository(
        getPage: (url) async {
          final query = Uri.parse(url).queryParameters;
          if (query['action'] != 'fix') return bankDirectoryFixture();
          if (query['op'] == 'out') return confirmation(int.parse(query['noid']!));
          return bankServiceFixture(BankService.term, records: _record(7));
        },
        postForm: (url, body) async {
          posts.add(Map.of(body));
          return answer;
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
      final action = find.widgetWithText(FilledButton, t.bank.termWithdraw);
      await tester.scrollUntilVisible(action, 160, scrollable: find.byType(Scrollable).first);
      await tester.tap(action);
      if (settle) await tester.pumpAndSettle();
    }

    setUp(() {
      posts = [];
      confirmation = (noid) async => _confirmation(noid);
      answer = '';
    });
    tearDown(() async => LocaleSettings.setLocale(AppLocale.en));

    testWidgets("the page's notice is shown with the record, then the form it serves is sent", (tester) async {
      answer = _message('银行密码错误，请返回修改。');
      await pump(tester);
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('Withdraw term deposit')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.textContaining('存款数目: 100')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text(_notice)), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('bank-input-bankpass')), 'synthetic-password');
      await tester.tap(find.byKey(const ValueKey('bank-service-continue')));
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('bank-service-confirm')));
      await tester.pumpAndSettle();
      expect(posts.single['noid'], '7');
      expect(posts.single['op'], 'out');
      // The reply sits at the top of the page, above the record.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bank-reply')),
        -160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('bank-reply')), findsOneWidget);
      expect(find.textContaining('Forum reply: 银行密码错误，请返回修改。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the button shows the wait while the confirmation page is read', (tester) async {
      final page = Completer<String>();
      confirmation = (_) => page.future;
      await pump(tester, settle: false);
      await tester.pump();
      expect(find.byKey(const ValueKey('bank-service-reading')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      page.complete(_confirmation(7));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bank-service-reading')), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a reason the forum gives instead is shown, without a password field', (tester) async {
      confirmation = (_) async => _message('参数传递错误，请返回。');
      await pump(tester, locale: AppLocale.zhTw);
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('支取定期')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.textContaining('参数传递错误')), findsOneWidget);
      expect(find.byKey(const ValueKey('bank-input-bankpass')), findsNothing);
      expect(posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed read says so; a page the app cannot take points to the website', (tester) async {
      confirmation = (_) async => throw const SocketExceptionStub();
      await pump(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(t.bank.confirmLoadFailed), findsOneWidget);
      expect(find.text(t.bank.unsupported), findsNothing);
      await tester.pumpWidget(const SizedBox());

      confirmation = (noid) async => _confirmation(noid + 1);
      await pump(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(t.bank.unsupported), findsOneWidget);
      expect(posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// A failed read, as the network client throws it (not a [FormatException]).
final class SocketExceptionStub implements Exception {
  /// Constructor.
  const SocketExceptionStub();
}
