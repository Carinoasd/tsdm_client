import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/extensions/uri.dart';

void main() {
  group('isForumHost 域名支持回归测试', () {
    test('支持 https://www.tsdm39.com', () {
      final uri = Uri.parse('https://www.tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(uri.isForumHost, isTrue);
    });

    test('支持不带 www 的 https://tsdm39.com', () {
      final uri = Uri.parse('https://tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(uri.isForumHost, isTrue);
    });

    test('支持 http 协议的论坛域名', () {
      final uri = Uri.parse('http://www.tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(uri.isForumHost, isTrue);
    });

    test('拒绝不受支持的 https://www.tsdm39.net', () {
      final uri = Uri.parse('https://www.tsdm39.net/forum.php?mod=viewthread&tid=123');
      expect(uri.isForumHost, isFalse);
    });

    test('拒绝其他外站域名', () {
      final uri = Uri.parse('https://example.com/forum.php?mod=viewthread&tid=123');
      expect(uri.isForumHost, isFalse);
    });
  });
}
