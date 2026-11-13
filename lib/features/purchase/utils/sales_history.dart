import 'package:flutter/foundation.dart' show immutable;
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart' show currentLoginUid;
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// One buyer in the sales history of a paid thread.
@immutable
final class SaleLogItem {
  /// Constructor.
  const SaleLogItem({required this.username, required this.uid, required this.time, required this.price});

  /// The buyer.
  final String username;

  /// The buyer's uid.
  final String uid;

  /// When it was bought, the forum's wall clock.
  final DateTime time;

  /// What the buyer paid, with the unit of the credit: the text of the page's last column.
  final String price;

  @override
  bool operator ==(Object other) =>
      other is SaleLogItem &&
      other.username == username &&
      other.uid == uid &&
      other.time == time &&
      other.price == price;

  @override
  int get hashCode => Object.hash(username, uid, time, price);

  @override
  String toString() => 'SaleLogItem($username, $uid, $time, $price)';
}

/// The sales history page of thread [tid] as the forum's floating window asks it (an AJAX xml answer).
String salesHistoryWindowUrl(String tid) =>
    '$baseUrl/forum.php?mod=misc&action=viewpayments&tid=$tid'
    '&infloat=yes&handlekey=pay&inajax=1&ajaxtarget=fwin_content_pay';

/// The buyers in the floating window [document] of the sales history (`table.list`: user, time, amount).
List<SaleLogItem> saleLogItemsOfDocument(uh.Document document) {
  final items = <SaleLogItem>[];
  for (final row in document.querySelectorAll('table.list tr')) {
    final tds = row.querySelectorAll('td');
    if (tds.length != 3) {
      continue;
    }
    final userNode = tds.first.querySelector('a');
    final username = userNode?.innerText.trim();
    final uid = userNode?.attributes['href']?.tryParseAsUri()?.queryParameters['uid'];
    final time = tds[1].dateTime();
    final price = tds[2].innerText.trim();
    if (username != null && uid != null && time != null) {
      items.add(SaleLogItem(username: username, uid: uid, time: time, price: price));
    }
  }
  return items;
}

/// The buyers of the sales history page of the forum's app API (plugin 4.0.0: `type: payments`, `schema` 51), the
/// same as the window lists them: the time as the page prints it (the member's wall clock, to the second), the
/// amount with the unit of the credit traded. A row without a buyer or a time is left out, as the window parser does.
List<SaleLogItem> saleLogItemsFromApi(Map<String, dynamic> json) {
  final unit = tsdmAppText(tsdmAppMap(json['credit'])['unit']);
  final offset = tsdmAppTimeOffset(json);
  final items = <SaleLogItem>[];
  for (final row in tsdmAppList(json['logs'])) {
    final uid = tsdmAppInt(row['uid']);
    final name = tsdmAppText(row['username']);
    final time = tsdmAppWallClockTime(row['dateline'], offset);
    if (uid > 0 && name.isNotEmpty && time != null) {
      items.add(
        SaleLogItem(username: name, uid: '$uid', time: time, price: '${tsdmAppInt(row['amount'])} $unit'.trim()),
      );
    }
  }
  return items;
}

/// The sales history of thread [tid], read with [client] (the account's) as the account logged in now: from the forum's
/// app API when it answers it (plugin 4.0.0, `thread_lists` names `payments`, [saleLogItemsFromApi]), else from the
/// floating window as before. Empty when it could not be read or the forum refused it (it shows nothing then, as
/// before).
Future<List<SaleLogItem>> fetchSalesHistory(String tid, {NetClientProvider? client, int Function()? currentUid}) async {
  final net = client ?? getIt.get<NetClientProvider>();
  if (TsdmAppV4.has(TsdmAppV4Group.threadLists, 'payments')) {
    final answer = await fetchTsdmAppV4Page(
      net,
      '$baseUrl/forum.php?mod=misc&action=viewpayments&tid=$tid',
      type: 'payments',
      schema: 51,
      uid: (currentUid ?? currentLoginUid)(),
    ).run();
    switch (answer) {
      case Left(:final value):
        talker.error('failed to fetch the sales history: $value');
        return const [];
      case Right(value: TsdmAppV4Page(:final json)):
        return saleLogItemsFromApi(json);
      case Right(value: final TsdmAppV4Answer refused):
        talker.warning('sales history refused: ${refused.json['message_key'] ?? refused.json['error']}');
        return const [];
      case Right(value: null):
        break;
    }
  }
  final result = await net
      .get(salesHistoryWindowUrl(tid))
      .mapHttp((v) => v.data as String)
      .map((e) => parseXmlDocument(e).documentElement?.nodes.first.text ?? '')
      .map(parseHtmlDocument)
      .run();
  if (result.isLeft()) {
    talker.error('failed to parse sales history item: ${result.unwrapErr()}');
    return const [];
  }
  return saleLogItemsOfDocument(result.unwrap());
}
