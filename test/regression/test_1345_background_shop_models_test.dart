/// The member's background shop of the forum's app API (plugin 4.1.0): `bg_mine` (74), `bg_store` (75), `bg_slot` (76)
/// and `bg_exchange` (77) read into the app's models, and the background plugin's own forms rebuilt from them.
///
/// * The answers are the test forum's (scrubbed: uid 31, form hash `f1f2f3f4`, `https://forum.test`); the exchange's
///   events there list no medal nor background, so one is filled in by hand for the exchange form.
/// * A form is used only when it goes to the background plugin of this forum (`ac=my`／`buybg`／`slot`, `background:sp`)
///   with plain field names: a tampered answer never sends a write anywhere else.
/// * The display form sends its four fields every time (one left out is set to the plugin's default) and the stretch
///   only when checked; the purchase carries the background and the position in the url.
/// * Background plugin off, too old, the event shop closed, the exchange switched off: "not available", never a page.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp/bgshop/$name.json').readAsStringSync()) as Map<String, dynamic>;

T _page<T>(BackgroundShopAnswer<T>? answer) => (answer! as BackgroundShopLoaded<T>).page;

Map<String, dynamic> _exchangeWithEvent() {
  final json = _fixture('bg_exchange_v77');
  ((json['campaigns'] as List).first as Map<String, dynamic>)
    ..['medals'] = [
      {'id': 717, 'name': '勋章甲', 'image': 'https://forum.test/static/image/common/m1.gif', 'owned': 1},
      {'id': 718, 'name': '勋章乙', 'image': 'https://forum.test/static/image/common/m2.gif', 'owned': 1},
    ]
    ..['owned_medals'] = 2
    ..['eligible'] = 1
    ..['backgrounds'] = [
      {'id': 96, 'name': '活动背景', 'image': 'https://forum.test/source/plugin/background/background/a.jpg', 'owned': 0},
      {'id': 97, 'name': '已有背景', 'image': '', 'owned': 1},
    ];
  return json;
}

