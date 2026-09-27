import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/instance.dart';

import 'fixtures/post_report_fixtures.dart';

PostReportForm _form([String? raw]) => parsePostReportForm(raw ?? reportFormAjax(), target: reportTarget);

Matcher _fails(PostReportProblem problem) =>
    throwsA(isA<PostReportFailure>().having((e) => e.problem, 'problem', problem));

List<(String, String)> _without(String name) => defaultHidden.where((f) => f.$1 != name).toList();

List<(String, String)> _with(String name, String value) => [
  for (final f in defaultHidden) f.$1 == name ? (name, value) : f,
];

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('reason length as the forum counts it', () {
    test('ASCII 1, other scalars 2, emoji 2 not 4', () {
      expect(postReportReasonWeight('abc'), 3);
      expect(postReportReasonWeight('a\tb\nc'), 5);
      expect(postReportReasonWeight('违规'), 4);
      expect(postReportReasonWeight('😀'), 2);
      expect('😀'.length, 2, reason: 'UTF-16 length differs from the forum count');
      expect(postReportReasonWeight('<>&"'), 4, reason: 'escaped entities count as the visible character');
    });

    test('line breaks and PHP trim are applied before counting', () {
      expect(normalizePostReportReason(' \r\n a\r\nb\r c \t\n'), 'a\nb\n c');
      expect(normalizePostReportReason('　a'), '　a', reason: 'PHP trim keeps the ideographic space');
    });

    test('boundaries: never cut, refused over 200', () {
      final form = _form();
      final custom = form.customIndex;
      expect(form.messageFor(custom, 'a' * 200), 'a' * 200);
      expect(form.messageFor(custom, 'a' * 201), isNull);
      expect(form.messageFor(custom, '中' * 100), '中' * 100);
      expect(form.messageFor(custom, '中' * 101), isNull);
      expect(form.messageFor(custom, '${'a' * 198}中'), '${'a' * 198}中');
      expect(form.messageFor(custom, '${'a' * 199}中'), isNull);
      expect(form.messageFor(custom, '😀' * 100), '😀' * 100);
      expect(form.messageFor(custom, '😀' * 101), isNull);
      expect(form.messageFor(custom, '  ${'a' * 200}  '), 'a' * 200, reason: 'trimmed like the server');
    });

    test('cutstr entity edge: a final &, ", < or > at exactly 200 is refused, never dropped', () {
      final form = _form();
      final custom = form.customIndex;
      for (final c in ['&', '"', '<', '>']) {
        final at200 = '${'a' * 199}$c';
        expect(postReportReasonWeight(at200), 200);
        expect(postReportReasonFits(at200), isFalse, reason: 'the forum would store only ${'a' * 199}');
        expect(form.messageFor(custom, at200), isNull, reason: c);
        final wide200 = '${'中' * 99}a$c';
        expect(postReportReasonWeight(wide200), 200);
        expect(form.messageFor(custom, wide200), isNull, reason: 'multibyte prefix, $c');
        final at199 = '${'a' * 198}$c';
        expect(form.messageFor(custom, at199), at199, reason: 'weight 199 keeps its closing sentinel, $c');
        final inside = '$c${'a' * 199}';
        expect(form.messageFor(custom, inside), inside, reason: 'an entity before the limit is kept, $c');
      }
      expect(form.messageFor(custom, 'a' * 200), 'a' * 200);
      expect(form.messageFor(custom, '${'a' * 199}b'), '${'a' * 199}b');
      expect(form.messageFor(custom, '😀' * 100), '😀' * 100);
      expect(form.messageFor(custom, '${'😀' * 99}a&'), isNull, reason: 'emoji prefix, entity at 200');
      expect(
        form.messageFor(custom, '${'a' * 190}&#12345;'),
        '${'a' * 190}&#12345;',
        reason: 'numeric entity stays literal',
      );
      expect(form.messageFor(custom, '${'a' * 10}\u0001'), '${'a' * 10}\u0001', reason: 'short text is never cut');
    });

    test('trailing backslashes are refused before the forum silently removes them', () {
      final form = _form();
      expect(form.messageFor(form.customIndex, r'path C:\'), isNull);
      expect(form.messageFor(form.customIndex, r'path C:\file'), r'path C:\file');
    });
  });

  group('report form', () {
    test('the observed form: fields kept as served, empty url kept, no tid added', () {
      final form = _form();
      expect(form.action.toString(), 'https://www.tsdm39.com/misc.php?mod=report');
      expect(form.reasons, ['广告垃圾', '违规内容', '恶意灌水', '重复发帖', '其他']);
      expect(form.customIndex, 4);
      expect(form.hidden, defaultHidden);
      final body = form.body('违规内容');
      expect(body['message'], '违规内容');
      expect(body['url'], '', reason: 'the standard form carries an empty url');
      expect(body.containsKey('tid'), isFalse, reason: 'the forum form has no tid field');
      expect(body.containsKey('report_select'), isFalse);
      expect(body['handlekey'], 'miscreport$reportPid');
      expect(body['inajax'], '1');
      expect(body['formhash'], 'synthetic0hash');
      expect(body.keys.toList(), [...defaultHidden.map((e) => e.$1), 'message']);
    });

    test('presets are sent as their text, the last choice sends the typed text', () {
      final form = _form();
      expect(form.messageFor(0, 'ignored'), '广告垃圾');
      expect(form.messageFor(4, ''), isNull);
      expect(form.messageFor(4, '  \n '), isNull);
      expect(form.messageFor(4, ' 具体说明 '), '具体说明');
      expect(form.messageFor(5, 'x'), isNull);
      expect(form.messageFor(-1, 'x'), isNull);
    });

    test('an omitted url stays omitted, a url of this floor is accepted, another is refused', () {
      expect(_form(reportFormAjax(hidden: _without('url'))).body('x').containsKey('url'), isFalse);
      for (final url in [
        'forum.php?mod=redirect&goto=findpost&ptid=0&pid=$reportPid',
        'https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&ptid=$reportTid&pid=$reportPid',
        'forum.php?mod=viewthread&tid=$reportTid',
      ]) {
        expect(_form(reportFormAjax(hidden: _with('url', url))).body('x')['url'], url);
      }
      for (final url in [
        'forum.php?mod=redirect&goto=findpost&ptid=0&pid=1',
        'forum.php?mod=viewthread&tid=1',
        'https://evil.example/forum.php?mod=viewthread&tid=$reportTid',
      ]) {
        expect(() => _form(reportFormAjax(hidden: _with('url', url))), _fails(PostReportProblem.unsupported));
      }
    });

    test('an action with inajax is accepted, any other action is refused', () {
      expect(_form(reportFormAjax(action: 'misc.php?mod=report&amp;inajax=1')).action.queryParameters, {
        'mod': 'report',
        'inajax': '1',
      });
      expect(
        _form(reportFormAjax(hidden: _without('inajax'), action: 'misc.php?mod=report&amp;inajax=1')).body('x'),
        isNot(contains('inajax')),
      );
      for (final action in [
        'https://evil.example/misc.php?mod=report',
        'misc.php?mod=report&amp;rtype=post',
        'misc.php?mod=report&amp;mod=report',
        'home.php?mod=report',
        'misc.php?mod=other',
      ]) {
        expect(() => _form(reportFormAjax(action: action)), _fails(PostReportProblem.unsupported), reason: action);
      }
      expect(() => _form(reportFormAjax(method: 'get')), _fails(PostReportProblem.unsupported));
      expect(
        () => _form(reportFormAjax(hidden: _without('inajax'))),
        _fails(PostReportProblem.unsupported),
        reason: 'the answer would not be the ajax one the app reads',
      );
    });

    test('required values must be present and match the floor', () {
      for (final hidden in [
        _without('formhash'),
        _with('formhash', ''),
        _without('reportsubmit'),
        _with('rtype', 'user'),
        _with('rid', '1'),
        _without('rid'),
        _with('fid', '1'),
        _without('fid'),
        _with('handlekey', 'miscreport1'),
        _without('handlekey'),
        _with('inajax', '0'),
        [...defaultHidden, ('tid', '$reportTid')],
        [...defaultHidden, ('uid', '$authorUid')],
        [...defaultHidden, ('unknown', 'x')],
        [...defaultHidden, ('formhash', 'second')],
      ]) {
        expect(() => _form(reportFormAjax(hidden: hidden)), _fails(PostReportProblem.unsupported), reason: '$hidden');
      }
    });

    test('verification or unknown fields fall back to the browser', () {
      expect(
        () => _form(reportFormAjax(extraFields: '<input type="text" name="seccodeverify" />')),
        _fails(PostReportProblem.verificationRequired),
      );
      expect(
        () => _form(reportFormAjax(extraFields: '<input type="text" name="secanswer" />')),
        _fails(PostReportProblem.verificationRequired),
      );
      expect(
        () => _form(reportFormAjax(extraFields: '<input type="text" name="extra" />')),
        _fails(PostReportProblem.unsupported),
      );
      expect(
        () => _form(reportFormAjax(extraFields: '<select name="level"><option value="1">1</option></select>')),
        _fails(PostReportProblem.unsupported),
      );
      expect(
        () => _form(reportFormAjax(extraFields: '<button type="submit" name="other" value="1">x</button>')),
        _fails(PostReportProblem.unsupported),
      );
      expect(
        () => _form(reportFormAjax(textarea: '<textarea name="reason"></textarea>')),
        _fails(PostReportProblem.unsupported),
      );
      expect(() => _form(reportFormAjax(textarea: '')), _fails(PostReportProblem.unsupported));
    });

    test('the form must be the only one and have the expected id', () {
      expect(() => _form(reportFormAjax(formId: 'form_miscreport1')), _fails(PostReportProblem.unsupported));
      expect(
        () => _form(reportFormAjax(extraForms: '<form id="other" method="post" action="misc.php?mod=report"></form>')),
        _fails(PostReportProblem.unsupported),
      );
    });

    test('reasons are read from the literal array only', () {
      for (final script in [
        r"var reasons = ['a\'b', '其他'];",
        'var reasons = ["广告垃圾", "其他"];',
        "var reasons = [foo(), '其他'];",
        "var reasons = ['其他'];",
        "var reasons = ['其他', '其他'];",
        "var reasons = ['', '其他'];",
        "var reasons = ['a', '其他']; var reasons = ['b', '其他'];",
      ]) {
        expect(() => _form(reportFormAjax(script: script)), _fails(PostReportProblem.unsupported), reason: script);
      }
      expect(_form(reportFormAjax(script: "var reasons = [ 'a' ,'其他', ];")).reasons, ['a', '其他']);
      expect(() => _form(reportFormAjax(script: null)), _fails(PostReportProblem.unsupported));
      final radios = _form(
        reportFormAjax(
          script: null,
          extraFields:
              '<input type="radio" name="report_select" value="广告垃圾" />'
              '<input type="radio" name="report_select" value="其他" />',
        ),
      );
      expect(radios.reasons, ['广告垃圾', '其他']);
      expect(radios.body('x').containsKey('report_select'), isFalse);
    });

    test('answers without the form', () {
      expect(
        () => _form('<!DOCTYPE html><html><body><form id="form_miscreport$reportPid"></form></body></html>'),
        _fails(PostReportProblem.unsupported),
        reason: 'not an ajax answer',
      );
      expect(
        () => _form(
          '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<p>请先登录</p>'
          '<a href="member.php?mod=logging&amp;action=login">登录</a>]]></root>',
        ),
        _fails(PostReportProblem.notLoggedIn),
      );
      expect(
        () => _form('<?xml version="1.0" encoding="utf-8"?><root><![CDATA[合成的论坛提示<script>x()</script>]]></root>'),
        throwsA(
          isA<PostReportFailure>()
              .having((e) => e.problem, 'problem', PostReportProblem.forumMessage)
              .having((e) => e.message, 'message', '合成的论坛提示'),
        ),
      );
      expect(() => _form(''), _fails(PostReportProblem.unsupported));
      expect(
        () => _form('<html><head><title>Just a moment...</title></head><body></body></html>'),
        _fails(PostReportProblem.challenge),
      );
    });
  });

  group('report answer', () {
    test('report_succeed: callback of the handle plus the right dialog', () {
      final outcome = parsePostReportResult(successAjax(), form: _form());
      expect(outcome, isA<PostReportSucceeded>().having((e) => e.message, 'message', '合成的成功提示'));
    });

    test('a callback of the handle alone is an explicit refusal with its plain text', () {
      final outcome = parsePostReportResult(rejectionAjax(text: '合成的<b>拒绝</b>提示'), form: _form());
      expect(outcome, isA<PostReportRejected>().having((e) => e.message, 'message', '合成的拒绝提示'));
      final login = parsePostReportResult(
        rejectionAjax().replaceFirst('<script', '<a href="member.php?mod=logging&amp;action=login">x</a><script'),
        form: _form(),
      );
      expect(login, isA<PostReportRejected>().having((e) => e.notLoggedIn, 'notLoggedIn', isTrue));
    });

    test('anything else is unknown, never success', () {
      for (final raw in [
        '',
        'OK',
        '<html><body>举报成功</body></html>',
        '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[]]></root>',
        successAjax(handle: 'miscreport1'),
        successAjax(dialogText: '另一段提示'),
        successAjax().replaceFirst("', {});", "', {'a':'b'});"),
        successAjax() + successAjax(),
        rejectionAjax().replaceFirst('</script>', "errorhandle_other('x', {});</script>"),
        '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script>showDialog(\'合成的成功提示\', \'right\');</script>]]></root>',
        successAjax()
            .replaceFirst('<script', '<div class="alert_right">x</div><script')
            .replaceAll('errorhandle_', 'x_'),
      ]) {
        expect(parsePostReportResult(raw, form: _form()), isA<PostReportUnknown>(), reason: raw);
      }
    });

    test('the verbatim upstream report_succeed answer and whitespace variants are success', () {
      const upstream =
          '<?xml version="1.0" encoding="UTF-8"?><root><![CDATA[<script type="text/javascript" reload="1">'
          "if(typeof errorhandle_miscreport60191995=='function') {errorhandle_miscreport60191995('Synthetic report "
          "accepted', {});}hideWindow('miscreport60191995');showDialog('Synthetic report accepted', 'right', null, "
          'null, 0, null, null, null, null, 3, null);</script>]]></root>';
      expect(
        parsePostReportResult(upstream, form: _form()),
        isA<PostReportSucceeded>().having((e) => e.message, 'message', 'Synthetic report accepted'),
      );
      final spaced = upstream
          .replaceFirst("=='function') {", " == 'function' ) {\n")
          .replaceFirst('3, null);', 'null , null ) ;\n');
      expect(parsePostReportResult(spaced, form: _form()), isA<PostReportSucceeded>());
    });

    test('inert text, partial calls, forwards and other statements are unknown, not success nor refusal', () {
      const h = 'miscreport$reportPid';
      const cb = "if(typeof errorhandle_$h=='function') {errorhandle_$h('x', {});}";
      const dialog = "showDialog('x', 'right', null, null, 0, null, null, null, null, 3, null);";
      final forward = dialog.replaceFirst('null, null, 0', "null, function () { location.href = 'x'; }, 0");
      String wrap(String inner) => '<?xml version="1.0" encoding="UTF-8"?><root><![CDATA[$inner]]></root>';
      String script(String body) => '<script type="text/javascript" reload="1">$body</script>';
      for (final raw in [
        wrap(script('var s = "$cb";')),
        wrap(script('/* $cb */')),
        wrap(script('// $cb')),
        wrap('<!-- ${script(cb)} -->'),
        wrap('<textarea>${script(cb)}</textarea>'),
        wrap('<noscript>${script(cb)}</noscript>'),
        wrap('<pre>$cb</pre>'),
        wrap(script("${cb}hideWindow('$h');showDialog('x', 'right');")),
        wrap(script("${cb}showDialog('x', 'right', null, null, 0, null, null, null, null, 3, null);")),
        wrap(script("${cb}hideWindow('$h');${dialog}alert(1);")),
        wrap(script("${cb}hideWindow('$h');${dialog.replaceFirst("'right'", "'alert'")}")),
        wrap(script("${cb}hideWindow('$h');$forward")),
        wrap(script("${cb}hideWindow('$h');${dialog.replaceFirst('3, null', '3, 1')}")),
        wrap(script("${cb}hideWindow('$h');$dialog".replaceFirst('{});', '[]);'))),
        wrap(script("${cb}hideWindow('other');$dialog")),
        wrap(script(cb.replaceFirst("errorhandle_$h('x'", "errorhandle_other('x'"))),
        wrap(script('$cb$cb')),
        wrap('${script(cb)}${script(cb)}'),
        wrap('${script(cb)}trailing text'),
        wrap(script("$cb;setTimeout(\"hideWindow('$h')\", 3000);")),
      ]) {
        expect(parsePostReportResult(raw, form: _form()), isA<PostReportUnknown>(), reason: raw);
      }
    });
  });
}
