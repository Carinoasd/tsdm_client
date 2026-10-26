/// Full UI redesign, phase 4: shop, bank and community surfaces on narrow screens, large fonts and wide windows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/features/bank/view/bank_page.dart';
import 'package:tsdm_client/features/checkin/widgets/auto_checkin_user_card.dart';
import 'package:tsdm_client/features/title_shop/cubit/title_shop_cubit.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/features/title_shop/view/title_shop_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/title_shop_fixtures.dart';

const _longName = '很长的虚构作品名称很长的虚构作品名称很长的虚构作品名称';

TitleShopCubit _shop(List<Map<String, String>> posts) => TitleShopCubit(
  currentUid: () => 1000,
  repository: () => TitleShopRepository(
    getPage: (_) async => shopPage([
      buyRow(9001, '虚构作品-甲', '3800'),
      ownedRow(9002, '虚构作品-乙', '4500'),
      buyRow(9003, _longName, '4294967295'),
    ]),
    postForm: (_, body) async {
      posts.add(body);
      return messagePage('操作完成');
    },
  ),
);

const _bank = ForumBank(id: 1, name: 'Synthetic bank', hasAccount: true);

// Synthetic markup, the same shape as the bank page tests use; no live account data.
BankSavings _savings() => parseBankSavings(
  parseHtmlDocument('''
<div class="tbn"><ul><li><font>Test coins:</font><span><b>800</b></span>(银行货币)</li></ul></div>
<table id="ttt"><tr><th><h2>活期储蓄</h2></th></tr>
<tr><td class="footoperation">您当前的存款金额为 100 ，活期利率为1‰。</td></tr>
<tr><td><form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="1">
<input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="synthetic-token">
<input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass"><button type="submit" name="banksubmit" value="true">提交</button>
</form></td></tr></table>
'''),
  bankId: 1,
);

class _BankRepository extends BankRepository {
  _BankRepository() : super(getPage: (_) async => '', postForm: (_, _) async => '');

  final submissions = <String>[];

  @override
  Future<BankDirectory> fetchDirectory(int uid) async => const BankDirectory(banks: [_bank]);

  @override
  Future<BankSavings> fetchSavings(int bankId, int uid) async => _savings();

  @override
  Future<BankLogs> fetchLogs(int bankId, int uid, {bool received = false, int page = 1}) async => BankLogs(
    entries: [
      BankLogEntry(message: 'Synthetic transaction record with a rather long description $page', time: '2026-01-01'),
    ],
    hasNext: page == 1,
  );

  @override
  Future<String> submit(BankTransactionForm form, BankOperation operation, String amount, String password) async {
    submissions.add(amount);
    return '';
  }
}

Future<void> _pump(WidgetTester tester, Widget home, {required Size size, double scale = 1}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('title shop', () {
    testWidgets('320 wide with 2x text: artwork keeps the 184x100 ratio and the confirmation keeps the price', (
      tester,
    ) async {
      final posts = <Map<String, String>>[];
      final cubit = _shop(posts);
      addTearDown(cubit.close);
      await _pump(
        tester,
        TitleShopPage(
          controller: cubit,
          imageBuilder: (_) => const ColoredBox(key: ValueKey('artwork'), color: Colors.grey),
        ),
        size: const Size(320, 640),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      final artwork = tester.getSize(find.byKey(const ValueKey('artwork')).first);
      expect(artwork.width / artwork.height, closeTo(184 / 100, 0.01), reason: 'contained, never cropped');
      expect(artwork.width, lessThanOrEqualTo(184));

      final buy = find.descendant(
        of: find.byKey(const ValueKey('title-9003')),
        matching: find.widgetWithText(FilledButton, t.titleShop.purchase),
      );
      await tester.scrollUntilVisible(buy.hitTestable(), 200);
      await tester.pumpAndSettle();
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text(shopConfirm('4294967295'))), findsOneWidget);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(t.titleShop.idAndPrice(id: 9003, price: '4294967295')),
        ),
        findsOneWidget,
        reason: 'the full price is shown, not shortened',
      );
      expect(find.descendant(of: dialog, matching: find.text(t.titleShop.notEquipped)), findsOneWidget);
      await tester.ensureVisible(find.text(t.general.cancel));
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a wide window shows the titles in two columns', (tester) async {
      final cubit = _shop([]);
      addTearDown(cubit.close);
      await _pump(
        tester,
        TitleShopPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
        size: const Size(1280, 800),
      );
      final first = tester.getRect(find.byKey(const ValueKey('title-9001')));
      final second = tester.getRect(find.byKey(const ValueKey('title-9002')));
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.right));
      expect(first.width, lessThanOrEqualTo(480), reason: 'the list is centered at most 960 wide');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('bank: 320 wide with 2x text keeps savings, records and the confirmation readable', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final repository = _BankRepository();
    final cubit = BankCubit(currentUid: () => 1000, repository: () => repository);
    addTearDown(cubit.close);
    await _pump(tester, BankPage(controller: cubit), size: const Size(320, 640), scale: 2);
    await tester.tap(find.byKey(const ValueKey('bank-1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final deposit = find.byKey(const ValueKey('bank-deposit'));
    await tester.ensureVisible(deposit);
    await tester.pumpAndSettle();
    await tester.tap(deposit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bank-amount')), '12');
    await tester.enterText(find.byKey(const ValueKey('bank-password')), 'synthetic-password');
    final next = find.byKey(const ValueKey('bank-continue'));
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('Deposit: 12 Test coins'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(repository.submissions, isEmpty, reason: 'reviewing is not confirming');
    await tester.tap(find.text(t.bank.cancel));
    await tester.pumpAndSettle();
    expect(repository.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('auto checkin card: long names and failures wrap at 320 wide with 2x text', (tester) async {
    await _pump(
      tester,
      const Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              AutoCheckinUserCard(
                UserLoginInfo(username: '一个非常非常长的虚构用户名称用于测试换行', uid: 123456789),
                'Synthetic failure message that is long enough to need several lines on a phone',
                failure: true,
              ),
              AutoCheckinUserCard(UserLoginInfo(username: 'x', uid: 1), null),
            ],
          ),
        ),
      ),
      size: const Size(320, 640),
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('UID 123456789'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
  });
}
