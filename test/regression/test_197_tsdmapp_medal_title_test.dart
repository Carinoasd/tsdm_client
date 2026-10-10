/// The medal centre, the title shop and my titles read the forum's app API first (tsdmapp 1.5.0: `medals`,
/// `titleshop`, `titles`).
///
/// The medal centre 3.2 and the title plugin 6.2 lay their pages out as cards; the web parsers only know the tables of
/// the older versions. The API answers the same data plainly and describes the plugins' own forms, so buying, claiming
/// and wearing post exactly what the website posts. Without a usable answer the web page is read as before.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/medal_center/cubit/medal_center_cubit.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

const _uid = 35;

Map<String, dynamic> _shop({int page = 1, int pages = 3, int balance = 500}) => {
  'ok': 1,
  'api': 1,
  'installed': 1,
  'uid': _uid,
  'formhash': 'abcd1234',
  'query': {'filter': 'all', 'sort': 'order', 'q': '', 'page': page, 'pages': pages, 'perpage': 40, 'total': 100},
  'credit': {'id': 2, 'title': '天使币', 'balance': balance},
  'items': [
    {
      'id': 11,
      'name': '可以买',
      'image': 'data/attachment/title/11.png',
      'price': 300,
      'for_sale': 1,
      'owned': 0,
      'afford': 1,
    },
    {
      'id': 12,
      'name': '太贵了',
      'image': 'data/attachment/title/12.png',
      'price': 900,
      'for_sale': 1,
      'owned': 0,
      'afford': 0,
    },
    {'id': 13, 'name': '已经有', 'image': '', 'price': 100, 'for_sale': 1, 'owned': 1, 'afford': 1},
    {'id': 14, 'name': '非卖品', 'image': '', 'price': 0, 'for_sale': 0, 'owned': 0, 'afford': 1},
  ],
  'buy_form': {
    'url': 'plugin.php?id=tsdmtitle:tsdmtitle&action=buy',
    'fields': {
      'formhash': 'abcd1234',
      'buysubmit': 'true',
      'tsdmtitle_return': 'plugin.php?id=tsdmtitle:tsdmtitle&action=shop',
    },
    'item_field': 'buyid',
  },
};

Map<String, dynamic> _titles() => {
  'ok': 1,
  'installed': 1,
  'uid': _uid,
  'formhash': 'abcd1234',
  'query': {'filter': 'all', 'q': '', 'page': 1, 'pages': 1, 'perpage': 200, 'total': 3},
  'titles': [
    {'id': 1, 'name': '戴着的', 'image': '$baseUrl/data/t/1.png', 'expired': 0, 'worn': 1},
    {'id': 2, 'name': '过期了', 'image': '$baseUrl/data/t/2.png', 'expired': 1, 'worn': 0},
    {'id': 3, 'name': '限时的', 'image': '$baseUrl/data/t/3.png', 'expired': 0, 'worn': 0},
  ],
};

Map<String, dynamic> _medals({
  int uid = _uid,
  int page = 1,
  int pages = 2,
  String claimUrl = 'plugin.php?id=dsu_medalCenter:memcp&action=claim',
}) => {
  'ok': 1,
  'installed': 1,
  'uid': uid,
  'query': {
    'typeid': 0,
    'filter': 'all',
    'sort': 'order',
    'q': '',
    'page': page,
    'pages': pages,
    'perpage': 45,
    'total': 60,
  },
  'types': [
    {'typeid': 3, 'name': '活动'},
  ],
  'medals': [
    {
      'id': 101,
      'name': '可以买的章',
      'description': '说明',
      'image': 'static/image/common/medal1.gif',
      'expiration_days': 30,
      'owned': 0,
      'pending': 0,
      'method_text': '购买',
      'price_text': '300 天使币',
      'sign_text': '',
      'conds': [
        {'label': '发帖数', 'text': '至少 10', 'ok': true},
      ],
      'actions': [
        {'method': 5, 'credit': 0, 'label': '购买', 'ok': true, 'why': '', 'confirm': '确定花费 300 天使币 购买「可以买的章」勋章吗？'},
        {'method': 2, 'credit': 0, 'label': '申请审核', 'ok': false, 'why': '您的发帖数不足'},
      ],
    },
    {
      'id': 102,
      'name': '有了的章',
      'description': '',
      'image': '',
      'expiration_days': 0,
      'owned': 1,
      'pending': 0,
      'method_text': '申请',
      'conds': <Object>[],
      'actions': [
        {'method': 1, 'credit': 0, 'label': '申请', 'ok': true, 'why': ''},
      ],
    },
  ],
  'claim_form': {
    'url': claimUrl,
    'fields': {'formhash': 'abcd1234', 'dsumcsubmit': '1'},
    'item_fields': ['medalid', 'method', 'credit'],
  },
};

