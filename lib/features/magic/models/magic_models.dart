import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/raw_query_parameters.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The magic shop of the forum (`home.php?mod=magic`), first page.
const magicShopUrl = '$baseUrl/home.php?mod=magic&action=shop';

/// The magics the account owns.
const magicBoxUrl = '$baseUrl/home.php?mod=magic&action=mybox';

/// The handle key the app asks the magic windows with, as the website's `showWindow('magics', …)` does.
const magicHandleKey = 'magics';

final _digits = RegExp(r'^\d+$');
final _spaces = RegExp(r'\s+');

/// Which list a page url belongs to.
enum MagicList {
  /// The shop (`action=shop`).
  shop,

  /// The account's magics (`action=mybox`).
  box,
}

/// Query of a same-origin `home.php?mod=magic` link, null for anything else.
Map<String, String>? _magicParams(String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final relative = Uri.tryParse(href.trim().replaceAll('&amp;', '&'));
  if (relative == null) return null;
  final uri = Uri.parse(magicShopUrl).resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) ||
      uri.origin != Uri.parse(baseUrl).origin ||
      uri.userInfo.isNotEmpty ||
      uri.path != '/home.php' ||
      uri.fragment.isNotEmpty) {
    return null;
  }
  final params = rawQueryParameters(uri.query);
  if (params == null || params['mod'] != 'magic') return null;
  return params;
}

/// The list page [href] points to as a safe url the app may GET (the shop or the account's magics, an optional page
/// number), null for anything else: a buy, use or other operation link never becomes a GET.
String? magicListPageUrl(String? href, MagicList list) {
  final params = _magicParams(href);
  if (params == null) return null;
  final action = params['action'] ?? 'shop';
  if (action != (list == MagicList.shop ? 'shop' : 'mybox') ||
      params.keys.any((k) => !{'mod', 'action', 'operation', 'page', 'pid'}.contains(k)) ||
      (list == MagicList.shop && (params['operation'] ?? 'index') != 'index') ||
      (list == MagicList.box && (params['operation'] ?? '').isNotEmpty) ||
      (params['pid'] ?? '0') != '0') {
    return null;
  }
  final page = params['page'];
  if (page != null && (!_digits.hasMatch(page) || (int.tryParse(page) ?? 0) <= 0)) return null;
  final base = list == MagicList.shop ? magicShopUrl : magicBoxUrl;
  return page == null || page == '1' ? base : '$base&page=$page';
}

/// Visible text of [node]: scripts, styles and controls removed, whitespace collapsed per line.
String magicText(uh.Element? node) {
  if (node == null) return '';
  final clone = node.clone(true) as uh.Element;
  for (final e in clone.querySelectorAll('script, style, button, input, select, textarea')) {
    e.remove();
  }
  for (final br in clone.querySelectorAll('br')) {
    br.replaceWith(uh.Text('\n'));
  }
  return (clone.text ?? '')
      .split('\n')
      .map((s) => s.replaceAll(_spaces, ' ').trim())
      .where((s) => s.isNotEmpty)
      .join('\n');
}

String? _image(uh.Element? img) {
  final src = img?.getAttribute('src')?.trim();
  if (src == null || src.isEmpty) return null;
  final relative = Uri.tryParse(src);
  if (relative == null) return null;
  final uri = Uri.parse('$baseUrl/').resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return uri.toString();
}

/// The forum's message page instead of a magic page: magics closed, no permission, the login prompt.
final class MagicForumMessage implements Exception {
  /// Constructor.
  const MagicForumMessage(this.message, {this.login = false});

  /// The forum's words, plain text; empty when it gave none.
  final String message;

  /// The forum asks to log in.
  final bool login;

  @override
  String toString() => 'MagicForumMessage($message, login: $login)';
}

/// The forum's message of [document], null when it is not a message page.
MagicForumMessage? magicMessageOf(uh.Document document) {
  final box = document.querySelector('#messagetext');
  if (box == null) return null;
  return MagicForumMessage(
    magicText(box.querySelector('p') ?? box),
    login: document.querySelector('#messagelogin') != null,
  );
}

/// One magic of a list: the shop or the account's magics.
final class MagicItem {
  /// Constructor.
  const MagicItem({
    required this.identifier,
    required this.name,
    required this.description,
    required this.imageUrl,
    this.price,
    this.priceText = '',
    this.buyable = false,
    this.magicId,
    this.count,
    this.weight,
  });

  /// The magic's identifier (`sofa`, `bump`, `prankmagic:pkcat`…): what the shop buys by.
  final String identifier;

  /// Name.
  final String name;

