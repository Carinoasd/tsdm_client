/// Issue #123: the native title shop screen, its confirmation and narrow layout.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/title_shop/cubit/title_shop_cubit.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/features/title_shop/view/title_shop_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import 'fixtures/title_shop_fixtures.dart';

final class _Harness {
  _Harness({Completer<String>? answer}) : _answer = answer;

  final Completer<String>? _answer;
  var owned = false;
  final posts = <Map<String, String>>[];

  late final cubit = TitleShopCubit(
    currentUid: () => 1000,
    repository: () => TitleShopRepository(
      getPage: (_) async => shopPage([
        if (owned) ownedRow(9001, '虚构作品-甲', '3800') else buyRow(9001, '虚构作品-甲', '3800'),
        ownedRow(9002, '虚构作品-乙', '4500'),
        buyRow(9003, '很长的虚构作品名称' * 5, '4294967295'),
      ]),
      postForm: (_, body) async {
        posts.add(body);
        final answer = _answer;
        final result = answer == null ? messagePage('操作完成') : await answer.future;
        owned = true;
        return result;
      },
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  TitleShopCubit cubit, {
  double width = 400,
  double height = 900,
  double scale = 1,
}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: TitleShopPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _buyOf(String name) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
  matching: find.widgetWithText(FilledButton, t.titleShop.purchase),
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('the shop lists server intro, balance, prices and statuses on a narrow screen', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit, width: 320);
    expect(find.text(shopIntro), findsOneWidget);
    expect(find.text('天使币：12345'), findsOneWidget);
    expect(find.text(t.titleShop.idAndPrice(id: 9001, price: '3800')), findsOneWidget);
    expect(find.text(t.titleShop.owned), findsOneWidget);
    await tester.scrollUntilVisible(find.text(t.titleShop.idAndPrice(id: 9003, price: '4294967295')), 300);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });

  testWidgets('large text and a long title leave the confirmation readable and cancellable', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit, width: 320, height: 640, scale: 1.8);
    final buy = _buyOf('很长的虚构作品名称' * 5);
    await tester.scrollUntilVisible(buy.hitTestable(), 250);
    await tester.pumpAndSettle();
    await tester.tap(buy);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text(t.general.cancel));
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(h.posts, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });

  testWidgets('cancelling the confirmation sends nothing', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit);
    await tester.tap(_buyOf('虚构作品-甲'));
    await tester.pumpAndSettle();
    expect(find.text(shopConfirm('3800')), findsOneWidget, reason: 'the server sentence carries the price');
    expect(find.text(t.titleShop.notEquipped), findsOneWidget);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(h.posts, isEmpty);
    expect(h.cubit.state.result, isNull);
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });

  testWidgets('confirming buys once, locks every button meanwhile and reports the verified owned state', (
    tester,
  ) async {
    final answer = Completer<String>();
    final h = _Harness(answer: answer);
    await _pump(tester, h.cubit);
    await tester.tap(_buyOf('虚构作品-甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(t.titleShop.purchase)));
    await tester.pump();
    // Let the dialog finish closing; the pending purchase keeps a progress indicator spinning.
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.posts, hasLength(1));
    for (final button in tester.widgetList<FilledButton>(find.byType(FilledButton))) {
      expect(button.onPressed, isNull, reason: 'no second purchase while one is pending');
    }
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh)).onPressed, isNull);
    answer.complete(messagePage('操作完成'));
    await tester.pumpAndSettle();
    expect(h.posts, hasLength(1));
    expect(find.byKey(const ValueKey('title-shop-result')), findsOneWidget);
    expect(find.text(t.titleShop.purchased(name: '虚构作品-甲')), findsOneWidget);
    expect(find.text(t.titleShop.owned), findsNWidgets(2));
    expect(h.cubit.state.page!.items.first.status, TitleShopStatus.owned);
    await tester.pumpWidget(const SizedBox());
    await h.cubit.close();
  });
}
