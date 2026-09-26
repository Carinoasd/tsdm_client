/// Regression test of issue #112: the forum remade its medal centre plugin (dsu_medalCenter 3.x) and the app parsed
/// nothing out of the new catalogue ("此分类暂无勋章" on every category).
///
/// The remade plugin renders `li#dsumc_mN` items (no more `li.pns`), takes every acquisition as a POST claim form
/// (hidden formhash/dsumcsubmit/medalid/method/credit/typeid; the button is disabled with a reason when the account
/// is not eligible), links manual review as a plain `action=apply` page carrying the claim form and a `reason`
/// textarea, and marks eligibility with `p.unmet`/`p.mine`/`p.wait`. An empty category is a `p.emp` line without a
/// list. Fixtures are captured from the live deployment with identity reduced to made-up values.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/medal_center/cubit/medal_center_cubit.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:tsdm_client/features/medal_center/view/medal_center_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/medal_${name}_v3_x5.html').readAsStringSync();
MedalCatalog _parse(String name) => parseMedalCatalog(parseHtmlDocument(_fixture(name)));

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('the remade catalogue is parsed: items, categories, status lines and pagination', () {
    final catalog = _parse('catalog');
    expect(catalog.supported, isTrue);
    expect(catalog.medals, hasLength(40), reason: 'every li#dsumc_mN of the first page is an item');
    expect(catalog.categories.take(3).map((c) => c.name), ['全部', '永久徽章', '特殊申请']);
    expect(catalog.page, 1);
    expect(catalog.previousUrl, isNull);
    expect(catalog.nextUrl, contains('page=2'));

    final granted = catalog.medals.firstWhere((m) => m.id == '1');
    expect(granted.method, '管理员颁发');
    expect(granted.actions, isEmpty);
    expect(granted.imageUrl, startsWith('https://www.tsdm39.com/static/image/'));
    expect(granted.description, isNotEmpty);
    expect(granted.details.join('\n'), contains('有效期：永久'));
    expect(granted.details.join('\n'), isNot(contains('ID 1')), reason: 'the menu heading repeats name and id');

    final manual = catalog.medals.firstWhere((m) => m.id == '6');
    expect(manual.method, '人工审核');
    expect(manual.accountStatus, '未达到领取条件');
    expect(manual.details.join('\n'), contains('威望 ≥ 5'));
    final review = manual.actions.single;
    expect(review.type, MedalActionType.manualReview);
    expect(review.url, '$medalCenterUrl&action=apply&medalid=6');
    expect(review.formData, isNull, reason: 'manual review goes through its application page');
  });

  test('an eligible purchase carries the whole claim form and the server confirmation sentence', () {
    final purchase = _parse('catalog').medals.firstWhere((m) => m.id == '593').actions.single;
    expect(purchase.type, MedalActionType.purchase);
    expect(purchase.url, '$medalCenterUrl&action=claim');
    expect(purchase.formData, {
      'formhash': 'XXXXXXXX',
      'dsumcsubmit': '1',
      'medalid': '593',
      'method': '5',
      'credit': '0',
      'typeid': '0',
    });
    expect(purchase.confirmText, '确定花费 30天使币 购买「【端午节】粽子勋章」勋章吗？');
    expect(purchase.disabledReason, isNull);
  });

  test('actions the server disabled keep its reason and are never offered as tappable', () {
    final catalog = _parse('catalog');
    final poor = catalog.medals.firstWhere((m) => m.id == '519').actions.single;
    expect(poor.type, MedalActionType.purchase);
    expect(poor.disabledReason, '您的积分不足以购买此勋章');
    final unmet = catalog.medals.firstWhere((m) => m.id == '120').actions.single;
    expect(unmet.type, MedalActionType.apply);
    expect(unmet.disabledReason, '您还没达到这枚勋章的领取资格');
    expect(unmet.formData?['method'], '1');
  });

  test('an empty category is the forum saying so, not an unsupported layout', () {
    final empty = _parse('empty');
    expect(empty.supported, isTrue);
    expect(empty.medals, isEmpty);
    expect(empty.message, '没有可以显示的勋章。');
    expect(empty.categories, isNotEmpty, reason: 'the category bar stays usable to leave the empty category');
  });

  test('the guest catalogue lists medals but offers no acquisition at all', () {
    final guest = _parse('guest');
    expect(guest.supported, isTrue);
    expect(guest.medals, hasLength(40));
    expect(guest.medals.expand((m) => m.actions), isEmpty);
    expect(guest.medals.map((m) => m.accountStatus).nonNulls, isEmpty);
  });

  test('claim forms that are not the plugin writing home are rejected before transport', () {
    ({String url, Map<String, String> data, int method})? parse(String form) =>
        medalClaimForm(parseHtmlDocument('<div>$form</div>').querySelector('form')!);
    const fields =
        '<input type="hidden" name="formhash" value="XXXXXXXX" /> '
        '<input type="hidden" name="dsumcsubmit" value="1" /> '
        '<input type="hidden" name="medalid" value="593" /> '
        '<input type="hidden" name="method" value="5" />';
    expect(parse('<form action="plugin.php?id=dsu_medalCenter:memcp&amp;action=claim">$fields</form>'), isNotNull);
    for (final (reason, form) in [
      (
        'foreign origin',
        '<form action="https://evil.example/plugin.php?id=dsu_medalCenter:memcp&amp;action=claim">$fields</form>',
      ),
      ('other module', '<form action="plugin.php?id=other:page&amp;action=claim">$fields</form>'),
      (
        'extra query parameter',
        '<form action="plugin.php?id=dsu_medalCenter:memcp&amp;action=claim&amp;x=1">$fields</form>',
      ),
      ('not the claim action', '<form action="plugin.php?id=dsu_medalCenter:memcp&amp;action=sethide">$fields</form>'),
      (
        'missing session token',
        '<form action="plugin.php?id=dsu_medalCenter:memcp&amp;action=claim"> '
            '<input type="hidden" name="dsumcsubmit" value="1" /> '
            '<input type="hidden" name="medalid" value="593" /> '
            '<input type="hidden" name="method" value="5" /></form>',
      ),
    ]) {
      expect(parse(form), isNull, reason: reason);
    }
    // The plugin is still growing: a new hidden field must not cost the button, and an unknown acquisition method
    // simply offers no action while the medal itself stays listed.
    final extra = parse(
      '<form action="plugin.php?id=dsu_medalCenter:memcp&amp;action=claim">$fields '
      '<input type="hidden" name="futurefield" value="1" /></form>',
    );
    expect(extra?.data['futurefield'], '1');
    expect(medalMethodType(3), isNull, reason: 'unknown method codes never become an action');
  });

  test('a claim posts the form as served; refusal and success keep the forum wording without script noise', () async {
    final posts = <(String, Map<String, String>)>[];
    var answer = _fixture('claim_rejected');
    final cubit = MedalCenterCubit(
      currentUid: () => 1000,
      fetchPage: (url) async => fail('a form action never falls back to GET: $url'),
      submitForm: (url, data) async {
        posts.add((url, data));
        return answer;
      },
    );
    final action = _parse('catalog').medals.firstWhere((m) => m.id == '593').actions.single;
    final refused = await cubit.performAction(action);
    expect(refused.success, isFalse);
    expect(refused.message, '您还没达到这枚勋章的领取资格');
    answer = _fixture('claim_success');
    final done = await cubit.performAction(action);
    expect(done.success, isTrue);
    expect(done.message, '购买成功，已扣除 30天使币。');
    expect(posts, hasLength(2));
    expect(posts.first.$1, '$medalCenterUrl&action=claim');
    expect(posts.first.$2, action.formData);
    await cubit.close();
  });

  test('manual review fetches its application page, then posts the claim form plus the reason', () async {
    final requests = <String>[];
    final posts = <(String, Map<String, String>)>[];
    final cubit = MedalCenterCubit(
      currentUid: () => 1000,
      fetchPage: (url) async {
        requests.add(url);
        return _fixture('apply_form');
      },
      submitForm: (url, data) async {
        posts.add((url, data));
        return _fixture('claim_success');
      },
    );
    final action = _parse('catalog').medals.firstWhere((m) => m.id == '6').actions.single;
    final result = await cubit.performAction(action, reason: '符合条件，请审核');
    expect(result.success, isTrue);
    expect(requests.single, action.url);
    expect(posts.single.$1, '$medalCenterUrl&action=claim');
    expect(posts.single.$2, {
      'formhash': 'XXXXXXXX',
      'dsumcsubmit': '1',
      'medalid': '6',
      'method': '2',
      'reason': '符合条件，请审核',
    });
    await cubit.close();
  });

  test('an ineligible application never posts and surfaces the page reason instead', () async {
    final posts = <String>[];
    final cubit = MedalCenterCubit(
      currentUid: () => 1000,
      fetchPage: (url) async => _fixture('apply_unmet'),
      submitForm: (url, data) async {
        posts.add(url);
        return _fixture('claim_success');
      },
    );
    final action = _parse('catalog').medals.firstWhere((m) => m.id == '6').actions.single;
    final result = await cubit.performAction(action, reason: 'x');
    expect(result.success, isFalse);
    expect(result.message, '您还没达到这枚勋章的领取资格');
    expect(posts, isEmpty);
    await cubit.close();
  });

  testWidgets('the purchase dialog quotes the server price sentence and the result reaches the screen', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cubit = MedalCenterCubit(
      currentUid: () => 1000,
      fetchPage: (_) async => _fixture('catalog'),
      submitForm: (_, _) async => _fixture('claim_success'),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MedalCenterPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = find.text('【端午节】粽子勋章');
    await tester.scrollUntilVisible(title, 400);
    await tester.tap(title);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.medalCenter.purchase).last);
    await tester.pumpAndSettle();
    expect(find.text('确定花费 30天使币 购买「【端午节】粽子勋章」勋章吗？'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(t.medalCenter.purchase)));
    await tester.pumpAndSettle();
    expect(find.text('购买成功，已扣除 30天使币。'), findsOneWidget, reason: 'the snackbar quotes the forum');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });

  testWidgets('a disabled action renders untappable with the server reason as its tooltip', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cubit = MedalCenterCubit(currentUid: () => 1000, fetchPage: (_) async => _fixture('catalog'));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MedalCenterPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final saber = _parseSaberName(cubit);
    final title = find.text(saber);
    await tester.scrollUntilVisible(title, 400);
    await tester.tap(title);
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
      find.descendant(of: find.byType(ExpansionTile), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == '您的积分不足以购买此勋章'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });

  testWidgets('an empty category shows the forum wording and keeps the category picker', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final cubit = MedalCenterCubit(currentUid: () => 1000, fetchPage: (_) async => _fixture('empty'));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MedalCenterPage(controller: cubit, imageBuilder: (_) => const SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有可以显示的勋章。'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });
}

String _parseSaberName(MedalCenterCubit cubit) => cubit.state.catalog!.medals.firstWhere((m) => m.id == '519').name;
