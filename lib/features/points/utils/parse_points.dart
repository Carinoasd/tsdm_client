import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;

/// Parse the points statistics page.
///
/// Marked as public for testing.
(Map<String, String>, List<PointsChange>)? parseStatisticsDocument(uh.Document document) {
  // Discuz X5: `div#ct`, Discuz X3: `div#ct_shell`.
  final rootNode = document.querySelector('div#ct_shell div.bm.bw0') ?? document.querySelector('div#ct div.bm.bw0');
  if (rootNode == null) {
    talker.error('points change root node not found');
    return null;
  }
  final pointsMapEntries = rootNode
      .querySelectorAll('ul.creditl > li')
      .map(_parseCreditLi)
      .whereType<(String, String)>()
      .map((e) => MapEntry(e.$1.split(':').first.trim(), e.$2.trim()));
  final pointsMap = Map<String, String>.fromEntries(pointsMapEntries);

  final tableNode = rootNode.querySelector('table.dt');
  if (tableNode == null) {
    talker.error('points change table not found');
    return null;
  }
  final pointsChangeList = buildChangeListFromTable(tableNode);
  return (pointsMap, pointsChangeList);
}

/// Parse all available filter parameters in changelog page.
///
/// Marked as public for testing.
ChangelogAllParameters parseAllParameters(uh.Document document) {
  // These options seem invisible in browser but exist.
  // <select id="optype" name="optype">
  //   <option value="">Choose</option>
  //   <option value="TRC">Task</option>
  //   ...
  // </select>
  final extTypeList = document
      .querySelectorAll('select#exttype > option')
      .where((e) => e.attributes['value'] != null)
      .map((e) => ChangelogPointsType(name: e.innerText.trim(), extType: e.attributes['value']!))
      .toList();
  final optTypeList = document
      .querySelectorAll('select#optype > option')
      .where((e) => e.attributes['value'] != null)
      .map((e) => ChangelogOperationType(name: e.innerText.trim(), operation: e.attributes['value']!))
      .toList();

  final changeTypeList = document
      .querySelectorAll('select#income > option')
      .where((e) => e.attributes['value'] != null)
      .map((e) => ChangelogChangeType(name: e.innerText.trim(), changeType: e.attributes['value']!))
      .toList();

  return ChangelogAllParameters(
    extTypeList: extTypeList,
    operationTypeList: optTypeList,
    changeTypeList: changeTypeList,
  );
}

/// Parse a credit item in the statistics page.
///
/// ```html
/// <li class="xi1 cl">
/// <em> 天使币: </em>10532  &nbsp; </li>
/// <li><em> 威望: </em>31669 </li>
/// <li class="cl"><em>积分: </em>31669 <span class="xg1">( <u>总积分</u>=<u>威望</u> )</span></li>
/// ```
///
/// Key is the `<em>` text, value is the text right after `<em>`, there may be blank text before `<em>`.
(String, String)? _parseCreditLi(uh.Element element) {
  final em = element.querySelector('em');
  if (em == null) {
    return null;
  }
  final key = em.innerText.trim();
  final value = em.nextNode?.text?.replaceAll(' ', ' ').trim();
  if (key.isEmpty || value == null || value.isEmpty) {
    return null;
  }
  return (key, value);
}

/// Build a list of [PointsChange] from <table class="dt">
///
/// Marked as public for testing.
List<PointsChange> buildChangeListFromTable(uh.Element element) {
  // Skip the table header row which only has `<th>`.
  final ret = element
      .querySelectorAll('tr')
      .where((e) => e.querySelector('td') != null)
      .map(PointsChange.fromTrNode)
      .whereType<PointsChange>()
      .toList();
  return ret;
}