  /// The forum's description, plain text.
  final String description;

  /// Absolute image url, null when the page gave none.
  final String? imageUrl;

  /// Shop: the list price (the discount, if any, shows in the buy window).
  final int? price;

  /// Shop: the price line as the page prints it (`10 天使币/张`).
  final String priceText;

  /// Shop: the page offers to buy it (in stock); a sold out magic is listed without.
  final bool buyable;

  /// Box: the id the account's magic is used by.
  final int? magicId;

  /// Box: how many the account owns.
  final int? count;

  /// Box: the total weight of those.
  final int? weight;
}

/// A page of the shop or of the account's magics.
final class MagicListPage {
  /// Constructor.
  const MagicListPage({
    required this.list,
    required this.items,
    this.capacity = '',
    this.balance = '',
    this.page = 1,
    this.nextUrl,
    this.previousUrl,
  });

  /// Which list.
  final MagicList list;

  /// The magics of this page, in the page's order.
  final List<MagicItem> items;

  /// The bag capacity line (`50/100`), empty when the forum sets no limit.
  final String capacity;

  /// Shop: the balances line (`天使币 1002`), empty when none.
  final String balance;

  /// Current page number.
  final int page;

  /// Next page, safe for a GET.
  final String? nextUrl;

  /// Previous page, safe for a GET.
  final String? previousUrl;
}

final _countRe = RegExp(r'(\d+)');

/// Parse a page of the shop or of the account's magics. Throws [MagicForumMessage] for a message page and
/// [FormatException] for a page without the magic list.
MagicListPage parseMagicList(uh.Document document, MagicList list) {
  if (magicMessageOf(document) case final message?) throw message;
  final main = document.querySelector('#ct .mn .bm') ?? document.querySelector('#ct .mn');
  if (main == null) throw const FormatException('Magic page without its block');
  final grid = main.querySelector('ul.mgcl');
  if (grid == null && main.querySelector('p.emp') == null) throw const FormatException('Magic page without a list');
  final seen = <String>{};
  final items = <MagicItem>[];
  for (final li in grid?.children.where((e) => e.localName == 'li') ?? const <uh.Element>[]) {
    final box = li.querySelector('div.mg_img');
    final id = box?.id ?? '';
    if (!id.startsWith('magic_') || id.length <= 'magic_'.length) continue;
    final identifier = id.substring('magic_'.length);
    final name = magicText(li.querySelector('p > strong'));
    if (name.isEmpty) continue;
    final description = magicText(li.querySelector('div.tip_c'));
    final image = _image(box!.querySelector('img'));
    final rows = li.children.where((e) => e.localName == 'p').toList();
    if (list == MagicList.shop) {
      if (!seen.add(identifier)) continue;
      final priceRow = rows.length > 1 ? rows[1] : null;
      final price = int.tryParse(magicText(priceRow?.querySelector('strong.xs2')));
      final buy = li
          .querySelectorAll('p.mtn a[href]')
          .map((a) => _magicParams(a.getAttribute('href')))
          .any((p) => p != null && p['operation'] == 'buy' && p['mid'] == identifier);
      items.add(
        MagicItem(
          identifier: identifier,
          name: name,
          description: description,
          imageUrl: image,
          price: price,
          priceText: magicText(priceRow).replaceAll('\n', ' '),
          buyable: buy && price != null,
        ),
      );
    } else {
      int? magicId;
      for (final a in li.querySelectorAll('p.mtn a[href]')) {
        final p = _magicParams(a.getAttribute('href'));
        final v = int.tryParse(p?['magicid'] ?? '');
        if (p != null && p['action'] == 'mybox' && v != null && v > 0) {
          magicId = v;
          break;
        }
      }
      if (magicId == null || !seen.add('$magicId')) continue;
      final numbers = rows.length > 1
          ? rows[1].querySelectorAll('font, span').map(magicText).toList()
          : const <String>[];
      int? at(int i) => i < numbers.length ? int.tryParse(_countRe.firstMatch(numbers[i])?.group(1) ?? '') : null;
      items.add(
        MagicItem(
          identifier: identifier,
          name: name,
          description: description,
          imageUrl: image,
          magicId: magicId,
          count: at(0),
          weight: at(1),
        ),
      );
    }
  }
  final tbmu = main.querySelector('.tbmu');
  var capacity = '';
  var balance = '';
  if (tbmu != null) {
    // The line is cut by `span.pipe`: the capacity (`N/M`), the discount note (no number of its own), the balances
    // (each number in a `span.xi1`), then the links to buy or exchange credits.
    final segments = <List<uh.Node>>[[]];
    for (final node in tbmu.nodes) {
      if (node is uh.Element && node.classes.contains('pipe')) {
        segments.add([]);
      } else {
        segments.last.add(node);
      }
    }
    final balances = <String>[];
    for (final nodes in segments) {
      final holder = uh.DivElement();
      for (final n in nodes) {
        holder.append(n.clone(true));
      }
      final text = magicText(holder).replaceAll('\n', ' ');
      final slash = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(text);
      if (slash != null && capacity.isEmpty) {
        capacity = '${slash.group(1)}/${slash.group(2)}';
      } else if (list == MagicList.shop && holder.querySelector('span.xi1') != null) {
        balances.add(text);
      }
    }
    balance = balances.join(' ').trim();
  }
  String? link(String selector) => magicListPageUrl(main.querySelector(selector)?.getAttribute('href'), list);
  final current = int.tryParse(magicText(main.querySelector('div.pg strong'))) ?? 1;
  return MagicListPage(
    list: list,
    items: List.unmodifiable(items),
    capacity: capacity,
    balance: balance,
    page: current,
    nextUrl: link('div.pg a.nxt'),
    previousUrl: link('div.pg a.prev'),
  );
}

