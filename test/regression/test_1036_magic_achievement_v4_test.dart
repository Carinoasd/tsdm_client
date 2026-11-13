/// The magic center and the achievements read from the forum's app API (plugin 4.0.0, `tsdmv=4`): the shop
/// (`magic_shop`, schema 69), the account's magics (`magic_mybox`, 70), the buy and use windows as small forms
/// (`magicbuy`, `magicuse`, schema 17) and the achievements (`achievement`, 68).
///
/// * Asked with `tsdmv=4` only once `status` listed them (`magic_pages`, `forms`, `achievement: 1`); otherwise the web
///   pages and windows are read as before.
/// * The same data read either way gives the same items and the same form (the recorded answers and pages).
/// * A form of 4.0.0 is posted back with `tsdmv=4`, its fields as they came; a buy is done only with
///   `magics_buy_succeed`; a use window whose inputs are not the plugin's `controls` is left to the website.
///
/// Fixtures: the pages and windows of the test forum (cleaned); the write results are the plugin's shape (spec 7.9),
/// not sent to the test forum (they write).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/achievements/cubit/achievements_cubit.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/parsing.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// A repository answering [v4] to the requests with `tsdmv=4`, [page] to the web pages and [window] to the windows;
/// the requests in [asked], the posts in [posted].
final class _Harness {
  _Harness({this.v4, this.page = '', this.window, this.result});

  final Object? Function(String url)? v4;
  final String page;
  final Object? window;
  final Object? result;
  final asked = <String>[];
  final posted = <(String, Map<String, String>, bool)>[];

  late final repository = MagicRepository(
    getPage: (url) async {
      asked.add(url);
      return page;
    },
    getWindow: (url) async {
      asked.add(url);
      return window;
    },
    postForm: (url, body) async {
      posted.add((url, body, false));
      return result;
    },
    getV4: (url) async {
      asked.add(url);
      return v4?.call(url);
    },
    postV4: (url, body) async {
      posted.add((url, body, true));
      return result;
    },
  );
}

Map<String, dynamic> _result(String key, {String message = '', int ok = 1, String kind = 'handle'}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': _uid,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': kind,
  'message': message,
  'message_key': key,
  'url': '',
  'handlekey': 'magics',
  'values': <String, Object>{},
  'login': 0,
  'alert': ok == 1 ? 'right' : 'error',
};

List<Object?> _items(MagicListPage page) => [
  for (final i in page.items)
    (
      i.identifier,
      i.name,
      i.description,
      Uri.tryParse(i.imageUrl ?? '')?.path,
      i.price,
      i.priceText,
      i.buyable,
      i.magicId,
      i.count,
      i.weight,
    ),
];

List<Object?> _fields(MagicForm form) => [
  for (final f in form.fields) (f.name, f.label, f.role, f.value, f.options.length),
];

