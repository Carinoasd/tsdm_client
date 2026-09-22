import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/instance.dart';

// Synthetic fixture grounded in upstream spacecp_privacy.php: one form repeats the same
// privacy2submit button under each group of filters. No real account data or formhash.
const _privacy = '''
<html><body><div id="um"><strong class="vwmy"><a href="home.php?mod=space&amp;uid=10">Owner</a></strong></div>
<form method="post" action="home.php?mod=spacecp&amp;ac=privacy&amp;op=filter">
<input type="hidden" name="formhash" value="synthetic-token">
<input type="checkbox" name="privacy[filter_gid][2]" value="2" checked>
<button type="submit" name="privacy2submit" value="true">Save</button>
<input type="checkbox" name="privacy[filter_icon][blog|20]" value="1" checked>
<button type="submit" name="privacy2submit" value="true">Save</button>
<label><input type="checkbox" name="privacy[filter_note][post|20]" value="1" checked>Reply 20</label>
<label><input type="checkbox" name="privacy[filter_note][friend|30]" value="1" checked>Friend 30</label>
<button type="submit" name="privacy2submit" value="true">Save</button>
</form></body></html>
''';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('real privacy form pattern with repeated identical Save buttons remains usable', () {
    final form = parsePrivacyFilterPage(_privacy, expectedUid: 10);
    expect(form.noteRules.length, 2);
    final body = Uri.splitQueryString(form.encode(removeKey: 'post|20'));
    expect(body['privacy2submit'], 'true');
    expect(body.containsKey('privacy[filter_note][post|20]'), isFalse);
    expect(body['privacy[filter_note][friend|30]'], '1');
    expect(body['privacy[filter_icon][blog|20]'], '1');
    expect(body['privacy[filter_gid][2]'], '2');
  });

  test('system notice author zero is a valid type-wide ignore target', () {
    final target = NoticeIgnoreTarget.tryParse('home.php?mod=spacecp&ac=common&op=ignore&type=system&authorid=0');
    expect(target, isNotNull);
    expect(target?.authorId, 0);
  });

  test('form action cannot redirect authenticated writes to nondefault port', () {
    final uri = Uri.parse('https://$baseHost:8443/home.php?mod=spacecp&ac=privacy&op=filter');
    expect(isForumOperationUrl(uri, {'mod': 'spacecp', 'ac': 'privacy', 'op': 'filter'}), isFalse);
  });
}