/// Answers the API with [api] in order (a status and a body each); records the requests.
final class _Forum implements HttpClientAdapter {
  _Forum(this.api);

  final List<(int, Object)> api;
  final requests = <RequestOptions>[];
  var _next = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = api[_next++];
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  setUp(TsdmAppApi.reset);

  group('title shop', () {
    test('owned, for sale and affordable come from the API; the buy form is the plugin’s own', () {
      final shop = titleShopFromApi(_shop(page: 2))!;
      expect(shop.items.map((e) => e.status), [
        TitleShopStatus.purchasable,
        TitleShopStatus.unavailable,
        TitleShopStatus.owned,
        TitleShopStatus.unavailable,
      ]);
      expect(shop.items.map((e) => e.statusText), [null, '天使币不足', '已拥有', '非卖品']);
      final form = shop.items.first.form!;
      expect(form.url, titleBuyUrl);
      expect(form.body(), {
        'formhash': 'abcd1234',
        'tsdmtitle_return': 'plugin.php?id=tsdmtitle:tsdmtitle&action=shop',
        'buyid': '11',
        'buysubmit': 'true',
      });
      expect(form.confirmText, contains('300'));
      expect(shop.items.first.imageUrl, '$baseUrl/data/attachment/title/11.png');
      expect(shop.items[2].imageUrl, isNull);
      expect(shop.balance, '天使币：500');
      expect(shop.page, 2);
      expect(shop.previousUrl, '$titleShopUrl&page=1');
      expect(shop.nextUrl, '$titleShopUrl&page=3');
    });

    test('a return path that leaves the shop gives no buy buttons', () {
      final json = _shop();
      (json['buy_form'] as Map)['fields'] = {'formhash': 'x', 'tsdmtitle_return': 'https://elsewhere.example/'};
      expect(titleShopFromApi(json)!.items.where((e) => e.form != null), isEmpty);
    });

    test('no plugin, no title plugin, an error: the web page is read', () {
      expect(titleShopFromApi(null), isNull);
      expect(titleShopFromApi({'ok': 1, 'installed': 0}), isNull);
      expect(titleShopFromApi({'ok': 0, 'error': 'login'}), isNull);
    });

    test('the repository asks the API with the page and checks the account', () async {
      final asked = <Map<String, String>>[];
      final repo = TitleShopRepository(
        getPage: (_) async => fail('the web page must not be read'),
        postForm: (_, _) async => '',
        askApi: (q) async {
          asked.add(q);
          return _shop();
        },
      );
      final page = await repo.fetchPage('$titleShopUrl&page=2', _uid);
      expect(asked.single, {'page': '2'});
      expect(page.items, hasLength(4));
      await expectLater(repo.fetchPage(titleShopUrl, 36), throwsA(isA<TitleShopIdentityException>()));
    });

    test('a logged-out answer is an expired session', () async {
      final repo = TitleShopRepository(
        getPage: (_) async => fail('the web page must not be read'),
        postForm: (_, _) async => '',
        askApi: (_) async => {'ok': 0, 'error': 'login'},
      );
      await expectLater(
        repo.fetchPage(titleShopUrl, _uid),
        throwsA(isA<TitleShopIdentityException>().having((e) => e.guest, 'guest', isTrue)),
      );
    });
  });

  test('my titles: expired ones are left out, the worn one is marked', () {
    final titles = SecondaryTitle.fromApi(_titles())!;
    expect(titles.map((e) => (e.id, e.activated)), [(1, true), (3, false)]);
    expect(SecondaryTitle.fromApi({'ok': 1, 'installed': 0}), isNull);
  });

