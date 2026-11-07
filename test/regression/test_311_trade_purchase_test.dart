/// Buying a goods of a trade thread in the app.
///
/// The goods page (`forum.php?mod=viewthread&do=tradeinfo`) is read as a web page: the plugin's JSON mode gives only
/// its bread crumbs. A goods sold for the trade credit alone is bought with the forum's two steps of a guaranteed
/// trade: the order (`forum.php?mod=trade&action=trade`, `trade_order_created`: the stock is held, no credit taken)
/// and its payment (`forum.php?mod=trade&orderid=`, `offlinestatus` 4 with the login password,
/// `trade_orderstatus_updated`: the credit is taken). The forum shows the wrong password as a note with a link (`ok`
/// 1, `alert` info) like the done payment: only the language key tells.
///
/// The fixtures in `test/data/trade` are the test forum's answers (Discuz! X5, plugin 3.4.0) cut to their blocks and
/// scrubbed: the goods pages of a virtual goods for credit, a physical one, one for money and credit, a sold out one,
/// as the seller and a guest see it; the order forms; the forum's results of each step.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_thread_card.dart';
import 'package:tsdm_client/features/trade/models/trade_models.dart';
import 'package:tsdm_client/features/trade/repository/trade_repository.dart';
import 'package:tsdm_client/features/trade/view/trade_goods_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/trade';
const _tid = 9202765;

String _html(String name) => File('$_dir/$name.html').readAsStringSync();

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

TradeGoodsDetail _goods(String name) => TradeGoodsDetail.parse(parseHtmlDocument(_html(name)))!;

TradeBuyForm _form(String name) => TradeBuyForm.parse(parseHtmlDocument(_html(name)))!;

/// A goods of the thread page's list.
TradeGoods _listed({required int pid, required String subject, num price = 0, int credit = 0}) => TradeGoods(
  pid: pid,
  removed: false,
  subject: subject,
  sticky: false,
  quality: 1,
  timeout: false,
  remain: null,
  price: price,
  credit: credit,
  costPrice: 0,
  costCredit: 0,
  thumb: null,
  image: null,
  url: tradeGoodsUrl(tid: _tid, pid: pid),
);

const _unit = SpecialCredit(id: 2, title: '天使币', unit: '');

/// No network in the tests: every request fails.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The forum, scripted: the pages by url, the answers to the posts in order; every post recorded.
final class _Forum {
  _Forum({required this.pages, List<Object?> answers = const []}) : _answers = [...answers];

  final Map<String, String> pages;
  final List<Object?> _answers;
  final posts = <(String, Map<String, String>)>[];
  final gets = <String>[];

