import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/antitheft/antitheft_decoder.dart';

/// Test decoding the Discuz! antitheft challenge pages.
///
/// Samples in `test/data/antitheft/` are real challenge responses captured from the forum,
/// each one only keeps the `<script>` tag. `expected.txt` records the url each sample
/// redirects to, verified by running the scripts in a real javascript engine.
void main() {
  final dir = Directory('test/data/antitheft');
  final expected = <String, String>{};
  for (final line in File('${dir.path}/expected.txt').readAsLinesSync()) {
    final parts = line.split(' ');
    if (parts.length == 2) {
      expected[parts[0]] = parts[1];
    }
  }

  test('samples are loaded', () {
    expect(expected.length, greaterThanOrEqualTo(40));
  });

  for (final entry in expected.entries) {
    test('decode challenge for tid ${entry.key}', () {
      final html = File('${dir.path}/${entry.key}.html').readAsStringSync();
      expect(AntitheftDecoder.isChallenge(html), isTrue);
      final result = AntitheftDecoder.decode(html);
      expect(result, isNotNull);
      expect(result!.redirectUrl, entry.value);
      expect(result.dsign, RegExp('_dsign=([0-9a-f]{8})').firstMatch(entry.value)!.group(1));
    });
  }

  test('normal page is not challenge', () {
    expect(AntitheftDecoder.isChallenge('<html><body>hello</body></html>'), isFalse);
    expect(AntitheftDecoder.isChallenge(null), isFalse);
    expect(AntitheftDecoder.decode('<html></html>'), isNull);
  });
}