/// The account a magic page was served to, null for a guest.
int? magicServedUid(uh.Document document) => parseLoggedUidFromDocument(document);

/// How the app shows an input of a magic window.
enum MagicFieldRole {
  /// A thread id (`tid`): digits, a pasted thread link gives its tid.
  thread,

  /// A user name (`username`, the target of the card).
  user,

  /// The account's new name (`newusername`, the rename card).
  newName,

  /// A count (`magicnum`).
  number,

  /// Any other text the forum asks for, shown with the forum's label.
  text,

  /// A choice of the forum's radio buttons or select.
  choice,

  /// A longer text (`textarea`).
  multiline,
}

/// An input of a magic window, as the forum printed it.
final class MagicField {
  /// Constructor.
  const MagicField({
    required this.name,
    required this.label,
    required this.role,
    this.value = '',
    this.options = const [],
  });

  /// The form field name.
  final String name;

  /// The forum's label for it (the line printed above the input), empty when none.
  final String label;

  /// How the app shows it.
  final MagicFieldRole role;

  /// The value the forum filled in.
  final String value;

  /// For a [MagicFieldRole.choice]: the values and their labels, in the page's order.
  final List<({String value, String label})> options;
}

/// A magic window's form (buy or use), read without running its scripts.
final class MagicForm {
  /// Constructor.
  const MagicForm({
    required this.action,
    required this.hidden,
    required this.fields,
    required this.notes,
    required this.title,
    this.facts = const [],
    this.unitPrice,
    this.balance,
    this.freeWeight,
    this.unitWeight,
    this.stock,
    this.api = false,
  });

  /// The form came from the forum's app API (plugin 4.0.0, the small form `magicbuy` or `magicuse`): it is posted back
  /// with `tsdmv=4` and its answer read as a write result ([magicV4ResultOf]).
  final bool api;

  /// Where the form is posted: the shop or the account's magics, as an AJAX window (`infloat=yes&inajax=1`).
  final String action;

  /// The hidden fields, in the page's order (a later field of the same name wins, as the browser posts the last).
  final Map<String, String> hidden;

  /// The inputs to fill.
  final List<MagicField> fields;

  /// The forum's own lines about using the magic, verbatim.
  final List<String> notes;

  /// The magic's name as the window prints it.
  final String title;

  /// Buy: the facts the window lists (price, balance, weight, room in the bag, stock), verbatim.
  final List<String> facts;

  /// Buy: what one costs for this account (the discount price when there is one).
  final int? unitPrice;

  /// Buy: the account's balance of the magic's credit.
  final int? balance;

  /// Buy: the room left in the account's bag.
  final int? freeWeight;

  /// Buy: the weight of one.
  final int? unitWeight;

  /// Buy: how many the shop has left.
  final int? stock;

  /// Buy: the most this account can buy now (stock, balance and room), null when the window did not tell.
  int? get maxCount {
    final limits = [
      ?stock,
      if (balance != null && unitPrice != null && unitPrice! > 0) balance! ~/ unitPrice!,
      if (freeWeight != null && unitWeight != null && unitWeight! > 0) freeWeight! ~/ unitWeight!,
    ];
    if (limits.isEmpty) return null;
    return limits.reduce((a, b) => a < b ? a : b);
  }

  /// The body to post: the hidden fields, then [values] by field name.
  Map<String, String> body(Map<String, String> values) => {
    ...hidden,
    for (final f in fields) f.name: values[f.name] ?? f.value,
  };
}

