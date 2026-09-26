import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/utils/raw_query_parameters.dart';
import 'package:universal_html/html.dart' as uh;

/// The read-only title shop catalogue (plugin tsdmtitle).
const titleShopUrl = '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=shop';

/// The only endpoint a purchase may be posted to.
const titleBuyUrl = '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=buy';

final _digits = RegExp(r'^\d+$');

/// Query parameters of a same-origin `plugin.php` link of the tsdmtitle plugin, or null for anything else.
Map<String, String>? _pluginParams(String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final relative = Uri.tryParse(href.trim());
  if (relative == null) return null;
  final uri = Uri.parse(titleShopUrl).resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) ||
      uri.origin != Uri.parse(baseUrl).origin ||
      uri.userInfo.isNotEmpty ||
      uri.path != '/plugin.php' ||
      uri.fragment.isNotEmpty) {
    return null;
  }
  final params = rawQueryParameters(uri.query);
  if (params == null || params['id'] != 'tsdmtitle:tsdmtitle') return null;
  return params;
}

/// Only shop catalogue pages are fetched; a purchase URL never becomes a GET.
///
/// Allows the observed pagination form `action=shop&buyitem=0&page=N`; `buyitem` other than `0` is refused because
/// its meaning is not verified.
String? titleShopPageUrl(String? href) {
  final params = _pluginParams(href);
  if (params == null ||
      params['action'] != 'shop' ||
      params.keys.any((k) => !{'id', 'action', 'buyitem', 'page'}.contains(k)) ||
      (params.containsKey('buyitem') && params['buyitem'] != '0')) {
    return null;
  }
  final page = params['page'];
  if (page != null && (!_digits.hasMatch(page) || (int.tryParse(page) ?? 0) <= 0)) return null;
  return [
    titleShopUrl,
    if (params.containsKey('buyitem')) 'buyitem=0',
    if (page != null) 'page=$page',
  ].join('&');
}

/// Whether a `tsdmtitle_return` value only sends the browser back to the shop (as observed:
/// `plugin.php?id=tsdmtitle:tsdmtitle&action=shop&app=plugin`, optionally with a page).
bool _isShopReturn(String value) {
  final params = _pluginParams(value);
  if (params == null ||
      params['action'] != 'shop' ||
      params.keys.any((k) => !{'id', 'action', 'app', 'buyitem', 'page'}.contains(k)) ||
      (params.containsKey('app') && params['app'] != 'plugin') ||
      (params.containsKey('buyitem') && params['buyitem'] != '0')) {
    return false;
  }
  final page = params['page'];
  return page == null || (_digits.hasMatch(page) && (int.tryParse(page) ?? 0) > 0);
}

/// A validated purchase form for one title.
final class TitleBuyForm {
  /// Constructor.
  const TitleBuyForm({required this.formHash, required this.returnPath, required this.buyId, this.confirmText});

  /// Session token served with the form.
  final String formHash;

  /// Where the plugin sends the browser afterwards, a shop page.
  final String returnPath;

  /// Title id, equal to its row.
  final int buyId;

  /// The server's own confirmation sentence (carries the exact price), if present.
  final String? confirmText;

  /// Pinned endpoint; never taken from the page.
  String get url => titleBuyUrl;

  /// The form body exactly as the website submits it.
  Map<String, String> body() => {
    'formhash': formHash,
    'tsdmtitle_return': returnPath,
    'buyid': '$buyId',
    'buysubmit': 'true',
  };
}

/// Whether [control] is disabled in HTML terms: its own `disabled` attribute or a disabled fieldset up to [scope].
bool _disabledControl(uh.Element control, uh.Element scope) =>
    control.attributes.containsKey('disabled') ||
    _inside(control, (e) => e.localName == 'fieldset' && e.attributes.containsKey('disabled'), scope);

/// The HTML type of a form control: a `<button>` without a known type submits.
String _controlType(uh.Element control) {
  final type = (control.getAttribute('type') ?? '').trim().toLowerCase();
  if (control.localName == 'button') return const {'button', 'reset'}.contains(type) ? type : 'submit';
  return type.isEmpty ? 'text' : type;
}

