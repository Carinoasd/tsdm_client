/// The warnings of a member, read from the forum's warning window (`forum.php?mod=misc&action=viewwarning`, the
/// floor's warned mark of the web page): the forum's app API answers no JSON there (the page comes back as it is), so
/// the ajax window is read: one row a warning (who, when, the reason), the head row left out, the moderator's link
/// where the forum shows the moderators (`moduser_public` 1) and its words for the staff otherwise (管理团队), the line
/// under the list; the forum's message in place of the list (no warning, no such member) is its refusal, without the
/// error hook's script.
///
/// The answers are the test forum's (scrubbed: the forum's name).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/moderate/models/warning_log.dart';

String _raw(String name) => File('test/data/warning_log/$name.xml').readAsStringSync();

WarningLog _shown(String raw) => switch (parseWarningLog(raw)) {
  WarningLogShown(:final log) => log,
  final other => throw StateError('not a list: $other'),
};

void main() {
  group('warning window', () {
    test('the staff named by the forum, the rows in order, the line under them', () {
      final log = _shown(_raw('staff'));
      expect(log.records, hasLength(2));
      expect(log.records.map((e) => e.operator), ['管理团队', '管理团队']);
      expect(log.records.map((e) => e.operatorUid), [null, null]);
      expect(log.records.map((e) => e.time), ['2026-9-12 04:42', '2026-9-12 08:20']);
      expect(log.records.map((e) => e.reason), ['BU區警告46626', 'notify 警告理由（warn_1789171425534）']);
      expect(log.summary, 'ag_low 已被累计警告 2 次，30 天内累计被警告 3 次，将被自动禁止发帖 30 天');
    });

    test('the moderators linked where the forum shows them', () {
      final log = _shown(_raw('moderators'));
      expect(log.records.map((e) => e.operator), ['ag_mid', 'ag_admin']);
      expect(log.records.map((e) => e.operatorUid), [33, 32]);
    });

    test('the window as the page opens it (infloat) reads the same', () {
      final log = _shown(_raw('staff_float'));
      expect(log.records.map((e) => e.reason), ['BU區警告46626', 'notify 警告理由（warn_1789171425534）']);
      expect(log.summary, startsWith('ag_low 已被累计警告 2 次'));
    });

    test("the line under the list is the window's own, not another on the page", () {
      final raw = _raw('staff').replaceFirst('<div class="f_c">', '<div class="o">其他</div>\n<div class="f_c">');
      expect(_shown(raw).summary, startsWith('ag_low 已被累计警告 2 次'));
      final none = _raw('staff').replaceFirst(RegExp('<div class="o pns">.*?</div>', dotAll: true), '');
      expect(_shown(none).summary, isEmpty);
    });

    test('an empty reason stays empty', () {
      final raw = _raw('staff').replaceFirst('<td>BU區警告46626</td>', '<td></td>');
      expect(_shown(raw).records.first.reason, '');
    });

    test("the forum's message is its refusal, without the error hook's script", () {
      expect(
        parseWarningLog(_raw('no_warning')),
        isA<WarningLogRefused>().having((e) => e.message, 'message', '抱歉，指定帖子没有警告记录'),
      );
      const page =
          '<html><body><div id="messagetext" class="alert_error"><p>抱歉，您没有权限访问该版块</p> '
          '<script type="text/javascript">if(history.length > 1) {}</script></div></body></html>';
      expect(
        parseWarningLog(page),
        isA<WarningLogRefused>().having((e) => e.message, 'message', '抱歉，您没有权限访问该版块'),
      );
    });

    test('anything else is not read', () {
      expect(parseWarningLog('<?xml version="1.0"?><root><![CDATA[]]></root>'), isNull);
      expect(parseWarningLog('<html><body><p>x</p></body></html>'), isNull);
    });

    test('the url of the window: the thread and the member, as an ajax window', () {
      expect(
        warningLogUrl(tid: 9199072, uid: 31),
        '$baseUrl/forum.php?mod=misc&action=viewwarning&tid=9199072&uid=31&inajax=1',
      );
      expect(warningLogUrl(tid: 0, uid: 31), isNull);
      expect(warningLogUrl(tid: 9199072, uid: 0), isNull);
    });
  });
}