  TradeRepository get repository => TradeRepository(
    getPage: (url) async {
      gets.add(url);
      return pages[url] ?? (throw const HttpException('no page'));
    },
    postForm: (url, body) async {
      posts.add((url, body));
      return _answers.removeAt(0);
    },
  );
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('A. the goods page', () {
    test('a goods for credit: the details as the page prints them, the seller, the buy button', () {
      final detail = _goods('goods_credit');
      expect(detail.servedUid, 31);
      expect(detail.removed, isFalse);
      expect(detail.subject, '测试徽章');
      expect((detail.sellerUid, detail.sellerName), (33, 'seller_a'));
      expect(detail.sellerAvatar, '$baseUrl/data/avatar/noavatar.svg');
      expect((detail.thumb, detail.image), (null, null));
      // No time limit: the page prints " 小时", left out.
      expect(detail.rows.map((e) => '$e'), ['商品类型: 全新商品', '运费: 虚拟物品', '商品数量: 2', '地点: 线上', '累计售出: 0']);
      expect(detail.stock, 2);
      expect(detail.prices, ['10 天使币']);
      expect(detail.costPrices, ['15 天使币']);
      expect(detail.buyUrl, '$baseUrl/forum.php?mod=trade&tid=$_tid&pid=11179');
      expect(detail.soldOut, isFalse);
      expect(detail.descriptionHtml, contains('柜台说明：测试用积分商品。'));
    });

    test('a physical goods, a goods for money and credit', () {
      final physical = _goods('goods_physical');
      expect(physical.subject, '测试抱枕');
      expect(physical.rows.map((e) => '$e'), contains('运费: 卖家承担运费'));
      expect(physical.prices, ['30 天使币']);
      final cash = _goods('goods_cash');
      expect(cash.prices, ['12.50 元', '附加 5 天使币']);
      expect(cash.rows.map((e) => '$e'), contains('运费: 平邮 8 元 快递 15 元'));
      expect(cash.buyUrl, '$baseUrl/forum.php?mod=trade&tid=$_tid&pid=11182');
    });

    test('sold out: the disabled button, nothing to buy', () {
      final detail = _goods('goods_soldout');
      expect(detail.soldOut, isTrue);
      expect(detail.buyUrl, isNull);
      expect(detail.stock, 0);
    });

    test('the seller and a guest get no buy button', () {
      final seller = _goods('goods_seller');
      expect(seller.servedUid, 33);
      expect((seller.buyUrl, seller.soldOut), (null, false));
      final guest = _goods('goods_guest');
      expect(guest.servedUid, isNull);
      expect((guest.buyUrl, guest.soldOut), (null, false));
    });

    test('a picture: the thumbnail and the zoomed image on the forum host', () {
      final page = _html('goods_credit').replaceFirst(
        '<div class="nophoto" title="测试徽章"></div>',
        '<a href="javascript:;"><img src="data/attachment/forum/a.thumb.jpg" '
            "onclick=\"zoom(this, 'data/attachment/forum/a.jpg')\" width=\"300\" /></a>",
      );
      final detail = TradeGoodsDetail.parse(parseHtmlDocument(page))!;
      expect(detail.thumb, '$baseUrl/data/attachment/forum/a.thumb.jpg');
      expect(detail.image, '$baseUrl/data/attachment/forum/a.jpg');
    });

    test('a deleted goods; the forum message instead of the page', () {
      final removed = TradeGoodsDetail.parse(
        parseHtmlDocument(
          "<html><head><script>var discuz_uid = '31';</script></head><body> "
          '<div class="trdb">此商品已被删除</div></body></html>',
        ),
      )!;
      expect(removed.removed, isTrue);
      expect(removed.buyUrl, isNull);
      final message = parseHtmlDocument(_html('buyform_not_found'));
      expect(TradeGoodsDetail.parse(message), isNull);
      expect(tradeMessageOf(message), '没有找到商品');
    });

    test('the goods of a list url', () {
      expect(tradeGoodsOfUrl(tradeGoodsUrl(tid: 5, pid: 9)), (tid: 5, pid: 9));
      expect(tradeGoodsOfUrl('$baseUrl/forum.php?mod=viewthread&do=tradeinfo&tid=5&pid=9&modthreadkey=k'), (
        tid: 5,
        pid: 9,
      ));
      expect(tradeGoodsOfUrl('$baseUrl/forum.php?mod=viewthread&tid=5'), isNull);
      expect(tradeGoodsOfUrl(null), isNull);
    });
  });

  group('B. the order form', () {
    test('a virtual goods for credit: no receiver fields, the body of the order', () {
      final form = _form('buyform_virtual');
      expect(form.servedUid, 31);
      expect(form.action, '$baseUrl/forum.php?mod=trade&action=trade&tid=$_tid&pid=11179');
      expect(form.formHash, 'f1f2f3f4');
      expect(form.creditOnly, isTrue);
      expect((form.price, form.credit, form.balance), (0, 10, 831));
      expect(form.fields, isEmpty);
      expect(form.messageLabel, '备注信息');
      expect(form.total(3), 30);
      expect(form.orderBody(number: 2, message: '留言'), {
        'formhash': 'f1f2f3f4',
        'number': '2',
        'transport': '3',
        'offline': '1',
        'buyername': '',
        'buyercontact': '',
        'buyerzip': '',
        'buyerphone': '',
        'buyermobile': '',
        'buyermsg': '留言',
        'tradesubmit': 'true',
      });
    });

    test('a physical goods: the receiver fields with the forum labels', () {
      final form = _form('buyform_physical');
      expect(form.creditOnly, isTrue);
      expect(form.credit, 30);
      expect(form.fields.map((e) => (e.name, e.label, e.maxLength)), [
        ('buyername', '收货人姓名', 50),
        ('buyercontact', '收货地址', 100),
        ('buyerzip', '收货人邮编', 10),
        ('buyerphone', '收货人电话', 20),
        ('buyermobile', '收货人手机', 20),
      ]);
      final body = form.orderBody(number: 1, message: '', values: {'buyername': '张三', 'buyermobile': '13800000000'});
      expect(body['transport'], '1');
      expect(body['buyername'], '张三');
      expect(body['buyermobile'], '13800000000');
      expect(body['buyercontact'], '');
    });

    test('a goods for money: not bought in the app', () {
      final form = _form('buyform_cash');
      expect(form.creditOnly, isFalse);
      expect((form.price, form.credit), (12.5, 5));
      // The first checked choice of each.
      expect((form.defaults['fee'], form.defaults['offline'], form.defaults['transport']), ('1', '0', '2'));
    });

    test('the forum message instead of the form', () {
      expect(TradeBuyForm.parse(parseHtmlDocument(_html('buyform_not_found'))), isNull);
      // An order page is not an order form.
      expect(
        TradeBuyForm.parse(
          parseHtmlDocument('<form id="tradepost" action="forum.php?mod=trade&amp;orderid=1"></form>'),
        ),
        isNull,
      );
    });
  });

