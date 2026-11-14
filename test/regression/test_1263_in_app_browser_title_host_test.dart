/// The title bar of the in-app browser showed the title of the page: a page can call itself anything, the forum's
/// name too, and look like the forum signed in. Now it shows the host the page is served from ([browserTitleOf]),
/// with the scheme before it when that is not https; the page's title is not shown.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/in_app_browser/utils/link_routing.dart';
import 'package:tsdm_client/features/in_app_browser/widgets/browser_host_title.dart';

void main() {
  String title(String url) => browserTitleOf(Uri.parse(url));

  test('the host, the scheme when it is not https', () {
    expect(title('https://www.tsdm39.com/plugin.php?id=bank:loan'), 'www.tsdm39.com');
    expect(title('https://example.com/a/b?c=d#e'), 'example.com');
    expect(title('http://example.com/'), 'http://example.com');
    expect(title('HTTP://Example.COM/'), 'http://example.com');
  });

  test('what only looks like the forum is shown as the host it is', () {
    expect(title('https://www.tsdm39.com@evil.example/'), 'evil.example');
    expect(title('https://www.tsdm39.com.evil.example/forum.php'), 'www.tsdm39.com.evil.example');
    expect(title('https://user:pass@evil.example:8443/'), 'evil.example');
    // A host of other letters as the url holds it, not drawn as the letters it stands for.
    expect(title('https://xn--tsdm39-9n6b.com/'), 'xn--tsdm39-9n6b.com');
  });

  test('a page without a host: its scheme only', () {
    expect(title('data:text/html,<title>天使动漫</title>'), 'data:');
    expect(title('about:blank'), 'about:');
  });

  testWidgets('a host too long for the bar loses its start, not the domain at its end', (tester) async {
    // The test font is wide: about twenty letters fit in the bar.
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const long = 'www.tsdm39.com.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.evil.example';
    Future<String> shown(String host) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              leading: const CloseButton(),
              title: BrowserHostTitle(host),
              actions: [for (var i = 0; i < 4; i++) IconButton(onPressed: () {}, icon: const Icon(Icons.refresh))],
            ),
          ),
        ),
      );
      return tester.widget<Text>(find.descendant(of: find.byType(BrowserHostTitle), matching: find.byType(Text))).data!;
    }

    final cut = await shown(long);
    expect(cut, startsWith('…'));
    expect(cut, endsWith('.evil.example'));
    expect(cut, isNot(contains('tsdm39')));
    expect(await shown('www.tsdm39.com'), 'www.tsdm39.com');
  });

  test('the page shows no title of the page', () {
    final page = File('lib/features/in_app_browser/view/in_app_browser_page.dart').readAsStringSync();
    expect(page, contains('BrowserHostTitle(browserTitleOf(_url))'));
    expect(page, isNot(contains('onTitleChanged')));
  });
}
