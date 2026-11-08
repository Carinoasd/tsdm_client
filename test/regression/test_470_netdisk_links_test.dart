// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/netdisk/models/netdisk_link.dart';
import 'package:tsdm_client/features/netdisk/utils/netdisk_parser.dart';
import 'package:tsdm_client/features/netdisk/widgets/netdisk_row.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:universal_html/parsing.dart';

/// Online storage links of a post: the service, the extract code and the archive password written near the link.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('provider table', () {
    const cases = <String, String>{
      'https://pan.baidu.com/s/1AbCdEfG': '百度网盘',
      'https://pan.baidu.com/s/1AbCdEfG?pwd=ab12': '百度网盘',
      'https://www.lanzou.com/iAbc': '蓝奏云',
      'https://tsdm.lanzoux.com/iAbc': '蓝奏云',
      'https://wwx.lanzn.com/iAbc': '蓝奏云',
      'https://pan.quark.cn/s/abcdef': '夸克网盘',
      'https://www.aliyundrive.com/s/abc': '阿里云盘',
      'https://www.alipan.com/s/abc': '阿里云盘',
      'https://www.123pan.com/s/abc-def': '123云盘',
      'https://115.com/s/swabc': '115网盘',
      'https://u.ctfile.com/f/123-456-abc': '城通网盘',
      'https://cloud.189.cn/t/AbCdEf': '天翼云盘',
      'https://pan.xunlei.com/s/VOabc': '迅雷云盘',
      'https://mega.nz/file/abc#key': 'Mega',
      'https://drive.google.com/file/d/abc/view': 'Google Drive',
      'https://1drv.ms/u/s!abc': 'OneDrive',
      'https://www.mediafire.com/file/abc/x.zip': 'MediaFire',
    };
    for (final entry in cases.entries) {
      test('${entry.key} is ${entry.value}', () {
        expect(netdiskProviderOf(entry.key)?.name, entry.value);
        final links = parseNetdiskLinks('下载 ${entry.key} 完');
        expect(links.single.provider.name, entry.value);
        expect(links.single.url, entry.key);
      });
    }

    test('other hosts and look-alikes are no online storage', () {
      expect(netdiskProviderOf('https://example.com/s/abc'), isNull);
      expect(netdiskProviderOf('https://notpan.baidu.com.evil.test/s/abc'), isNull);
      expect(netdiskProviderOf('https://evilmega.nz.test/x'), isNull);
      expect(parseNetdiskLinks('https://example.com/ 提取码：abcd'), isEmpty);
    });
  });

  group('codes near a link', () {
    ({String? extract, String? unzip}) codes(String text, {int index = 0}) {
      final l = parseNetdiskLinks(text)[index];
      return (extract: l.extractCode, unzip: l.unzipPassword);
    }

    const url = 'https://pan.baidu.com/s/1AbCdEfG';
    const labels = <String, String>{
      '提取码：abcd': 'abcd',
      '提取码:abcd': 'abcd',
      '提取码 abcd': 'abcd',
      '提取码=abcd': 'abcd',
      '提取碼：abcd': 'abcd',
      '密码：abcd': 'abcd',
      '密碼: abcd': 'abcd',
      '访问码：a1b2': 'a1b2',
      '訪問碼：a1b2': 'a1b2',
      '提取密码：a1b2': 'a1b2',
      'pwd：abcd': 'abcd',
      'PWD=abcd': 'abcd',
      'password: abcd': 'abcd',
      'Extract Code: abcd': 'abcd',
    };
    for (final entry in labels.entries) {
      test('after the link: ${entry.key}', () {
        expect(codes('$url ${entry.key}').extract, entry.value);
      });
    }

    test('the code before the link', () {
      expect(codes('提取码：abcd $url').extract, 'abcd');
    });

    test('the code on the next line', () {
      expect(codes('$url\n提取码：abcd\n\n解压密码：tsdm').extract, 'abcd');
    });

    test('the code ends where the text turns Chinese', () {
      expect(codes('$url 提取码：abcd解压密码：xyz').extract, 'abcd');
    });

    const unzipLabels = <String>['解压密码', '解壓密碼', '解压码', '解壓碼', '压缩包密码', 'unzip password'];
    for (final label in unzipLabels) {
      test('archive password: $label', () {
        final c = codes('$url 提取码：abcd $label：tsdm@2026');
        expect(c.extract, 'abcd');
        expect(c.unzip, 'tsdm@2026');
      });
    }

    test('an archive password is not read as the extract code, nor the other way round', () {
      final c = codes('$url 解压密码：Tsdm01');
      expect(c.extract, isNull);
      expect(c.unzip, 'Tsdm01');
    });

    test('"none" is no archive password', () {
      expect(codes('$url 提取码：abcd 解压密码：无').unzip, isNull);
    });

    test('the pwd of the url is the extract code, a written one wins', () {
      expect(codes('https://pan.baidu.com/s/1AbCdEfG?pwd=zz99').extract, 'zz99');
      expect(codes('https://pan.baidu.com/s/1AbCdEfG?pwd=zz99 提取码：abcd').extract, 'abcd');
    });

    test('no code, nothing made up', () {
      final c = codes('$url 无需提取码');
      expect(c.extract, isNull);
      expect(c.unzip, isNull);
    });

    test('too far away is not near', () {
      final text = '$url ${'一' * 260} 提取码：abcd';
      expect(codes(text).extract, isNull);
    });

    test('several links each take the codes next to them', () {
      const text =
          '百度：https://pan.baidu.com/s/1AAA 提取码：aaaa 解压密码：one\n'
          '夸克：https://pan.quark.cn/s/bbb 提取码：bbbb\n'
          '蓝奏：https://tsdm.lanzoux.com/iccc 密码：cccc\n'
          'Mega：https://mega.nz/file/ddd#key';
      final links = parseNetdiskLinks(text);
      expect(links.map((l) => l.extractCode), ['aaaa', 'bbbb', 'cccc', null]);
      expect(links.map((l) => l.unzipPassword), ['one', null, null, null]);
    });

    test('codes written before each link', () {
      const text = '提取码：aaaa https://pan.baidu.com/s/1AAA\n\n提取码：bbbb https://pan.quark.cn/s/bbb';
      expect(parseNetdiskLinks(text).map((l) => l.extractCode), ['aaaa', 'bbbb']);
    });

    test('trailing punctuation is no part of the link', () {
      expect(parseNetdiskLinks('链接（$url），提取码：abcd。').single.url, url);
    });
  });

  group('opening', () {
    NetdiskLink link(String url, {String? code}) =>
        NetdiskLink(url: url, provider: netdiskProviderOf(url)!, extractCode: code);

    test('the code goes in the url where the service takes it', () {
      final baidu = link('https://pan.baidu.com/s/1AbCdEfG', code: 'ab12');
      expect(baidu.openUrl, 'https://pan.baidu.com/s/1AbCdEfG?pwd=ab12');
      expect(baidu.needsCopyBeforeOpen, isFalse);
      expect(link('https://115.com/s/sw1', code: 'ab12').openUrl, 'https://115.com/s/sw1?password=ab12');
      expect(link('https://www.123pan.com/s/x', code: 'ab12').openUrl, 'https://www.123pan.com/s/x?pwd=ab12');
    });

    test('an url that has the code already stays as it is', () {
      final l = link('https://pan.baidu.com/s/1AbCdEfG?pwd=ab12', code: 'ab12');
      expect(l.openUrl, l.url);
      expect(l.needsCopyBeforeOpen, isFalse);
    });

    test('other services: the code is copied first', () {
      final l = link('https://pan.quark.cn/s/abc', code: 'ab12');
      expect(l.openUrl, l.url);
      expect(l.needsCopyBeforeOpen, isTrue);
      expect(link('https://pan.quark.cn/s/abc').needsCopyBeforeOpen, isFalse);
    });
  });

  group('the text of a post', () {
    String textOf(String html) => netdiskTextOf(parseHtmlDocument('<html><body>$html</body></html>').body!);

    test('a link with its own words keeps the target and the words', () {
      final text = textOf('<a href="https://pan.baidu.com/s/1AAA">点击下载</a><br>提取码：abcd');
      final l = parseNetdiskLinks(text).single;
      expect(l.url, 'https://pan.baidu.com/s/1AAA');
      expect(l.extractCode, 'abcd');
    });

    test('a link shown as its url is found once', () {
      final text = textOf('<a href="https://pan.baidu.com/s/1AAA">https://pan.baidu.com/s/1AAA</a> 提取码：abcd');
      expect(parseNetdiskLinks(text), hasLength(1));
    });

    test('paragraphs keep the codes apart', () {
      final text = textOf('<p>https://pan.baidu.com/s/1AAA</p><p>提取码：abcd</p><p>解压密码：xyz1</p>');
      final l = parseNetdiskLinks(text).single;
      expect(l.extractCode, 'abcd');
      expect(l.unzipPassword, 'xyz1');
    });
  });

  test('copied text: name, link, codes, a blank line between links', () {
    final links = parseNetdiskLinks('https://pan.baidu.com/s/1AAA 提取码：abcd 解压密码：x1\nhttps://mega.nz/file/z#k');
    expect(
      netdiskLinksToText(links, extractCodeLabel: '提取码', unzipPasswordLabel: '解压密码'),
      '百度网盘\nhttps://pan.baidu.com/s/1AAA\n提取码：abcd\n解压密码：x1\n\nMega\nhttps://mega.nz/file/z#k',
    );
  });

  group('in a post', () {
    Future<void> pump(WidgetTester tester, String html, {bool post = true}) async {
      final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
      Widget content() => Builder(builder: (context) => munchElement(context, body));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 400,
                  child: post ? PostTypographyScope(typography: const PostTypography(), child: content()) : content(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    testWidgets('every link has its own row with its codes', (tester) async {
      await pump(
        tester,
        '<div>资源：<a href="https://pan.baidu.com/s/1AAA">https://pan.baidu.com/s/1AAA</a> 提取码：abcd 解压密码：x1<br>'
        '备用 https://pan.quark.cn/s/bbb<br>其他 https://example.com/a</div>',
      );
      final rows = tester.widgetList<NetdiskRow>(find.byType(NetdiskRow)).toList();
      expect(rows.map((r) => r.link.provider.name), ['百度网盘', '夸克网盘']);
      expect(rows[0].link.extractCode, 'abcd');
      expect(rows[1].link.extractCode, isNull);
    });

    testWidgets('a row without codes is the name and the open button', (tester) async {
      await pump(tester, '<div>https://pan.quark.cn/s/bbb</div>');
      expect(find.byType(ActionChip), findsOneWidget);
      expect(find.byType(Chip), findsOneWidget);
    });

    testWidgets('a row with both codes has four chips, the codes tap to copy', (tester) async {
      await pump(tester, '<div>https://pan.baidu.com/s/1AAA 提取码：abcd 解压密码：x1</div>');
      expect(find.byType(ActionChip), findsNWidgets(3));
      expect(find.byType(Chip), findsOneWidget);
    });

    testWidgets('no rows outside a post', (tester) async {
      await pump(tester, '<div>https://pan.baidu.com/s/1AAA 提取码：abcd</div>', post: false);
      expect(find.byType(NetdiskRow), findsNothing);
    });

    testWidgets('a post without storage links has no row', (tester) async {
      await pump(tester, '<div>https://example.com/a 提取码：abcd</div>');
      expect(find.byType(NetdiskRow), findsNothing);
    });
  });
}
