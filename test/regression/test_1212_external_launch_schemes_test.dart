/// Which links may be handed to another app ([mayLaunchExternally]): web pages, mail and the schemes the forum takes
/// in `[url]`; never local files, scripts or the handlers of the system. The in-app browser on a phone also hands over
/// the links of apps (`weixin://`, `market://`), but not those. How `dispatchAsUrl` uses it is in test_700.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/external_launch.dart';

void main() {
  bool may(String url, {bool appSchemes = false}) => mayLaunchExternally(Uri.parse(url), appSchemes: appSchemes);

  test('web pages, mail and the forum schemes', () {
    for (final url in [
      'https://example.com/',
      'HTTP://example.com/',
      'mailto:a@b.c',
      'magnet:?xt=urn:btih:0123',
      'ed2k://file',
      'thunder://QUFodHRw',
      'ftp://example.com/a.zip',
      'tel:123',
      'rtsp://example.com/a',
      'mms://example.com/a',
      'qqdl://x',
    ]) {
      expect(may(url), isTrue, reason: url);
      expect(may(url, appSchemes: true), isTrue, reason: url);
    }
  });

  test('files, scripts, the handlers of the system and anything else', () {
    for (final url in [
      'file:///etc/hosts',
      'FILE:///etc/hosts',
      'content://x/y',
      'intent://x#Intent;end',
      'javascript:alert(1)',
      'vbscript:x',
      'data:text/html,x',
      'blob:https://example.com/x',
      'about:blank',
      'smb://server/share',
      'ms-msdt:/id',
      'MS-SETTINGS:privacy',
      'search-ms:query=x',
      'shell:startup',
      'jar:file:///a.jar!/x',
    ]) {
      expect(may(url), isFalse, reason: url);
      expect(may(url, appSchemes: true), isFalse, reason: url);
    }
    // An app's link: only where the in-app browser hands those over.
    expect(may('weixin://dl/x'), isFalse);
    expect(may('weixin://dl/x', appSchemes: true), isTrue);
    expect(may('market://details?id=x', appSchemes: true), isTrue);
    // No scheme: a link of the forum, never another app's.
    expect(may('forum.php?mod=viewthread&tid=1'), isFalse);
  });
}
