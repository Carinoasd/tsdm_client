import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/features/bank/view/bank_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/parsing.dart';

const _bank = ForumBank(id: 1, name: 'Synthetic bank', hasAccount: true);

// Synthetic markup supplies the validated form without any live account data.
BankSavings _savings({bool supported = true}) => parseBankSavings(
  parseHtmlDocument('''
<div class="tbn"><ul><li><font>Test coins:</font><span><b>800</b></span>(银行货币)</li></ul></div>
<table id="ttt"><tr><th><h2>活期储蓄</h2></th></tr>
<tr><td class="footoperation">您当前的存款金额为 100 ，活期利率为1‰。</td></tr>
<tr><td><form method="post" action="plugin.php?id=bank_ane:bank">
${supported ? '<input type="hidden" name="bankid" value="1">' : ''}
<input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="synthetic-token">
<input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass"><button type="submit" name="banksubmit" value="true">提交</button>
</form></td></tr></table>
'''),
  bankId: 1,
);

class _Repository extends BankRepository {
  _Repository({this.supported = true, this.pendingSubmission, this.pendingDirectory})
    : super(getPage: (_) async => '', postForm: (_, _) async => '');

  final bool supported;
  final Completer<void>? pendingSubmission;
  final Completer<BankDirectory>? pendingDirectory;
  final submissions = <({BankOperation operation, String amount, String password})>[];

  @override
  Future<BankDirectory> fetchDirectory(int uid) async {
    if (pendingDirectory case final pending?) return pending.future;
    return const BankDirectory(banks: [_bank]);
  }

  @override
  Future<BankSavings> fetchSavings(int bankId, int uid) async => _savings(supported: supported);

  @override
  Future<BankLogs> fetchLogs(int bankId, int uid, {bool received = false, int page = 1}) async => BankLogs(
    entries: [BankLogEntry(message: '${received ? "Received" : "Own"} transaction page $page', time: '2026-01-01')],
    hasNext: page == 1,
  );

  @override
  Future<void> submit(BankTransactionForm form, BankOperation operation, String amount, String password) async {
    submissions.add((operation: operation, amount: amount, password: password));
    if (pendingSubmission case final pending?) await pending.future;
  }
}

