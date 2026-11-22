/// The background shop page (plugin 4.1.0): the tabs of the website, each read from its own action when first shown,
/// and every write sent once, only when asked for, then the pages it changed read again.
///
/// * My backgrounds: both positions with the display form; a save sends the four fields of that position's form.
/// * Buy: the purchase dialog is the confirmation (position, plan, months, cost, what is left); not enough credits
///   keeps it from being sent; a purchase reads my backgrounds, the shop and the storeroom again.
/// * An answer that tells nothing (the forum's 503 page): "not known", sent once, the shop and the storeroom read again.
/// * Storeroom and exchange: their GETs are sent only on a tap (never while reading); an exchange is confirmed first
///   and, done, shows the storeroom.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';
import 'package:tsdm_client/features/background_shop/repository/background_shop_repository.dart';
import 'package:tsdm_client/features/background_shop/view/background_shop_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp/bgshop/$name.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _result(String key, {int ok = 0}) => {
  'ok': ok,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'message',
  'message': key,
  'message_key': key,
  'login': 0,
};

Map<String, dynamic> _exchange() {
  final json = _fixture('bg_exchange_v77');
  ((json['campaigns'] as List).first as Map<String, dynamic>)
    ..['owned_medals'] = 2
    ..['eligible'] = 1
    ..['backgrounds'] = [
      {'id': 96, 'name': '活动背景', 'image': 'https://forum.test/a.jpg', 'owned': 0},
    ];
  return json;
}

