/// The magic center: the shop and "my magic" pages, the buy and use windows and the answers to them, as the test
/// forum (Discuz! X5, tsdmapp 3.4.0, the prankmagic cards and the sofa card) printed them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/magic/$name').readAsStringSync();

Object? _json(String name) => jsonDecode(_fixture(name));

MagicForm _form(Object? data) => parseMagicForm(magicWindowHtml(data));

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('list pages', () {
    test('the shop lists every magic with image, description, price and whether it can be bought', () {
      final page = parseMagicList(parseHtmlDocument(_fixture('shop_x5.html')), MagicList.shop);
      expect(page.list, MagicList.shop);
      expect(page.items.map((i) => i.identifier), [
        'sofa',
        'prankmagic:pkname',
        'prankmagic:pkclown',
        'prankmagic:pkcat',
        'prankmagic:pkshield',
        'prankmagic:pkflip',
        'prankmagic:pkdress',
      ]);
      final sofa = page.items.first;
      expect(sofa.name, '抢沙发卡');
      expect(sofa.price, 10);
      expect(sofa.priceText, '10 天使币/张');
      expect(sofa.buyable, isFalse, reason: 'out of stock: the page prints 此道具缺货 and no buy link');
      expect(sofa.imageUrl, '$baseUrl/static/image/magic/sofa.gif');
      final cat = page.items[3];
      expect(cat.name, '猫娘卡');
      expect(cat.buyable, isTrue);
      expect(cat.price, 1);
      expect(cat.description, contains('喵～'));
      expect(cat.imageUrl, '$baseUrl/source/plugin/prankmagic/magic/magic_pkcat.gif');
      expect(page.capacity, matches(RegExp(r'^\d+/100$')));
      expect(page.balance, matches(RegExp(r'天使币 \d+')));
      expect(page.nextUrl, isNull);
      expect(page.previousUrl, isNull);
    });

    test('my magic lists the owned magics with their id and count', () {
      final page = parseMagicList(parseHtmlDocument(_fixture('mybox_x5.html')), MagicList.box);
      expect(page.items, isNotEmpty);
      final sofa = page.items.firstWhere((i) => i.identifier == 'sofa');
      expect(sofa.magicId, 1);
      expect(sofa.count, 4);
      expect(sofa.weight, 40);
      expect(page.items.every((i) => i.magicId != null && (i.count ?? 0) > 0), isTrue);
      expect(page.balance, isEmpty);
      expect(page.capacity, matches(RegExp(r'^\d+/100$')));
    });

    test('a guest is served the login prompt, not a list', () {
      final doc = parseHtmlDocument(_fixture('guest_x5.html'));
      expect(magicServedUid(doc), isNull);
      expect(
        () => parseMagicList(doc, MagicList.shop),
        throwsA(isA<MagicForumMessage>().having((m) => m.login, 'login', isTrue)),
      );
    });

    test('a pager is read, but only list pages are ever fetched', () {
      final html = _fixture('shop_x5.html').replaceFirst(
        '</ul>\n</div>',
        '</ul><div class="pgs cl mtm"><div class="pg"><a href="home.php?mod=magic&amp;action=shop&amp;operation=index&amp;page=1" class="prev">上一页</a><strong>2</strong> '
            '<a href="home.php?mod=magic&amp;action=shop&amp;operation=index&amp;page=3" class="nxt">下一页</a></div></div>\n</div>',
      );
      final page = parseMagicList(parseHtmlDocument(html), MagicList.shop);
      expect(page.page, 2);
      expect(page.nextUrl, '$magicShopUrl&page=3');
      expect(page.previousUrl, magicShopUrl);
      expect(magicListPageUrl('home.php?mod=magic&action=shop&operation=buy&mid=sofa', MagicList.shop), isNull);
      expect(magicListPageUrl('home.php?mod=magic&action=mybox&operation=use&magicid=1', MagicList.box), isNull);
      expect(magicListPageUrl('https://elsewhere.test/home.php?mod=magic', MagicList.shop), isNull);
      expect(magicListPageUrl('home.php?mod=magic&action=mybox&page=2', MagicList.box), '$magicBoxUrl&page=2');
    });
  });

  group('windows', () {
    test('the buy window, plugin result or forum xml, gives the count, the facts and the limits', () {
      for (final (data, stock, balance, room, max) in [
        (_json('buy_form_x5.json'), 995, 1004, 30, 3),
        (_fixture('buy_form_x5.xml'), 998, 1002, 50, 5),
      ]) {
        final form = _form(data);
        expect(form.action, '$baseUrl/home.php?mod=magic&action=shop&infloat=yes&inajax=1');
        expect(form.title, '猫娘卡');
        expect(form.hidden['operation'], 'buy');
        expect(form.hidden['mid'], 'prankmagic:pkcat');
        expect(form.hidden['formhash'], 'f1f2f3f4');
        expect(form.hidden['operatesubmit'], 'yes');
        expect(form.fields.single.name, 'magicnum');
        expect(form.fields.single.role, MagicFieldRole.number);
        expect(form.unitPrice, 1);
        expect(form.unitWeight, 10);
        expect(form.stock, stock);
        expect(form.balance, balance);
        expect(form.freeWeight, room);
        expect(form.maxCount, max, reason: 'the room left in the bag at 10 each is the tightest limit');
        expect(form.facts, contains('库存: $stock 张'));
        expect(form.notes.single, contains('喵～'));
        expect(form.body({'magicnum': '2'}), containsPair('magicnum', '2'));
      }
    });

    test('the sofa card asks for a thread id', () {
      final form = _form(_fixture('use_sofa_x5.xml'));
      expect(form.action, '$baseUrl/home.php?mod=magic&action=mybox&infloat=yes&inajax=1');
      expect(form.title, '抢沙发卡');
      expect(form.fields.single.name, 'tid');
      expect(form.fields.single.role, MagicFieldRole.thread);
      expect(form.fields.single.label, contains('主题 ID'));
      expect(form.notes.single, contains('请先在该主题回帖'));
      expect(form.body({'tid': '1000'}), {
        'formhash': 'f1f2f3f4',
        'handlekey': 'magics',
        'operation': 'use',
        'magicid': '1',
        'usesubmit': 'yes',
        'tid': '1000',
      });
    });

    test('a card on a user asks for the name, the name plate card also for its text', () {
      final cat = _form(_fixture('use_pkcat_x5.xml'));
      expect(cat.fields.map((f) => (f.name, f.role)), [('username', MagicFieldRole.user)]);
      expect(cat.notes, hasLength(2));
      final plate = _form(_fixture('use_pkname_x5.xml'));
      expect(plate.fields.map((f) => (f.name, f.role)), [
        ('username', MagicFieldRole.user),
        ('pktext', MagicFieldRole.text),
      ]);
      expect(plate.fields.last.label, '称号（不用加【】）');
      expect(plate.hidden['magicid'], '32');
    });

    test('a card used on oneself has no input; one on a thread link keeps the forum label', () {
      final shield = _form(_fixture('use_pkshield_x5.xml'));
      expect(shield.fields, isEmpty);
      expect(shield.notes, hasLength(2));
      final flip = _form(_json('use_pkflip_x5.json'));
      expect(flip.fields.single.name, 'tidurl');
      expect(flip.fields.single.role, MagicFieldRole.text);
      expect(flip.fields.single.label, '主题 ID 或网址');
    });

    test('a window the forum refused is its message', () {
      expect(
        () => _form(_fixture('use_missing_x5.xml')),
        throwsA(isA<MagicForumMessage>().having((m) => m.message, 'message', contains('道具不存在'))),
      );
    });

    test('a window with a control the app cannot fill is sent to the website', () {
      final html = magicUnwrapAjax(
        _fixture('use_sofa_x5.xml'),
      ).replaceFirst('<input type="text" name="tid"', '<input type="checkbox" name="tid"');
      expect(() => parseMagicForm(html), throwsA(isA<MagicFormUnsupported>()));
      final picker = magicUnwrapAjax(
        _fixture('use_sofa_x5.xml'),
      ).replaceFirst('<input type="text" name="tid"', '<span onclick="pick()"></span><input type="text" name="tid"');
      expect(() => parseMagicForm(picker), throwsA(isA<MagicFormUnsupported>()));
      final radio = magicUnwrapAjax(_fixture('use_sofa_x5.xml')).replaceFirst(
        '<input type="text" name="tid" class="px p_fre" value="" size="12" autocomplete="off" />',
        '<input type="radio" name="opt" value="1" /> 是 &nbsp; <input type="radio" name="opt" value="0" checked="checked" /> 否',
      );
      final form = parseMagicForm(radio);
      expect(form.fields.single.role, MagicFieldRole.choice);
      expect(form.fields.single.value, '0');
      expect(form.fields.single.options.map((o) => (o.value, o.label)), [('1', '是'), ('0', '否')]);
    });

    test('an unchecked radio group is no choice; disabled controls and ones outside the settings are not posted', () {
      final sofa = magicUnwrapAjax(_fixture('use_sofa_x5.xml'));
      final unchecked = parseMagicForm(
        sofa.replaceFirst(
          '<input type="text" name="tid" class="px p_fre" value="" size="12" autocomplete="off" />',
          '<input type="radio" name="opt" value="1" /> 是 <input type="radio" name="opt" value="0" /> 否',
        ),
      );
      expect(unchecked.fields.single.value, isEmpty, reason: 'the browser posts nothing for an unchecked group');
      final disabled = parseMagicForm(
        sofa.replaceFirst(
          '<input type="hidden" name="usesubmit"',
          '<input type="hidden" name="extra" value="1" disabled="disabled" /><input type="hidden" name="usesubmit"',
        ),
      );
      expect(disabled.hidden.containsKey('extra'), isFalse);
      final outside = sofa.replaceFirst(
        '<input type="hidden" name="usesubmit"',
        '<input type="text" name="note" value="" /><input type="hidden" name="usesubmit"',
      );
      expect(() => parseMagicForm(outside), throwsA(isA<MagicFormUnsupported>()));
    });

    test('the discount note is not taken for a balance', () {
      final html = _fixture('shop_x5.html').replaceFirst(
        '<span class="pipe">|</span>\n目前有',
        '<span class="pipe">|</span>您可以享受 8 折优惠<span class="pipe">|</span>\n目前有',
      );
      expect(html, contains('8 折'));
      final page = parseMagicList(parseHtmlDocument(html), MagicList.shop);
      expect(page.balance, startsWith('目前有 天使币'));
      expect(page.balance, isNot(contains('8 折')));
      expect(page.capacity, matches(RegExp(r'^\d+/100$')));
    });

    test('a form posted anywhere else is refused', () {
      final html = magicUnwrapAjax(
        _fixture('use_sofa_x5.xml'),
      ).replaceFirst('action="home.php?mod=magic&amp;action=mybox&amp;infloat=yes"', 'action="home.php?mod=spacecp"');
      expect(() => parseMagicForm(html), throwsFormatException);
    });
  });

  group('results', () {
    test('the plugin results are read by ok and alert, with or without a language key', () {
      final bought = parseMagicResult(_json('buy_ok.json'));
      expect(bought.kind, MagicResultKind.succeeded);
      expect(bought.message, '您用 1 天使币 购买了 1 张猫娘卡');
      final short = parseMagicResult(_json('buy_credit_short.json'));
      expect(short.kind, MagicResultKind.rejected);
      expect(short.message, contains('天使币'));
      expect(parseMagicResult(_json('use_ok.json')).kind, MagicResultKind.succeeded, reason: 'no message_key');
      expect(parseMagicResult(_json('use_sofa_ok.json')).kind, MagicResultKind.succeeded);
      final missing = parseMagicResult(_json('use_user_missing.json'));
      expect(missing.kind, MagicResultKind.rejected);
      expect(missing.message, startsWith('找不到这个用户'));
    });

    test('without the plugin the forum handlers are read', () {
      final bought = parseMagicResult(_fixture('raw_buy_ok.xml'));
      expect(bought.kind, MagicResultKind.succeeded);
      expect(bought.message, '您用 2 天使币 购买了 2 张猫娘卡');
      expect(parseMagicResult(_fixture('raw_buy_fail.xml')).kind, MagicResultKind.rejected);
      expect(parseMagicResult(_fixture('raw_use_ok.xml')).kind, MagicResultKind.succeeded);
      final fail = parseMagicResult(_fixture('raw_use_fail.xml'));
      expect(fail.kind, MagicResultKind.rejected);
      expect(fail.message, startsWith('找不到这个用户'));
      expect(parseMagicResult('').kind, MagicResultKind.unknown);
      expect(parseMagicResult('<html><body>502</body></html>').kind, MagicResultKind.unknown);
    });

    test('a pasted thread link gives its tid', () {
      expect(magicThreadIdOf(' 1000 '), '1000');
      expect(magicThreadIdOf('https://forum.test/forum.php?mod=viewthread&tid=1234&page=2'), '1234');
      expect(magicThreadIdOf('https://forum.test/thread-5678-1-1.html'), '5678');
    });
  });
}
