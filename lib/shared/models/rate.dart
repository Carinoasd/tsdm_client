part of 'models.dart';

/// Single rate record for a single user.
@MappableClass()
class SingleRate with SingleRateMappable {
  /// Constructor.
  const SingleRate({required this.user, required this.attrValueList});

  /// User info.
  /// Name, user space url and avatar url is required.
  final User user;

  /// Rate content.
  /// Values for each attr in this rate.
  /// Should have same length with attrList in rate info table.
  final List<String> attrValueList;
}

/// Rate record for a single user.
@MappableClass()
class Rate with RateMappable {
  /// Constructor.
  const Rate({
    required this.userCount,
    required this.detailUrl,
    required this.attrList,
    required this.records,
    required this.rateStatus,
  });

  /// Count of users rated.
  final int? userCount;

  /// Url contains rate detail info.
  final String? detailUrl;

  /// Rated attributes.
  /// Show as column header.
  /// Should have same length with attrValueList in single rate record.
  final List<String> attrList;

  /// Records of rating.
  final List<SingleRate> records;

  /// Total rate status.
  final String? rateStatus;

  /// Build a [Rate] from element <dl id="ratelog_xxx" class="rate">.
  ///
  /// ```html
  /// <dl id="ratelog_${PID}" class="rate">
  ///   <dd>
  ///     <table class="ratl">
  ///       <tr>
  ///         <th><a href="...action=viewratings..."> 参与人数 <span class="xi1">${USER_COUNT}</span></a></th>
  ///         <th>${ATTR_NAME} <i><span class="xi1">${ATTR_TOTAL}</span></i></th>
  ///         ...
  ///         <th><a class="y xi2 op">收起</a><i class="txt_h">理由</i></th>
  ///       </tr>
  ///       <tbody class="ratl_l">
  ///         <tr id="rate_${PID}_${UID}">
  ///           <td><a href="...uid=${UID}"><img data-src="${AVATAR}"></a> <a href="...uid=${UID}">${NAME}</a></td>
  ///           <td class="xi1"> + 100</td>
  ///           ...
  ///           <td class="xg1">${REASON}</td>
  ///         </tr>
  ///       </tbody>
  ///     </table>
  ///     <p class="ratc"><a>查看全部评分</a></p>
  ///   </dd>
  /// </dl>
  /// ```
  static Rate? fromRateLogNode(uh.Element? element) {
    if (element == null) {
      return null;
    }
    // The header row may be directly in `<table>` (and parsed into a `<tbody>` by the html parser) or in `<thead>`.
    final rateHeaders = element.querySelectorAll('table.ratl > tbody:nth-child(1) > tr > th');
    final headers = rateHeaders.isNotEmpty ? rateHeaders : element.querySelectorAll('table th');
    if (headers.length < 2) {
      talker.error('failed to build rate: invalid rate header');
      return null;
    }

    final infoNode = headers.firstOrNull?.querySelector('a');
    final userCount = infoNode?.querySelector('span.xi1')?.firstEndDeepText()?.parseToInt();
    if (userCount == null) {
      talker.error('failed to build rate: user count not found');
      return null;
    }
    final detailUrl = infoNode?.firstHref()?.prependHost();
    if (detailUrl == null) {
      talker.error('failed to build rate: detail url not found');
      return null;
    }

    // Attribute columns: `${ATTR_NAME} <i><span class="xi1">${ATTR_TOTAL}</span></i>`.
    //
    // Attribute name is in the text nodes directly under `<th>`, total value is inside `<i>`.
    // The last column is rate reason: `<i class="txt_h">理由</i>`.
    final attrList = <String>[];
    final totalList = <String>[];
    for (final th in headers.skip(1)) {
      final name = th.nodes
          .where((e) => e.nodeType == uh.Node.TEXT_NODE)
          .map((e) => e.text?.trim() ?? '')
          .where((e) => e.isNotEmpty)
          .join(' ');
      final iNode = th.querySelector('i');
      final iText = iNode?.innerText.trim();
      if (name.isNotEmpty) {
        attrList.add(name);
        if (iText != null && iText.isNotEmpty) {
          totalList.add('$name $iText');
        }
      } else if (iText != null && iText.isNotEmpty) {
        // Legacy style where the attr name is inside `<i>`, or the reason column.
        attrList.add(iText);
      }
    }
    if (attrList.isEmpty) {
      talker.error('failed to build rate: rate attr list is empty');
      return null;
    }

    final recordNodeList = element.querySelectorAll('table > tbody.ratl_l > tr');
    final records = recordNodeList.map(_parseSingleRate).whereType<SingleRate>().toList();
    if (records.isEmpty) {
      talker.error('failed to build rate: records is empty');
      return null;
    }

    // Total rate status.
    //
    // Legacy style has it in `<p class="ratc"><span>...</span></p>`, Discuz X5 has only totals in headers.
    final ratcSpans = element
        .querySelector('p.ratc')
        ?.querySelectorAll('span')
        .map((e) => e.firstEndDeepText()?.trim())
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .toList();
    final rateStatus = (ratcSpans?.isNotEmpty ?? false) ? ratcSpans!.join(' ') : totalList.join(' ');

    return Rate(
      userCount: userCount,
      detailUrl: detailUrl,
      attrList: attrList,
      records: records,
      rateStatus: rateStatus,
    );
  }

  /// Try parse a [SingleRate] from [element] <tr id="xxx">
  static SingleRate? _parseSingleRate(uh.Element element) {
    final tdList = element.querySelectorAll('td');
    if (tdList.length < 2) {
      return null;
    }
    final userNode = tdList.firstOrNull;
    final linkNodes = userNode?.querySelectorAll('a[href*="uid="]') ?? <uh.Element>[];
    final url = linkNodes.firstOrNull?.attributes['href']?.prependHost() ?? userNode?.querySelector('a')?.firstHref();
    final avatarUrl = userNode?.querySelector('a > img')?._lazyImageUrl();
    final name =
        linkNodes.map((e) => e.innerText.trim()).firstWhereOrNull((e) => e.isNotEmpty) ??
        userNode?.querySelector('a:nth-child(2)')?.firstEndDeepText();
    final uid = _uidFromUrl(url);
    final attrValueList = tdList.skip(1).map((e) => e.innerText.trim().replaceAll(RegExp(r'\s+'), ' ')).toList();

    if (url == null || name == null) {
      return null;
    }
    return SingleRate(
      user: User(name: name, url: url, uid: uid, avatarUrl: avatarUrl),
      attrValueList: attrValueList,
    );
  }
}
