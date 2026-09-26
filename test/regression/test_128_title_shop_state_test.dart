/// Issue #123: title purchases are account-bound, revalidated on a fresh page, posted at most once and verified by GET.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/title_shop/cubit/title_shop_cubit.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/instance.dart';

import 'fixtures/title_shop_fixtures.dart';

/// Serves [pages] in order (the last one repeats) and records every request.
final class _Shop {
  _Shop(this.pages, {this.answer});

  final List<FutureOr<String> Function()> pages;
  final FutureOr<String> Function()? answer;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  TitleShopRepository repository() => TitleShopRepository(
    getPage: (url) async {
      gets.add(url);
      final next = pages.length > 1 ? pages.removeAt(0) : pages.single;
      return next();
    },
    postForm: (url, body) async {
      posts.add((url, body));
      return (answer ?? () => messagePage('操作完成'))();
    },
  );
}

String _buyable({String price = '3800', String name = '虚构作品-甲'}) =>
    shopPage([buyRow(9001, name, price), ownedRow(9002, '虚构作品-乙', '4500')]);
String _owned() => shopPage([ownedRow(9001, '虚构作品-甲', '3800'), ownedRow(9002, '虚构作品-乙', '4500')]);

Future<TitleShopCubit> _loaded(_Shop shop, {int? Function()? uid}) async {
  final cubit = TitleShopCubit(currentUid: uid ?? () => 1000, repository: shop.repository);
  addTearDown(cubit.close);
  await cubit.load();
  expect(cubit.state.page, isNotNull);
  return cubit;
}

TitleShopItem _item(TitleShopCubit cubit, [int id = 9001]) => cubit.state.page!.items.firstWhere((i) => i.id == id);

