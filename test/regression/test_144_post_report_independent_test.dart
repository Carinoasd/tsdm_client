import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';

import 'fixtures/post_report_fixtures.dart';

void main() {
  final form = parsePostReportForm(reportFormAjax(), target: reportTarget);
  final callback = "errorhandle_${reportTarget.handleKey}('x', {});";
  const dialog = "showDialog('x', 'right');";

  for (final entry in <String, String>{
    'quoted JavaScript string': '<script>const debug = "$callback$dialog";</script>',
    'JavaScript comment': '<script>/* $callback$dialog */</script>',
    'HTML comment': '<!-- $callback$dialog -->',
    'plain HTML text': '<pre>$callback$dialog</pre>',
  }.entries) {
    test('non-executing ${entry.key} cannot prove report acceptance', () {
      final raw = '<?xml version="1.0"?><root><![CDATA[${entry.value}]]></root>';
      expect(parsePostReportResult(raw, form: form), isA<PostReportUnknown>());
    });
  }

  test('genuine source-shaped success with an escaped apostrophe is accepted', () {
    final raw = successAjax(text: r"User\'s synthetic report");
    expect(
      parsePostReportResult(raw, form: form),
      isA<PostReportSucceeded>().having((outcome) => outcome.message, 'message', "User's synthetic report"),
    );
  });
}
