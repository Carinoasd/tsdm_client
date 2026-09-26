import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/features/bank/view/bank_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/bank_service_fixtures.dart';

class _Repository extends BankRepository {
  _Repository({this.hasAccount = true, this.pending, this.record = false, this.closeOperation = false})
    : super(getPage: (_) async => '', postForm: (_, _) async => '');

  final bool hasAccount;
  final bool record;
  final bool closeOperation;
  final Completer<void>? pending;
  final submissions = <Map<String, String>>[];

  @override
  Future<BankDirectory> fetchDirectory(int uid) async => BankDirectory(
    banks: [
      ForumBank(id: 1, name: 'Synthetic bank', hasAccount: hasAccount && !(closeOperation && submissions.isNotEmpty)),
    ],
  );

  @override
  Future<BankSavings> fetchSavings(int bankId, int uid) async => const BankSavings(bankId: 1);

  @override
  Future<BankServiceData> fetchService(BankService service, int uid, {int? bankId, int page = 1}) async {
    final recordForm = bankServiceFormFixture(
      BankService.term,
      operation: 'out',
      record: true,
      extraHidden: '<input type="hidden" name="fixid" value="7">',
    );
    final html = service == BankService.exchange
        ? bankDocument('<div id="messagetext">银行暂时不允许积分买卖，请返回。</div>')
        : bankServiceFixture(
            service,
            operation: closeOperation && service == BankService.account ? 'cl' : null,
            form: record ? '' : null,
            records: record ? '<tr><td>本金100；期限30天</td><td>$recordForm</td></tr>' : null,
          );
    return parseBankService(parseHtmlDocument(html), service, bankId: bankId, page: page);
  }

  @override
  Future<void> submitService(BankServiceForm form, Map<String, String> values) async {
    submissions.add(form.body(values));
    if (pending case final wait?) await wait.future;
  }
}

Future<BankCubit> _pump(WidgetTester tester, _Repository repo, {int? Function()? uid}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  final cubit = BankCubit(currentUid: uid ?? () => 1000, repository: () => repo);
  addTearDown(cubit.close);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(home: BankPage(controller: cubit)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('bank-1')));
  await tester.pumpAndSettle();
  return cubit;
}

Future<void> _choose(WidgetTester tester, BankService service) async {
  final picker = find.byKey(const ValueKey('bank-service-picker'));
  await tester.scrollUntilVisible(picker, -180, scrollable: find.byType(Scrollable).first);
  await tester.tap(picker);
  await tester.pumpAndSettle();
  final item = find.byKey(ValueKey('bank-service-${service.name}')).last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: item, matching: find.byType(Text)));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String title) async {
  final action = find.widgetWithText(FilledButton, title);
  await tester.scrollUntilVisible(action, 160, scrollable: find.byType(Scrollable).first);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester, String field, String value) async {
  final input = find.byKey(ValueKey('bank-input-$field'));
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
  await tester.enterText(input, value);
  await tester.pumpAndSettle();
}

Future<void> _continue(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('bank-service-continue'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('term input validates minimum days, confirms exact values and clears passwords after cancellation', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await _choose(tester, BankService.term);
    expect(find.text('还没有相关数据。'), findsOneWidget);
    await _open(tester, 'Make term deposit');
    await _fill(tester, 'banknum', '1.5');
    await _fill(tester, 'daynum', '29');
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _continue(tester);
    expect(find.byKey(const ValueKey('bank-service-confirm')), findsNothing);
    expect(repo.submissions, isEmpty);
    await _fill(tester, 'banknum', '100');
    await _fill(tester, 'daynum', '30');
    await _continue(tester);
    expect(find.text('Amount: 100'), findsOneWidget);
    expect(find.text('Days: 30'), findsOneWidget);
    expect(find.text('synthetic-password'), findsNothing);
    expect(repo.submissions, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _open(tester, 'Make term deposit');
    final field = tester.widget<TextFormField>(find.byKey(const ValueKey('bank-input-bankpass')));
    expect(field.controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('remittance retains recipient and calculated fee through confirmation, and sends only once', (
    tester,
  ) async {
    final pending = Completer<void>();
    final repo = _Repository(pending: pending);
    final cubit = await _pump(tester, repo);
    await _choose(tester, BankService.remittance);
    await _open(tester, 'Transfer');
    await _fill(tester, 'banknum', '501');
    await _fill(tester, 'touser', 'Synthetic recipient');
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _continue(tester);
    expect(find.textContaining('Estimated fee: 2 Test coins'), findsOneWidget);
    expect(find.textContaining("Recipient's forum account: Synthetic recipient"), findsOneWidget);
    final confirm = find.byKey(const ValueKey('bank-service-confirm'));
    await tester.tap(confirm);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repo.submissions, hasLength(1));
    expect(repo.submissions.single['banknum'], '501');
    expect(repo.submissions.single['touser'], 'Synthetic recipient');
    expect(cubit.state.submitting, isTrue);
    expect(tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('bank-service-picker'))).onChanged, isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('its result is not confirmed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a service confirmation cannot submit after switching accounts', (tester) async {
    int? uid = 1000;
    final repo = _Repository();
    final cubit = await _pump(tester, repo, uid: () => uid);
    await _choose(tester, BankService.term);
    await _open(tester, 'Make term deposit');
    await _fill(tester, 'banknum', '100');
    await _fill(tester, 'daynum', '30');
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _continue(tester);
    uid = null;
    cubit.invalidate();
    await cubit.load();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bank-service-confirm')), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(repo.submissions, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening an account is available without savings and checks password confirmation', (tester) async {
    final repo = _Repository(hasAccount: false);
    await _pump(tester, repo);
    await _choose(tester, BankService.hall);
    await _open(tester, 'Open bank account · 我要开户(开户费用:20)');
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _fill(tester, 'bankpass2', 'different');
    await _continue(tester);
    expect(find.text('The passwords do not match.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-service-confirm')), findsNothing);
    await _fill(tester, 'bankpass2', 'synthetic-password');
    await _continue(tester);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('开户费用:20')), findsOneWidget);
    expect(repo.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('record withdrawal shows the selected term details and sends the server record ID', (tester) async {
    final repo = _Repository(record: true);
    await _pump(tester, repo);
    await _choose(tester, BankService.term);
    await _open(tester, '支取');
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('本金100')), findsOneWidget);
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _continue(tester);
    expect(repo.submissions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('bank-service-confirm')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single['fixid'], '7');
    expect(repo.submissions.single['op'], 'out');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('320-wide service form and confirmation remain scrollable with the keyboard open', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repository();
    await _pump(tester, repo);
    await _choose(tester, BankService.term);
    await _open(tester, 'Make term deposit');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    await _fill(tester, 'banknum', '100');
    await _fill(tester, 'daynum', '30');
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _continue(tester);
    expect(find.byKey(const ValueKey('bank-service-confirm')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disabled credit exchange shows the forum reason without a transaction button', (tester) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await _choose(tester, BankService.exchange);
    expect(find.textContaining('银行暂时不允许积分买卖'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closing an account keeps the result page valid after membership changes', (tester) async {
    final repo = _Repository(closeOperation: true);
    final cubit = await _pump(tester, repo);
    await _choose(tester, BankService.account);
    await _open(tester, 'Close bank account');
    await _fill(tester, 'bankpass', 'synthetic-password');
    await _continue(tester);
    expect(find.textContaining('This closes the bank account.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bank-service-confirm')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single['op'], 'cl');
    expect(cubit.state.bank!.hasAccount, isFalse);
    expect(find.textContaining('its result is not confirmed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
