import 'package:collection/collection.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

final _formHashRe = RegExp(r'formhash" value="(?<FormHash>\w+)"');

/// Parse the form hash in checkin page [document].
///
/// The checkin form is `form#qiandao` (plugin dsu_paulsign) with a hidden `formhash` input, fallback to any formhash
/// input in page and finally the regexp on raw html.
///
/// Marked as public for testing.
String? parseCheckinFormHash(uh.Document document) {
  return document.querySelector('form#qiandao input[name="formhash"]')?.attributes['value'] ??
      document.querySelector('input[name="formhash"]')?.attributes['value'] ??
      _formHashRe.firstMatch(document.documentElement?.innerHtml ?? '')?.namedGroup('FormHash');
}

/// Parse the checkin status text in checkin page [document] if the page tells user the checkin is not available
/// (already checked in today, or not in checkin time).
///
/// ```html
/// <div id="ct_shell"><div class="mn">
/// <h1 class="mt">您今天已经签到过了或者签到时间还未开始</h1>
/// ```
///
/// Marked as public for testing.
String? parseCheckinPageMessage(uh.Document document) =>
    document.querySelectorAll('h1.mt').map((e) => e.innerText.trim()).firstWhereOrNull((e) => e.isNotEmpty);

/// Parse the message text in the checkin ajax response [data].
///
/// The response is an xml document wrapping html:
///
/// ```xml
/// <?xml version="1.0" encoding="utf-8"?>
/// <root><![CDATA[
/// <div class="c">MESSAGE</div>
/// <script ...>...</script>
/// ]]></root>
/// ```
///
/// Fallback to the line heuristic (first line containing `</div>`) if not parsed.
///
/// Marked as public for testing.
String? parseCheckinResponseMessage(String data) {
  String? fromXml;
  try {
    final xmlDoc = parseXmlDocument(data);
    final htmlData = xmlDoc.documentElement?.nodes.firstOrNull?.text;
    if (htmlData != null) {
      final htmlDoc = parseHtmlDocument(htmlData);
      fromXml =
          htmlDoc.querySelector('div.c')?.innerText.trim() ??
          htmlDoc.querySelector('div#messagetext')?.innerText.trim() ??
          htmlDoc.querySelector('div.alert_error, div.alert_right, div.alert_info')?.innerText.trim();
    }
  } on Exception catch (_) {
    // Not xml, use fallback below.
  }
  if (fromXml != null && fromXml.isNotEmpty) {
    return fromXml;
  }
  return data.split('\n').firstWhereOrNull((e) => e.contains('</div>'))?.replaceFirst('</div>', '').trim();
}