void main() {
  late List<String> asked;
  late List<(String, Map<String, String>)> posted;
  late List<String> got;
  late Object? Function() reply;
  late Map<String, dynamic> Function() store;
  late bool readsFail;
  late List<Map<String, String>> storeQueries;
  Completer<void>? holdSpecial;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() {
    asked = [];
    posted = [];
    got = [];
    reply = () => _result('');
    store = () => _fixture('bg_store_v75');
    readsFail = false;
    storeQueries = [];
    holdSpecial = null;
  });

  BackgroundShopRepository repo() => BackgroundShopRepository(
    ask: (action, query) async {
      asked.add(action);
      if (readsFail) return null;
      if (action == 'bgstore') {
        storeQueries.add(query);
        if (query['mode'] == 'special') {
          await holdSpecial?.future;
          return _fixture('bg_store_v75_special');
        }
      }
      return switch (action) {
        'bgmine' => _fixture('bg_mine_v74'),
        'bgstore' => store(),
        'bgslot' => _fixture('bg_slot_v76'),
        'bgexchange' => _exchange(),
        _ => null,
      };
    },
    post: (url, data) async {
      posted.add((url, data));
      final r = reply();
      return r is Future<Object?> ? await r : r;
    },
    get: (url) async {
      got.add(url);
      return reply();
    },
    currentUid: () => 31,
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          scaffoldMessengerKey: snackbarKey,
          home: BackgroundShopPage(repository: repo(), dataSaver: DataSaverMode.always),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey('bgshop-tab-$key')));
    await tester.pumpAndSettle();
  }

  Future<void> clearSnackBar(WidgetTester tester) async {
    snackbarKey.currentState?.clearSnackBars();
    await tester.pumpAndSettle();
  }

  testWidgets('my backgrounds: both positions; a save sends that form once, then reads it again', (tester) async {
    await pump(tester);
    expect(asked, ['bgmine']);
    expect(find.byKey(const ValueKey('bgshop-mine-content')), findsOneWidget);
    expect(find.byKey(const ValueKey('bgshop-mine-sidebar')), findsOneWidget);

    final sidebar = find.byKey(const ValueKey('bgshop-mine-sidebar'));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('bgshop-sidebar-dipbg')),
        matching: find.text('不显'),
      ),
    );
    await tester.pumpAndSettle();
    reply = () => _result('bgshop_style_saved', ok: 1);
    await tester.tap(find.descendant(of: sidebar, matching: find.byKey(const ValueKey('bgshop-sidebar-save'))));
    await tester.pumpAndSettle();
    expect(posted.length, 1);
    expect(posted.single.$2['bgmemeditsubmit'], 'true');
    expect(posted.single.$2['dipbg'], '0');
    expect(
      posted.single.$2.keys.toSet(),
      {'formhash', 'bgmemeditsubmit', 'dipbg', 'background_repeat', 'background_positionh', 'background_positionv'},
    );
    expect(find.text(tr.backgroundShop.saved), findsOneWidget);
    expect(asked, ['bgmine', 'bgmine']);
    expect(got, isEmpty);
    await clearSnackBar(tester);
  });

  testWidgets('buy: the dialog confirms what it costs, sends once, and reads the changed pages again', (tester) async {
    await pump(tester);
    await tab(tester, 'store');
    expect(asked, ['bgmine', 'bgstore']);

    await tester.tap(find.byKey(const ValueKey('bgshop-buy-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bgshop-buy-months')), '3');
    await tester.pumpAndSettle();
    expect(find.text('30 天使币'), findsOneWidget);
    expect(find.text('104 天使币'), findsOneWidget);

    // More than the balance: not sent.
    await tester.enterText(find.byKey(const ValueKey('bgshop-buy-months')), '20');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('bgshop-buy-confirm'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('bgshop-buy-months')), '3');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('bgshop-buy-position')),
        matching: find.text(tr.backgroundShop.sidebar),
      ),
    );
    await tester.pumpAndSettle();
    reply = () => _result('bgshop_bought', ok: 1);
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-confirm')));
    await tester.pumpAndSettle();
    expect(posted.length, 1);
    final url = Uri.parse(posted.single.$1);
    expect((url.queryParameters['bgid'], url.queryParameters['p']), ('1', '1'));
    expect((posted.single.$2['plan'], posted.single.$2['buynum']), ('c2', '3'));
    expect(find.text(tr.backgroundShop.bought), findsOneWidget);
    // My backgrounds again (built already), the shop again; the storeroom is read when first shown.
    expect(asked, ['bgmine', 'bgstore', 'bgmine', 'bgstore']);
    await clearSnackBar(tester);
  });

  Future<void> buySecond(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('an answer that tells nothing, nothing changed: not done, sent once', (tester) async {
    await pump(tester);
    await tab(tester, 'slot');
    await tab(tester, 'store');
    asked.clear();
    reply = () => '<html><body>Discuz! System Error</body></html>';
    await buySecond(tester);
    expect(posted.length, 1);
    expect(find.text(tr.backgroundShop.notDone), findsOneWidget);
    // Read once to compare, then the pages it changes.
    expect(asked.first, 'bgstore');
    expect(asked.toSet(), {'bgmine', 'bgstore', 'bgslot'});
    await clearSnackBar(tester);
  });

  testWidgets('bgshop_unknown, the background owned now: bought', (tester) async {
    await pump(tester);
    await tab(tester, 'store');
    reply = () {
      store = () {
        final json = _fixture('bg_store_v75');
        ((json['backgrounds'] as List)[1] as Map)['owned'] = {'expiration': 1800000000, 'permanent': 0};
        return json;
      };
      return _result('bgshop_unknown');
    };
    await buySecond(tester);
    expect(posted.length, 1);
    expect(find.text(tr.backgroundShop.bought), findsOneWidget);
    await clearSnackBar(tester);
  });

  testWidgets('no answer and the page can not tell: asked to check, with a refresh', (tester) async {
    await pump(tester);
    await tab(tester, 'store');
    reply = () {
      store = () => {..._fixture('bg_store_v75'), 'backgrounds': <Object>[]};
      throw const BackgroundShopNoAnswer();
    };
    await buySecond(tester);
    expect(posted.length, 1);
    expect(find.text(tr.backgroundShop.unknown), findsOneWidget);
    asked.clear();
    await tester.tap(find.text(tr.backgroundShop.refresh));
    await tester.pumpAndSettle();
    expect(asked, contains('bgstore'));
    expect(posted.length, 1, reason: 'never sent again');
    await clearSnackBar(tester);
  });

  testWidgets('no answer and nothing changed: still not known, not "not done"', (tester) async {
    await pump(tester);
    await tab(tester, 'store');
    reply = () => throw const BackgroundShopNoAnswer();
    await buySecond(tester);
    expect(posted.length, 1);
    expect(find.text(tr.backgroundShop.unknown), findsOneWidget);
    expect(find.text(tr.backgroundShop.notDone), findsNothing);
    await clearSnackBar(tester);
  });

  testWidgets('offline: the reads after a write not known fail quietly, the message and its refresh stay', (
    tester,
  ) async {
    await pump(tester);
    await tab(tester, 'slot');
    await tab(tester, 'store');
    reply = () {
      readsFail = true;
      throw const BackgroundShopNoAnswer();
    };
    await buySecond(tester);
    expect(find.text(tr.backgroundShop.unknown), findsOneWidget);
    expect(find.text(tr.backgroundShop.refresh), findsOneWidget);
    expect(find.text(tr.general.failedToLoad), findsNothing);
    // The member's own refresh does tell its failure.
    await tester.tap(find.text(tr.backgroundShop.refresh));
    await tester.pumpAndSettle();
    expect(find.text(tr.general.failedToLoad), findsOneWidget);
    await clearSnackBar(tester);
  });

  testWidgets('leaving the page while a refused write is on its way', (tester) async {
    await pump(tester);
    final pending = Completer<Object?>();
    reply = () => pending.future;
    await tester.tap(find.byKey(const ValueKey('bgshop-content-save')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(_result('submit_invalid'));
    await tester.pumpAndSettle();
    expect(posted.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the page while a write is on its way', (tester) async {
    await pump(tester);
    final pending = Completer<Object?>();
    reply = () => pending.future;
    await tester.tap(find.byKey(const ValueKey('bgshop-content-save')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(_result('bgshop_style_saved', ok: 1));
    await tester.pumpAndSettle();
    expect(posted.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a purchase not known while another list is on its way: compared on the page it was sent from', (
    tester,
  ) async {
    await pump(tester);
    await tab(tester, 'store');
    holdSpecial = Completer<void>();
    await tester.tap(find.text('活动商店'));
    await tester.pump();
    reply = () => _result('bgshop_unknown');
    await buySecond(tester);
    expect(storeQueries.last, isEmpty, reason: 'the shop, page 1, no keyword');
    expect(find.text(tr.backgroundShop.notDone), findsOneWidget);
    holdSpecial!.complete();
    await tester.pumpAndSettle();
    // The event shop that came back late does not replace the page compared.
    expect(find.byKey(const ValueKey('bgshop-store-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('bgshop-store-29')), findsNothing);
    await clearSnackBar(tester);
  });

  testWidgets('leaving the page after a search while a purchase is on its way, answered with nothing', (tester) async {
    await pump(tester);
    await tab(tester, 'store');
    await tester.enterText(find.byKey(const ValueKey('bgshop-search')), '樱花');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final pending = Completer<Object?>();
    reply = () => pending.future;
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-confirm')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.completeError(const BackgroundShopNoAnswer());
    await tester.pumpAndSettle();
    expect(posted.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a known failure shows the forum words', (tester) async {
    await pump(tester);
    await tab(tester, 'store');
    reply = () => {..._result('bgshop_credit_insufficient'), 'message': '您的天使币不足'};
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bgshop-buy-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('您的天使币不足'), findsOneWidget);
    await clearSnackBar(tester);
  });

  testWidgets('storeroom: one GET on a tap, none while reading', (tester) async {
    await pump(tester);
    await tab(tester, 'slot');
    expect(got, isEmpty);
    // In use at both places: no button for it.
    expect(find.byKey(const ValueKey('bgshop-slot-142-content-inuse')), findsOneWidget);
    expect(find.byKey(const ValueKey('bgshop-slot-142-sidebar-inuse')), findsOneWidget);
    reply = () => _result('bgshop_slot_set', ok: 1);
    await tester.tap(find.byKey(const ValueKey('bgshop-slot-143-content')));
    await tester.pumpAndSettle();
    expect(got.length, 1);
    final url = Uri.parse(got.single);
    expect((url.queryParameters['changesid'], url.queryParameters['bgside']), ('143', '0'));
    expect(find.text(tr.backgroundShop.slotSet), findsOneWidget);
    expect(asked.where((a) => a == 'bgslot').length, 2);
    await clearSnackBar(tester);
  });

  testWidgets('exchange: confirmed first, one GET, then the storeroom', (tester) async {
    await pump(tester);
    await tab(tester, 'exchange');
    expect(got, isEmpty);
    // Events with nothing to choose are not listed.
    expect(find.byKey(const ValueKey('bgshop-campaign-get20210501_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('bgshop-campaign-get20200501_1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bgshop-exchange-get20210501_1-96')));
    await tester.pumpAndSettle();
    expect(find.text(tr.backgroundShop.exchangeOnce), findsOneWidget);
    await tester.tap(find.text(tr.general.cancel));
    await tester.pumpAndSettle();
    expect(got, isEmpty);

    reply = () => _result('bgshop_exchanged', ok: 1);
    await tester.tap(find.byKey(const ValueKey('bgshop-exchange-get20210501_1-96')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, tr.backgroundShop.exchange).last);
    await tester.pumpAndSettle();
    expect(got.length, 1);
    expect(Uri.parse(got.single).queryParameters['getbgid'], '96');
    expect(find.text(tr.backgroundShop.exchangeDone), findsOneWidget);
    expect(find.byKey(const ValueKey('bgshop-slot-143')), findsOneWidget, reason: 'the storeroom is shown');
    await clearSnackBar(tester);
  });

  test('what each write makes stale', () {
    expect(backgroundShopStaleAfter(BackgroundShopWrite.buy), {'mine', 'store', 'slot'});
    expect(backgroundShopStaleAfter(BackgroundShopWrite.exchange), {'exchange', 'slot'});
  });
}