  group('medal centre', () {
    test('cards, conditions and claim actions from the API', () {
      final c = medalCatalogFromApi(_medals(), medalCenterUrl)!;
      expect(c.viaApi, isTrue);
      expect(c.categories.map((e) => e.name), ['全部', '活动']);
      expect(c.categories.last.url, '$medalCenterUrl&typeid=3');
      final buy = c.medals.first;
      expect(buy.imageUrl, '$baseUrl/static/image/common/medal1.gif');
      expect(buy.details, ['价格：300 天使币', '有效期：30 天', '发帖数：至少 10 ✓']);
      expect(buy.accountStatus, '您的发帖数不足');
      expect(buy.actions.map((a) => a.type), [MedalActionType.purchase, MedalActionType.manualReview]);
      expect(buy.actions.first.formData, {
        'formhash': 'abcd1234',
        'dsumcsubmit': '1',
        'medalid': '101',
        'method': '5',
        'credit': '0',
      });
      expect(buy.actions.first.url, '$baseUrl/plugin.php?id=dsu_medalCenter:memcp&action=claim');
      expect(buy.actions.first.disabledReason, isNull);
      expect(buy.actions.last.disabledReason, '您的发帖数不足');
      final owned = c.medals.last;
      expect(owned.accountStatus, '已拥有');
      expect(owned.actions, isEmpty);
      expect(c.nextUrl, '$medalCenterUrl&page=2');
      expect(c.previousUrl, isNull);
    });

    test('a claim form posting anywhere else gives no actions', () {
      final c = medalCatalogFromApi(
        _medals(claimUrl: 'https://elsewhere.example/plugin.php?id=dsu_medalCenter:memcp&action=claim'),
        medalCenterUrl,
      )!;
      expect(c.medals.first.actions, isEmpty);
    });

    test('the page of a category or a search keeps it in the page links', () {
      final search = medalSearchUrl('活动 章');
      expect(medalApiQuery(search), {'q': '活动 章'});
      final c = medalCatalogFromApi(_medals(), '$medalCenterUrl&typeid=3')!;
      expect(c.nextUrl, '$medalCenterUrl&typeid=3&page=2');
      expect(medalApiQuery(c.nextUrl!), {'typeid': '3', 'page': '2'});
      final s = medalCatalogFromApi(_medals(), search)!;
      expect(medalApiQuery(s.nextUrl!), {'q': '活动 章', 'page': '2'});
    });

    MedalCenterCubit cubit({
      required List<Map<String, dynamic>?> answers,
      int? uid = _uid,
      List<Map<String, String>>? asked,
      List<(String, Map<String, String>)>? posted,
    }) {
      var i = 0;
      return MedalCenterCubit(
        currentUid: () => uid,
        fetchPage: (_) async => fail('the web page must not be read'),
        fetchApi: (q) async {
          asked?.add(q);
          return answers[i++];
        },
        submitForm: (url, data) async {
          posted?.add((url, data));
          return '<div id="messagetext"><p>申请已提交</p></div>';
        },
      );
    }

    test('loads, searches and claims through the API', () async {
      final asked = <Map<String, String>>[];
      final posted = <(String, Map<String, String>)>[];
      final c = cubit(answers: [_medals(), _medals()], asked: asked, posted: posted);
      await c.load();
      expect(c.state.catalog?.medals, hasLength(2));
      await c.search('活动');
      expect(asked.last, {'q': '活动'});
      expect(c.state.query, '活动');
      final review = c.state.catalog!.medals.first.actions.last;
      final r = await c.performAction(review, reason: '我想要');
      expect(r.success, isTrue);
      expect(posted.single.$2['reason'], '我想要');
      expect(posted.single.$2['method'], '2');
      await c.close();
    });

    test('another account or a logged-out answer is not shown', () async {
      final other = cubit(answers: [_medals(uid: 36)]);
      await other.load();
      expect(other.state.failed, isTrue);
      expect(other.state.catalog, isNull);
      await other.close();
      final out = cubit(answers: [_medals(uid: 0)]);
      await out.load();
      expect(out.state.needLogin, isTrue);
      await out.close();
    });

    test('without a usable answer the web page is read', () async {
      var pages = 0;
      final c = MedalCenterCubit(
        currentUid: () => null,
        fetchApi: (_) async => null,
        fetchPage: (_) async {
          pages++;
          return '<html><body><ul class="mdl"></ul></body></html>';
        },
      );
      await c.load();
      expect(pages, 1);
      expect(c.state.catalog?.viaApi, isFalse);
      await c.close();
    });
  });

  test('askWaiting waits for an answer "too soon" and asks once more', () async {
    final forum = _Forum([
      (429, {'ok': 0, 'error': 'busy', 'retry_after': 1}),
      (200, _titles()),
    ]);
    final client = NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);
    final json = await TsdmAppApi.askWaiting(client, 'titles');
    expect(json?['ok'], 1);
    expect(forum.requests, hasLength(2));
    expect(TsdmAppApi.knownUnavailable, isFalse);
  });
}
