/// The background plugin's forms sent from the app (plugin 4.1.0, `tsdmapp=json&tsdmv=4`): what each answer means and
/// what the repository sends.
///
/// * Done only with the success key of that form (`bgshop_style_saved`, `bgshop_bought`, `bgshop_slot_set`,
///   `bgshop_exchanged`); `ok 1` with any other key is not done, a known failure keeps the forum's words.
/// * Not known (`bgshop_unknown`, the forum's HTTP 503 page of a stale form hash, the "插件不存在或已关闭" page, a timeout):
///   never taken as done nor as refused, never sent again; only an answer that is not JSON has `status` asked again.
/// * Each write is sent once, to the url and with the body the answer described; nothing is sent once the account
///   changed, and an answer served to another account is dropped.
/// * Reading goes through `bgmine`, `bgstore` (`mode`, `kw`, `page`), `bgslot`, `bgexchange`; a guest is asked to log in.
///
/// The write results are the test forum's (scrubbed), `bgshop_unknown` as the spec gives it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';
import 'package:tsdm_client/features/background_shop/repository/background_shop_repository.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp/bgshop/$name.json').readAsStringSync()) as Map<String, dynamic>;

T _page<T>(BackgroundShopAnswer<T>? answer) => (answer! as BackgroundShopLoaded<T>).page;

/// A write result of the test forum, as the plugin answered it.
Map<String, dynamic> _result(String key, String message, {int ok = 0, int uid = 31, int login = 0}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': uid,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'message',
  'message': message,
  'message_key': key,
  'url': '',
  'handlekey': '',
  'values': const <String, Object>{},
  'login': login,
  'alert': ok == 1 ? 'info' : 'error',
};

const _staleFormHash =
    '<!DOCTYPE html><html><head><title>System Error</title></head><body><div class="info">'
    ' Discuz! System Error</div></body></html>';

const _pluginOff =
    '<!DOCTYPE html><html><head><title>提示信息</title></head><body><div id="messagetext" class="alert_error"> '
    '<p>插件不存在或已关闭</p></div></body></html>';