/// Validate a row's purchase form. Returns null unless it posts to the plugin's buy action with exactly the observed
/// fields, a session token, the row's own id and a shop return path: a tampered page cannot redirect the purchase.
///
/// Follows browser submit semantics: every control must be enabled, and the only submitter must be an enabled
/// `buysubmit` submit button. A disabled or non-submitting control means the site itself does not offer the purchase.
TitleBuyForm? titleBuyForm(uh.Element form, int rowId) {
  if ((form.getAttribute('method') ?? '').toLowerCase() != 'post') return null;
  final params = _pluginParams(form.getAttribute('action'));
  if (params == null || params.length != 2 || params['action'] != 'buy') return null;
  final data = <String, String>{};
  final submitters = <uh.Element>[];
  for (final control in form.querySelectorAll('input, select, textarea, button')) {
    if (control.attributes.containsKey('form') || _disabledControl(control, form)) return null;
    final type = _controlType(control);
    if ((control.localName == 'button' || control.localName == 'input') && type == 'submit') {
      submitters.add(control);
      continue;
    }
    final name = control.getAttribute('name');
    if (control.localName != 'input' || type != 'hidden' || name == null || data.containsKey(name)) return null;
    data[name] = control.getAttribute('value') ?? '';
  }
  if (submitters.length != 1 ||
      submitters.single.getAttribute('name') != 'buysubmit' ||
      submitters.single.getAttribute('value') != 'true' ||
      data.keys.toSet().difference({'formhash', 'tsdmtitle_return', 'buyid'}).isNotEmpty) {
    return null;
  }
  final formHash = data['formhash'] ?? '';
  final returnPath = data['tsdmtitle_return'] ?? '';
  final buyId = data['buyid'] ?? '';
  if (formHash.isEmpty || !_isShopReturn(returnPath) || !_digits.hasMatch(buyId) || int.tryParse(buyId) != rowId) {
    return null;
  }
  final confirm = form.getAttribute('data-c')?.trim();
  return TitleBuyForm(
    formHash: formHash,
    returnPath: returnPath,
    buyId: rowId,
    confirmText: confirm == null || confirm.isEmpty ? null : confirm,
  );
}

/// What the current account may do with a title, as stated by the server.
enum TitleShopStatus {
  /// The row carries a valid purchase form.
  purchasable,

  /// The server says the account already owns it.
  owned,

  /// No usable purchase form; [TitleShopItem.statusText] holds the server wording, if any.
  unavailable,
}

/// One title in the shop.
final class TitleShopItem {
  /// Constructor.
  const TitleShopItem({
    required this.id,
    required this.name,
    required this.price,
    required this.status,
    this.imageUrl,
    this.statusText,
    this.form,
  });

  /// Title id.
  final int id;

  /// Title name.
  final String name;

  /// Price digits as served; kept as text so very large amounts are never overflowed or reinterpreted.
  final String price;

  /// Safe image URL, if supplied.
  final String? imageUrl;

  /// Account status.
  final TitleShopStatus status;

  /// Server wording in the purchase column when there is no form (e.g. 已拥有).
  final String? statusText;

  /// Validated purchase form when [status] is [TitleShopStatus.purchasable].
  final TitleBuyForm? form;

  /// Whether a confirmation shown for this item still describes [other] exactly.
  bool sameTerms(TitleShopItem other) =>
      id == other.id && name == other.name && price == other.price && form?.confirmText == other.form?.confirmText;
}

/// One page of the title shop.
final class TitleShopCatalog {
  /// Constructor.
  const TitleShopCatalog({
    this.heading,
    this.intro = const [],
    this.items = const [],
    this.page = 1,
    this.previousUrl,
    this.nextUrl,
    this.balance,
    this.supported = true,
    this.message,
  });

  /// Shop heading as served.
  final String? heading;

  /// Server introduction paragraphs (durations, rules), shown verbatim.
  final List<String> intro;

  /// Titles on this page, each id once.
  final List<TitleShopItem> items;

  /// Current page reported by the forum.
  final int page;

  /// Safe previous page link.
  final String? previousUrl;

  /// Safe next page link.
  final String? nextUrl;

  /// The currency line of the account status box (e.g. `天使币：…`), shown but never logged.
  final String? balance;

  /// Whether the document carries the known shop table.
  final bool supported;

  /// Server message when the table is missing.
  final String? message;
}

/// Visible text: scripts, styles and controls removed, whitespace collapsed per line.
String titleShopText(uh.Element? node) {
  if (node == null) return '';
  final clone = node.clone(true) as uh.Element;
  for (final e in clone.querySelectorAll('script, style, button, input')) {
    e.remove();
  }
  for (final br in clone.querySelectorAll('br')) {
    br.replaceWith(uh.Text('\n'));
  }
  return (clone.text ?? '')
      .split('\n')
      .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((s) => s.isNotEmpty)
      .join('\n');
}

bool _inside(uh.Element node, bool Function(uh.Element) test, uh.Element stop) {
  for (var e = node.parent; e != null && !identical(e, stop); e = e.parent) {
    if (test(e)) return true;
  }
  return false;
}

const _headers = ['称号ID', '称号名称', '称号价格', '图片', '购买'];

String? _safeImage(uh.Element? img) {
  final src = img?.getAttribute('src')?.trim();
  if (src == null || src.isEmpty) return null;
  final relative = Uri.tryParse(src);
  if (relative == null) return null;
  final uri = Uri.parse(baseUrl).resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return uri.toString();
}