/// The window answered something the app cannot fill in safely (an unknown control, a script picker): the website
/// has to be used for this magic.
final class MagicFormUnsupported implements Exception {
  /// Constructor.
  const MagicFormUnsupported();
}

final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*)\]\]>');

/// The html carried by an AJAX answer `<root><![CDATA[…]]></root>`, the text itself otherwise.
String magicUnwrapAjax(String raw) => _cdataRe.firstMatch(raw)?.group(1) ?? raw;

/// The html of a magic window answer [data]: the plugin's `page` result (plugin 2.6.0), or the forum's AJAX answer.
/// Throws [MagicForumMessage] when the forum answered a message instead (no such magic, no permission, log in).
String magicWindowHtml(Object? data) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    if (result.kind != TsdmAppWriteKind.page) {
      throw MagicForumMessage(result.reason, login: result.login);
    }
    return result.documentHtml;
  }
  final raw = tsdmAppAnswerText(data);
  final html = magicUnwrapAjax(raw);
  if (!html.contains('magicform')) {
    if (magicMessageOf(parseHtmlDocument(html)) case final message?) throw message;
    if (_handleRe('errorhandle').firstMatch(html) case final m?) {
      throw MagicForumMessage(_unescape(m.group(1)!));
    }
  }
  return html;
}

String? _formAction(String? href) {
  final params = _magicParams(href);
  if (params == null ||
      !{'shop', 'mybox'}.contains(params['action']) ||
      params.keys.any((k) => !{'mod', 'action', 'infloat'}.contains(k))) {
    return null;
  }
  return '$baseUrl/home.php?mod=magic&action=${params['action']}&infloat=yes&inajax=1';
}

final _intRe = RegExp(r'-?\d+');

int? _firstInt(String? s) => int.tryParse(_intRe.firstMatch(s ?? '')?.group(0) ?? '');

/// Parse a magic window [html] (the buy or the use window). Throws [MagicForumMessage] for a message,
/// [MagicFormUnsupported] for a form with controls the app does not know, [FormatException] for anything else.
MagicForm parseMagicForm(String html) {
  final doc = parseHtmlDocument(html);
  final form = doc.querySelector('form#magicform');
  if (form == null) {
    if (magicMessageOf(doc) case final message?) throw message;
    throw const FormatException('No magic form');
  }
  if ((form.getAttribute('method') ?? '').toLowerCase() != 'post') throw const FormatException('Not a POST form');
  final action = _formAction(form.getAttribute('action'));
  if (action == null) throw const FormatException('Unexpected magic form target');

  final hidden = <String, String>{};
  for (final input in form.querySelectorAll('input[type="hidden"]:not([disabled])')) {
    final name = input.getAttribute('name') ?? '';
    if (name.isNotEmpty) hidden[name] = input.getAttribute('value') ?? '';
  }
  final operation = hidden['operation'];
  if (operation == 'buy') return _parseBuy(form, action, hidden);
  if (operation == 'use') return _parseUse(form, action, hidden);
  throw const FormatException('Unknown magic operation');
}

MagicForm _parseBuy(uh.Element form, String action, Map<String, String> hidden) {
  final num = form.querySelector('input#magicnum[name="magicnum"]');
  if (num == null || (hidden['mid'] ?? '').isEmpty) throw const FormatException('Buy form without its count');
  final dt = form.querySelector('dl.xld dt');
  final paragraphs = dt?.querySelectorAll('p').toList() ?? const <uh.Element>[];
  final title = paragraphs.isEmpty ? '' : magicText(paragraphs.first);
  final description = paragraphs.length > 1 ? magicText(paragraphs[1]) : '';
  final facts = [
    for (final p in paragraphs.skip(2))
      if (p.querySelector('input') == null && magicText(p).isNotEmpty) magicText(p).replaceAll('\n', ' '),
  ];
  final docScripts = form.ownerDocument?.querySelectorAll('script').map((s) => s.text ?? '').join('\n') ?? '';
  int? scriptVar(String name) => _firstInt(RegExp('var $name = (-?\\d+);').firstMatch(docScripts)?.group(1));
  final price = _firstInt(magicText(form.querySelector('#discountprice') ?? form.querySelector('#magicprice')));
  final stockRow = dt
      ?.querySelectorAll('div.xw0 p')
      .where((p) => p.querySelector('input') == null && p.querySelector('span.xs2') != null)
      .firstOrNull;
  return MagicForm(
    action: action,
    hidden: Map.unmodifiable(hidden..remove('magicnum')),
    fields: [
      MagicField(name: 'magicnum', label: '', role: MagicFieldRole.number, value: num.getAttribute('value') ?? '1'),
    ],
    notes: [if (description.isNotEmpty) description],
    title: title,
    facts: List.unmodifiable(facts),
    unitPrice: price,
    balance: scriptVar('totalcredit'),
    freeWeight: scriptVar('totalweight'),
    unitWeight: _firstInt(magicText(form.querySelector('#magicweight'))),
    stock: _firstInt(magicText(stockRow?.querySelector('span.xs2'))),
  );
}