  group('C. what the forum answered', () {
    test('the order: created with its order, or refused with the forum words', () {
      expect(
        (tradeOrderOutcomeOf(_json('order_created')) as TradeOrderCreated).orderId,
        '20261107220315gMXxWgQjqGIzN3Kl6k',
      );
      for (final (name, words) in [
        ('order_lack', '抱歉，商品剩余数量不足'),
        ('order_by_myself', '抱歉，您无法购买自己的商品'),
        ('order_input_no', '抱歉，请输入正确的商品数'),
      ]) {
        final outcome = tradeOrderOutcomeOf(_json(name));
        expect(outcome, isA<TradeRefused>(), reason: name);
        expect((outcome as TradeRefused).message, words);
      }
      // The answer of another step's key is no order.
      expect(tradeOrderOutcomeOf(_json('pay_done')), isA<TradeRefused>());
      expect(tradeOrderOutcomeOf(_json('pay_replayed')), isA<TradeUnknown>());
    });

    test('the order without the plugin: the message page and its link', () {
      expect(
        (tradeOrderOutcomeOf(_html('order_created_web')) as TradeOrderCreated).orderId,
        '20261107220532MT6tkme6bsBDvOV6xo',
      );
      expect((tradeOrderOutcomeOf(_html('buyform_not_found')) as TradeRefused).message, '没有找到商品');
      expect(tradeOrderOutcomeOf('<html><body>whatever</body></html>'), isA<TradeUnknown>());
      expect(tradeOrderOutcomeOf(null), isA<TradeUnknown>());
    });

    test('the payment: done by its key only; the wrong password (ok 1, info) is refused', () {
      expect(_json('pay_password_error')['ok'], 1);
      expect(_json('pay_password_error')['alert'], 'info');
      expect(tradePayOutcomeOf(_json('pay_done')), isA<TradePaid>());
      expect((tradePayOutcomeOf(_json('pay_password_error')) as TradeRefused).wrongPassword, isTrue);
      expect((tradePayOutcomeOf(_json('pay_credit_lack')) as TradeRefused).wrongPassword, isFalse);
      expect((tradePayOutcomeOf(_json('pay_password_error')) as TradeRefused).message, '抱歉，您输入的密码不正确，不能修改订单状态');
      expect((tradePayOutcomeOf(_json('pay_credit_lack')) as TradeRefused).message, '抱歉，您的积分不足无法购买');
      // Paid already: the forum's error page.
      expect(tradePayOutcomeOf(_json('pay_replayed')), isA<TradeUnknown>());
      expect(tradePayOutcomeOf(_json('order_created')), isA<TradeRefused>());
    });

    test('the payment without the plugin: the note tells nothing, a refusal is one', () {
      expect(tradePayOutcomeOf(_html('order_created_web')), isA<TradeUnknown>());
      expect(tradePayOutcomeOf(_html('buyform_not_found')), isA<TradeRefused>());
    });

    test('the verification, the login', () {
      final seccode = {..._json('order_lack'), 'message': '验证码填写错误', 'message_key': 'submit_seccode_invalid'};
      expect((tradeOrderOutcomeOf(seccode) as TradeRefused).verification, isTrue);
      final login = {..._json('order_lack'), 'message': '', 'message_key': 'not_loggedin', 'login': 1};
      final refused = tradeOrderOutcomeOf(login) as TradeRefused;
      expect((refused.login, refused.message.isNotEmpty), (true, true));
    });

    test('the body of the payment', () {
      expect(tradePayBody(formHash: 'f1f2f3f4', password: 'pw'), {
        'formhash': 'f1f2f3f4',
        'password': 'pw',
        'message': '',
        'offlinestatus': '4',
        'offlinesubmit': 'true',
      });
      expect(tradeOrderUrl('2026ab'), '$baseUrl/forum.php?mod=trade&orderid=2026ab');
    });
  });

