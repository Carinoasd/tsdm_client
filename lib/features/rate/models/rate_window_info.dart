part of 'models.dart';

/// A type of score in rate window.
///
/// Here the entire model assumes that:
/// * The first column of rate window table is score name.
/// * The second column is user selected value.
/// * The third column is allowed values.
/// * The forth last column is points remains today.
///
/// We can tell if here is other type of forms that have more or less than four
/// columns.
@MappableClass()
final class RateWindowScore with RateWindowScoreMappable {
  /// Constructor.
  const RateWindowScore({
    required this.id,
    required this.name,
    required this.allowedRange,
    required this.allowedRangeDescription,
    required this.remaining,
    this.min,
    this.max,
  });

  /// Score type:
  ///
  /// "score2" -> 天使币
  /// ("score3" -> 威望)
  /// "score4" -> 天然
  /// "score5" -> 腹黑
  final String id;

  /// Readable name in the first column.
  final String name;

  /// Allowed values.
  final List<String> allowedRange;

  /// Description of allowed range.
  final String allowedRangeDescription;

  /// Score that remaining to use in rate today.
  final String remaining;

  /// The lowest score allowed (`min` of the forum's app API, plugin 3.0.0); null when the window was parsed from the
  /// web page, whose range is [allowedRangeDescription].
  final int? min;

  /// The highest score allowed (`max`, plugin 3.0.0); null when parsed from the web page.
  final int? max;

  /// Today's remaining as a number, null when it is not one.
  int? get todayLeft => int.tryParse(remaining.trim());
}

/// Information in rate confirm dialog window.
///
/// Used to post a rate action.
@MappableClass()
final class RateWindowInfo with RateWindowInfoMappable {
  /// Constructor.
  const RateWindowInfo({
    required this.rowTitleList,
    required this.scoreList,
    required this.defaultReasonList,
    required this.formHash,
    required this.tid,
    required this.pid,
    required this.referer,
    required this.handleKey,
    this.noticeAuthorForced = false,
    this.submitUrl,
    this.submitFields,
    this.noticeAuthorName,
    this.noticeAuthorValue = 'on',
    this.noticeAuthorPreset = false,
    this.selfDeduct = false,
  });

  /// Row title of the rate table.
  /// The second value may be "&nbsp;" that need to be translated into
  /// whitespace.
  ///
  /// Expected title list:
  /// ["Factor 1", "&nbsp;", "评分区间", "今日剩余"]
  final List<String> rowTitleList;

  /// All types of scores that can rate.
  final List<RateWindowScore> scoreList;

  /// Default rate reason provided by server side.
  final List<String> defaultReasonList;

  /// Form data.
  final String formHash;

  /// Thread id.
  final String tid;

  /// Post id to rate.
  final String pid;

  /// Referer in url parameter.
  final String referer;

  /// Handle key in parameter.
  final String handleKey;

  /// The forum always notifies the author of this rate, whatever the user picks.
  ///
  /// The user group setting `reasonpm` 2 or 3 renders the "通知作者" checkbox checked and disabled:
  ///
  /// `<input type="checkbox" name="sendreasonpm" id="sendreasonpm" class="pc" checked="checked" disabled="disabled" />`
  final bool noticeAuthorForced;

  /// The url the form posts to (`submit.url` of the forum's app API, plugin 3.0.0, absolute; posted with
  /// `inajax=1` as the website does); null when the window was parsed from the web page, which posts to the fixed
  /// rate url.
  final String? submitUrl;

  /// The hidden fields of the form and its submit button as served (`submit.fields`, plugin 3.0.0): the form hash,
  /// `tid`, `pid`, `referer`, `handlekey`, `ratesubmit`. Null when parsed from the web page: its five hidden fields
  /// are posted ([formHash], [tid], [pid], [referer], [handleKey]).
  final Map<String, String>? submitFields;

  /// Name of the "通知作者" checkbox, posted with [noticeAuthorValue] when it is on (plugin 3.0.0: `notify`); null when
  /// the form has none or was parsed from the web page (which posts `sendreasonpm=on`).
  final String? noticeAuthorName;

  /// Value of the "通知作者" checkbox of the forum's app API ([noticeAuthorName]).
  final String noticeAuthorValue;

  /// The "通知作者" checkbox is served checked (plugin 3.0.0: `notify.checked`; checked by the site's `ratenotify`
  /// plugin as on the website, `notify.preset`). The page starts with it.
  final bool noticeAuthorPreset;

