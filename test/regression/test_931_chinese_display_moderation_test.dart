/// The Chinese display on the moderation and the tools pages test 930 left out: the windows of a floor (their
/// refusals and what they list), the credits of the admin page, the reason of a batch rate, the result of a magic.
///
/// The names of members ("测试版主", which the dictionary would convert) and the app's own words stay as they are.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_list_page.dart';
import 'package:tsdm_client/features/magic/cubit/magic_center_cubit.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';
import 'package:tsdm_client/features/magic/view/magic_center_page.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/remove_rate_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

import 'admin_tools_fakes.dart';

ChineseConverter _load(String name) => ChineseConverter.parse(File('assets/text/opencc/$name.txt').readAsStringSync());

Object? _data(String path) {
  final text = File('test/data/$path').readAsStringSync();
  return path.endsWith('.json') ? jsonDecode(text) : text;
}

/// Whether some text on screen (a [RichText], which every [Text] builds, or a selectable text) contains [text].
Finder _shown(String text) => find.byWidgetPredicate(
  (w) =>
      (w is RichText && w.text.toPlainText(includeSemanticsLabels: false).contains(text)) ||
      (w is EditableText && w.controller.text.contains(text)),
  skipOffstage: false,
);

/// [home] in the app showing forum text in the Traditional script.
Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        scaffoldMessengerKey: snackbarKey,
        builder: (context, child) => ChineseDisplayHost(mode: ChineseDisplayMode.traditional, child: child!),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    ChineseDisplay.instance.useConverters(s2t: _load('s2t'), t2s: _load('t2s'));
  });

  tearDownAll(ChineseDisplay.instance.useConverters);

  setUp(() async {
    // The app in Simplified Chinese: its own words must stay Simplified in the Traditional mode.
    await LocaleSettings.setLocale(AppLocale.zhCn);
    AdminAccessCache.reset();
  });

  tearDown(() async => LocaleSettings.setLocale(AppLocale.en));

  testWidgets("taking back rates: the forum's refusal converted, the members not", (tester) async {
    final repo = FloorOpsRepository(
      get: (_) async => right((statusCode: 200, data: _data('moderate/removerate_window.json'))),
      getOnce: (_) async => throw StateError('no write by GET'),
      post: (_, _) async => right((statusCode: 200, data: _data('moderate/removerate_nopermission_ajax.xml'))),
      currentUid: () => 31,
    );
    await _pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => showRemoveRateDialog(context, tid: '1234567', pid: '7654321', repository: repo),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(_shown('测试版主'), findsOneWidget);
    expect(_shown('測試版主'), findsNothing);
    await tester.tap(find.text('测试管理员'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, t.general.ok));
    await tester.pumpAndSettle();
    expect(_shown('抱歉，您沒有權限撤銷評分'), findsOneWidget);
  });

  testWidgets('the credits of the admin page: their names and units converted', (tester) async {
    final members = adminFixture('credit_members');
    for (final c in members['credits'] as List<dynamic>) {
      (c as Map<String, dynamic>)['unit'] = '个钱';
    }
    final forum = FakeAdminForum({
      'GET:admincredit': [members],
    });
    await _pump(tester, AdminCreditPage(repository: forum.repository(), initialMembers: '101', writable: true));
    expect(_shown('天使幣 0個錢'), findsWidgets);
    expect(_shown('个钱'), findsNothing);
  });

  testWidgets('a batch rate: its reason converted', (tester) async {
    const list = '$baseUrl/plugin.php?id=batchrate:list';
    final detail = _data('tsdmapp_390/batchrate_detail.json')! as Map<String, dynamic>;
    (detail['batch'] as Map<String, dynamic>)['reason'] = '允许重复';
    final repo = BatchRateRepository(
      ask: (_) async => null,
      get: (url) async => url.contains('bract=detail') ? detail : _data('tsdmapp_390/batchrate_list.json'),
      post: (_, _) async => throw StateError('nothing sent'),
      currentUid: () => 31,
    );
    await _pump(tester, BatchRateListPage(listUrl: list, repository: repo));
    await tester.tap(find.byKey(const ValueKey('batch-rate-batch-10')));
    await tester.pumpAndSettle();
    expect(_shown('允許重複'), findsOneWidget);
    expect(_shown('允许重复'), findsNothing);
  });

  testWidgets("a magic used: its name converted in the app's sentence", (tester) async {
    String file(String name) => File('test/data/magic/$name').readAsStringSync();
    final cubit = MagicCenterCubit(
      currentUid: () => 31,
      repository: () => MagicRepository(
        getPage: (url) async => file(url.contains('mybox') ? 'mybox_x5.html' : 'shop_x5.html'),
        getWindow: (url) async => file(url.contains('magicid=34&') ? 'use_pkcat_x5.xml' : 'use_missing_x5.xml'),
        postForm: (_, _) async => throw const SocketException('reset'),
      ),
    );
    addTearDown(cubit.close);
    await _pump(tester, MagicCenterPage(controller: cubit, imageBuilder: (_) => const SizedBox()));
    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tap(find.byKey(const ValueKey('magic-tab-mine')));
    await tap(find.byKey(const ValueKey('magic-use-34')));
    await tester.enterText(find.byKey(const ValueKey('magic-field-username')), '测试用户甲');
    await tap(find.byKey(const ValueKey('magic-submit')));
    expect(_shown(t.magicCenter.unknown(name: '貓娘卡')), findsWidgets);
  });
}