  group('D. the repository', () {
    test('each step sent once to its url; a failed request has no verdict', () async {
      final forum = _Forum(
        pages: {
          tradeGoodsUrl(tid: _tid, pid: 11179): _html('goods_credit'),
          '$baseUrl/forum.php?mod=trade&tid=$_tid&pid=11179': _html('buyform_virtual'),
        },
        answers: [_json('order_created'), _json('pay_done')],
      );
      final repository = forum.repository;
      final goods = await repository.fetchGoods(tid: _tid, pid: 11179);
      expect(goods.page!.subject, '测试徽章');
      final form = (await repository.fetchBuyForm(goods.page!.buyUrl!)).page!;
      final placed = await repository.order(form, form.orderBody(number: 1, message: ''));
      expect(placed, isA<TradeOrderCreated>());
      final paid = await repository.pay(
        orderId: (placed as TradeOrderCreated).orderId,
        formHash: form.formHash,
        password: 'pw',
      );
      expect(paid, isA<TradePaid>());
      expect(forum.posts.map((e) => e.$1), [
        '$baseUrl/forum.php?mod=trade&action=trade&tid=$_tid&pid=11179',
        '$baseUrl/forum.php?mod=trade&orderid=20261107220315gMXxWgQjqGIzN3Kl6k',
      ]);
      expect(forum.posts.last.$2['password'], 'pw');
      // The order form is read without `action=trade`: the forum creates the order at once on that url.
      expect(forum.gets.every((e) => !e.contains('action=trade')), isTrue);

      final failing = TradeRepository(
        getPage: (_) async => '',
        postForm: (_, _) async => throw const HttpException('down'),
      );
      expect(await failing.order(form, const {}), isA<TradeUnknown>());
      expect(await failing.pay(orderId: '1', formHash: 'f', password: 'pw'), isA<TradeUnknown>());
      final message = await failing.fetchGoods(tid: 1, pid: 2);
      expect((message.page, message.message), (null, null));
    });
  });