void main() {
  setUpAll(() async {
    registerV4TestServices();
    // The forum's own words are Chinese: the app's words for them are compared in the same language.
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group("shop (69) and the account's magics (70)", () {
    test('the answer and the web page of the shop give the same magics, capacity and balance', () async {
      knowV4Status();
      final h = _Harness(v4: (_) => v4Json('magic_shop_v69.json'));
      final fromApi = await h.repository.fetchList(magicShopUrl, MagicList.shop, _uid);
      expect(h.asked.single, contains('tsdmv=4'));
      final fromWeb = parseMagicList(parseHtmlDocument(v4Raw('magic_shop_web.html')), MagicList.shop);
      expect(fromApi.items, hasLength(7));
      expect(_items(fromApi), _items(fromWeb));
      expect(fromApi.capacity, fromWeb.capacity);
      expect(fromApi.balance, fromWeb.balance);
      expect(fromApi.nextUrl, fromWeb.nextUrl);
      expect(fromApi.items.first.buyable, isFalse, reason: 'sold out');
    });

    test("the account's magics: the same as the web page", () async {
      knowV4Status();
      final h = _Harness(v4: (_) => v4Json('magic_mybox_v70.json'));
      final fromApi = await h.repository.fetchList(magicBoxUrl, MagicList.box, 35);
      final fromWeb = parseMagicList(parseHtmlDocument(v4Raw('magic_mybox_web.html')), MagicList.box);
      expect(fromApi.items, hasLength(5));
      expect(_items(fromApi), _items(fromWeb));
      expect(fromApi.capacity, fromWeb.capacity);
    });

    test('pages: the next and previous ones safe for a GET', () {
      final json = v4Json('magic_shop_v69.json')
        ..['page'] = 2
        ..['pages'] = 3;
      final page = magicListPageFromApi(json, MagicList.shop, magicShopUrl);
      expect(page.nextUrl, '$magicShopUrl&page=3');
      expect(page.previousUrl, magicShopUrl);
    });

    test("another account refused; the forum's message is its words; not listed: the web page", () async {
      knowV4Status();
      await expectLater(
        _Harness(v4: (_) => v4Json('magic_shop_v69.json')).repository.fetchList(magicShopUrl, MagicList.shop, 32),
        throwsA(isA<MagicIdentityException>()),
      );
      await expectLater(
        _Harness(
          v4: (_) => const {
            'ok': 0,
            'error': 'message',
            'message': '您所在的用户组没有使用道具的权限',
            'message_key': 'magics_nopermission',
            'login': 0,
            'uid': _uid,
          },
        ).repository.fetchList(magicShopUrl, MagicList.shop, _uid),
        throwsA(isA<MagicForumMessage>().having((e) => e.message, 'message', '您所在的用户组没有使用道具的权限')),
      );
      knowV4Status(v4Status({'magic_pages': <String>[]}));
      final off = _Harness(page: v4Raw('magic_shop_web.html'));
      expect((await off.repository.fetchList(magicShopUrl, MagicList.shop, _uid)).items, hasLength(7));
      expect(off.asked.single, isNot(contains('tsdmv')));
    });
  });

  group('buy (magicbuy) and use (magicuse) windows', () {
    test("the buy form of the answer is the window's", () async {
      knowV4Status();
      final h = _Harness(v4: (_) => v4Json('magic_buy_v17.json'));
      final fromApi = await h.repository.buyWindow('prankmagic:pkname');
      final asked = Uri.parse(h.asked.single).queryParameters;
      expect(asked, containsPair('tsdmv', '4'));
      expect(asked, containsPair('tsdmform', '1'));
      expect(asked, containsPair('inajax', '1'));
      final fromWindow = parseMagicForm(magicWindowHtml(v4Json('magic_buy_window.json')));
      expect(fromApi.api, isTrue);
      expect(fromApi.action, fromWindow.action);
      expect(fromApi.hidden, fromWindow.hidden);
      expect(_fields(fromApi), _fields(fromWindow));
      expect(fromApi.title, fromWindow.title);
      expect(fromApi.notes, fromWindow.notes);
      expect(fromApi.facts, fromWindow.facts);
      expect(
        (fromApi.unitPrice, fromApi.balance, fromApi.freeWeight, fromApi.unitWeight, fromApi.stock, fromApi.maxCount),
        (
          fromWindow.unitPrice,
          fromWindow.balance,
          fromWindow.freeWeight,
          fromWindow.unitWeight,
          fromWindow.stock,
          fromWindow.maxCount,
        ),
      );
    });

    test("the use form of the answer is the window's", () async {
      knowV4Status();
      final h = _Harness(v4: (_) => v4Json('magic_use_v17.json'));
      final fromApi = await h.repository.useWindow(34);
      final fromWindow = parseMagicForm(magicWindowHtml(v4Json('magic_use_window.json')));
      expect(fromApi.api, isTrue);
      expect(fromApi.action, fromWindow.action);
      expect(fromApi.hidden, fromWindow.hidden);
      expect(_fields(fromApi), _fields(fromWindow));
      expect(fromApi.notes, fromWindow.notes);
      expect(fromApi.fields.single.role, MagicFieldRole.user);
    });

    test("inputs that are not the plugin's controls, or none read: left to the website", () {
      final extra = v4Json('magic_use_v17.json')
        ..['controls'] = [
          {'name': 'username', 'type': 'text', 'value': ''},
          {'name': 'tid', 'type': 'text', 'value': ''},
        ];
      expect(() => magicFormFromApi(extra, SmallFormKind.magicuse), throwsA(isA<MagicFormUnsupported>()));
      final none = v4Json('magic_use_v17.json')
        ..['controls'] = null
        ..['unsupported'] = ['controls'];
      expect(() => magicFormFromApi(none, SmallFormKind.magicuse), throwsA(isA<MagicFormUnsupported>()));
      final script = v4Json('magic_use_v17.json')..['show_html'] = '<input name="username" onclick="x()" />';
      expect(() => magicFormFromApi(script, SmallFormKind.magicuse), throwsA(isA<MagicFormUnsupported>()));
      final away = v4Json('magic_use_v17.json');
      (away['submit'] as Map<String, dynamic>)['url'] = 'https://elsewhere.test/home.php?mod=magic&action=mybox';
      expect(() => magicFormFromApi(away, SmallFormKind.magicuse), throwsA(isA<FormatException>()));
    });

    test("the forum's message instead of the window is its words", () {
      expect(
        () => magicFormFromApi(v4Json('magic_use_v17_none.json'), SmallFormKind.magicuse),
        throwsA(isA<MagicForumMessage>().having((e) => e.message, 'message', '抱歉，您选择的道具不存在，请到道具商店购买')),
      );
    });

    test('not in forms: the window as before', () async {
      knowV4Status(v4Status({'forms': <String>[]}));
      final h = _Harness(window: v4Json('magic_buy_window.json'));
      final form = await h.repository.buyWindow('prankmagic:pkname');
      expect(form.api, isFalse);
      expect(h.asked.single, isNot(contains('tsdmv')));
    });

    test('a form of 4.0.0 is posted with tsdmv once; a buy is done only with magics_buy_succeed', () async {
      knowV4Status();
      final form = magicFormFromApi(v4Json('magic_buy_v17.json'), SmallFormKind.magicbuy)!;
      final h = _Harness(result: _result('magics_buy_succeed', message: '购买成功'));
      final done = await h.repository.submit(form, {'magicnum': '2'});
      expect(done.kind, MagicResultKind.succeeded);
      final (url, body, v4) = h.posted.single;
      expect(v4, isTrue);
      expect(url, form.action);
      expect(body, containsPair('magicnum', '2'));
      expect(body, containsPair('mid', 'prankmagic:pkname'));
      expect(body, containsPair('handlekey', 'magics'));
      expect(
        magicV4ResultOf(_result('magics_credits_no_enough', message: '积分不足', ok: 0), buy: true).kind,
        MagicResultKind.rejected,
      );
      expect(
        magicV4ResultOf(_result('', message: '完成'), buy: true).kind,
        MagicResultKind.rejected,
        reason: 'ok without the success key',
      );
      expect(magicV4ResultOf(_result('', kind: 'page'), buy: true).kind, MagicResultKind.unknown);
      // A use: the cards answer their own words without a key, judged as before.
      expect(magicV4ResultOf(_result('', message: '施法成功'), buy: false).kind, MagicResultKind.succeeded);
    });
  });

  group('achievements (68)', () {
    Future<AchievementsState> load({required Object? api, String page = '', int uid = _uid}) async {
      var webAsked = 0;
      final cubit = AchievementsCubit(
        currentUid: () => uid,
        fetchPage: () async {
          webAsked++;
          return page;
        },
        fetchApi: () async => api,
      );
      await cubit.load();
      final state = cubit.state;
      await cubit.close();
      if (api == null) expect(webAsked, 1);
      return state;
    }

    test("the list of the answer as the page's text; none is the empty list", () async {
      knowV4Status();
      final empty = await load(api: v4Json('achievement_v68_empty.json'));
      expect(empty.data!.recognized, isTrue);
      expect(empty.data!.empty, isTrue);
      final listed = v4Json('achievement_v68_empty.json')
        ..['list'] = [
          {
            'id': 1,
            'name': '初来乍到',
            'description': '发第一帖',
            'icon': '',
            'rank': '1',
            'reward': {'value': '5', 'unit': '天使币'},
            'progress': 1,
            'requirements': 3,
            'percent': 34,
          },
        ];
      final data = (await load(api: listed)).data!;
      expect(data.empty, isFalse);
      expect(data.content, '初来乍到\n发第一帖\n1 / 3 (34%)\n5 天使币');
    });

    test('a guest is the login; another account fails; achievement off: the web page', () async {
      knowV4Status();
      final guest = await load(
        api: const {
          'ok': 0,
          'error': 'message',
          'message': '请先登录',
          'message_key': 'not_loggedin',
          'login': 1,
          'uid': 0,
        },
      );
      expect(guest.needLogin, isTrue);
      expect((await load(api: v4Json('achievement_v68_empty.json'), uid: 32)).failed, isTrue);
      knowV4Status(v4Status({'achievement': 0}));
      var webAsked = 0;
      var apiAsked = 0;
      final cubit = AchievementsCubit(
        currentUid: () => _uid,
        fetchPage: () async {
          webAsked++;
          return '';
        },
        fetchApi: () async {
          apiAsked++;
          return null;
        },
      );
      await cubit.load();
      await cubit.close();
      expect((webAsked, apiAsked), (1, 0));
    });
  });
}
