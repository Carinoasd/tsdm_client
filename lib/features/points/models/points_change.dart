part of 'models.dart';

/// Describe the change is lifting points up or down.
///
enum PointsChangeType {
  /// Points become more.
  more,

  /// Points become less.
  less,

  /// Unknown change type.
  ///
  /// We do not know the points become more or less.
  ///
  /// Use as a fallback type.
  unlimited,
}

/// A single change on the user's points.
///
/// Contains of change operation, attr points change list, change detail and
/// happened datetime.
@MappableClass()
class PointsChange with PointsChangeMappable {
  /// Constructor
  const PointsChange({
    required this.operation,
    required this.operationFilterUrl,
    required this.pointsChangeType,
    required this.changeMap,
    required this.detail,
    required this.time,
    this.redirectUrl,
  });

  /// Operation type of this change.
  final String operation;

  /// Url to show the filter result of same type operation in points changelog; empty for a log another plugin wrote,
  /// which names no operation.
  final String operationFilterUrl;

  /// Map of the changes in different attr types with their names and values.
  final Map<String, String> changeMap;

  /// Describe how the change effect the user's points: lift up or down.
  ///
  /// # Caution
  ///
  /// This section is detected by the change type on the first kind of points
  /// in the changelog, we  assume that the whole change type is always the same
  /// with that of the first one.
  final PointsChangeType pointsChangeType;

  /// Html node to parse the detail change.
  final String detail;

  /// An url to redirect.
  ///
  /// Point changes usually have this, but not guaranteed.
  final String? redirectUrl;

  /// Datetime of this change.
  final DateTime time;

  /// The change of a row [row] of the structured credit log answer (plugin 2.5.0, `schema: 12`, `logs[]`): the
  /// operation as the page prints it in its first column (`operation`) and the link of that column (`filter_url`,
  /// empty for a record without a code, which the page prints without a link), the changed credits (`changes[]`:
  /// the title of each, and the signed value as the page prints it, "+2", read from the printed `text` "天使币 +2";
  /// the cleared credits of a reset read "清零"), whether the credits grew or shrank (`type`: income, expense; a mixed
  /// change goes by its first credit, as the page parser goes by the first printed value), the detail column (plain
  /// text, wrapped as the cell the page parser kept) and its link (`url`), the time (`dateline`, shown as the forum's
  /// wall clock with [timeOffset], `timeoffset` of the answer, as the page prints it). Null for a row without an
  /// operation or a time, as the page parser skips such a row.
  static PointsChange? fromApi(Map<String, dynamic> row, {required num timeOffset}) {
    final operation = tsdmAppText(row['operation']).trim();
    final time = tsdmAppWallClockTime(row['dateline'], timeOffset);
    if (operation.isEmpty || time == null) {
      talker.error('failed to build PointsChange: operation=$operation, dateline=${row['dateline']}');
      return null;
    }
    final changes = tsdmAppList(row['changes']);
    final changeMap = <String, String>{};
    for (final change in changes) {
      final title = tsdmAppText(change['title']).trim();
      if (title.isEmpty) {
        continue;
      }
      changeMap[title] = _signedChangeOf(change, title);
    }
    final firstValue = changes.isEmpty ? 0 : tsdmAppInt(changes.first['value']);
    final pointsChangeType = switch (tsdmAppText(row['type'])) {
      'income' => PointsChangeType.more,
      'expense' => PointsChangeType.less,
      _ when firstValue > 0 => PointsChangeType.more,
      _ when firstValue < 0 => PointsChangeType.less,
      _ => PointsChangeType.unlimited,
    };
    final url = tsdmAppText(row['url']).trim();
    return PointsChange(
      operation: operation,
      operationFilterUrl: tsdmAppText(row['filter_url']).trim(),
      pointsChangeType: pointsChangeType,
      changeMap: changeMap,
      detail: '<td>${const HtmlEscape(HtmlEscapeMode.element).convert(tsdmAppText(row['detail']).trim())}</td>',
      redirectUrl: url.isEmpty ? null : url.prependHost(),
      time: time,
    );
  }

  /// The signed value of a changed credit [change] titled [title] as the page prints it after the title ("+2",
  /// "-5", "清零"): the printed `text` without the title, else built from `value`.
  static String _signedChangeOf(Map<String, dynamic> change, String title) {
    final text = tsdmAppText(change['text']).trim();
    if (text.startsWith(title)) {
      final rest = text.substring(title.length).trim();
      if (rest.isNotEmpty) {
        return rest;
      }
    }
    final value = tsdmAppInt(change['value']);
    return value > 0 ? '+$value' : '$value';
  }

