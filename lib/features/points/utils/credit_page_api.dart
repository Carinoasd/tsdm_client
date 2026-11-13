import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// The structured credit log answer in [data]: a JSON answer of the forum's app API that carries the credit log page
/// (`home.php?mod=spacecp&ac=credit&op=log`, with its filters and pages) as fields (plugin 2.5.0, `type: credit`,
/// `schema` 12 or later), or the forum's own message of such a plugin (a guest: `ok` 0, `error: message`, with
/// `login` telling the two apart). Null when the answer has to be read from its `document` as before: a web page,
/// an older plugin's answer (no `schema`, no `login`), a failed build, and the other credit pages (`op=base`, the
/// system reward log), which the plugin keeps answering as `type: credit` without a `schema`.
///
/// The log is then built by [pointsChangelogFromApi]; the `document` of the answer, when there is one, is never
/// parsed.
Map<String, dynamic>? creditApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 12;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'credit' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// One page of the credit log built from a structured answer: the changes of the page, the pagination the forum
/// printed and the filters of its query form.
typedef PointsChangelogPage = ({
  List<PointsChange> changes,
  int currentPage,
  int totalPages,
  ChangelogAllParameters allParameters,
});

/// The label of the choice that filters by no operation as the forum's query form prints its first option
/// (`<option value="">请选择操作类型</option>`), for a plugin that lists the operation codes only (2.5.0): plugin 2.6.0
/// gives that option first in `filters.optype` (an empty `value`), and the app's query form offers (and starts on) the
/// first choice of the list.
const _anyOperationFallbackName = '请选择操作类型';

/// The credit log of a structured answer [json] ([creditApiAnswerOf]): the rows of the page as [PointsChange.fromApi]
/// builds them (a row without an operation or a time dropped, as the page parser drops a malformed row; the forum
/// skips a record without any change, so a page may hold fewer than 20), the pagination the forum printed (`page`,
/// `pages`; [fallbackPage] when the answer names no page, as the page parser falls back to the page it asked for) and
/// the filters of the query form ([changelogParametersFromApi]). The forum's message (`ok` 0: a guest) is null, as
/// the message page parsed to (no table on it).
PointsChangelogPage? pointsChangelogFromApi(Map<String, dynamic> json, {int fallbackPage = 1}) {
  if (json['ok'] != 1) {
    talker.info('points changelog: the forum answered a message: ${json['message']}');
    return null;
  }
  final timeOffset = tsdmAppTimeOffset(json);
  final changes = tsdmAppList(
    json['logs'],
  ).map((e) => PointsChange.fromApi(e, timeOffset: timeOffset)).nonNulls.toList();
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  final currentPage = page > 0 ? page : fallbackPage;
  return (
    changes: changes,
    currentPage: currentPage,
    totalPages: pages > 0 ? pages : currentPage,
    allParameters: changelogParametersFromApi(json),
  );
}

/// The filters of the query form of a structured answer [json] (`filters`: the credits, `exttype`; the direction,
/// `income`; the operations, `optype`), the same [ChangelogAllParameters] the web page gives through
/// `parseAllParameters` (its three `<select>`s): the values and the order of the page, the choice of no operation
/// first among the operations (an empty value: the form's first option as plugin 2.6.0 lists it, named by `name` or
/// `title`; put there with the label the form prints when the plugin lists the codes only). Empty lists for the
/// forum's message, which carries no form (no `filters`).
ChangelogAllParameters changelogParametersFromApi(Map<String, dynamic> json) {
  final filters = tsdmAppMap(json['filters']);
  if (filters.isEmpty) {
    return const ChangelogAllParameters.empty();
  }
  final operations = tsdmAppList(
    filters['optype'],
  ).map((e) => ChangelogOperationType(name: _nameOf(e), operation: _valueOf(e))).toList();
  return ChangelogAllParameters(
    extTypeList: tsdmAppList(
      filters['exttype'],
    ).map((e) => ChangelogPointsType(name: _nameOf(e), extType: _valueOf(e))).toList(),
    operationTypeList: [
      if (operations.isEmpty || operations.first.operation.isNotEmpty)
        const ChangelogOperationType(name: _anyOperationFallbackName, operation: ''),
      ...operations,
    ],
    changeTypeList: tsdmAppList(
      filters['income'],
    ).map((e) => ChangelogChangeType(name: _nameOf(e), changeType: _valueOf(e))).toList(),
  );
}

/// The label of a filter option [option] as the form prints it: `name`, or `title` (the form's first operation option
/// of plugin 2.6.0 names it so).
String _nameOf(Map<String, dynamic> option) {
  final name = tsdmAppText(option['name']).trim();
  return name.isNotEmpty ? name : tsdmAppText(option['title']).trim();
}

/// The `value` of a filter option [option] as the query sends it: a number (`exttype`, `income`) or a code
/// (`optype`; empty for the choice of no operation).
String _valueOf(Map<String, dynamic> option) => switch (option['value']) {
  final num n => '${n.toInt()}',
  final String s => s.trim(),
  _ => '',
};

/// The statistics page of the credits: each credit with its value as the page prints it, then the total, and the
/// latest changes, newest first.
typedef PointsStatistics = ({Map<String, String> points, List<PointsChange> changes});

/// The statistics page of plugin 4.0.0 [json] (`type: credit_base`, `schema` 52) as `parseStatisticsDocument` reads the
/// web page: `credits` in the page's order, each its title and its value with the unit the page prints after it; then
/// the total (the forum names it with the word of its language pack, the app with its own), and the total of a special
/// upgrade group when the account is in one; `logs` as the rows of the credit log ([PointsChange.fromApi]).
PointsStatistics pointsStatisticsFromApi(Map<String, dynamic> json) {
  final credits = t.profilePage.statistics.credits;
  final timeOffset = tsdmAppTimeOffset(json);
  final total = tsdmAppMap(json['total']);
  final upgroup = tsdmAppMap(json['upgroup']);
  return (
    points: {
      for (final credit in tsdmAppList(json['credits']))
        if (tsdmAppText(credit['title']).trim() case final String title when title.isNotEmpty)
          title: '${_number(credit['value'])} ${tsdmAppText(credit['unit'])}'.trim(),
      if (total.isNotEmpty) credits: _number(total['value']),
      if (upgroup.isNotEmpty) '${tsdmAppText(upgroup['name']).trim()}$credits': _number(upgroup['value']),
    },
    changes: tsdmAppList(json['logs']).map((e) => PointsChange.fromApi(e, timeOffset: timeOffset)).nonNulls.toList(),
  );
}

/// A number of the answer as the page prints it.
String _number(Object? value) => switch (value) {
  final num n => '${n.toInt()}',
  final String s => s.trim(),
  _ => '',
};
