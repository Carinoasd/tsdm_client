import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The forum's url [relative] (as a page prints it) on the forum's host; null when empty or on another host.
String? tradeForumUrl(String? relative) {
  final value = relative?.trim() ?? '';
  if (value.isEmpty || value.startsWith('javascript:')) {
    return null;
  }
  final base = Uri.parse('$baseUrl/');
  final Uri url;
  try {
    url = base.resolve(value.replaceAll('&amp;', '&'));
  } on FormatException {
    return null;
  }
  if (url.host != base.host) {
    return null;
  }
  return url.replace(scheme: base.scheme).toString();
}

/// The goods page (`forum.php?mod=viewthread&do=tradeinfo&tid=&pid=`) of the goods [pid] of the thread [tid].
String tradeGoodsUrl({required int tid, required int pid}) =>
    '$baseUrl/forum.php?mod=viewthread&do=tradeinfo&tid=$tid&pid=$pid';

/// The order page of the order [orderId] (`forum.php?mod=trade&orderid=`), where the buyer pays and the order goes
/// on.
String tradeOrderUrl(String orderId) => '$baseUrl/forum.php?mod=trade&orderid=${Uri.encodeQueryComponent(orderId)}';

/// The account's orders (`home.php?mod=space&do=trade&view=tradelog`, 交易记录).
const tradeOrdersUrl = '$baseUrl/home.php?mod=space&do=trade&view=tradelog';

/// The tid and the pid of a goods page url [url]; null when it is not one.
({int tid, int pid})? tradeGoodsOfUrl(String? url) {
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || uri.queryParameters['do'] != 'tradeinfo') {
    return null;
  }
  final tid = int.tryParse(uri.queryParameters['tid'] ?? '');
  final pid = int.tryParse(uri.queryParameters['pid'] ?? '');
  return tid == null || pid == null || tid <= 0 || pid <= 0 ? null : (tid: tid, pid: pid);
}