  /// [PointsChange] is expected to exists inside a <table class="dt">.
  ///
  /// In that table, each <tr> (except the table header) can be converted to an
  /// instance of [PointsChange] :
  ///
  /// <tr>
  ///   <td>
  ///     <a>operation</a>
  ///   </td>
  ///   <td>
  ///     attr1
  ///     <span class="xi1">signed_value1</span>
  ///     attr2
  ///     <span class="xi1">signed_value2</span>
  ///     attr3
  ///     <span class="xi1">signed_value3</span>
  ///     ...
  ///   </td>
  ///   <td>
  ///     <a href=link_to_the_thread>detail</a>
  ///   </td>
  ///   <td>datetime</td>
  ///
  /// This function tries to build [PointsChange] from <tr> [element].
  ///
  /// Discuz X5 adds a column "变更后" (points after change) after the change column:
  ///
  /// <tr>
  ///   <td><a>operation</a></td>
  ///   <td>attr1 <span class="xi1">+200</span><br/>attr2 <span class="xi1">+200</span></td>
  ///   <td>attr1 27253<br/>attr2 27250</td>
  ///   <td><a href=link_to_the_thread>detail</a></td>
  ///   <td>2026-09-04 19:25:28</td>
  /// </tr>
  static PointsChange? fromTrNode(uh.Element element) {
    final allTd = element.querySelectorAll('td');
    if (allTd.length != 4 && allTd.length != 5) {
      talker.error(
        'failed to build PointsChange instance: '
        'invalid td count: ${allTd.length}',
      );
      return null;
    }
    // Drop the "points after change" column on X5.
    final tdList = allTd.length == 5 ? [allTd[0], allTd[1], allTd[3], allTd[4]] : allTd.toList();

    // An operation of the forum links to the log filtered by it; a log another plugin wrote (a game's reward, a
    // check-in) names no operation and the page prints its title as plain text (`$value['title']`), as the plugin's
    // structured rows give it ([fromApi]: no filter url).
    final link = tdList[0].querySelector('a');
    final operation = (link?.innerText ?? tdList[0].innerText).trim();
    final operationFilterUrl = link?.attributes['href'] ?? '';
    if (operation.isEmpty) {
      talker.error('failed to build PointsChange: no operation');
      return null;
    }
    final attrNameList = <String>[];
    final attrValueList = <String>[];
    for (final node in tdList[1].childNodes) {
      if (node.nodeType == uh.Node.ELEMENT_NODE) {
        final e = node as uh.Element;
        if (e.localName == 'span') {
          attrValueList.add(e.innerText.trim());
        }
      } else if (node.nodeType == uh.Node.TEXT_NODE) {
        final attrNameText = node.text?.trim();
        if (attrNameText?.isNotEmpty ?? false) {
          attrNameList.add(attrNameText!);
        }
      }
    }
    if (attrNameList.length != attrValueList.length) {
      talker.error(
        'failed to build PointsChange: invalid attar name '
        'value length: $attrNameList and $attrValueList',
      );
      return null;
    }

    // Points become more or less on this change.
    final pointsChangeType = switch (tdList[1].querySelector('span')?.classes.firstOrNull) {
      // Up lifted changelog has an orange font color with class name "xi1"
      'xi1' => PointsChangeType.more,
      // Down lifted changelog has an gray font color with class name "xg1".
      'xg1' => PointsChangeType.less,
      // Fallback to unknown type.
      // This might not happen but we should consider it.
      String() || null => PointsChangeType.unlimited,
    };
    final changeMap = <String, String>{};
    for (var i = 0; i < attrNameList.length; i++) {
      changeMap[attrNameList[i]] = attrValueList[i];
    }

    final detail = tdList[2].outerHtml ?? tdList[2].innerText.trim();
    final redirectUrl = tdList[2].querySelector('a')?.attributes['href']?.prependHost();
    final changedTime = tdList[3].innerText.trim().parseToDateTimeUtc8();
    if (changedTime == null) {
      talker.error(
        'failed to build PointsChange: invalid change time:'
        '${tdList[3].innerText.trim()}',
      );
      return null;
    }

    return PointsChange(
      operation: operation,
      operationFilterUrl: operationFilterUrl,
      pointsChangeType: pointsChangeType,
      detail: detail,
      redirectUrl: redirectUrl,
      changeMap: changeMap,
      time: changedTime,
    );
  }

  /// Get tht formatted change.
  String get changeMapString => changeMap.entries.map((e) => '${e.key} ${e.value}').join(',');
}
