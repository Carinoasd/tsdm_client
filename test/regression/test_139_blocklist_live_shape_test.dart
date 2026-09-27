import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';

// Synthetic identities and tokens in the DOM structure observed read-only on the forum.
const _query = '''<form id="bu_qform" method="get" action="home.php">
<input type="hidden" name="mod" value="spacecp"><input type="hidden" name="ac" value="plugin">
<input type="hidden" name="id" value="blockuser:spacecp"><input name="bu_q" id="bu_q">
<button type="submit" id="bu_qbtn">查詢</button></form>''';
const _action = 'home.php?mod=spacecp&amp;ac=plugin&amp;id=blockuser:spacecp';
String _page({String rows = '', String confirmation = '', int used = 0}) =>
    '''<!doctype html><html><body>
<div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=1000">SyntheticOwner</a></strong></div>
<div id="ct"><div id="bu_page" class="bu-page">
<div id="bu_quota">已屏蔽 $used／10 人</div>$_query
<table id="bu_list"><thead><tr><th>會員</th><th>加入時間</th><th>操作</th></tr></thead><tbody>$rows</tbody></table>
$confirmation</div></div></body></html>''';
const _removeRow =
    '''<tr id="bu_row_2001"><td><span class="bu-name"><a href="home.php?mod=space&amp;uid=2001">SyntheticTarget</a></span><span class="bu-uid">UID 2001</span></td><td>2026-09-27</td><td>
<form class="bu-delform" method="post" action="$_action"><input type="hidden" name="formhash" value="synthetic-token"><input type="hidden" name="blockuserdel" value="synthetic-remove"><input type="hidden" name="buid" value="2001"><button type="submit">解除</button></form></td></tr>''';
const _confirm =
    '''<div id="bu_confirm"><div class="bu-member"><span class="bu-name"><b id="bu_confirmname">SyntheticTarget</b></span><span class="bu-uid">UID 2001</span></div>
<form id="bu_addform" method="post" action="$_action"><input type="hidden" name="formhash" value="synthetic-token"><input type="hidden" name="blockuseradd" value="synthetic-add"><input type="hidden" name="buid" value="2001"><button id="bu_addbtn" type="submit">確定屏蔽</button></form></div>''';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('observed GET form and full-width quota identify a genuinely empty list', () {
    final page = parseWebsiteBlocklistDocument(_page(), expectedUid: 1000);
    expect(page.list.rows, isEmpty);
    expect(page.list.quota?.used, 0);
    expect(page.list.quota?.limit, 10);
    expect(page.list.complete, isTrue);
  });
  test('observed remove form preserves plugin-specific operation flag', () {
    final page = parseWebsiteBlocklistDocument(_page(rows: _removeRow, used: 1), expectedUid: 1000);
    expect(page.list.rows.single.removable, isTrue);
    expect(page.removePayload(2001), {
      'formhash': 'synthetic-token',
      'blockuserdel': 'synthetic-remove',
      'buid': '2001',
    });
  });
  test('observed lookup b and UID span resolve member without a profile link', () {
    final page = parseWebsiteBlocklistDocument(_page(confirmation: _confirm), expectedUid: 1000, lookupUid: 2001);
    expect(page.lookup?.uid, 2001);
    expect(page.lookup?.username, 'SyntheticTarget');
    expect(page.lookup?.canAdd, isTrue);
    expect(page.addPayload(2001), {'formhash': 'synthetic-token', 'blockuseradd': 'synthetic-add', 'buid': '2001'});
  });
  test('missing list container is not evidence of a complete empty list', () {
    final missing = _page().replaceAll(RegExp(r'<table id="bu_list">.*?</table>', dotAll: true), '');
    expect(() => parseWebsiteBlocklistDocument(missing, expectedUid: 1000), throwsA(anything));
  });
  test('profile URL input rejects ambiguous or non-decimal UID values consistently', () {
    for (final input in [
      '2147483648',
      'https://www.tsdm39.com/home.php?mod=space&uid=2147483648',
      'https://www.tsdm39.com/home.php?mod=space&uid=0x7d1',
      'https://www.tsdm39.com/home.php?mod=space&uid=2001&uid=2002',
      'https://www.tsdm39.com/home.php?mod=space&mod=spacecp&uid=2001',
    ]) {
      expect(parseWebsiteBlocklistTarget(input), isNull, reason: input);
    }
  });
}