MagicFieldRole _roleOf(String name, String type) => switch ((name, type)) {
  ('tid', _) => MagicFieldRole.thread,
  ('username', _) => MagicFieldRole.user,
  ('newusername', _) => MagicFieldRole.newName,
  ('magicnum', _) => MagicFieldRole.number,
  (_, 'textarea') => MagicFieldRole.multiline,
  _ => MagicFieldRole.text,
};

bool _within(uh.Element node, uh.Element ancestor) {
  for (uh.Element? e = node; e != null; e = e.parent) {
    if (identical(e, ancestor)) return true;
  }
  return false;
}

MagicForm _parseUse(uh.Element form, String action, Map<String, String> hidden) {
  if (!_digits.hasMatch(hidden['magicid'] ?? '')) throw const FormatException('Use form without its magic');
  final dt = form.querySelector('dl.xld dt');
  final box = dt?.querySelector('div.pns');
  if (dt == null || box == null) throw const FormatException('Use form without its settings');
  // A control the user would fill outside the settings would be left out of the post: the website has to do it.
  for (final control in form.querySelectorAll('input, select, textarea')) {
    final type = (control.getAttribute('type') ?? '').toLowerCase();
    if (type == 'hidden' || type == 'submit' || control.attributes.containsKey('disabled')) continue;
    if (!_within(control, box)) throw const MagicFormUnsupported();
  }
  final title = dt.nodes.whereType<uh.Text>().map((t) => t.text ?? '').join(' ').replaceAll(_spaces, ' ').trim();
  final (:fields, :notes) = _useControlsOf(box);
  for (final f in fields) {
    hidden.remove(f.name);
  }
  return MagicForm(action: action, hidden: Map.unmodifiable(hidden), fields: fields, notes: notes, title: title);
}

/// The inputs and the forum's lines of the settings [box] of a use window (the `div.pns` of the window, or the
/// `show_html` of plugin 4.0.0). Throws [MagicFormUnsupported] for what the app cannot fill in safely.
({List<MagicField> fields, List<String> notes}) _useControlsOf(uh.Element box) {
  // A picker driven by script (the colour of the highlight card) cannot be filled in without running it.
  if (box.querySelector('script, [onclick], [onchange], [onfocus], input[type="checkbox"], select[multiple]') != null) {
    throw const MagicFormUnsupported();
  }
  final fields = <MagicField>[];
  final notes = <String>[];
  var label = '';
  final radios = <String, List<({String value, String label})>>{};
  final radioChecked = <String, String>{};
  final radioLabels = <String, String>{};

  void walk(uh.Element node) {
    for (final child in node.children) {
      // The browser never posts a disabled control.
      if (child.attributes.containsKey('disabled')) continue;
      switch (child.localName) {
        case 'p':
          final classes = child.classes;
          if (child.querySelector('input, select, textarea, p') != null) {
            walk(child);
          } else if (classes.contains('mtm') && classes.contains('mbn')) {
            label = magicText(child).replaceAll('\n', ' ');
          } else if (magicText(child) case final text when text.isNotEmpty) {
            notes.add(text);
          }
        case 'input':
          final name = child.getAttribute('name') ?? '';
          final type = (child.getAttribute('type') ?? 'text').toLowerCase();
          if (name.isEmpty || type == 'hidden') continue;
          if (type == 'radio') {
            final options = radios.putIfAbsent(name, () {
              radioLabels[name] = label;
              label = '';
              fields.add(MagicField(name: name, label: radioLabels[name]!, role: MagicFieldRole.choice));
              return [];
            });
            final next = child.nextNode;
            final text = next is uh.Text ? (next.text ?? '').replaceAll(' ', ' ').replaceAll(_spaces, ' ').trim() : '';
            final value = child.getAttribute('value') ?? '';
            options.add((value: value, label: text.isEmpty ? value : text));
            if (child.attributes.containsKey('checked')) radioChecked[name] = value;
          } else if (type == 'text' || type == 'number' || type == 'tel') {
            fields.add(
              MagicField(name: name, label: label, role: _roleOf(name, type), value: child.getAttribute('value') ?? ''),
            );
            label = '';
          } else {
            throw const MagicFormUnsupported();
          }
        case 'textarea':
          final name = child.getAttribute('name') ?? '';
          if (name.isEmpty) throw const MagicFormUnsupported();
          fields.add(MagicField(name: name, label: label, role: MagicFieldRole.multiline, value: child.text ?? ''));
          label = '';
        case 'select':
          final name = child.getAttribute('name') ?? '';
          if (name.isEmpty) throw const MagicFormUnsupported();
          final options = [
            for (final o in child.querySelectorAll('option'))
              (value: o.getAttribute('value') ?? magicText(o), label: magicText(o)),
          ];
          if (options.isEmpty) throw const MagicFormUnsupported();
          final selected = child.querySelector('option[selected]');
          fields.add(
            MagicField(
              name: name,
              label: label,
              role: MagicFieldRole.choice,
              value: selected?.getAttribute('value') ?? options.first.value,
              options: List.unmodifiable(options),
            ),
          );
          label = '';
        case 'button':
          throw const MagicFormUnsupported();
        default:
          walk(child);
      }
    }
  }

  walk(box);
  final resolved = [
    for (final f in fields)
      if (radios[f.name] case final options?)
        MagicField(
          name: f.name,
          label: f.label,
          role: MagicFieldRole.choice,
          value: radioChecked[f.name] ?? '',
          options: List.unmodifiable(options),
        )
      else
        f,
  ];
  if (resolved.map((f) => f.name).toSet().length != resolved.length) throw const MagicFormUnsupported();
  return (fields: List.unmodifiable(resolved), notes: List.unmodifiable(notes));
}