  /// The forum takes the scores from the rater's own credits of the same kind (`self_deduct`, plugin 3.0.0): the
  /// website says so above the form.
  final bool selfDeduct;

  /// Whether this window came from the forum's app API (plugin 3.0.0) and is posted as served.
  bool get isFromApi => submitFields != null && submitUrl != null;

  /// The window of the forum's app API (plugin 3.0.0, `type: form`, `form: rate`) [form]: every credit with its
  /// range (`min`, `max`), today's remaining (`today_left`) and its choices, the reasons, the "通知作者" checkbox
  /// and the form as served. Null when the answer misses what a rate needs (no credit, no form hash, a post or a
  /// target url that is not the rate of this window): the window is then read as before.
  static RateWindowInfo? fromApi(SmallFormFields form) {
    final json = form.json;
    final tid = tsdmAppInt(json['tid']);
    final pid = tsdmAppInt(json['pid']);
    final fields = form.submitFields;
    final url = form.submitUrl('forum.php', const {'mod': 'misc', 'action': 'rate', 'ratesubmit': 'yes'});
    final formHash = fields['formhash'] ?? '';
    if (tid <= 0 || pid <= 0 || url == null || formHash.isEmpty || fields['tid'] != '$tid' || fields['pid'] != '$pid') {
      talker.error('invalid rate form of the app api: tid=$tid pid=$pid url=${url != null} fields=${fields.keys}');
      return null;
    }
    final scores = <RateWindowScore>[];
    for (final credit in tsdmAppList(json['credits'])) {
      final input = PostFormInput.fromJson(credit['input']);
      final min = credit['min'];
      final max = credit['max'];
      final left = credit['today_left'];
      if (input == null || input.type != 'text' || min is! int || max is! int || left is! int) {
        talker.error('invalid rate credit of the app api: ${credit['id']}');
        return null;
      }
      scores.add(
        RateWindowScore(
          id: input.name,
          name: tsdmAppText(credit['title']),
          allowedRange: switch (credit['choices']) {
            final List<dynamic> list => list.map((e) => '$e').toList(),
            _ => const [],
          },
          allowedRangeDescription: '$min ~ $max',
          remaining: '$left',
          min: min,
          max: max,
        ),
      );
    }
    if (scores.isEmpty) {
      talker.error('invalid rate form of the app api: no credit');
      return null;
    }
    final notify = PostFormInput.fromJson(json['notify']);
    return RateWindowInfo(
      // The web page's table head, for the code that reads it.
      rowTitleList: const ['', '', '', ''],
      scoreList: scores,
      defaultReasonList: switch (json['reasons']) {
        final List<dynamic> list => list.whereType<String>().where((e) => e.trim().isNotEmpty).toList(),
        _ => const [],
      },
      formHash: formHash,
      tid: '$tid',
      pid: '$pid',
      referer: fields['referer'] ?? '',
      handleKey: fields['handlekey'] ?? '',
      noticeAuthorForced: notify != null && notify.checked && notify.disabled,
      submitUrl: url,
      submitFields: fields,
      noticeAuthorName: notify == null || !notify.isCheckbox ? null : notify.name,
      noticeAuthorValue: notify?.value ?? 'on',
      noticeAuthorPreset: notify != null && notify.checked,
      selfDeduct: json['self_deduct'] == 1,
    );
  }

  /// The fields to post for a rate with [scores] (score id to the value typed, `0` or empty for none), [reason] and
  /// the "通知作者" switch [noticeAuthor].
  ///
  /// A window of the forum's app API ([fromApi]) posts what it served (`submit.fields`) with the member's values
  /// over it, and the checkbox only when it is on and not locked, as the browser does (a locked one is always
  /// notified by the forum). A window parsed from the web page posts its five hidden fields and `sendreasonpm=on`
  /// when on or locked, as it always did.
  Map<String, String> body({
    required Map<String, String> scores,
    required String reason,
    required bool noticeAuthor,
  }) {
    final served = submitFields;
    if (served != null) {
      return {
        ...served,
        'reason': reason,
        ...scores,
        if (noticeAuthorName case final String name when noticeAuthor && !noticeAuthorForced) name: noticeAuthorValue,
      };
    }
    return {
      'formhash': formHash,
      'tid': tid,
      'pid': pid,
      'referer': referer,
      'handlekey': handleKey,
      'reason': reason,
      ...scores,
      // A checkbox on the web page: sent only when checked. The forum notifies the author whenever the field is not
      // empty, so sending "off" notified the author as well.
      if (noticeAuthor || noticeAuthorForced) 'sendreasonpm': 'on',
    };
  }