/// Parse the shop page without running scripts. Only rows of the table with the known header are read.
TitleShopCatalog parseTitleShop(uh.Document document) {
  final table = document
      .querySelectorAll('table.dt')
      .where((t) => t.querySelectorAll('thead th').map(titleShopText).join('|') == _headers.join('|'))
      .firstOrNull;
  if (table == null) {
    final message = titleShopText(document.querySelector('#messagetext p') ?? document.querySelector('#messagetext'));
    return TitleShopCatalog(supported: false, message: message.isEmpty ? null : message);
  }

  final items = <TitleShopItem>[];
  final seen = <int>{};
  for (final row in table.querySelectorAll('tbody > tr')) {
    final cells = row.querySelectorAll('td');
    if (cells.length != 5) continue;
    final idText = titleShopText(cells[0]);
    final name = titleShopText(cells[1]);
    final price = titleShopText(cells[2]).replaceAll(RegExp(r'\s'), '');
    final id = _digits.hasMatch(idText) ? int.tryParse(idText) : null;
    if (id == null || id <= 0 || name.isEmpty || !_digits.hasMatch(price) || !seen.add(id)) continue;
    final forms = cells[4].querySelectorAll('form');
    final form = forms.length == 1 ? titleBuyForm(forms.single, id) : null;
    var text = titleShopText(cells[4]);
    if (form == null && text.isEmpty) {
      // A form the site disabled usually says why on its button (e.g. 余额不足); a plain 购买 is not a reason.
      text = forms
          .expand((f) => f.querySelectorAll('button, input'))
          .where((b) => b.localName == 'button' || _controlType(b) == 'submit')
          .where((b) => _disabledControl(b, cells[4]) || _controlType(b) == 'button')
          .map((b) => b.localName == 'button' ? titleShopText(b) : (b.getAttribute('value') ?? '').trim())
          .where((t) => t.isNotEmpty && t != '购买')
          .join('\n');
    }
    items.add(
      TitleShopItem(
        id: id,
        name: name,
        price: price,
        imageUrl: _safeImage(cells[3].querySelector('img')),
        status: form != null
            ? TitleShopStatus.purchasable
            : forms.isEmpty && text == '已拥有'
            ? TitleShopStatus.owned
            : TitleShopStatus.unavailable,
        statusText: form != null || text.isEmpty ? null : text,
        form: form,
      ),
    );
  }

  final heading = document.querySelectorAll('h2').where((h) => titleShopText(h) == '称号商店').firstOrNull;
  var container = heading?.parent;
  for (var e = heading?.parent; e != null; e = e.parent) {
    if (e.classes.contains('bm')) {
      container = e;
      break;
    }
  }
  final intro = <String>[];
  if (container != null) {
    for (final p in container.querySelectorAll('p')) {
      if (_inside(p, (e) => e.localName == 'table' || e.localName == 'form' || e.classes.contains('pg'), container)) {
        continue;
      }
      final text = titleShopText(p);
      if (text.isNotEmpty) intro.add(text);
    }
  }

  String? balance;
  final status = document
      .querySelectorAll('h2, h3, strong, span, div')
      .where((e) => e.children.isEmpty && titleShopText(e) == '我的状态')
      .firstOrNull;
  var box = status?.parent;
  for (var depth = 0; box != null && depth < 3 && balance == null; depth++, box = box.parent) {
    balance = box.querySelectorAll('li').map(titleShopText).where((t) => t.startsWith('天使币')).firstOrNull;
  }

  // The pager is repeated above and below the table; the first one is read and nothing is added twice.
  final pagination = document.querySelector('.pg');
  return TitleShopCatalog(
    heading: heading == null ? null : titleShopText(heading),
    intro: List.unmodifiable(intro),
    items: List.unmodifiable(items),
    page: int.tryParse(titleShopText(pagination?.querySelector('strong'))) ?? 1,
    previousUrl: titleShopPageUrl(pagination?.querySelector('a.prev')?.getAttribute('href')),
    nextUrl: titleShopPageUrl(pagination?.querySelector('a.nxt')?.getAttribute('href')),
    balance: balance,
  );
}

/// The server's answer to a purchase POST. Wording is quoted, never interpreted as success.
({bool error, String? message}) parseTitleBuyResponse(uh.Document document) {
  final error = document.querySelector('.alert_error');
  if (error != null) {
    final text = titleShopText(error.querySelector('p') ?? error);
    return (error: true, message: text.isEmpty ? null : text);
  }
  final message = document.querySelector('#messagetext');
  final text = titleShopText(message?.querySelector('p') ?? message);
  return (error: false, message: text.isEmpty ? null : text);
}