/// How the forum answered a buy or a use.
enum MagicResultKind {
  /// Done: the forum's success handler.
  succeeded,

  /// Refused: the forum's error handler or message (nothing was taken).
  rejected,

  /// The forum asks to log in.
  login,

  /// The answer could not be read: the forum may have done it.
  unknown,
}

/// The forum's answer to a buy or a use.
final class MagicResult {
  /// Constructor.
  const MagicResult(this.kind, [this.message = '']);

  /// What happened.
  final MagicResultKind kind;

  /// The forum's words, plain text.
  final String message;
}

RegExp _handleRe(String handler) {
  final url = handler == 'succeedhandle' ? '$_jsString,\\s*' : '';
  return RegExp('${handler}_$magicHandleKey\\($url$_jsCapture');
}

/// A single quoted javascript string of the forum's handler call, and the same capturing its text.
const _jsCapture = r"'((?:[^'\\]|\\.)*)'";

const _jsString = r"'(?:[^'\\]|\\.)*'";

String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1) == 'n' ? '\n' : m.group(1)!);

String _plain(String html) =>
    (parseHtmlDocument('<body>$html</body>').body?.text ?? '').replaceAll(_spaces, ' ').trim();

/// Read the answer [data] to a posted magic window: the plugin's write result (plugin 2.6.0), or the forum's AJAX
/// answer (`succeedhandle_magics(…)`, `errorhandle_magics(…)`).
///
/// Judged by `ok` and `alert`, never by `message_key`: the cards of plugins answer their own words without a key.
MagicResult parseMagicResult(Object? data) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    final text = _plain(result.message);
    if (result.login) return MagicResult(MagicResultKind.login, text);
    switch (result.kind) {
      case TsdmAppWriteKind.handle || TsdmAppWriteKind.message:
        if (result.ok) return MagicResult(MagicResultKind.succeeded, text);
        if (result.isError || result.kind == TsdmAppWriteKind.handle) {
          return MagicResult(MagicResultKind.rejected, text);
        }
        return MagicResult(MagicResultKind.unknown, text);
      case TsdmAppWriteKind.redirect:
        return MagicResult(MagicResultKind.unknown, text);
      case TsdmAppWriteKind.page:
        return const MagicResult(MagicResultKind.unknown);
    }
  }
  final html = magicUnwrapAjax(tsdmAppAnswerText(data));
  if (_handleRe('succeedhandle').firstMatch(html) case final m?) {
    return MagicResult(MagicResultKind.succeeded, _plain(_unescape(m.group(1)!)));
  }
  if (_handleRe('errorhandle').firstMatch(html) case final m?) {
    return MagicResult(MagicResultKind.rejected, _plain(_unescape(m.group(1)!)));
  }
  if (magicMessageOf(parseHtmlDocument(html)) case final message?) {
    return MagicResult(message.login ? MagicResultKind.login : MagicResultKind.unknown, message.message);
  }
  return const MagicResult(MagicResultKind.unknown);
}

