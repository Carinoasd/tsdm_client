import 'package:tsdm_client/constants/url.dart';
import 'package:universal_html/html.dart' as uh;

const _pluginId = 'bank_ane:bank';
const _endpoint = '$baseUrl/plugin.php';

/// The two current-savings operations supported by the client.
enum BankOperation {
  /// Move forum currency into the current-savings account.
  deposit,

  /// Move current savings back to the forum wallet.
  withdraw,
}

/// One bank advertised by the forum directory.
final class ForumBank {
  /// Constructor.
  const ForumBank({required this.id, required this.name, this.description = '', this.hasAccount = false});

  /// Server bank identifier.
  final int id;

  /// Bank name, without the manager's identity.
  final String name;

  /// Public bank description.
  final String description;

  /// Whether the directory explicitly marks an existing account.
  final bool hasAccount;
}

/// The directory returned by the bank plugin.
final class BankDirectory {
  /// Constructor.
  const BankDirectory({required this.banks});

  /// Banks in server order.
  final List<ForumBank> banks;
}

/// An ephemeral snapshot of current savings; amounts and rates remain server text.
final class BankSavings {
  /// Constructor.
  const BankSavings({
    required this.bankId,
    this.summary = '',
    this.interest = '',
    this.notices = '',
    this.currency = '',
    this.walletBalance = '',
    this.form,
  });

  /// Bank this snapshot belongs to.
  final int bankId;

  /// Current balance, rate and accrual start, as reported by the forum.
  final String summary;

  /// Server-reported interest, without a guessed settlement operation.
  final String interest;

  /// Conditions and notices supplied by the bank.
  final String notices;

  /// Currency name supplied by the account sidebar.
  final String currency;

  /// Available forum wallet balance, when supplied.
  final String walletBalance;

  /// Validated deposit/withdrawal form; null for unknown or incomplete markup.
  final BankTransactionForm? form;
}

/// A validated, account-bound form snapshot. It never retains a bank password.
final class BankTransactionForm {
  BankTransactionForm._({required this.bankId, required this.action, required Map<String, String> fields})
    : fields = Map.unmodifiable(fields);

  /// The bank explicitly named by the hidden form field.
  final int bankId;

  /// Validated same-origin POST destination.
  final String action;

  /// Immutable server fields, including the observed submit control value.
  final Map<String, String> fields;

  /// Only positive integer strings up to 18 digits can be submitted.
  ///
  /// Do not use floating-point parsing: it loses precision for large balances.
  bool accepts(String amount) => RegExp(r'^[1-9][0-9]{0,17}$').stringMatch(amount) == amount;

  /// Create one transient form body for an explicit user operation.
  Map<String, String> body(BankOperation operation, String amount, String password) {
    if (!accepts(amount) || password.isEmpty) throw const FormatException('Invalid bank transaction input');
    return {
      ...fields,
      'banknum': amount,
      'op': operation == BankOperation.deposit ? 'in' : 'out',
      'bankpass': password,
    };
  }
}

/// One log item, excluding the IP address carried by the website.
final class BankLogEntry {
  /// Constructor.
  const BankLogEntry({required this.message, required this.time});

  /// Server transaction description.
  final String message;

  /// Server time, without assuming the device's timezone.
  final String time;
}

/// One page of own or received bank records.
final class BankLogs {
  /// Constructor.
  const BankLogs({required this.entries, this.hasNext = false});

  /// Entries in server order.
  final List<BankLogEntry> entries;

  /// Whether a safe next-page link exists for this exact bank and log tab.
  final bool hasNext;
}

/// Build a read-only bank URL. State-changing destinations cannot be generated.
String bankPageUrl({int? bankId, String? action, bool received = false, int page = 1}) {
  if ((bankId != null && bankId <= 0) ||
      (action != null && !{'cur', 'log'}.contains(action)) ||
      (action != null && bankId == null) ||
      page <= 0 ||
      (action != 'log' && (received || page != 1))) {
    throw const FormatException('Invalid bank page');
  }
  return Uri.parse(_endpoint)
      .replace(
        queryParameters: {
          'id': _pluginId,
          if (bankId != null) 'bankid': '$bankId',
          'action': ?action,
          if (action == 'log') 'show': received ? '1' : '0',
          if (action == 'log') 'page': '$page',
        },
      )
      .toString();
}

String _text(uh.Element? element) {
  if (element == null) return '';
  final copy = element.clone(true) as uh.Element;
  for (final node in copy.querySelectorAll('script, style, input, textarea, button, [hidden]')) {
    node.remove();
  }
  for (final node in copy.querySelectorAll('br')) {
    node.replaceWith(uh.Text(' '));
  }
  return copy.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
}

uh.Element? _nearestTable(uh.Element element) {
  var current = element.parent;
  while (current != null && current.localName != 'table') {
    current = current.parent;
  }
  return current;
}