  /// Build from <div class="c"> node [element] or from the floating window raw
  /// html.
  static RateWindowInfo? fromDivCNode(uh.Element element) {
    // Parse table row title.

    // Rows in table.
    // The first element is row title.
    final rateTableRowsNodeList = element.querySelectorAll('table > tbody > tr').toList();

    // Should have at least one type of score to rate and also the row title as
    // list elements.
    if (rateTableRowsNodeList.length < 2) {
      talker.error(
        'invalid rate window info: incorrect rateTableRowsNodeList '
        'length: ${rateTableRowsNodeList.length}',
      );
      return null;
    }

    // Length of row title list should be 4.
    final rowTitleList = rateTableRowsNodeList.firstOrNull
        ?.querySelectorAll('th')
        .map((e) => e.firstEndDeepText())
        .whereType<String>()
        .toList();
    // Explicitly check null here just make the compiler happy.
    if (rowTitleList == null || rowTitleList.length != 4) {
      talker.error(
        'invalid rate window info: incorrect rowTitleList length: '
        '${rowTitleList?.length}',
      );
      return null;
    }
    // Replace the second column title "&nbsp;" with whitespace.
    rowTitleList[1] = '';

    // Parse table score rows.

    final scoreList = rateTableRowsNodeList
        .skip(1)
        .map(_buildRateScoreRowFromTrNode)
        .whereType<RateWindowScore>()
        .toList();

    /// Score types available to rate should not be empty;
    if (scoreList.isEmpty) {
      talker.error('invalid rate score list: no available score types');
      return null;
    }

    // Parse default reasons.

    // Allow default reason list to be empty.
    final defaultReasonList = element
        .querySelector('div.tpclg ul#reasonselect')
        ?.querySelectorAll('li')
        .map((e) => e.firstEndDeepText())
        .whereType<String>()
        .toList();

    // Parse form data.
    final formHash = element.querySelector('input[name="formhash"]')?.attributes['value'];
    final tid = element.querySelector('input[name="tid"]')?.attributes['value'];
    final pid = element.querySelector('input[name="pid"]')?.attributes['value'];
    final referer = element.querySelector('input[name="referer"]')?.attributes['value'];
    final handleKey = element.querySelector('input[name="handlekey"]')?.attributes['value'];

    if (formHash == null || tid == null || pid == null || referer == null || handleKey == null) {
      talker.error(
        'invalid rate window info: invalid form data: formHash=$formHash, '
        'tid=$tid, pid=$pid, referer=$referer, handleKey=$handleKey',
      );
      return null;
    }

    final noticeAuthorInput = element.querySelector('input[name="sendreasonpm"]');
    final noticeAuthorForced = noticeAuthorInput?.attributes.containsKey('disabled') ?? false;

    return RateWindowInfo(
      rowTitleList: rowTitleList,
      scoreList: scoreList,
      defaultReasonList: defaultReasonList ?? [],
      formHash: formHash,
      tid: tid,
      pid: pid,
      referer: referer,
      handleKey: handleKey,
      noticeAuthorForced: noticeAuthorForced,
    );
  }

  /// Build a row of score to rate in rate table.
  static RateWindowScore? _buildRateScoreRowFromTrNode(uh.Element element) {
    final name = element.querySelector('td')?.firstEndDeepText()?.trim();
    final id = element.querySelector('td:nth-child(2) > input')?.id;
    final allowedRange = element
        .querySelector('td:nth-child(2) > ul')
        ?.querySelectorAll('li')
        .map((e) => e.firstEndDeepText())
        .whereType<String>()
        .toList();
    final allowedRangeDescription = element.querySelector('td:nth-child(3)')?.firstEndDeepText();
    final remaining = element.querySelector('td:nth-child(4)')?.firstEndDeepText();
    if (name == null || id == null || allowedRange == null || allowedRangeDescription == null || remaining == null) {
      talker.error(
        'invalid rate score row: name=$name, id=$id, '
        'allowedRange=$allowedRange, '
        'allowedRangeDescription=$allowedRangeDescription',
      );
      return null;
    }

    return RateWindowScore(
      name: name,
      id: id,
      allowedRange: allowedRange,
      allowedRangeDescription: allowedRangeDescription,
      remaining: remaining,
    );
  }
}