void main() {
  group('bg_mine', () {
    test('both positions, their style and the display form of each', () {
      final mine = _page(BackgroundMine.fromJson(_fixture('bg_mine_v74')));
      expect(mine.uid, 31);
      final content = mine.content!;
      expect(content.imageUrl, 'https://forum.test/source/plugin/background/background/1209-1.jpg');
      expect(content.display, isTrue);
      expect(content.permanent, isFalse);
      expect(content.expiration, greaterThan(0));
      expect(content.form!.url, '$baseUrl/plugin.php?id=background:memcp&ac=my&p=0');
      expect(content.form!.fields, {'formhash': 'f1f2f3f4', 'bgconeditsubmit': 'true'});
      expect(mine.sidebar!.form!.fields, {'formhash': 'f1f2f3f4', 'bgmemeditsubmit': 'true'});
      expect(mine.choices[BackgroundStyleFields.display]!.map((c) => c.value), ['1', '0']);
      expect(mine.choices[BackgroundStyleFields.alignX]!.length, 3);
      expect(mine.choices[BackgroundStyleFields.stretch]!.single.value, '1');
    });

    test('the four fields are sent every time, the stretch only when checked', () {
      final form = _page(BackgroundMine.fromJson(_fixture('bg_mine_v74'))).content!.form!;
      expect(form.body(const {'dipbg': '0'}), {
        'formhash': 'f1f2f3f4',
        'bgconeditsubmit': 'true',
        'dipbg': '0',
        // The rest as the website's form starts with them.
        'background_repeat': form.values['background_repeat'],
        'background_positionh': form.values['background_positionh'],
        'background_positionv': form.values['background_positionv'],
      });
      final stretched = form.body(const {
        'dipbg': '1',
        'background_repeat': '0',
        'background_positionh': '2',
        'background_positionv': '0',
        'background_size': '1',
      });
      expect(stretched['background_size'], '1');
      expect(form.body(const {'background_size': ''}).containsKey('background_size'), isFalse);
    });

    test('nothing in use: both null', () {
      final json = _fixture('bg_mine_v74')..['backgrounds'] = {'content': null, 'sidebar': null};
      final mine = _page(BackgroundMine.fromJson(json));
      expect(mine.content, isNull);
      expect(mine.sidebar, isNull);
    });

    test('a display form posting elsewhere, or with other fields, is not used', () {
      for (final url in [
        'https://evil.test/plugin.php?id=background:memcp&ac=my&p=0',
        'plugin.php?id=background:memcp&ac=buybg&p=0',
        'plugin.php?id=tsdmapp:api&ac=my',
        'plugin.php?id=background:memcp&ac=my&p=0&uid=1',
        'forum.php?id=background:memcp&ac=my',
        '//evil.test/plugin.php?id=background:memcp&ac=my',
        'mailto:x',
        'javascript:alert(1)',
        'https://user@www.tsdm39.com/plugin.php?id=background:memcp&ac=my&p=0',
      ]) {
        final json = _fixture('bg_mine_v74');
        (((json['backgrounds'] as Map)['content'] as Map)['form'] as Map)['url'] = url;
        expect(_page(BackgroundMine.fromJson(json)).content!.form, isNull, reason: url);
      }
      final json = _fixture('bg_mine_v74');
      (((json['backgrounds'] as Map)['content'] as Map)['form'] as Map)['fields'] = {'a b': '1'};
      expect(_page(BackgroundMine.fromJson(json)).content!.form, isNull);
    });
  });

  group('bg_store', () {
    test('the shop: credits, balances, offers, owned, the purchase form', () {
      final store = _page(BackgroundStore.fromJson(_fixture('bg_store_v75')));
      expect(store.mode, BackgroundStoreMode.shop);
      expect(store.specialOn, isTrue);
      expect(store.specialTitle, '活动商店');
      expect(store.paging, (page: 1, pages: 2, total: 31));
      expect(store.balanceOf(2), 134);
      expect(store.balanceOf(99), isNull);
      final first = store.items.first;
      expect(first.name, '樱花小道');
      expect(first.offers.map((o) => o.plan), ['c2', 'c6', 'c1']);
      expect(first.offers.first.kind, BackgroundPlanKind.month);
      expect(first.offers.first.cost(3), 30);
      expect(first.buyable, isTrue);
      final buy = store.buy!;
      expect(
        Uri.parse(buy.target(first, BackgroundPosition.sidebar)).queryParameters,
        {'id': 'background:memcp', 'ac': 'buybg', 'bgid': '1', 'p': '1'},
      );
      expect(buy.body(first.offers[1], 4), {'formhash': 'f1f2f3f4', 'buysubmit': 'true', 'plan': 'c6', 'buynum': '4'});
    });

    test('the event shop: a year or for good, one plan each, owned for good is not for sale', () {
      final store = _page(BackgroundStore.fromJson(_fixture('bg_store_v75_special')));
      expect(store.mode, BackgroundStoreMode.special);
      final item = store.items.single;
      expect(item.special, isTrue);
      expect(item.offers.map((o) => (o.plan, o.kind, o.maxMonths)), [
        ('sy', BackgroundPlanKind.year, 1),
        ('sf', BackgroundPlanKind.forever, 1),
      ]);
      expect(item.offers.last.cost(12), 100, reason: 'one plan whatever the months');
      expect(store.buy!.body(item.offers.last, 12)['buynum'], '1');
      // Bought for good on the test forum.
      expect(item.ownedForever, isTrue);
      expect(item.buyable, isFalse);

      final json = _fixture('bg_store_v75_special');
      ((json['backgrounds'] as List).single as Map)['owned'] = null;
      final free = _page(BackgroundStore.fromJson(json)).items.single;
      expect(free.ownedForever, isFalse);
      expect(free.ownedUntil, isNull);
      expect(free.buyable, isTrue);
    });

    test('the months are held to what the plugin takes', () {
      final json = _fixture('bg_store_v75');
      final offer = (((json['backgrounds'] as List).first as Map)['offers'] as List).first as Map;
      offer['price'] = 1000000;
      final parsed = _page(BackgroundStore.fromJson(json)).items.first.offers.first;
      expect(parsed.maxMonths, BackgroundOffer.maxCost ~/ 1000000);
    });

    test('a non-sale background has no way to buy it', () {
      final json = _fixture('bg_store_v75');
      ((json['backgrounds'] as List).first as Map)
        ..['nonsale'] = 1
        ..['offers'] = <Object>[];
      expect(_page(BackgroundStore.fromJson(json)).items.first.buyable, isFalse);
    });

    test('a purchase form posting elsewhere is not used', () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (b) => b['url'] = 'https://evil.test/plugin.php?id=background:memcp&ac=buybg',
        (b) => b['url'] = 'plugin.php?id=background:memcp&ac=slot',
        (b) => b['query'] = {'bgid': 'id', 'position': 'p'},
        (b) => b['query'] = {'bgid': 'bgid', 'position': 'bgid'},
        (b) => b['plan_field'] = 'plan[]',
        (b) => b['months_field'] = b['plan_field'],
        (b) => b['url'] = 'data:text/plain,x',
        (b) => b['method'] = 'GET',
      ]) {
        final json = _fixture('bg_store_v75');
        change(json['buy'] as Map<String, dynamic>);
        expect(_page(BackgroundStore.fromJson(json)).buy, isNull);
      }
    });

    test('the event shop closed, the plugin off or too old: not available', () {
      expect(
        BackgroundStore.fromJson(const {
          'ok': 0,
          'error': 'message',
          'message': '活动商店未开放',
          'message_key': 'bgshop_special_closed',
          'login': 0,
          'uid': 31,
        }),
        isA<BackgroundShopUnavailable<BackgroundStore>>(),
      );
      expect(
        BackgroundStore.fromJson(const {'ok': 1, 'api': 1, 'uid': 31, 'installed': 0}),
        isA<BackgroundShopUnavailable<BackgroundStore>>(),
      );
      expect(
        BackgroundStore.fromJson(const {
          'ok': 1,
          'uid': 31,
          'installed': 1,
          'type': 'bg_store',
          'schema': 75,
          'supported': 0,
        }),
        isA<BackgroundShopUnavailable<BackgroundStore>>(),
      );
      // Not an answer of this action at all.
      expect(BackgroundStore.fromJson(const {'ok': 1, 'installed': 1, 'type': 'bg_slot', 'schema': 76}), isNull);
      expect(BackgroundStore.fromJson(null), isNull);
    });
  });

  group('bg_slot', () {
    test('the slots, which is in use where, and the GET putting one in use', () {
      final slots = _page(BackgroundSlots.fromJson(_fixture('bg_slot_v76')));
      expect(slots.slots.map((s) => (s.sid, s.bgid, s.inContent, s.inSidebar)), [
        // The same background in both places (put in use for the sidebar too on the test forum).
        (143, 2, false, false),
        (142, 1, true, true),
      ]);
      final url = Uri.parse(slots.set!.target(slots.slots.last, BackgroundPosition.sidebar, 1));
      expect(url.origin, Uri.parse(baseUrl).origin);
      expect(url.queryParameters, {
        'id': 'background:memcp',
        'ac': 'slot',
        'changesid': '142',
        'bgside': '1',
        'page': '1',
        'formhash': 'f1f2f3f4',
      });
    });

    test('a set form going elsewhere or as a POST is not used', () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (s) => s['url'] = 'https://evil.test/plugin.php?id=background:memcp&ac=slot',
        (s) => s['url'] = 'plugin.php?id=background:sp',
        (s) => s['method'] = 'POST',
        (s) => s['sid_field'] = 'formhash',
        (s) => s['fields'] = {'formhash': 'a&b=c'},
      ]) {
        final json = _fixture('bg_slot_v76');
        change(json['set'] as Map<String, dynamic>);
        expect(_page(BackgroundSlots.fromJson(json)).set, isNull);
      }
    });
  });

  group('bg_exchange', () {
    test("the events, the medals they count, what the member has, and the exchange's GET", () {
      final exchange = _page(BackgroundExchange.fromJson(_exchangeWithEvent()));
      expect(exchange.campaigns.length, 3);
      final event = exchange.campaigns.first;
      expect(event.id, 'get20210501_1');
      expect((event.minMedals, event.ownedMedals, event.eligible, event.exchanged), (2, 2, true, false));
      expect(event.days, 365);
      expect(event.medals.map((m) => m.owned), [true, true]);
      expect(event.backgrounds.map((b) => (b.id, b.owned, b.imageUrl == null)), [(96, false, false), (97, true, true)]);
      expect(Uri.parse(exchange.form!.target(event, 96)).queryParameters, {
        'id': 'background:sp',
        'action': 'get20210501_1',
        'getbgid': '96',
        'formhash': 'f1f2f3f4',
      });
      // The test forum's own events list nothing to choose.
      expect(exchange.campaigns.skip(1).every((c) => c.backgrounds.isEmpty), isTrue);
    });

    test('switched off, or the exchange part too old: not available', () {
      expect(
        BackgroundExchange.fromJson({..._fixture('bg_exchange_v77'), 'enabled': 0, 'campaigns': <Object>[]}),
        isA<BackgroundShopUnavailable<BackgroundExchange>>(),
      );
      expect(
        BackgroundExchange.fromJson({..._fixture('bg_exchange_v77'), 'supported': 0}),
        isA<BackgroundShopUnavailable<BackgroundExchange>>(),
      );
    });

    test('an exchange form going elsewhere is not used', () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (f) => f['url'] = 'plugin.php?id=background:memcp&ac=slot',
        (f) => f['url'] = 'https://evil.test/plugin.php?id=background:sp',
        (f) => f['bg_field'] = 'id',
        (f) => f['method'] = 'POST',
      ]) {
        final json = _exchangeWithEvent();
        change(json['form'] as Map<String, dynamic>);
        expect(_page(BackgroundExchange.fromJson(json)).form, isNull);
      }
    });
  });
}
