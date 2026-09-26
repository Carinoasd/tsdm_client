/// Issue #123: parsing the secondary title shop and validating its purchase forms.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/title_shop_fixtures.dart';

TitleShopCatalog _parse(String html) => parseTitleShop(parseHtmlDocument(html));

void main() {
  test('the shop page yields intro, balance line, rows, statuses and one pager', () {
    final page = _parse(
      shopPage([
        buyRow(9001, '虚构作品-甲', '3800'),
        ownedRow(9002, '虚构作品-乙', '4500'),
        buyRow(9003, '虚构作品-丙 & <丁>', '4294967295'),
        buyRow(9001, '虚构作品-甲', '3800'),
      ]),
    );
    expect(page.supported, isTrue);
    expect(page.heading, '称号商店');
    expect(page.intro, [shopIntro], reason: 'server rules are shown verbatim, nothing invented');
    expect(page.balance, '天使币：12345');
    expect(page.items.map((i) => i.id), [9001, 9002, 9003], reason: 'a repeated row is listed once');
    expect(page.page, 1);
    expect(page.previousUrl, isNull);
    expect(page.nextUrl, '$titleShopUrl&buyitem=0&page=2', reason: 'the pager above and below is read once');

    final buy = page.items.first;
    expect(buy.status, TitleShopStatus.purchasable);
    expect(buy.price, '3800');
    expect(buy.imageUrl, Uri.parse('https://img.tsdm39.com/img01/title/虚构作品-甲.gif').toString());
    expect(buy.form!.url, titleBuyUrl);
    expect(buy.form!.confirmText, shopConfirm('3800'));
    expect(buy.form!.body(), {
      'formhash': 'TEST_HASH',
      'tsdmtitle_return': 'plugin.php?id=tsdmtitle:tsdmtitle&action=shop&app=plugin',
      'buyid': '9001',
      'buysubmit': 'true',
    });

    final owned = page.items[1];
    expect(owned.status, TitleShopStatus.owned);
    expect(owned.form, isNull);
    expect(owned.statusText, '已拥有');

    final large = page.items[2];
    expect(large.name, '虚构作品-丙 & <丁>');
    expect(large.price, '4294967295', reason: 'kept as served, never overflowed or treated as a sentinel');
    expect(large.status, TitleShopStatus.purchasable);
  });

  test('a page in the middle links both ways', () {
    final page = _parse(shopPage([buyRow(9001, '甲', '1')], page: 3));
    expect(page.page, 3);
    expect(page.previousUrl, '$titleShopUrl&buyitem=0&page=2');
    expect(page.nextUrl, '$titleShopUrl&buyitem=0&page=4');
    expect(_parse(shopPage([buyRow(9001, '甲', '1')], page: 7)).nextUrl, isNull);
  });

  test('tampered or unknown purchase forms never become a purchase', () {
    for (final (reason, row) in [
      (
        'foreign origin',
        buyRow(1, 'x', '1', action: 'https://evil.example/plugin.php?id=tsdmtitle:tsdmtitle&amp;action=buy'),
      ),
      ('other plugin', buyRow(1, 'x', '1', action: 'plugin.php?id=other:other&amp;action=buy')),
      (
        'extra query parameter',
        buyRow(1, 'x', '1', action: 'plugin.php?id=tsdmtitle:tsdmtitle&amp;action=buy&amp;buyid=2'),
      ),
      ('other action', buyRow(1, 'x', '1', action: 'plugin.php?id=tsdmtitle:tsdmtitle&amp;action=settitle')),
      ('GET form', buyRow(1, 'x', '1', method: 'get')),
      ('missing token', buyRow(1, 'x', '1', formHash: '')),
      ('id of another row', buyRow(1, 'x', '1', buyId: '2')),
      ('non-numeric id', buyRow(1, 'x', '1', buyId: '1 OR 1')),
      ('return leaves the shop', buyRow(1, 'x', '1', returnPath: 'home.php?mod=spacecp')),
      (
        'return to foreign site',
        buyRow(1, 'x', '1', returnPath: 'https://evil.example/plugin.php?id=tsdmtitle:tsdmtitle&amp;action=shop'),
      ),
      ('unknown hidden field', buyRow(1, 'x', '1', extra: '<input type="hidden" name="amount" value="9"/>')),
      ('visible input', buyRow(1, 'x', '1', extra: '<input type="text" name="note"/>')),
      ('duplicated field', buyRow(1, 'x', '1', extra: '<input type="hidden" name="buyid" value="1"/>')),
      ('missing submit', buyRow(1, 'x', '1', button: '')),
      ('different submit', buyRow(1, 'x', '1', button: '<button name="other" type="submit" value="true">x</button>')),
    ]) {
      final item = _parse(shopPage([row])).items.single;
      expect(item.form, isNull, reason: reason);
      expect(item.status, TitleShopStatus.unavailable, reason: reason);
    }
  });

  for (final (reason, row) in [
    (
      'disabled submit button',
      buyRow(9001, '甲', '3800', button: '<button name="buysubmit" type="submit" value="true" disabled>余额不足</button>'),
    ),
    (
      'non-submit button',
      buyRow(9001, '甲', '3800', button: '<button name="buysubmit" type="button" value="true">请先完成验证</button>'),
    ),
    (
      'disabled hidden field',
      buyRow(9001, '甲', '3800').replaceFirst('name="buyid"', 'disabled name="buyid"'),
    ),
  ]) {
    test('server $reason does not become an enabled purchase', () {
      final item = _parse(shopPage([row])).items.single;
      expect(item.status, TitleShopStatus.unavailable);
      expect(item.form, isNull);
    });
  }

  test('rows missing an id, name or numeric price are skipped rather than guessed', () {
    final page = _parse(
      shopPage([
        '<tr><td>abc</td><td>名</td><td>1</td><td></td><td>已拥有</td></tr>',
        '<tr><td>5</td><td></td><td>1</td><td></td><td>已拥有</td></tr>',
        '<tr><td>6</td><td>名</td><td>一千</td><td></td><td>已拥有</td></tr>',
        '<tr><td>7</td><td>名</td><td>1</td><td>已拥有</td></tr>',
        '<tr><td>8</td><td>名</td><td>1</td><td><img src="javascript:alert(1)"></td><td>已下架</td></tr>',
      ]),
    );
    expect(page.items.map((i) => i.id), [8]);
    expect(page.items.single.imageUrl, isNull);
    expect(page.items.single.status, TitleShopStatus.unavailable);
    expect(page.items.single.statusText, '已下架', reason: 'server wording is shown as is');
  });

  test('a page without the known table is unsupported and keeps the forum message', () {
    final page = _parse(messagePage('抱歉，您尚未登录，无法进行此操作'));
    expect(page.supported, isFalse);
    expect(page.message, '抱歉，您尚未登录，无法进行此操作');
    final other = _parse(
      '<table class="dt"><thead><tr><th>ID</th><th>名称</th></tr></thead><tbody><tr><td>1</td><td>x</td></tr></tbody></table>',
    );
    expect(other.supported, isFalse);
  });

  test('only shop pages are fetched; purchase URLs and unknown parameters are refused', () {
    expect(titleShopPageUrl('plugin.php?id=tsdmtitle:tsdmtitle&action=shop'), titleShopUrl);
    expect(
      titleShopPageUrl('plugin.php?id=tsdmtitle:tsdmtitle&action=shop&buyitem=0&page=2'),
      '$titleShopUrl&buyitem=0&page=2',
    );
    for (final href in [
      'plugin.php?id=tsdmtitle:tsdmtitle&action=buy',
      'plugin.php?id=tsdmtitle:tsdmtitle&action=buy&buyid=1&buysubmit=true',
      'plugin.php?id=tsdmtitle:tsdmtitle&action=shop&buyitem=5',
      'plugin.php?id=tsdmtitle:tsdmtitle&action=shop&page=0',
      'plugin.php?id=tsdmtitle:tsdmtitle&action=shop&page=2&page=3',
      'plugin.php?id=tsdmtitle:tsdmtitle&action=shop&formhash=x',
      'plugin.php?id=tsdmtitle:tsdmtitle&action=settitle',
      'https://evil.example/plugin.php?id=tsdmtitle:tsdmtitle&action=shop',
    ]) {
      expect(titleShopPageUrl(href), isNull, reason: href);
    }
  });

  test('purchase answers are quoted, never read as success', () {
    final refused = parseTitleBuyResponse(parseHtmlDocument(messagePage('您的天使币不足', error: true)));
    expect(refused.error, isTrue);
    expect(refused.message, '您的天使币不足', reason: 'redirect script and fallback link removed');
    final message = parseTitleBuyResponse(parseHtmlDocument(messagePage('操作完成')));
    expect(message.error, isFalse);
    expect(message.message, '操作完成');
    final unknown = parseTitleBuyResponse(parseHtmlDocument(shopPage([])));
    expect(unknown.error, isFalse);
    expect(unknown.message, isNull);
  });
}