void main() {
  // Account binding reads the logged-in user through the parser, which logs via the global talker.
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test(
    'a confirmed purchase revalidates, posts the fresh form once and verifies ownership without equipping',
    () async {
      final shop = _Shop([
        _buyable,
        () => _buyable().replaceAll('TEST_HASH', 'FRESH_HASH'),
        _owned,
      ]);
      final cubit = await _loaded(shop);
      await cubit.purchase(expected: cubit.state.page!, item: _item(cubit));
      expect(shop.gets, [titleShopUrl, titleShopUrl, titleShopUrl], reason: 'load, revalidate, verify');
      expect(shop.posts.single.$1, titleBuyUrl);
      expect(shop.posts.single.$2, {
        'formhash': 'FRESH_HASH',
        'tsdmtitle_return': 'plugin.php?id=tsdmtitle:tsdmtitle&action=shop&app=plugin',
        'buyid': '9001',
        'buysubmit': 'true',
      });
      expect(shop.posts.any((p) => p.$1.contains('settitle') || p.$2.containsKey('settitleid')), isFalse);
      expect(cubit.state.result?.outcome, TitlePurchaseOutcome.purchased);
      expect(cubit.state.result?.message, '操作完成');
      expect(_item(cubit).status, TitleShopStatus.owned, reason: 'the list shows the refreshed owned state');
      expect(cubit.state.purchasingId, isNull);
    },
  );

  test('a changed price, name or confirmation posts nothing and needs a new confirmation', () async {
    final shop = _Shop([_buyable, () => _buyable(price: '4500'), () => _buyable(price: '4500'), _owned]);
    final cubit = await _loaded(shop);
    final stale = _item(cubit);
    await cubit.purchase(expected: cubit.state.page!, item: stale);
    expect(shop.posts, isEmpty);
    expect(cubit.state.result?.outcome, TitlePurchaseOutcome.termsChanged);
    expect(_item(cubit).price, '4500', reason: 'the fresh terms are displayed for the new confirmation');
    await cubit.purchase(expected: cubit.state.page!, item: stale);
    expect(shop.posts, isEmpty, reason: 'the old confirmation cannot be reused');
    await cubit.purchase(expected: cubit.state.page!, item: _item(cubit));
    expect(shop.posts, hasLength(1));
    expect(cubit.state.result?.outcome, TitlePurchaseOutcome.purchased);
  });

  test('a title owned or withdrawn meanwhile is not bought', () async {
    final shop = _Shop([_buyable, _owned]);
    final cubit = await _loaded(shop);
    await cubit.purchase(expected: cubit.state.page!, item: _item(cubit));
    expect(shop.posts, isEmpty);
    expect(cubit.state.result?.outcome, TitlePurchaseOutcome.unavailable);
    expect(cubit.state.result?.message, '已拥有');
  });

  test('a transport failure is never re-posted; ownership decides the outcome', () async {
    final shop = _Shop([_buyable, _buyable, _owned], answer: () => throw const SocketException('reset'));
    final cubit = await _loaded(shop);
    await cubit.purchase(expected: cubit.state.page!, item: _item(cubit));
    expect(shop.posts, hasLength(1));
    expect(cubit.state.result?.outcome, TitlePurchaseOutcome.purchased);

    final lost = _Shop([_buyable, _buyable, _buyable], answer: () => throw const SocketException('reset'));
    final other = await _loaded(lost);
    await other.purchase(expected: other.state.page!, item: _item(other));
    expect(lost.posts, hasLength(1));
    expect(other.state.result?.outcome, TitlePurchaseOutcome.unconfirmed, reason: 'no error text, not owned');
  });

  test('a forum refusal is quoted; an unverifiable result stays unconfirmed across retries', () async {
    final refused = _Shop([_buyable, _buyable, _buyable], answer: () => messagePage('您的天使币不足', error: true));
    final cubit = await _loaded(refused);
    await cubit.purchase(expected: cubit.state.page!, item: _item(cubit));
    expect(cubit.state.result?.outcome, TitlePurchaseOutcome.rejected);
    expect(cubit.state.result?.message, '您的天使币不足');

    final offline = _Shop([_buyable, _buyable, () => throw const SocketException('offline'), _owned]);
    final other = await _loaded(offline);
    await other.purchase(expected: other.state.page!, item: _item(other));
    expect(offline.posts, hasLength(1));
    expect(other.state.failed, isTrue);
    expect(other.state.result?.outcome, TitlePurchaseOutcome.unconfirmed);
    await other.load();
    expect(offline.posts, hasLength(1), reason: 'retry is a GET only');
    expect(other.state.result?.outcome, TitlePurchaseOutcome.unconfirmed, reason: 'the warning survives a refresh');
    expect(_item(other).status, TitleShopStatus.owned);
  });

  test('repeated taps and stale confirmations send one POST at most', () async {
    final answer = Completer<String>();
    final shop = _Shop([_buyable, _buyable, _owned], answer: () => answer.future);
    final cubit = await _loaded(shop);
    final page = cubit.state.page!;
    final item = _item(cubit);
    final first = cubit.purchase(expected: page, item: item);
    final second = cubit.purchase(expected: page, item: item);
    expect(cubit.canPurchase(page, item), isFalse);
    await cubit.load();
    await pumpEventQueue();
    answer.complete(messagePage('操作完成'));
    await Future.wait([first, second]);
    expect(shop.posts, hasLength(1));
    await cubit.purchase(expected: page, item: item);
    expect(shop.posts, hasLength(1), reason: 'the page it was confirmed on has been replaced');
  });

  test('an account switch before or during the purchase sends nothing more and shows nothing old', () async {
    var uid = 1000;
    final revalidate = Completer<String>();
    final shop = _Shop([_buyable, () => revalidate.future]);
    final cubit = await _loaded(shop, uid: () => uid);
    final pending = cubit.purchase(expected: cubit.state.page!, item: _item(cubit));
    uid = 2000;
    cubit.invalidate();
    revalidate.complete(_buyable());
    await pending;
    expect(shop.posts, isEmpty, reason: 'no POST once the account changed');
    expect(cubit.state.page, isNull);
    expect(cubit.state.result, isNull);

    var owner = 1000;
    final answer = Completer<String>();
    final during = _Shop([_buyable, _buyable, _owned], answer: () => answer.future);
    final other = await _loaded(during, uid: () => owner);
    final sent = other.purchase(expected: other.state.page!, item: _item(other));
    await pumpEventQueue();
    expect(during.posts, hasLength(1));
    owner = 2000;
    other.invalidate();
    answer.complete(messagePage('操作完成'));
    await sent;
    expect(during.gets, hasLength(2), reason: 'no verification GET is made for the old account');
    expect(other.state.result, isNull, reason: 'the old account result is not shown as the new one');
  });

  test('a page served to another account or a guest is not shown', () async {
    final cubit = TitleShopCubit(currentUid: () => 1000, repository: _Shop([() => shopPage([], uid: 2000)]).repository);
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.page, isNull);
    expect(cubit.state.failed, isTrue);

    final guest = TitleShopCubit(currentUid: () => 1000, repository: _Shop([() => shopPage([], uid: 0)]).repository);
    addTearDown(guest.close);
    await guest.load();
    expect(guest.state.loginRequired, isTrue);

    final signedOut = TitleShopCubit(currentUid: () => null, repository: _Shop([_buyable]).repository);
    addTearDown(signedOut.close);
    await signedOut.load();
    expect(signedOut.state.loginRequired, isTrue);
  });

  test('pagination follows only shop links and clears the previous result', () async {
    final shop = _Shop([
      _buyable,
      () => shopPage([buyRow(9010, '第二页', '1')], page: 2),
    ]);
    final cubit = await _loaded(shop);
    await cubit.load(cubit.state.page!.nextUrl);
    expect(shop.gets.last, '$titleShopUrl&buyitem=0&page=2');
    expect(cubit.state.page!.page, 2);
    await cubit.load('$titleBuyUrl&buyid=9010');
    expect(shop.gets, hasLength(2), reason: 'a purchase URL never becomes a GET');
  });
}
