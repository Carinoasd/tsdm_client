/// A download link of another app (`thunder://`, `ed2k://`) was handed over as the app's parsed [Uri] wrote it back:
/// the host in small letters and what a host may not hold percent-encoded. `thunder://` carries base64 (its case
/// matters) where the host goes and `ed2k://|file|Name.mkv|…|/` its fields: neither opened in the download app. Now a
/// link of another scheme than the web's is handed over as written ([externalLaunchTarget]); the scheme is still
/// checked on the parsed form ([mayLaunchExternally]), and a web page is handed over as before.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/external_launch.dart';

const _thunder = 'thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vQS5aaXBaWg==';
const _ed2k = 'ed2k://|file|My.File.MKV|123|ABCDEF0123456789ABCDEF0123456789|/';
const _magnet = 'magnet:?xt=urn:btih:ABCDEF0123&dn=Name';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  test('the parsed form changes them', () {
    expect('${Uri.parse(_thunder)}', isNot(_thunder));
    expect('${Uri.parse(_ed2k)}', isNot(_ed2k));
  });

  test('a link of another scheme is handed over as written', () {
    for (final link in [_thunder, _ed2k, _magnet, 'THUNDER://QUFodHRw', 'qqdl://AbCd==']) {
      expect(externalLaunchTarget(Uri.parse(link), link), link, reason: link);
      expect(externalLaunchTarget(Uri.parse(link), '  $link\n'), link, reason: 'trimmed: $link');
    }
  });

  test('a web page as parsed, as before; anything that is not the same link as parsed', () {
    const web = 'https://Example.COM/a b';
    expect(externalLaunchTarget(Uri.parse(web), web), '${Uri.parse(web)}');
    expect(externalLaunchTarget(Uri.parse(_thunder), null), '${Uri.parse(_thunder)}');
    // Another scheme than the one checked.
    expect(externalLaunchTarget(Uri.parse(_thunder), 'file:///etc/hosts'), '${Uri.parse(_thunder)}');
    // A control character.
    expect(externalLaunchTarget(Uri.parse(_thunder), 'thunder://a\u0000b'), '${Uri.parse(_thunder)}');
  });

  group('what reaches the platform', () {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> launched;
    setUp(() {
      launched = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map)['url'] as String);
        }
        return true;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the link as written, its scheme checked', () async {
      for (final link in [_thunder, _ed2k, _magnet]) {
        expect(await launchExternalUrl(Uri.parse(link), original: link), isTrue);
      }
      expect(launched, [_thunder, _ed2k, _magnet]);
      // A scheme that is never handed over stays so, written as it may be.
      expect(await launchExternalUrl(Uri.parse('file:///etc/hosts'), original: 'file:///etc/hosts'), isFalse);
      expect(launched, hasLength(3));
    });
  });

  test('a tap on a link and a link followed in the in-app browser hand over the link as written', () {
    final dispatch = File('lib/extensions/build_context.dart').readAsStringSync();
    expect(RegExp(r'launchExternalUrl\(absoluteForumUri\(u\), original: url\)').allMatches(dispatch), hasLength(2));
    final browser = File('lib/features/in_app_browser/view/in_app_browser_page.dart').readAsStringSync();
    expect(browser, contains('_launchOtherApp(controller, uri, original: url.rawValue)'));
    expect(browser, contains('launchExternalUrl(uri, appSchemes: isAndroid || isIOS, original: original)'));
  });
}