  group('E. the page', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhTw);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      await LocaleSettings.setLocale(AppLocale.en);
    });

    Future<void> pump(
      WidgetTester tester,
      _Forum forum, {
      required int pid,
      TradeGoods? goods,
      bool canBuy = true,
      VoidCallback? onBought,
      int? uid = 31,
    }) async {
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(
            child: MaterialApp(
              scaffoldMessengerKey: snackbarKey,
              home: TradeGoodsPage(
                key: UniqueKey(),
                tid: _tid,
                pid: pid,
                goods: goods,
                creditUnit: _unit,
                canBuy: canBuy,
                onBought: onBought,
                repository: forum.repository,
                currentUid: () => uid,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Map<String, String> pages(String goods, String form, {int pid = 11179}) => {
      tradeGoodsUrl(tid: _tid, pid: pid): _html(goods),
      '$baseUrl/forum.php?mod=trade&tid=$_tid&pid=$pid': _html(form),
    };

    Future<void> enterPassword(WidgetTester tester, String password) async {
      final tr = t.specialThread.trade;
      await tester.enterText(find.widgetWithText(TextField, tr.password), password);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, tr.pay));
      await tester.pumpAndSettle();
    }

    testWidgets('buying: quantity, the confirmation with the balance, the order then its payment', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(
        pages: pages('goods_credit', 'buyform_virtual'),
        answers: [_json('order_created'), _json('pay_done')],
      );
      var bought = 0;
      await pump(
        tester,
        forum,
        pid: 11179,
        goods: _listed(pid: 11179, subject: '测试徽章', credit: 10),
        onBought: () => bought++,
      );
      expect(find.text('测试徽章'), findsWidgets);
      expect(find.text('10 天使币'), findsOneWidget);
      expect(find.text('seller_a'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      // The order dialog: no receiver fields for a virtual goods.
      expect(find.text('收货人姓名'), findsNothing);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();
      // The stock is 2.
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_circle_outline)).onPressed, isNull);
      await tester.enterText(find.widgetWithText(TextField, '备注信息'), '谢谢');
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      // The confirmation: 2 × 10 from 831.
      expect(find.text('测试徽章 × 2'), findsOneWidget);
      expect(find.text(tr.credit(credit: 20, unit: '天使币')), findsOneWidget);
      expect(find.text(tr.credit(credit: 831, unit: '天使币')), findsOneWidget);
      expect(find.text(tr.credit(credit: 811, unit: '天使币')), findsOneWidget);
      expect(forum.posts, isEmpty);
      await enterPassword(tester, 'secret');
      expect(forum.posts, hasLength(2));
      expect(forum.posts.first.$2['number'], '2');
      expect(forum.posts.first.$2['buyermsg'], '谢谢');
      expect(forum.posts.first.$2.containsKey('password'), isFalse);
      expect(forum.posts.last.$2['password'], 'secret');
      expect(bought, 1);
      expect(find.text(tr.bought), findsOneWidget);
    });

    testWidgets('the wrong password: the order is kept, only the payment is sent again', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(
        pages: pages('goods_credit', 'buyform_virtual'),
        answers: [_json('order_created'), _json('pay_password_error'), _json('pay_done')],
      );
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'wrong');
      expect(find.text('抱歉，您输入的密码不正确，不能修改订单状态'), findsOneWidget);
      expect(find.text(tr.notPaid), findsOneWidget);
      await tester.tap(find.text(tr.payAgain));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'right');
      expect(forum.posts.map((e) => e.$1.contains('action=trade')), [true, false, false]);
      expect(forum.posts.last.$2['password'], 'right');
      expect(find.text(tr.bought), findsOneWidget);
    });

    testWidgets('the lack of credit at the payment: no paying again, the order to look at', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(
        pages: pages('goods_credit', 'buyform_virtual'),
        answers: [_json('order_created'), _json('pay_credit_lack')],
      );
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'pw');
      expect(find.text('抱歉，您的积分不足无法购买'), findsOneWidget);
      expect(find.text(tr.openOrder), findsOneWidget);
      expect(find.text(tr.payAgain), findsNothing);
      expect(forum.posts, hasLength(2));
    });

    testWidgets('no balance on the form: not bought in the app (the forum does not check it)', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(
        pages: {
          tradeGoodsUrl(tid: _tid, pid: 11179): _html('goods_credit'),
          '$baseUrl/forum.php?mod=trade&tid=$_tid&pid=11179': _html(
            'buyform_virtual',
          ).replaceFirst('var currentcredit = 831;', ''),
        },
      );
      expect(
        TradeBuyForm.parse(
          parseHtmlDocument(_html('buyform_virtual').replaceFirst('var currentcredit = 831;', '')),
        )!.balance,
        isNull,
      );
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      expect(find.text(tr.next), findsNothing);
      expect(forum.posts, isEmpty);
    });

    testWidgets('the account switched before the payment: the order is placed, not paid, no payment sent', (
      tester,
    ) async {
      final tr = t.specialThread.trade;
      var uid = 31;
      final forum = _Forum(pages: pages('goods_credit', 'buyform_virtual'), answers: [_json('order_created')]);
      final repository = forum.repository;
      final switching = TradeRepository(
        getPage: repository.getPage,
        postForm: (url, body) async {
          final answer = await repository.postForm(url, body);
          // Switched while the order was sent.
          uid = 35;
          return answer;
        },
      );
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(
            child: MaterialApp(
              scaffoldMessengerKey: snackbarKey,
              home: TradeGoodsPage(
                tid: _tid,
                pid: 11179,
                goods: _listed(pid: 11179, subject: '测试徽章', credit: 10),
                creditUnit: _unit,
                canBuy: true,
                repository: switching,
                currentUid: () => uid,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'pw');
      expect(find.text(tr.notPaid), findsOneWidget);
      expect(forum.posts, hasLength(1));
    });

    testWidgets('no verdict on the payment: the order page to look at', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(
        pages: pages('goods_credit', 'buyform_virtual'),
        answers: [_json('order_created'), _json('pay_replayed')],
      );
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'pw');
      expect(find.text(tr.unknown), findsOneWidget);
      expect(find.text(tr.openOrder), findsOneWidget);
      expect(find.text(tr.unknownOrder), findsNothing);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(2));
    });

    testWidgets('refused order: the forum words, no payment', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(pages: pages('goods_credit', 'buyform_virtual'), answers: [_json('order_lack')]);
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'pw');
      expect(find.text('抱歉，商品剩余数量不足'), findsOneWidget);
      expect(forum.posts, hasLength(1));
    });

    testWidgets('no verdict on the order: the orders to look at, the list reloaded, no payment', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(pages: pages('goods_credit', 'buyform_virtual'), answers: [_json('pay_replayed')]);
      var reloaded = 0;
      await pump(
        tester,
        forum,
        pid: 11179,
        goods: _listed(pid: 11179, subject: '测试徽章', credit: 10),
        onBought: () => reloaded++,
      );
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr.next));
      await tester.pumpAndSettle();
      await enterPassword(tester, 'pw');
      expect(find.text(tr.unknownOrder), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(reloaded, 1);
    });

    testWidgets('not enough credit: the order cannot go on', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(
        pages: {
          tradeGoodsUrl(tid: _tid, pid: 11179): _html('goods_credit'),
          '$baseUrl/forum.php?mod=trade&tid=$_tid&pid=11179': _html(
            'buyform_virtual',
          ).replaceFirst('var currentcredit = 831;', 'var currentcredit = 15;'),
        },
      );
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      expect(find.text(tr.insufficient), findsNothing);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();
      expect(find.text(tr.insufficient), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, tr.next)).onPressed, isNull);
    });

    testWidgets('a physical goods asks the receiver fields the forum shows', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(pages: pages('goods_physical', 'buyform_physical', pid: 11181));
      await pump(tester, forum, pid: 11181, goods: _listed(pid: 11181, subject: '测试抱枕', credit: 30));
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      for (final label in ['收货人姓名', '收货地址', '收货人邮编', '收货人电话', '收货人手机']) {
        expect(find.widgetWithText(TextField, label), findsOneWidget, reason: label);
      }
    });

    testWidgets('another account than the one the form was served to: nothing sent', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(pages: pages('goods_credit', 'buyform_virtual'));
      await pump(tester, forum, pid: 11179, goods: _listed(pid: 11179, subject: '测试徽章', credit: 10), uid: 35);
      await tester.tap(find.widgetWithText(FilledButton, tr.buy));
      await tester.pumpAndSettle();
      expect(find.text(tr.next), findsNothing);
      expect(find.text(t.specialThread.accountChanged), findsOneWidget);
      expect(forum.posts, isEmpty);
    });

    testWidgets('what is not bought here: sold out, money, read only, the seller', (tester) async {
      final tr = t.specialThread.trade;
      await pump(tester, _Forum(pages: pages('goods_soldout', 'buyform_virtual', pid: 11183)), pid: 11183);
      final soldOut = tester.widget<FilledButton>(find.widgetWithText(FilledButton, tr.soldOut));
      expect(soldOut.onPressed, isNull);

      await pump(
        tester,
        _Forum(pages: pages('goods_cash', 'buyform_cash', pid: 11182)),
        pid: 11182,
        goods: _listed(pid: 11182, subject: '测试画集', price: 12.5, credit: 5),
      );
      expect(find.text(tr.buyInBrowser), findsOneWidget);
      expect(find.text(tr.buy), findsNothing);

      // An offline copy, a notice's post: the details only.
      await pump(tester, _Forum(pages: pages('goods_credit', 'buyform_virtual')), pid: 11179, canBuy: false);
      expect(find.text('测试徽章'), findsWidgets);
      expect(find.text(tr.buy), findsNothing);

      await pump(tester, _Forum(pages: pages('goods_seller', 'buyform_virtual')), pid: 11179, uid: 33);
      expect(find.text(tr.buy), findsNothing);
    });

    testWidgets('the card opens the goods in the app; buying only with the thread page above', (tester) async {
      final tr = t.specialThread.trade;
      final forum = _Forum(pages: pages('goods_credit', 'buyform_virtual'));
      final trade = TradeSpecial(
        formHash: 'f1f2f3f4',
        viewerUid: 31,
        count: null,
        creditUnit: _unit,
        canManage: false,
        manageUrl: null,
        canAdd: false,
        addUrl: null,
        goods: [_listed(pid: 11179, subject: '测试徽章', credit: 10)],
      );
      Future<void> open({VoidCallback? onReload}) async {
        await tester.pumpWidget(
          BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: RepositoryProvider<TradeRepository>.value(
                value: forum.repository,
                child: MaterialApp(
                  key: UniqueKey(),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      child: SpecialThreadCard(trade, pid: '11179', onReload: onReload),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('测试徽章'));
        await tester.pumpAndSettle();
      }

      await open(onReload: () {});
      expect(find.byType(TradeGoodsPage), findsOneWidget);
      expect(find.text('seller_a'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, tr.buy), findsOneWidget);
      // A notice's post: no thread page to reload, read only.
      await open();
      expect(find.byType(TradeGoodsPage), findsOneWidget);
      expect(find.text(tr.buy), findsNothing);
    });
  });
}