void main() {
  group('the answer to a write', () {
    test('done only with the success key of that form', () {
      for (final (write, key, message) in [
        (BackgroundShopWrite.style, 'bgshop_style_saved', '设置成功'),
        (BackgroundShopWrite.buy, 'bgshop_bought', '购买成功'),
        (BackgroundShopWrite.slot, 'bgshop_slot_set', '更新完成'),
        (BackgroundShopWrite.exchange, 'bgshop_exchanged', 'succ_exchange_done'),
      ]) {
        expect(
          backgroundShopOutcomeOf(_result(key, message, ok: 1), write, uid: 31),
          isA<BackgroundShopDone>(),
          reason: key,
        );
        // Another form's success is not this one's.
        for (final other in BackgroundShopWrite.values.where((w) => w != write)) {
          expect(
            backgroundShopOutcomeOf(_result(key, message, ok: 1), other, uid: 31),
            isA<BackgroundShopRefused>(),
            reason: '$key for ${other.name}',
          );
        }
      }
    });

    test('ok 1 with a key that is not the success is not done', () {
      final outcome = backgroundShopOutcomeOf(_result('', '请选择支付方式', ok: 1), BackgroundShopWrite.buy, uid: 31);
      expect(outcome, isA<BackgroundShopRefused>());
      expect((outcome! as BackgroundShopRefused).message, '请选择支付方式');
    });

    test("a known failure keeps the key and the forum's words", () {
      for (final (key, message) in [
        ('bgshop_credit_insufficient', '您的精灵不足'),
        ('bgshop_plan_required', '请选择支付方式'),
        ('bgshop_owned_forever', '该背景已永久拥有，无需重复购买'),
        ('bgshop_nonsale', '此背景为非卖品，无法购买'),
        ('bgshop_months_invalid', '购买月数或金额超出允许范围'),
        ('bgshop_slot_invalid', '参数错误~'),
        ('bgshop_bg_illegal', 'err_getbgid_illegal'),
        ('bgshop_exchange_closed', 'err_undefined_action_or_empty'),
        ('submit_invalid', '抱歉，您的请求来路不正确或表单验证串不符，无法提交'),
      ]) {
        final outcome = backgroundShopOutcomeOf(_result(key, message), BackgroundShopWrite.buy, uid: 31);
        expect(outcome, isA<BackgroundShopRefused>(), reason: key);
        final refused = outcome! as BackgroundShopRefused;
        expect((refused.key, refused.message), (key, message));
      }
    });

    test('the login asked for is a refusal with login', () {
      final outcome = backgroundShopOutcomeOf(
        _result('not_loggedin', '请先登录', uid: 0, login: 1),
        BackgroundShopWrite.style,
        uid: 31,
      );
      expect((outcome! as BackgroundShopRefused).login, isTrue);
    });

    test('bgshop_unknown, a page, nothing: not known, never done nor refused', () {
      final unknown = backgroundShopOutcomeOf(_result('bgshop_unknown', '奇怪的提示'), BackgroundShopWrite.buy, uid: 31);
      expect(unknown, isA<BackgroundShopUnknown>());
      expect((unknown! as BackgroundShopUnknown).answered, isTrue);
      for (final data in [_staleFormHash, _pluginOff, null, '', '{"ok":1}']) {
        final outcome = backgroundShopOutcomeOf(data, BackgroundShopWrite.exchange, uid: 31);
        expect(outcome, isA<BackgroundShopUnknown>(), reason: '$data');
        expect((outcome! as BackgroundShopUnknown).answered, isFalse);
      }
    });

    test('an answer served to another account is dropped', () {
      expect(
        backgroundShopOutcomeOf(_result('bgshop_bought', '购买成功', ok: 1, uid: 32), BackgroundShopWrite.buy, uid: 31),
        isNull,
      );
    });
  });

  group('the repository', () {
    late List<(String, Map<String, String>)> asked;
    late List<(String, Map<String, String>)> posted;
    late List<String> got;
    late int unknowns;
    late int uid;
    late Object? Function() reply;
    late Map<String, dynamic>? Function(String action) answer;

    BackgroundShopRepository repo() => BackgroundShopRepository(
      ask: (action, query) async {
        asked.add((action, query));
        return answer(action);
      },
      post: (url, data) async {
        posted.add((url, data));
        return reply();
      },
      get: (url) async {
        got.add(url);
        return reply();
      },
      onUnknown: () => unknowns++,
      currentUid: () => uid,
    );

    setUp(() {
      asked = [];
      posted = [];
      got = [];
      unknowns = 0;
      uid = 31;
      reply = () => _result('', '');
      answer = (action) => switch (action) {
        'bgmine' => _fixture('bg_mine_v74'),
        'bgstore' => _fixture('bg_store_v75'),
        'bgslot' => _fixture('bg_slot_v76'),
        'bgexchange' => _fixture('bg_exchange_v77'),
        _ => null,
      };
    });

    test('each page is read from its action, the shop with its mode, keyword and page', () async {
      final r = repo();
      await r.mine();
      await r.store();
      await r.store(mode: BackgroundStoreMode.special, keyword: '樱花', page: 2);
      await r.slots(page: 3);
      await r.exchange();
      expect(asked.map((a) => [a.$1, a.$2]), [
        ['bgmine', <String, String>{}],
        ['bgstore', <String, String>{}],
        [
          'bgstore',
          {'mode': 'special', 'kw': '樱花', 'page': '2'},
        ],
        [
          'bgslot',
          {'page': '3'},
        ],
        ['bgexchange', <String, String>{}],
      ]);
      expect(posted, isEmpty);
      expect(got, isEmpty, reason: 'reading never sends a GET that writes');
    });

    test('a guest is asked to log in; an answer of another account is dropped; no answer fails', () async {
      answer = (_) => const {'ok': 0, 'error': 'login', 'message_key': 'to_login', 'login': 1};
      await expectLater(repo().mine(), throwsA(isA<BackgroundShopLoginRequired>()));
      answer = (_) => {..._fixture('bg_mine_v74'), 'uid': 32};
      await expectLater(repo().mine(), throwsA(isA<IdentityChangedException>()));
      answer = (_) => null;
      await expectLater(repo().slots(), throwsA(isA<FormatException>()));
      uid = 0;
      asked.clear();
      await expectLater(repo().exchange(), throwsA(isA<BackgroundShopLoginRequired>()));
      expect(asked, isEmpty, reason: 'nothing is asked without an account');
    });

    test('the display form: once, every field, to its url', () async {
      final background = _page(BackgroundMine.fromJson(_fixture('bg_mine_v74'))).sidebar!;
      reply = () => _result('bgshop_style_saved', '设置成功', ok: 1);
      final outcome = await repo().saveStyle(31, background.form!, const {
        'dipbg': '0',
        'background_repeat': '0',
        'background_positionh': '2',
        'background_positionv': '0',
      });
      expect(outcome, isA<BackgroundShopDone>());
      expect(posted.map((p) => [p.$1, p.$2]), [
        [
          '$baseUrl/plugin.php?id=background:memcp&ac=my&p=1',
          {
            'formhash': 'f1f2f3f4',
            'bgmemeditsubmit': 'true',
            'dipbg': '0',
            'background_repeat': '0',
            'background_positionh': '2',
            'background_positionv': '0',
          },
        ],
      ]);
    });

    test('a purchase: once, the background and the position in the url, the plan and the months in the body', () async {
      final store = _page(BackgroundStore.fromJson(_fixture('bg_store_v75')));
      final item = store.items.first;
      reply = () => _result('bgshop_bought', '购买成功', ok: 1);
      final outcome = await repo().buy(31, store.buy!, item, BackgroundPosition.content, item.offers.first, 2);
      expect(outcome, isA<BackgroundShopDone>());
      expect(posted.single.$1, '$baseUrl/plugin.php?id=background:memcp&ac=buybg&bgid=1&p=0');
      expect(posted.single.$2, {'formhash': 'f1f2f3f4', 'buysubmit': 'true', 'plan': 'c2', 'buynum': '2'});
      expect(unknowns, 0);
    });

    test('a slot put in use and an exchange: one GET each', () async {
      final slots = _page(BackgroundSlots.fromJson(_fixture('bg_slot_v76')));
      reply = () => _result('bgshop_slot_set', '更新完成', ok: 1);
      expect(
        await repo().useSlot(31, slots.set!, slots.slots.first, BackgroundPosition.content, 1),
        isA<BackgroundShopDone>(),
      );
      final exchange = _page(BackgroundExchange.fromJson(_fixture('bg_exchange_v77')));
      reply = () => _result('bgshop_medals_insufficient', 'err_not_enough_medals');
      expect(
        await repo().exchangeFor(31, exchange.form!, exchange.campaigns.first, 96),
        isA<BackgroundShopRefused>(),
      );
      expect(got.length, 2);
      expect(Uri.parse(got.first).queryParameters['changesid'], '143');
      expect(Uri.parse(got.last).queryParameters['getbgid'], '96');
      expect(posted, isEmpty);
    });

    test('a page instead of a result: not known, sent once, status asked again', () async {
      final store = _page(BackgroundStore.fromJson(_fixture('bg_store_v75')));
      final item = store.items.first;
      for (final page in [_staleFormHash, _pluginOff, null]) {
        posted.clear();
        unknowns = 0;
        reply = () => page;
        final outcome = await repo().buy(31, store.buy!, item, BackgroundPosition.sidebar, item.offers.first, 1);
        expect(outcome, isA<BackgroundShopUnknown>(), reason: '$page');
        expect(posted.length, 1, reason: 'never sent again');
        expect(unknowns, 1);
      }
      // `bgshop_unknown` is an answer of the plugin: `status` is not asked for it.
      posted.clear();
      unknowns = 0;
      reply = () => _result('bgshop_unknown', '');
      expect(
        await repo().buy(31, store.buy!, item, BackgroundPosition.sidebar, item.offers.first, 1),
        isA<BackgroundShopUnknown>(),
      );
      expect((posted.length, unknowns), (1, 0));
    });

    test('nothing is sent once the account changed; an answer of another account is dropped', () async {
      final slots = _page(BackgroundSlots.fromJson(_fixture('bg_slot_v76')));
      uid = 32;
      await expectLater(
        repo().useSlot(31, slots.set!, slots.slots.first, BackgroundPosition.content, 1),
        throwsA(isA<IdentityChangedException>()),
      );
      expect(got, isEmpty);
      uid = 31;
      reply = () => _result('bgshop_slot_set', '更新完成', ok: 1, uid: 32);
      await expectLater(
        repo().useSlot(31, slots.set!, slots.slots.first, BackgroundPosition.content, 1),
        throwsA(isA<IdentityChangedException>()),
      );
      expect(got.length, 1);
    });
  });
}