/// The thread id of what the user typed for a thread: digits, or a thread link (`tid=…`, `thread-…-1-1.html`).
String magicThreadIdOf(String input) {
  final s = input.trim();
  if (_digits.hasMatch(s)) return s;
  final tid = RegExp(r'[?&]tid=(\d+)').firstMatch(s) ?? RegExp(r'thread-(\d+)-').firstMatch(s);
  return tid?.group(1) ?? s;
}

/// A page of the shop (`type: magic_shop`, `schema` 69) or of the account's magics (`magic_mybox`, 70) of the forum's
/// app API (plugin 4.0.0), asked as [url], as [parseMagicList] reads the web page: the price line and the balances as
/// the page words them, a sold out magic without its buy link, the pages safe for a GET ([magicListPageUrl]).
MagicListPage magicListPageFromApi(Map<String, dynamic> json, MagicList list, String url) {
  final words = t.magicCenter.forumWords;
  final seen = <String>{};
  final items = <MagicItem>[];
  for (final row in tsdmAppList(json['list'])) {
    final identifier = tsdmAppText(row['identifier']);
    final name = tsdmAppText(row['name']).replaceAll(_spaces, ' ').trim();
    if (identifier.isEmpty || name.isEmpty) continue;
    final description = tsdmAppText(row['description']).trim();
    final image = _image(uh.ImageElement()..src = tsdmAppText(row['pic']));
    if (list == MagicList.shop) {
      if (!seen.add(identifier)) continue;
      final price = row['price'] is num ? (row['price'] as num).toInt() : null;
      final credit = tsdmAppMap(row['credit']);
      items.add(
        MagicItem(
          identifier: identifier,
          name: name,
          description: description,
          imageUrl: image,
          price: price,
          priceText: price == null
              ? ''
              : words.priceText(price: price, credit: '${tsdmAppText(credit['title'])}${tsdmAppText(credit['unit'])}'),
          buyable: price != null && row['soldout'] != 1 && tsdmAppText(row['buy_url']).isNotEmpty,
        ),
      );
    } else {
      final magicId = tsdmAppInt(row['magicid']);
      if (magicId <= 0 || !seen.add('$magicId')) continue;
      items.add(
        MagicItem(
          identifier: identifier,
          name: name,
          description: description,
          imageUrl: image,
          magicId: magicId,
          count: tsdmAppInt(row['num']),
          weight: tsdmAppInt(row['weight']),
        ),
      );
    }
  }
  final capacity = tsdmAppMap(json['capacity']);
  final page = tsdmAppInt(json['page']) > 0 ? tsdmAppInt(json['page']) : 1;
  final pages = tsdmAppInt(json['pages']);
  final base = list == MagicList.shop ? magicShopUrl : magicBoxUrl;
  String? at(int n) => magicListPageUrl(n == 1 ? base : '$base&page=$n', list);
  return MagicListPage(
    list: list,
    items: List.unmodifiable(items),
    capacity: capacity.isEmpty
        ? ''
        : words.capacity(used: tsdmAppInt(capacity['used']), max: tsdmAppInt(capacity['max'])),
    balance: list != MagicList.shop
        ? ''
        : [
            for (final b in tsdmAppList(json['balances']))
              words.balance(
                credit: tsdmAppText(b['title']),
                amount: '${tsdmAppInt(b['amount'])}${tsdmAppText(b['unit'])}',
              ),
          ].join(' ').trim(),
    page: page,
    nextUrl: page < pages ? at(page + 1) : null,
    previousUrl: page > 1 ? at(page - 1) : null,
  );
}