Future<BankCubit> _pumpBank(
  WidgetTester tester,
  _Repository repository, {
  int? Function()? currentUid,
}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  final cubit = BankCubit(currentUid: currentUid ?? () => 1000, repository: () => repository);
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

Future<void> _fillTransaction(WidgetTester tester, {bool withdraw = false}) async {
  await tester.tap(find.byKey(ValueKey(withdraw ? 'bank-withdraw' : 'bank-deposit')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('bank-amount')), '12');
  await tester.enterText(find.byKey(const ValueKey('bank-password')), 'synthetic-password');
  await tester.tap(find.byKey(const ValueKey('bank-continue')));
  await tester.pumpAndSettle();
}

Future<void> _pushBank(WidgetTester tester, BankCubit cubit) async {
  await LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => BankPage(controller: cubit)),
              ),
              child: const Text('Open bank'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open bank'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('pending transaction blocks page back until the result warning is shown', (tester) async {
    final pending = Completer<void>();
    final repository = _Repository(pendingSubmission: pending);
    final cubit = BankCubit(currentUid: () => 1000, repository: () => repository);
    addTearDown(cubit.close);
    await _pushBank(tester, cubit);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-1')));
    await tester.pumpAndSettle();
    await _fillTransaction(tester);
    await tester.tap(find.byKey(const ValueKey('bank-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.submissions, hasLength(1));
    expect(cubit.state.submitting, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Back'))
          .onPressed,
      isNull,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(BankPage), findsOneWidget);
    expect(find.text('Open bank'), findsNothing);
    expect(repository.submissions, hasLength(1));

    pending.complete();
    await tester.pumpAndSettle();
    expect(cubit.state.submitting, isFalse);
    expect(find.textContaining('its result is not confirmed'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BankPage), findsNothing);
    expect(find.text('Open bank'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ordinary bank page reads do not block navigation back', (tester) async {
    final pending = Completer<BankDirectory>();
    final repository = _Repository(pendingDirectory: pending);
    final cubit = BankCubit(currentUid: () => 1000, repository: () => repository);
    addTearDown(cubit.close);
    await _pushBank(tester, cubit);
    expect(cubit.state.busy, isTrue);
    expect(cubit.state.submitting, isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BankPage), findsNothing);
    expect(find.text('Open bank'), findsOneWidget);
    expect(repository.submissions, isEmpty);
    pending.complete(const BankDirectory(banks: [_bank]));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('both cancellation steps leave the bank unchanged', (tester) async {
    final repository = _Repository();
    await _pumpBank(tester, repository);
    await tester.tap(find.byKey(const ValueKey('bank-deposit')));
    await tester.pumpAndSettle();
    final passwordField = tester.widget<TextFormField>(find.byKey(const ValueKey('bank-password')));
    expect(passwordField.controller!.text, isEmpty);
    final editablePassword = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('bank-password')), matching: find.byType(TextField)),
    );
    expect(editablePassword.obscureText, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.submissions, isEmpty);

    await _fillTransaction(tester);
    expect(find.text('Confirm bank transaction'), findsOneWidget);
    expect(find.text('Deposit: 12 Test coins'), findsOneWidget);
    expect(repository.submissions, isEmpty, reason: 'Reviewing an amount is not confirmation');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.submissions, isEmpty);
    expect(tester.takeException(), isNull, reason: 'Input controllers must survive the closing route animation');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('withdrawal requires explicit confirmation and never claims success', (tester) async {
    final repository = _Repository();
    await _pumpBank(tester, repository);
    await _fillTransaction(tester, withdraw: true);
    expect(find.text('Withdraw: 12 Test coins'), findsOneWidget);
    expect(repository.submissions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('bank-confirm')));
    await tester.pumpAndSettle();
    expect(repository.submissions, [(operation: BankOperation.withdraw, amount: '12', password: 'synthetic-password')]);
    expect(find.textContaining('its result is not confirmed'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bank-deposit')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('bank-password'))).controller!.text, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pasted decimals and oversized amounts are rejected without becoming another amount', (tester) async {
    final repository = _Repository();
    await _pumpBank(tester, repository);
    await tester.tap(find.byKey(const ValueKey('bank-deposit')));
    await tester.pumpAndSettle();
    final amountFinder = find.byKey(const ValueKey('bank-amount'));
    await tester.enterText(amountFinder, '1.5');
    expect(tester.widget<TextFormField>(amountFinder).controller!.text, isEmpty);
    await tester.enterText(amountFinder, '1234567890123456789');
    expect(tester.widget<TextFormField>(amountFinder).controller!.text, isEmpty);
    await tester.enterText(amountFinder, '-12');
    expect(tester.widget<TextFormField>(amountFinder).controller!.text, isEmpty);
    await tester.enterText(amountFinder, '0');
    await tester.tap(find.byKey(const ValueKey('bank-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a positive whole number, up to 18 digits.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-confirm')), findsNothing);
    expect(repository.submissions, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an account change dismisses the confirmation without submitting', (tester) async {
    int? uid = 1000;
    final repository = _Repository();
    final cubit = await _pumpBank(tester, repository, currentUid: () => uid);
    await _fillTransaction(tester);
    uid = null;
    cubit.invalidate();
    await cubit.load();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Sign in to view your bank account'), findsOneWidget);
    expect(repository.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an incomplete form is read-only and bank logs can be paged independently', (tester) async {
    final repository = _Repository(supported: false);
    await _pumpBank(tester, repository);
    expect(find.byKey(const ValueKey('bank-deposit')), findsNothing);
    expect(find.byKey(const ValueKey('bank-withdraw')), findsNothing);
    expect(find.textContaining('Transactions are unavailable'), findsOneWidget);
    await tester.ensureVisible(find.text('My transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Own transaction page 1'), findsOneWidget);
    final nextButton = find.widgetWithText(TextButton, 'Next');
    await tester.ensureVisible(nextButton);
    await tester.pumpAndSettle();
    await tester.tap(nextButton);
    await tester.pumpAndSettle();
    expect(find.text('Own transaction page 2'), findsOneWidget);
    await tester.ensureVisible(find.text('Received transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Received transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Received transaction page 1'), findsOneWidget);
    expect(repository.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('320-wide transaction input and confirmation remain usable above the keyboard', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = _Repository();
    await _pumpBank(tester, repository);
    final depositButton = find.byKey(const ValueKey('bank-deposit'));
    await tester.ensureVisible(depositButton);
    await tester.pumpAndSettle();
    await tester.tap(depositButton);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final amountField = find.byKey(const ValueKey('bank-amount'));
    await tester.ensureVisible(amountField);
    await tester.pumpAndSettle();
    await tester.enterText(amountField, '12');
    final passwordField = find.byKey(const ValueKey('bank-password'));
    await tester.ensureVisible(passwordField);
    await tester.pumpAndSettle();
    await tester.enterText(passwordField, 'synthetic-password');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final continueButton = find.byKey(const ValueKey('bank-continue'));
    await tester.ensureVisible(continueButton);
    await tester.pumpAndSettle();
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(find.text('Confirm bank transaction'), findsOneWidget);
    expect(find.text('Deposit: 12 Test coins'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(repository.submissions, isEmpty);

    final confirmButton = find.byKey(const ValueKey('bank-confirm'));
    await tester.ensureVisible(confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();
    expect(repository.submissions, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