/// The text of the forum's 提示信息 page (`div#messagetext`) in [document], null when the page is not one.
String? tradeMessageOf(uh.Document document) {
  final message = document.querySelector('div#messagetext');
  if (message == null) {
    return null;
  }
  final text = (message.querySelector('p')?.text ?? message.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? null : text;
}

String _text(uh.Element? element) => (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The labels the goods page prints for the remaining time and the stock (`trade_remaindays`, `post_trade_number`),
/// simplified and traditional.
const _remainLabels = {'剩余时间', '剩餘時間'};
const _stockLabels = {'商品数量', '商品數量'};

/// A row "label: value" of the goods page's details, as the page prints them.
final class TradeInfoRow {
  /// Constructor.
  const TradeInfoRow(this.label, this.value);

  /// The page's label, without its colon.
  final String label;

  /// The value.
  final String value;

  @override
  String toString() => '$label: $value';
}

/// The goods page (`forum.php?mod=viewthread&do=tradeinfo`, the default template `forum/trade_info`): what the thread
/// page's list does not carry. The plugin's JSON mode gives nothing of it (its answer to this page is the bread crumbs
/// only), so the web page is read.
final class TradeGoodsDetail {
  /// Constructor.
  const TradeGoodsDetail({
    required this.servedUid,
    required this.removed,
    required this.subject,
    required this.sellerUid,
    required this.sellerName,
    required this.sellerAvatar,
    required this.thumb,
    required this.image,
    required this.rows,
    required this.stock,
    required this.prices,
    required this.costPrices,
    required this.buyUrl,
    required this.soldOut,
    required this.descriptionHtml,
  });

  /// Read the goods page [document]; null when it is not one (the forum's message, another page).
  static TradeGoodsDetail? parse(uh.Document document) {
    final servedUid = parseLoggedUidFromDocument(document);
    if (document.querySelector('div.trdb') != null && document.querySelector('div.spi') == null) {
      return TradeGoodsDetail(
        servedUid: servedUid,
        removed: true,
        subject: '',
        sellerUid: 0,
        sellerName: '',
        sellerAvatar: null,
        thumb: null,
        image: null,
        rows: const [],
        stock: null,
        prices: const [],
        costPrices: const [],
        buyUrl: null,
        soldOut: false,
        descriptionHtml: '',
      );
    }
    final spi = document.querySelector('div.spi');
    if (spi == null) {
      return null;
    }
    final subject = _text(document.querySelector('h1.ph a') ?? document.querySelector('h1.ph'));
    // The seller: the name is the text of the header's `dt` around the private message link and the online mark.
    final header = document.querySelector('div.ih dt');
    final sellerName = header == null
        ? ''
        : header.nodes.whereType<uh.Text>().map((e) => e.text ?? '').join().replaceAll(RegExp(r'\s+'), ' ').trim();
    final sellerLink = document.querySelector('div.ih .avt a')?.attributes['href'] ?? '';
    final sellerUid = int.tryParse(RegExp(r'uid=(\d+)').firstMatch(sellerLink)?.group(1) ?? '') ?? 0;
    final avatarImg = document.querySelector('div.ih .avt img');
    final avatar = tradeForumUrl(avatarImg?.attributes['data-src'] ?? avatarImg?.attributes['src']);

    final picture = document.querySelector('div.spvimg img');
    final thumb = tradeForumUrl(picture?.attributes['src']);
    final zoomed = RegExp(r"zoom\(this,\s*'([^']+)'").firstMatch(picture?.attributes['onclick'] ?? '')?.group(1);
    final image = tradeForumUrl(zoomed) ?? thumb;

    final rows = <TradeInfoRow>[];
    int? stock;
    final lists = spi.querySelectorAll('dl');
    final details = lists.where((e) => !e.classes.contains('nums')).firstOrNull;
    if (details != null) {
      String? label;
      for (final child in details.children) {
        if (child.localName == 'dt') {
          label = _text(child).replaceAll(RegExp(r'[:：]\s*$'), '').trim();
        } else if (child.localName == 'dd' && label != null) {
          final value = _text(child);
          // The forum prints " 小时" for a goods without a time limit: nothing to say.
          final empty =
              value.isEmpty ||
              (_remainLabels.contains(label) && !RegExp(r'\d').hasMatch(value) && child.querySelector('em') == null);
          if (!empty) {
            rows.add(TradeInfoRow(label, value));
          }
          if (_stockLabels.contains(label)) {
            stock = int.tryParse(value);
          }
          label = null;
        }
      }
    }
    final prices = [
      for (final p in spi.querySelectorAll('dl.nums dd p'))
        if (_text(p) case final text when text.isNotEmpty) text,
    ];
    final costPrices = [
      for (final del in spi.querySelectorAll('dd.xg1 del'))
        if (_text(del) case final text when text.isNotEmpty) text,
    ];

    // The buy button: the page prints it for another account than the seller's while the trade is open, opening the
    // order form (`forum.php?mod=trade&tid=&pid=`); disabled when sold out; a guest's opens the login.
    String? buyUrl;
    var soldOut = false;
    for (final button in spi.querySelectorAll('p.pns button')) {
      final onclick = button.attributes['onclick'] ?? '';
      final target = RegExp(r"'(forum\.php\?mod=trade&(?:amp;)?tid=\d+&(?:amp;)?pid=\d+)'").firstMatch(onclick);
      if (target != null) {
        buyUrl = tradeForumUrl(target.group(1));
      } else if (button.attributes.containsKey('disabled') && onclick.isEmpty) {
        soldOut = true;
      }
    }
    final description = document.querySelector('div.mtw div.c') ?? document.querySelector('div.c.pbm');
    return TradeGoodsDetail(
      servedUid: servedUid,
      removed: false,
      subject: subject,
      sellerUid: sellerUid,
      sellerName: sellerName,
      sellerAvatar: avatar,
      thumb: thumb,
      image: image,
      rows: rows,
      stock: stock,
      prices: prices,
      costPrices: costPrices,
      buyUrl: buyUrl,
      soldOut: soldOut,
      descriptionHtml: description?.innerHtml?.trim() ?? '',
    );
  }

  /// The account the page was served to (null: a guest page).
  final int? servedUid;

  /// The goods' floor was deleted: the page says only that.
  final bool removed;

  /// Name.
  final String subject;

  /// The seller.
  final int sellerUid;

  /// The seller's name.
  final String sellerName;

  /// The seller's avatar (absolute), null when the page has none.
  final String? sellerAvatar;

  /// The picture (absolute), null when none.
  final String? thumb;

  /// The picture at full size (absolute), null when none.
  final String? image;

  /// The details as the page prints them: quality, shipping, time left, stock, place, sold.
  final List<TradeInfoRow> rows;

  /// How many are left, when the page says.
  final int? stock;

  /// The price lines (`10 元`, `附加 10 天使币`).
  final List<String> prices;

  /// The original price lines, struck through on the page.
  final List<String> costPrices;

  /// The order form (absolute), null when the page offers no buying to this account (the seller, a guest, an ended
  /// trade, a closed thread).
  final String? buyUrl;

  /// The page's buy button is disabled: sold out.
  final bool soldOut;

  /// The goods' description (its floor's content), html.
  final String descriptionHtml;
}

/// A text field of the order form the forum shows (the receiver's name, address, zip, phones), with its label.
final class TradeBuyField {
  /// Constructor.
  const TradeBuyField({required this.name, required this.label, required this.value, required this.maxLength});

  /// The form field.
  final String name;

  /// The form's label.
  final String label;

  /// The value the forum filled in (the account's last order).
  final String value;

  /// The field's limit, null when none.
  final int? maxLength;
}

/// The order form of a goods (`forum.php?mod=trade&tid=&pid=`, template `forum/trade`).
///
/// Never read with `action=trade` in the url: the forum then creates the order at once, without the form hash.
final class TradeBuyForm {
  /// Constructor.
  const TradeBuyForm({
    required this.servedUid,
    required this.action,
    required this.formHash,
    required this.defaults,
    required this.fields,
    required this.messageLabel,
    required this.price,
    required this.credit,
    required this.balance,
  });

  /// Read the order form page [document]; null when it is not one (the forum's message: closed, not found, log in).
  static TradeBuyForm? parse(uh.Document document) {
    final form = document.querySelector('form#tradepost');
    final action = tradeForumUrl(form?.attributes['action']);
    if (form == null || action == null || !action.contains('mod=trade') || !action.contains('action=trade')) {
      return null;
    }
    final defaults = <String, String>{};
    final fields = <TradeBuyField>[];
    for (final input in form.querySelectorAll('input')) {
      final name = input.attributes['name'] ?? '';
      final type = (input.attributes['type'] ?? 'text').toLowerCase();
      if (name.isEmpty || type == 'submit' || type == 'button') {
        continue;
      }
      final value = input.attributes['value'] ?? '';
      if (type == 'radio' || type == 'checkbox') {
        // The first checked one (the shipping fees are all printed checked: the browser keeps the last, the forum
        // takes any).
        if (input.attributes.containsKey('checked')) {
          defaults.putIfAbsent(name, () => value);
        }
        continue;
      }
      defaults[name] = value;
      if (type == 'text' && name != 'number') {
        final id = input.attributes['id'];
        final label = id == null ? '' : _text(form.querySelector('label[for="$id"]'));
        fields.add(
          TradeBuyField(
            name: name,
            label: label.isEmpty ? name : label,
            value: value,
            maxLength: int.tryParse(input.attributes['maxlength'] ?? ''),
          ),
        );
      }
    }
    final message = form.querySelector('textarea[name="buyermsg"]');
    if (message != null) {
      defaults['buyermsg'] = message.text ?? '';
    }
    final messageId = message?.attributes['id'];
    final scripts = document.querySelectorAll('script').map((e) => e.text ?? '').join('\n');
    num? number(String name) => num.tryParse(RegExp('var $name = (-?[0-9.]+);').firstMatch(scripts)?.group(1) ?? '');
    return TradeBuyForm(
      servedUid: parseLoggedUidFromDocument(document),
      action: action,
      formHash: defaults['formhash'] ?? '',
      defaults: defaults,
      fields: fields,
      messageLabel: messageId == null ? '' : _text(form.querySelector('label[for="$messageId"]')),
      price: number('price') ?? 0,
      credit: (number('credit') ?? 0).toInt(),
      balance: number('currentcredit')?.toInt(),
    );
  }

  /// The account the form was served to (null: a guest page).
  final int? servedUid;

  /// Where the form goes (absolute, `forum.php?mod=trade&action=trade&tid=&pid=`).
  final String action;

  /// The session's form hash.
  final String formHash;

  /// Every field as the forum filled it: the hidden ones (the shipping, the payment), the checked choices, the texts.
  final Map<String, String> defaults;

  /// The receiver's fields the forum shows (none for a virtual goods: hidden and empty).
  final List<TradeBuyField> fields;

  /// The form's label of the buyer's message.
  final String messageLabel;

  /// The price in money of one (0: none).
  final num price;

  /// The price in the trade credit of one (0: none).
  final int credit;

  /// The account's trade credit, when the page says (it does for a goods sold for credit).
  final int? balance;

  /// Sold for the trade credit alone: the order is paid in the app. Money goes through the website.
  bool get creditOnly => price <= 0 && credit > 0;

  /// The credit [number] goods cost.
  int total(int number) => credit * number;

  /// The body of the order of [number] goods with the buyer's [message] and the receiver's [values] (by field name):
  /// the forum's own fields with the user's on top.
  Map<String, String> orderBody({
    required int number,
    required String message,
    Map<String, String> values = const {},
  }) => {
    ...defaults,
    for (final field in fields) field.name: values[field.name] ?? field.value,
    'number': '$number',
    'buyermsg': message,
    'tradesubmit': 'true',
  };
}

/// The body of paying the order: the buyer's "我已付款" of a guaranteed trade (`offlinestatus` 4), which the forum
/// takes with the account's login password and which takes the credit. [message] goes to the order's messages.
Map<String, String> tradePayBody({required String formHash, required String password, String message = ''}) => {
  'formhash': formHash,
  'password': password,
  'message': message,
  'offlinestatus': '4',
  'offlinesubmit': 'true',
};

/// What the forum answered a step of buying.
sealed class TradeOutcome {
  const TradeOutcome();
}

/// The forum created the order [orderId] (`trade_order_created`).
final class TradeOrderCreated extends TradeOutcome {
  /// Constructor.
  const TradeOrderCreated(this.orderId);

  /// The order.
  final String orderId;
}

/// The forum took the payment (`trade_orderstatus_updated`).
final class TradePaid extends TradeOutcome {
  /// Constructor.
  const TradePaid();
}

/// The forum refused, with its [message] (empty when it gave none); [verification] when it asks for a captcha or a
/// security question only the website shows; [login] when it asks to log in.
final class TradeRefused extends TradeOutcome {
  /// Constructor.
  const TradeRefused(this.message, {this.verification = false, this.login = false});

  /// The forum's words.
  final String message;

  /// The forum asks for a verification.
  final bool verification;

  /// The forum asks to log in.
  final bool login;
}

/// No verdict: the request failed, or the forum answered something else. The step may have been done all the same.
final class TradeUnknown extends TradeOutcome {
  /// Constructor.
  const TradeUnknown();
}

const _orderCreatedKey = 'trade_order_created';
const _paidKey = 'trade_orderstatus_updated';

/// The order an url [url] of the forum goes on to (`forum.php?mod=trade&orderid=`), null when it is not one.
String? _orderIdOf(String url) {
  final uri = Uri.tryParse(url.replaceAll('&amp;', '&'));
  if (uri == null || uri.queryParameters['mod'] != 'trade') {
    return null;
  }
  final id = uri.queryParameters['orderid'] ?? '';
  return RegExp(r'^[0-9A-Za-z]+$').hasMatch(id) ? id : null;
}

/// The outcome of the forum's answer [data] to a step of buying, done with the language key [doneKey]: the JSON
/// result of the forum's app API (plugin 2.6.0) decided by its key alone (the forum shows a refusal with a link, the
/// wrong password, as `alert` info and `ok` 1 like a success), or the forum's own 提示信息 page without the plugin,
/// read by [page] (its class, its text, the link to go on to; null: no verdict).
TradeOutcome _outcomeOf(
  Object? data, {
  required String doneKey,
  required TradeOutcome Function(String url) done,
  required TradeOutcome? Function({required bool error, required String message, required String link}) page,
}) {
  final result = tsdmAppWriteResultOf(data);
  if (result != null) {
    if (result.kind == TsdmAppWriteKind.page) {
      return const TradeUnknown();
    }
    if (result.login) {
      return TradeRefused(result.reason, login: true);
    }
    if (result.asksVerification) {
      return TradeRefused(result.reason, verification: true);
    }
    if (result.messageKey == doneKey) {
      return done(result.url);
    }
    if (result.messageKey.isEmpty && result.message.isEmpty) {
      return const TradeUnknown();
    }
    return TradeRefused(result.message);
  }
  final document = parseHtmlDocument(tsdmAppAnswerText(data));
  final message = tradeMessageOf(document);
  if (message == null) {
    return const TradeUnknown();
  }
  if (document.querySelector('div#messagelogin') != null) {
    return TradeRefused(message, login: true);
  }
  final box = document.querySelector('div#messagetext');
  return page(
        error: box?.classes.contains('alert_error') ?? false,
        message: message,
        link: box?.querySelector('p.alert_btnleft a')?.attributes['href'] ?? '',
      ) ??
      const TradeUnknown();
}

/// The outcome of placing an order (`forum.php?mod=trade&action=trade`): [TradeOrderCreated] with the order the forum
/// goes on to, [TradeRefused] with the forum's words (`trade_lack`, `trade_by_myself`, `trade_closed`…), or
/// [TradeUnknown].
///
/// Without the plugin the forum's page tells a created order by the link to its order page; any other message is a
/// refusal.
TradeOutcome tradeOrderOutcomeOf(Object? data) => _outcomeOf(
  data,
  doneKey: _orderCreatedKey,
  done: (url) => switch (_orderIdOf(url)) {
    final String id => TradeOrderCreated(id),
    null => const TradeUnknown(),
  },
  page: ({required error, required message, required link}) => switch (error ? null : _orderIdOf(link)) {
    final String id => TradeOrderCreated(id),
    null => TradeRefused(message),
  },
);

/// The outcome of paying an order ([tradePayBody]): [TradePaid], [TradeRefused] with the forum's words
/// (`trade_password_error`, `trade_credit_lack`), or [TradeUnknown] (an order no longer waiting for the payment gets
/// the forum's error page).
///
/// Without the plugin the forum shows the wrong password and the done payment alike (a note with a link to the
/// order): no verdict but for a refusal shown as one; only the order page tells.
TradeOutcome tradePayOutcomeOf(Object? data) => _outcomeOf(
  data,
  doneKey: _paidKey,
  done: (_) => const TradePaid(),
  page: ({required error, required message, required link}) => error ? TradeRefused(message) : null,
);
