/// The title bar of the in-app browser showed the title of the page: a page can call itself anything, the forum's
/// name too, and look like the forum signed in. Now it shows the host the page is served from ([browserTitleOf]),
/// with the scheme before it when that is not https; the page's title is not shown.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/in_app_browser/utils/link_routing.dart';

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

  test('the page shows no title of the page', () {
    final page = File('lib/features/in_app_browser/view/in_app_browser_page.dart').readAsStringSync();
    expect(page, contains('browserTitleOf(_url)'));
    expect(page, isNot(contains('onTitleChanged')));
  });
}
