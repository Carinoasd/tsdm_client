import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/extensions/uri.dart';

void main() {
  group('isForumHost 域名支持回归测试', () {
    test('支持 www.tsdm39.com', () {
      final uri = Uri.parse('https://www.tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(isForumHost(uri), isTrue);
    });

    test('支持不带 www 的 tsdm39.com', () {
      final uri = Uri.parse('https://tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(isForumHost(uri), isTrue);
    });

    test('拒绝不受支持的 www.tsdm39.net', () {
      final uri = Uri.parse('https://www.tsdm39.net/forum.php?mod=viewthread&tid=123');
      expect(isForumHost(uri), isFalse);
    });
  });
}
