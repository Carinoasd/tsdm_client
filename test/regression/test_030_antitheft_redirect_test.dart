import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/antitheft_interceptor.dart';

/// The antitheft challenge may only send the client back to the forum, over https.
void main() {
  test('https urls on the forum hosts are allowed', () {
    for (final ok in [
      'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1&_dsign=0123abcd',
      'https://tsdm39.com/forum.php?mod=viewthread&tid=1',
      'https://WWW.TSDM39.COM/forum.php?mod=redirect&goto=findpost&pid=2',
    ]) {
      expect(AntitheftInterceptor.isAllowedRedirect(Uri.parse(ok)), isTrue, reason: ok);
    }
  });

  test('other hosts, plain http and other schemes are refused', () {
    for (final bad in [
      'http://www.tsdm39.com/forum.php?mod=viewthread&tid=1',
      'https://evil.example/forum.php?mod=viewthread&tid=1',
      'https://www.tsdm39.com.evil.example/forum.php',
      'https://www.tsdm39.com@evil.example/forum.php',
      'ftp://www.tsdm39.com/forum.php',
      'javascript:alert(1)',
      'forum.php?mod=viewthread&tid=1',
    ]) {
      expect(AntitheftInterceptor.isAllowedRedirect(Uri.parse(bad)), isFalse, reason: bad);
    }
  });
}
