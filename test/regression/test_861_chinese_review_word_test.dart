import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';

void main() {
  final s2t = ChineseConverter.parse(File('assets/text/opencc/s2t.txt').readAsStringSync());

  test('audit and check words keep the character 核', () {
    expect(s2t.convert('审核通过'), '審核通過');
    expect(s2t.convert('考核'), '考核');
    expect(s2t.convert('复核'), '複核');
    expect(s2t.convert('核实'), '核實');
    expect(s2t.convert('核对表'), '核對表');
  });

  test('the dictionary never writes 覈', () {
    expect(File('assets/text/opencc/s2t.txt').readAsStringSync().contains('覈'), isFalse);
  });
}