uh.Element _sectionTable(uh.Document document, String heading) {
  if (document.querySelector('.alert_error') != null) throw const FormatException('Bank returned an error page');
  final matches = document
      .querySelectorAll('table[id="ttt"]')
      .where(
        (table) => table.querySelectorAll('h2').any((node) => _nearestTable(node) == table && _text(node) == heading),
      )
      .toList();
  if (matches.length != 1) throw const FormatException('Unrecognised bank page');
  return matches.single;
}

Uri? _pluginUri(String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final relative = Uri.tryParse(href.trim());
  if (relative == null) return null;
  final uri = Uri.parse(_endpoint).resolveUri(relative);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.origin != Uri.parse(baseUrl).origin ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.path != '/plugin.php' ||
      uri.queryParameters['id'] != _pluginId ||
      uri.queryParametersAll.values.any((values) => values.length != 1)) {
    return null;
  }
  return uri;
}

int? _positiveId(String? value) {
  if (value == null || RegExp(r'^[1-9][0-9]*$').stringMatch(value) != value) return null;
  final id = int.tryParse(value);
  return id != null && id > 0 ? id : null;
}

/// Parse the real directory table, not the unrelated bank links in the site header.
BankDirectory parseBankDirectory(uh.Document document) {
  final table = _sectionTable(document, '银行列表');
  final banks = <ForumBank>[];
  final seen = <int>{};
  for (final row in table.querySelectorAll('tr').where((row) => _nearestTable(row) == table)) {
    final cells = row.children.where((cell) => cell.localName == 'td').toList();
    if (cells.length != 3) continue;
    final links = cells.last.querySelectorAll('a[href]').where((link) => _text(link) == '进入银行').toList();
    if (links.length != 1) continue;
    final uri = _pluginUri(links.single.attributes['href']);
    if (uri == null || uri.queryParameters.keys.any((key) => !{'id', 'bankid'}.contains(key))) {
      throw const FormatException('Invalid bank directory link');
    }
    final id = _positiveId(uri.queryParameters['bankid']);
    final details = _text(cells[1]);
    final name = RegExp(r'银行名称\s*[:：]\s*(.*?)\s*银行行长\s*[:：]').firstMatch(details)?.group(1)?.trim();
    final description = RegExp(r'银行简介\s*[:：]\s*(.*)$').firstMatch(details)?.group(1)?.trim() ?? '';
    if (id == null || name == null || name.isEmpty || !seen.add(id)) {
      throw const FormatException('Invalid bank directory entry');
    }
    banks.add(ForumBank(id: id, name: name, description: description, hasAccount: _text(cells.last).contains('已开户')));
  }
  if (banks.isEmpty) throw const FormatException('Bank directory contains no recognised banks');
  return BankDirectory(banks: List.unmodifiable(banks));
}

bool _enabled(uh.Element element) {
  if (element.hasAttribute('disabled')) return false;
  var parent = element.parent;
  while (parent != null) {
    if (parent.localName == 'fieldset' && parent.hasAttribute('disabled')) return false;
    parent = parent.parent;
  }
  return true;
}

BankTransactionForm? _transactionForm(uh.Element form, int bankId) {
  final uri = _pluginUri(form.attributes['action']);
  if (form.attributes['method']?.toLowerCase() != 'post' ||
      uri == null ||
      uri.queryParameters.keys.any((key) => key != 'id')) {
    return null;
  }
  const allowed = {'bankid', 'action', 'formhash', 'banknum', 'op', 'bankpass', 'banksubmit'};
  final controls = form.querySelectorAll('input[name], select[name], textarea[name], button[name]');
  if (controls.any((node) => !allowed.contains(node.attributes['name']) || !_enabled(node))) return null;
  final named = <String, List<uh.Element>>{};
  for (final node in controls) {
    named.putIfAbsent(node.attributes['name']!, () => []).add(node);
  }
  uh.Element? one(String name) => named[name]?.length == 1 ? named[name]!.single : null;
  String? hidden(String name) {
    final node = one(name);
    return node?.localName == 'input' && node?.attributes['type']?.toLowerCase() == 'hidden'
        ? node?.attributes['value']
        : null;
  }

  final rawBank = hidden('bankid');
  final action = hidden('action');
  final amount = one('banknum');
  final password = one('bankpass');
  final submit = one('banksubmit');
  final operations = named['op'] ?? [];
  if (_positiveId(rawBank) != bankId ||
      action != 'cur' ||
      amount?.localName != 'input' ||
      !{'text', 'number'}.contains(amount?.attributes['type']?.toLowerCase() ?? 'text') ||
      amount!.hasAttribute('readonly') ||
      password?.localName != 'input' ||
      password?.attributes['type']?.toLowerCase() != 'password' ||
      password!.hasAttribute('readonly') ||
      submit == null ||
      !{'input', 'button'}.contains(submit.localName) ||
      (submit.attributes['type']?.toLowerCase() ?? (submit.localName == 'button' ? 'submit' : 'text')) != 'submit' ||
      submit.attributes['value'] != 'true' ||
      operations.length != 2 ||
      operations.any((node) => node.localName != 'input' || node.attributes['type']?.toLowerCase() != 'radio') ||
      operations.map((node) => node.attributes['value']).toSet().difference({'in', 'out'}).isNotEmpty ||
      operations.map((node) => node.attributes['value']).toSet().length != 2) {
    return null;
  }
  final hash = hidden('formhash');
  if (named.containsKey('formhash') && (hash == null || hash.isEmpty)) return null;
  return BankTransactionForm._(
    bankId: bankId,
    action: uri.toString(),
    fields: {'bankid': rawBank!, 'action': action!, 'formhash': ?hash, 'banksubmit': 'true'},
  );
}