/// The buy ([SmallFormKind.magicbuy]) or use ([SmallFormKind.magicuse]) window of the forum's app API (plugin 4.0.0,
/// a small form, `schema` 17) out of its answer [data], as [parseMagicForm] reads the window; null when the answer is
/// not that form (the caller reads the window as before).
///
/// The form is posted where the forum's own form goes (`submit.url`, the shop or the account's magics only) with its
/// fields as they came (`handlekey`, `mid`, `magicid`… are only posted back, never shown or acted on). A use window's
/// inputs are read from the forum's own markup of them (`show_html`, the same reading and the same refusals as the
/// window's) and must be the `controls` the plugin lists; a window the plugin could not read (`controls` null,
/// `unsupported`) is [MagicFormUnsupported]. Throws [MagicForumMessage] for the forum's message instead of the form.
MagicForm? magicFormFromApi(Object? data, SmallFormKind kind) {
  switch (smallFormAnswerOf(data, kind)) {
    case null:
      return null;
    case SmallFormMessage(:final reason, :final login):
      throw MagicForumMessage(reason, login: login);
    case final SmallFormFields form:
      if (!form.hasSubmit || !form.usable) throw const MagicFormUnsupported();
      final action = _formAction(form.submitUrlRaw);
      if (action == null) throw const FormatException('Unexpected magic form target');
      final json = form.json;
      final magic = tsdmAppMap(json['magic']);
      final title = tsdmAppText(magic['name']).trim();
      final hidden = {...form.submitFields};
      if (kind == SmallFormKind.magicbuy) {
        final count = tsdmAppMap(json['num']);
        final numName = tsdmAppText(count['name']);
        if (numName != 'magicnum' || (hidden['mid'] ?? '').isEmpty || hidden['operation'] != 'buy') {
          throw const FormatException('Buy form without its count');
        }
        hidden.remove(numName);
        final words = t.magicCenter.forumWords;
        final creditMap = tsdmAppMap(json['credit']);
        final credit = '${tsdmAppText(creditMap['title'])}${tsdmAppText(creditMap['unit'])}';
        int? whole(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
        final price = whole(json['price']);
        final discount = whole(json['discountprice']);
        final balance = whole(json['balance']);
        final weight = whole(json['weight']);
        final freeWeight = whole(json['free_weight']);
        final stock = whole(json['stock']);
        final description = tsdmAppText(magic['description']).trim();
        return MagicForm(
          action: action,
          hidden: Map.unmodifiable(hidden),
          fields: [
            MagicField(
              name: 'magicnum',
              label: '',
              role: MagicFieldRole.number,
              value: tsdmAppText(count['value']).isEmpty ? '1' : tsdmAppText(count['value']),
            ),
          ],
          notes: [if (description.isNotEmpty) description],
          title: title,
          facts: List.unmodifiable([
            if (price != null) words.price(credit: credit, price: price),
            if (discount != null && discount != price) words.discountPrice(credit: credit, price: discount),
            if (balance != null) words.myBalance(credit: credit, amount: balance),
            if (weight != null) words.weight(weight: weight),
            if (freeWeight != null) words.freeWeight(weight: freeWeight),
            if (stock != null) words.stock(stock: stock),
          ]),
          unitPrice: discount ?? price,
          balance: balance,
          freeWeight: freeWeight,
          unitWeight: weight,
          stock: stock,
          api: true,
        );
      }
      if (hidden['operation'] != 'use' || !_digits.hasMatch(hidden['magicid'] ?? '')) {
        throw const FormatException('Use form without its magic');
      }
      final controls = json['controls'];
      if (controls is! List) throw const MagicFormUnsupported();
      final box = parseHtmlDocument(
        '<html><body><div>${tsdmAppText(json['show_html'])}</div></body></html>',
      ).body?.querySelector('div');
      if (box == null) throw const FormatException('Use form without its settings');
      final (:fields, :notes) = _useControlsOf(box);
      final names = {for (final c in tsdmAppList(controls)) tsdmAppText(c['name'])};
      // What the app would post must be what the forum asks for, no more and no less.
      if (names.length != fields.length || !fields.every((f) => names.contains(f.name))) {
        throw const MagicFormUnsupported();
      }
      for (final f in fields) {
        hidden.remove(f.name);
      }
      return MagicForm(
        action: action,
        hidden: Map.unmodifiable(hidden),
        fields: fields,
        notes: notes,
        title: title,
        api: true,
      );
  }
}

/// The forum's answer [data] to a buy ([buy]) or a use posted from a form of plugin 4.0.0 ([MagicForm.api]): a buy is
/// done only with the forum's `magics_buy_succeed`, never on `ok` alone; a use is judged as before
/// ([parseMagicResult]: the cards of plugins answer their own words without a key). A buy without that key is
/// refused in the forum's words, or unknown without words.
MagicResult magicV4ResultOf(Object? data, {required bool buy}) {
  if (!buy) return parseMagicResult(data);
  final result = tsdmAppWriteResultOf(data);
  if (result == null) return parseMagicResult(data);
  final text = _plain(result.message);
  if (result.login) return MagicResult(MagicResultKind.login, text);
  if (result.messageKey == 'magics_buy_succeed') return MagicResult(MagicResultKind.succeeded, text);
  if (result.kind == TsdmAppWriteKind.page || text.isEmpty) return MagicResult(MagicResultKind.unknown, text);
  return MagicResult(MagicResultKind.rejected, text);
}
