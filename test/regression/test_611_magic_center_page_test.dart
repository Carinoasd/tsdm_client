/// The magic center screen: the two lists, the buy and use windows, one POST per confirmation and the account guard.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/magic/cubit/magic_center_cubit.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';
import 'package:tsdm_client/features/magic/view/magic_center_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

String _fixture(String name) => File('test/data/magic/$name').readAsStringSync();

final class _Harness {
  _Harness({this.answer, this.fail = false});

  /// The answer to a POST; a pending completer holds it.
  final Completer<Object?>? answer;

  /// The POST fails at the transport.
  final bool fail;

  int uid = 31;
  final gets = <String>[];
  final windows = <String>[];
  final posts = <(String, Map<String, String>)>[];

  late final cubit = MagicCenterCubit(
    currentUid: () => uid,
    repository: () => MagicRepository(
      getPage: (url) async {
        gets.add(url);
        return _fixture(url.contains('mybox') ? 'mybox_x5.html' : 'shop_x5.html');
      },
      getWindow: (url) async {
        windows.add(url);
        if (url.contains('operation=buy')) return jsonDecode(_fixture('buy_form_x5.json'));
        if (url.contains('magicid=1&')) return _fixture('use_sofa_x5.xml');
        if (url.contains('magicid=34&')) return _fixture('use_pkcat_x5.xml');
        return _fixture('use_missing_x5.xml');
      },
      postForm: (url, body) async {
        posts.add((url, body));
        if (fail) throw const SocketException('reset');
        if (answer case final answer?) return answer.future;
        return jsonDecode(_fixture(body['operation'] == 'buy' ? 'buy_ok.json' : 'use_sofa_ok.json'));
      },
    ),
  );
}

Future<void> _pump(WidgetTester tester, MagicCenterCubit cubit, {double width = 400, double scale = 1}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  tester.view.physicalSize = Size(width, 900);
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
        home: MagicCenterPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('the shop and my magic list on a narrow screen with large text', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit, width: 320, scale: 1.6);
    expect(tester.takeException(), isNull);
    expect(find.text('猫娘卡'), findsOneWidget);
    expect(find.byKey(const ValueKey('magic-buy-prankmagic:pkcat')), findsOneWidget);
    expect(find.byKey(const ValueKey('magic-buy-sofa')), findsNothing, reason: 'sold out');
    expect(find.text(t.magicCenter.soldOut), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('magic-tab-mine')));
    expect(find.byKey(const ValueKey('magic-use-1')), findsOneWidget);
    expect(find.text(t.magicCenter.owned(count: 4)), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(h.gets.every((u) => u == magicShopUrl || u == magicBoxUrl), isTrue);
  });

  testWidgets('buying posts the chosen count once and shows the forum words', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit);
    await _tap(tester, find.byKey(const ValueKey('magic-buy-prankmagic:pkcat')));
    expect(find.text('库存: 998 张'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('magic-count-plus')));
    await _tap(tester, find.byKey(const ValueKey('magic-count-plus')));
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('magic-count-plus')), warnIfMissed: false);
      await tester.pump();
    }
    expect(find.widgetWithText(TextFormField, '5'), findsOneWidget, reason: 'room in the bag allows five');
    await tester.enterText(find.byKey(const ValueKey('magic-field-magicnum')), '3');
    await _tap(tester, find.byKey(const ValueKey('magic-submit')));
    expect(h.posts, hasLength(1));
    final (url, body) = h.posts.single;
    expect(url, contains('action=shop&infloat=yes&inajax=1'));
    expect(body, containsPair('magicnum', '3'));
    expect(body, containsPair('mid', 'prankmagic:pkcat'));
    expect(find.byKey(const ValueKey('magic-result')), findsOneWidget);
    expect(find.text('您用 1 天使币 购买了 1 张猫娘卡'), findsOneWidget);
    expect(h.gets.length, 4, reason: 'both lists are read again after the buy');
  });

  testWidgets('using the sofa card turns a pasted thread link into its id', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit);
    await _tap(tester, find.byKey(const ValueKey('magic-tab-mine')));
    await _tap(tester, find.byKey(const ValueKey('magic-use-1')));
    expect(find.text(t.magicCenter.fieldThread), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('magic-submit')));
    expect(h.posts, isEmpty, reason: 'the thread is required');
    await tester.enterText(
      find.byKey(const ValueKey('magic-field-tid')),
      'https://forum.test/forum.php?mod=viewthread&tid=1000',
    );
    await _tap(tester, find.byKey(const ValueKey('magic-submit')));
    expect(h.posts.single.$2, containsPair('tid', '1000'));
    expect(h.posts.single.$2, containsPair('magicid', '1'));
    expect(h.posts.single.$1, contains('action=mybox&infloat=yes&inajax=1'));
    expect(find.text('抢到沙发了！你的回帖已置顶到 1 楼之后。'), findsWidgets);
  });

  testWidgets('a failed POST is never sent again and is reported as unconfirmed', (tester) async {
    final h = _Harness(fail: true);
    await _pump(tester, h.cubit);
    await _tap(tester, find.byKey(const ValueKey('magic-tab-mine')));
    await _tap(tester, find.byKey(const ValueKey('magic-use-34')));
    await tester.enterText(find.byKey(const ValueKey('magic-field-username')), '测试用户甲');
    await _tap(tester, find.byKey(const ValueKey('magic-submit')));
    expect(h.posts, hasLength(1));
    expect(find.text(t.magicCenter.unknown(name: '猫娘卡')), findsWidgets);
  });

  testWidgets('a window the forum refuses shows its words and posts nothing', (tester) async {
    final h = _Harness();
    await _pump(tester, h.cubit);
    await _tap(tester, find.byKey(const ValueKey('magic-tab-mine')));
    await _tap(tester, find.byKey(const ValueKey('magic-use-35')));
    expect(find.textContaining('道具不存在'), findsOneWidget);
    expect(h.posts, isEmpty);
  });

  test('an answer for another account is dropped', () async {
    final answer = Completer<Object?>();
    final h = _Harness(answer: answer);
    await h.cubit.load();
    final item = h.cubit.state.box!.items.firstWhere((i) => i.magicId == 1);
    final form = await h.cubit.openWindow(item, buy: false);
    final pending = h.cubit.submit(form!, {'tid': '1000'}, name: item.name);
    await Future<void>.delayed(Duration.zero);
    h.uid = 32;
    answer.complete(jsonDecode(_fixture('use_sofa_ok.json')));
    expect(await pending, isNull);
    expect(h.posts, hasLength(1));
    expect(h.cubit.state.result, isNull);
    await h.cubit.close();
  });
}