/// Parse current savings without guessing missing amounts, rates or action fields.
BankSavings parseBankSavings(uh.Document document, {required int bankId}) {
  if (bankId <= 0) throw const FormatException('Invalid bank identity');
  final table = _sectionTable(document, '活期储蓄');
  final rows = table.querySelectorAll('tr').where((row) => _nearestTable(row) == table).toList();
  final summary = table
      .querySelectorAll('td.footoperation')
      .map(_text)
      .firstWhere(
        (text) => text.contains('您当前的存款金额为'),
        orElse: () => '',
      );
  if (summary.isEmpty) throw const FormatException('Bank savings summary is missing');
  final interest = table
      .querySelectorAll('p')
      .map(_text)
      .firstWhere(
        (text) => text.contains('您当前可得利息'),
        orElse: () => '',
      )
      .replaceAll('手动结息', '')
      .trim();
  final notices = <String>[];
  var inNotices = false;
  for (final row in rows) {
    if (row.querySelectorAll('td.footoperation').any((cell) => _text(cell).contains('注意事项'))) {
      inNotices = true;
    } else if (inNotices) {
      final paragraphs = row.querySelectorAll('p').map(_text).where((value) => value.isNotEmpty);
      notices.addAll(paragraphs);
    }
  }
  final wallet = document.querySelectorAll('div.tbn li').where((node) => _text(node).contains('(银行货币)')).firstOrNull;
  final currency = _text(wallet?.querySelector('font')).replaceFirst(RegExp(r'\s*[:：]\s*$'), '');
  final balance = _text(wallet?.querySelector('span > b'));
  final forms = table.querySelectorAll('form').where((form) => form.querySelector('[name="banknum"]') != null).toList();
  return BankSavings(
    bankId: bankId,
    summary: summary,
    interest: interest,
    notices: notices.join('\n'),
    currency: currency,
    walletBalance: balance,
    form: currency.isNotEmpty && forms.length == 1 ? _transactionForm(forms.single, bankId) : null,
  );
}

/// Parse records without retaining the separate IP column.
BankLogs parseBankLogs(uh.Document document, {required int bankId, required bool received, required int page}) {
  if (bankId <= 0 || page <= 0) throw const FormatException('Invalid bank logs page');
  final table = _sectionTable(document, '理财日志');
  final entries = <BankLogEntry>[];
  final recordTables = table.querySelectorAll('table[id="ttt"]').where((node) => _nearestTable(node) == table).toList();
  if (recordTables.length != 1) throw const FormatException('Bank records table is missing or ambiguous');
  final records = recordTables.single;
  var empty = false;
  for (final row in records.querySelectorAll('tr').where((row) => _nearestTable(row) == records)) {
    final cells = row.children.where((cell) => cell.localName == 'td').toList();
    if (cells.length == 1 && {'还没有相关数据。', '还没有相关数据'}.contains(_text(cells.single))) {
      empty = true;
      continue;
    }
    if (cells.length != 3) throw const FormatException('Unrecognised bank log row');
    final message = _text(cells[0]);
    final time = _text(cells[1]);
    if (!message.startsWith('Info:') || !time.startsWith('Time:')) {
      throw const FormatException('Unrecognised bank log entry');
    }
    final messageValue = message.substring('Info:'.length).trim();
    final timeValue = time.substring('Time:'.length).trim();
    if (messageValue.isEmpty || timeValue.isEmpty) throw const FormatException('Incomplete bank log entry');
    entries.add(BankLogEntry(message: messageValue, time: timeValue));
  }
  if ((entries.isEmpty && !empty) || (entries.isNotEmpty && empty)) {
    throw const FormatException('Bank logs are not recognisable');
  }
  final next = table.querySelectorAll('div.pg a[href]').any((link) {
    final uri = _pluginUri(link.attributes['href']);
    if (uri == null ||
        uri.queryParameters.keys.any((key) => !{'id', 'bankid', 'action', 'show', 'page'}.contains(key))) {
      return false;
    }
    return _positiveId(uri.queryParameters['bankid']) == bankId &&
        uri.queryParameters['action'] == 'log' &&
        uri.queryParameters['show'] == (received ? '1' : '0') &&
        _positiveId(uri.queryParameters['page']) == page + 1;
  });
  return BankLogs(entries: List.unmodifiable(entries), hasNext: next);
}
