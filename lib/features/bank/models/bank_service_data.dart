part of 'bank_data.dart';

/// Read-only destinations offered by the forum bank plugin.
enum BankService {
  /// Business information and account opening.
  hall('', '欢迎来到'),

  /// Term deposits and their individual records.
  term('fix', '定期储蓄'),

  /// Transfers to another forum account.
  remittance('chg', '账户汇款'),

  /// Loan applications and records.
  loans('len', '贷款专柜'),

  /// Bank password changes and account closure.
  account('pas', '账户管理'),

  /// Explicit current-savings interest settlement.
  interest('cur', '活期储蓄'),

  /// Current, term and loan balances across banks.
  overview('', '我的账户'),

  /// The five public wealth rankings.
  ranking('list', '财富排行'),

  /// Credit exchange, when enabled by the forum.
  exchange('buy', '积分买卖')
  ;

  const BankService(this.action, this.heading);

  /// The observed read-only action, never a submit operation.
  final String action;

  /// Section heading used to identify the plugin response.
  final String heading;

  /// Global services do not belong to a selected bank.
  bool get global => this == overview || this == ranking || this == exchange;
}

/// Generate a read URL without ever including a state-changing operation.
String bankServiceUrl(BankService service, {int? bankId, int page = 1}) {
  if (page < 1 || (!service.global && (bankId == null || bankId <= 0))) {
    throw const FormatException('Invalid bank service');
  }
  return Uri.parse(_endpoint)
      .replace(
        queryParameters: {
          'id': _pluginId,
          if (service.global) 'mode': 'other' else 'bankid': '$bankId',
          if (service.action.isNotEmpty) 'action': service.action,
          if (page > 1) 'page': '$page',
        },
      )
      .toString();
}

/// One server-provided text block, without form controls or executable links.
final class BankServiceBlock {
  /// Constructor.
  const BankServiceBlock(this.text, {this.heading = false});

  /// Server text, including dates, rates and account status.
  final String text;

  /// A subsection title rather than a record.
  final bool heading;
}

/// Supported visible fields; passwords never become defaults or persisted state.
enum BankInput {
  /// Positive integer amount.
  amount('banknum'),

  /// Positive integer duration in days.
  days('daynum'),

  /// The recipient's forum account name.
  recipient('touser'),

  /// Current bank password, or the password chosen when opening an account.
  password('bankpass'),

  /// Account-opening password confirmation.
  passwordConfirm('bankpass2'),

  /// Replacement bank password.
  newPassword('newbankpass'),

  /// Replacement password confirmation.
  newPasswordConfirm('newbankpass2')
  ;

  const BankInput(this.field);

  /// Name present in the actual HTML form.
  final String field;

  /// Secret fields must use obscured input and be excluded from confirmation text.
  bool get secret => this != amount && this != days && this != recipient;
}

/// A validated, immutable server form for one specific bank service or record.
final class BankServiceForm {
  BankServiceForm._({
    required this.service,
    required this.bankId,
    required this.action,
    required this.label,
    required this.context,
    required Map<String, String> hidden,
    required List<BankInput> inputs,
  }) : hidden = Map.unmodifiable(hidden),
       inputs = List.unmodifiable(inputs);

  /// Service whose page supplied this form.
  final BankService service;

  /// Bank bound by the response, never filled in by the client.
  final int bankId;

  /// Same-origin POST endpoint.
  final String action;

  /// Observed submit label, including account-opening fees.
  final String label;

  /// Record description shown alongside the form.
  final String context;

  /// Server-supplied hidden fields. Contains no entered credentials.
  final Map<String, String> hidden;

  /// Visible inputs in their original order.
  final List<BankInput> inputs;

  /// Observed operation, not an operation invented from the visible label.
  String get operation => hidden['op'] ?? '';

  /// Whether an input is valid without rounding or silently changing an amount.
  bool valid(BankInput input, Map<String, String> values) {
    final value = values[input.field] ?? '';
    if (input == BankInput.amount || input == BankInput.days) {
      if (RegExp(r'^[1-9][0-9]{0,17}$').stringMatch(value) != value) return false;
      final minimum = input == BankInput.days && service == BankService.term && operation == 'in'
          ? BigInt.from(30)
          : input == BankInput.amount && service == BankService.remittance
          ? BigInt.from(10)
          : BigInt.one;
      return BigInt.parse(value) >= minimum;
    }
    if (input == BankInput.recipient) {
      return value.trim() == value && value.isNotEmpty && value.length <= 100 && !value.contains(RegExp(r'[\r\n]'));
    }
    if (value.isEmpty) return false;
    if (input == BankInput.passwordConfirm) return value == values[BankInput.password.field];
    if (input == BankInput.newPasswordConfirm) return value == values[BankInput.newPassword.field];
    return true;
  }

  /// Recheck the form identity while allowing the server to refresh its CSRF token.
  bool matches(BankServiceForm other) =>
      service == other.service &&
      bankId == other.bankId &&
      action == other.action &&
      label == other.label &&
      context == other.context &&
      inputs.length == other.inputs.length &&
      List.generate(inputs.length, (i) => inputs[i] == other.inputs[i]).every((value) => value) &&
      hidden.keys.where((key) => key != 'formhash').length ==
          other.hidden.keys.where((key) => key != 'formhash').length &&
      hidden.entries.where((entry) => entry.key != 'formhash').every((entry) => other.hidden[entry.key] == entry.value);

  /// Create the transient body only after all input and confirmation checks pass.
  Map<String, String> body(Map<String, String> values) {
    if (values.length != inputs.length || inputs.any((input) => !valid(input, values))) {
      throw const FormatException('Invalid bank service input');
    }
    if (values.keys.any((key) => !inputs.any((input) => input.field == key))) {
      throw const FormatException('Unexpected bank service field');
    }
    return {...hidden, ...values, 'banksubmit': 'true'};
  }
}

/// A service snapshot scoped to the selected bank and signed-in account.
final class BankServiceData {
  /// Constructor.
  const BankServiceData({
    required this.service,
    required this.blocks,
    this.forms = const [],
    this.currency = '',
    this.walletBalance = '',
    this.unavailable = '',
    this.unsupportedForms = false,
    this.hasNext = false,
    this.feeRate,
  });

  /// Loaded service.
  final BankService service;

  /// Ordered server sections and records.
  final List<BankServiceBlock> blocks;

  /// Validated native operations, including individual record forms.
  final List<BankServiceForm> forms;

  /// Currency explicitly supplied by the account sidebar.
  final String currency;

  /// Available forum wallet amount, kept as server text.
  final String walletBalance;

  /// The server's reason for disabling a service.
  final String unavailable;

  /// At least one form or executable record link cannot be rendered safely.
  final bool unsupportedForms;

  /// A verified next-page link in the same bank/service.
  final bool hasNext;

  /// Decimal per-mille fee rate supplied by the remittance page.
  final String? feeRate;

  /// Terms and records rechecked before submitting a stale confirmation.
  String get confirmationTerms => blocks.map((block) => block.text).join('\n');

  /// Exact ceiling calculation matching the forum's displayed fee rule.
  String? estimatedFee(String amount) {
    if (feeRate == null || !RegExp(r'^[1-9][0-9]{0,17}$').hasMatch(amount)) return null;
    final parts = feeRate!.split('.');
    final digits = parts.length == 2 ? parts[1].length : 0;
    final numerator = BigInt.parse(parts.join());
    final denominator = BigInt.from(1000) * BigInt.from(10).pow(digits);
    return ((BigInt.parse(amount) * numerator + denominator - BigInt.one) ~/ denominator).toString();
  }
}

String _serviceText(uh.Element element) {
  final copy = element.clone(true) as uh.Element;
  for (final node in copy.querySelectorAll('form, script, style, .pg, input, button, select, textarea')) {
    node.remove();
  }
  return _text(copy);
}

BankServiceForm? _serviceForm(uh.Element form, BankService service, int bankId) {
  final uri = _pluginUri(form.attributes['action']);
  if (form.attributes['method']?.toLowerCase() != 'post' ||
      uri == null ||
      uri.queryParameters.keys.any((key) => key != 'id')) {
    return null;
  }
  final hidden = <String, String>{};
  final inputs = <BankInput>[];
  uh.Element? submit;
  for (final node in form.querySelectorAll('input, button, select, textarea')) {
    final name = node.attributes['name'];
    final type = node.attributes['type']?.toLowerCase() ?? (node.localName == 'button' ? 'submit' : 'text');
    if (type == 'button' && name == 'taxcheck' && service == BankService.remittance) continue;
    if (name == null || !_enabled(node) || node.hasAttribute('readonly')) return null;
    if (name == 'banksubmit' && type == 'submit' && {'input', 'button'}.contains(node.localName)) {
      if (submit != null || node.attributes['value'] != 'true') return null;
      submit = node;
    } else if (type == 'hidden' && node.localName == 'input') {
      final value = node.attributes['value'];
      if (value == null ||
          value.isEmpty ||
          hidden.containsKey(name) ||
          !RegExp(r'^[a-z][a-z0-9_]{0,30}$').hasMatch(name) ||
          BankInput.values.any((input) => input.field == name)) {
        return null;
      }
      // Extra server record identifiers are numeric. Never accept an arbitrary URL or script field.
      if (!{'bankid', 'action', 'op', 'formhash'}.contains(name) && !RegExp(r'^[0-9]{1,18}$').hasMatch(value)) {
        return null;
      }
      hidden[name] = value;
    } else {
      final input = BankInput.values.where((input) => input.field == name).firstOrNull;
      if (input == null ||
          inputs.contains(input) ||
          hidden.containsKey(name) ||
          node.localName != 'input' ||
          (input.secret ? type != 'password' : !{'text', 'number'}.contains(type))) {
        return null;
      }
      inputs.add(input);
    }
  }
  if (submit == null ||
      _positiveId(hidden['bankid']) != bankId ||
      hidden['action'] != (service == BankService.hall ? 'open' : service.action)) {
    return null;
  }
  final operation = hidden['op'] ?? '';
  final expectedInputs = switch (service) {
    BankService.hall when operation.isEmpty => {BankInput.password, BankInput.passwordConfirm},
    BankService.interest when operation == 'ok' => <BankInput>{},
    BankService.term when operation == 'in' => {BankInput.amount, BankInput.days, BankInput.password},
    BankService.remittance when operation == 'ok' => {BankInput.amount, BankInput.recipient, BankInput.password},
    BankService.loans when operation == 'try' => {BankInput.amount, BankInput.days, BankInput.password},
    BankService.account when operation == 'cg' => {
      BankInput.password,
      BankInput.newPassword,
      BankInput.newPasswordConfirm,
    },
    BankService.account when operation == 'cl' => {BankInput.password},
    _ => null,
  };
  final label = _text(submit).isNotEmpty ? _text(submit) : submit.attributes['value'] ?? '';
  var record = form.parent;
  while (record != null && record.localName != 'tr') {
    record = record.parent;
  }
  final context = service == BankService.interest ? _text(form) : _serviceText(record ?? form.parent ?? form);
  if (expectedInputs == null) {
    // Record operations are offered only by an actual, labelled record form. No guessed IDs/ops.
    if (!{BankService.term, BankService.loans}.contains(service) ||
        !RegExp(r'^[a-z]{1,12}$').hasMatch(operation) ||
        hidden.keys.every((key) => {'bankid', 'action', 'op', 'formhash'}.contains(key)) ||
        context.isEmpty ||
        !RegExp('取|还|還|取消|撤').hasMatch(label) ||
        inputs.any((input) => input != BankInput.password)) {
      return null;
    }
  } else if (inputs.length != expectedInputs.length || !inputs.toSet().containsAll(expectedInputs)) {
    return null;
  }
  return BankServiceForm._(
    service: service,
    bankId: bankId,
    action: uri.toString(),
    label: label,
    context: context,
    hidden: hidden,
    inputs: inputs,
  );
}

/// Parse service content and actual server forms without running any page scripts.
BankServiceData parseBankService(uh.Document document, BankService service, {int? bankId, int page = 1}) {
  final request = Uri.parse(bankServiceUrl(service, bankId: bankId, page: page));
  final message = document.querySelector('#messagetext');
  if (message != null) {
    final copy = message.clone(true) as uh.Element;
    for (final link in copy.querySelectorAll('a')) {
      link.remove();
    }
    final reason = _text(copy);
    if (reason.isEmpty) throw const FormatException('Empty bank response');
    return BankServiceData(service: service, blocks: const [], unavailable: reason);
  }
  final tables = document
      .querySelectorAll('table[id="ttt"]')
      .where(
        (table) => table
            .querySelectorAll('h2')
            .any(
              (node) =>
                  _nearestTable(node) == table &&
                  (service == BankService.hall
                      ? _text(node).startsWith(service.heading)
                      : _text(node) == service.heading),
            ),
      )
      .toList();
  if (tables.length != 1 || document.querySelector('.alert_error') != null) {
    throw const FormatException('Unrecognised bank service page');
  }
  final roots = <uh.Element>[tables.single];
  if (service == BankService.ranking) {
    final next = tables.single.nextElementSibling;
    if (next?.localName == 'table' && next?.id == 'ttt') roots.add(next!);
  }
  final blocks = <BankServiceBlock>[];
  for (final table in roots) {
    for (final row in table.querySelectorAll('tr')) {
      if (row.querySelector('table, h2') != null) continue;
      final cells = row.children.where((node) => node.localName == 'td' || node.localName == 'th');
      final text = cells.map(_serviceText).where((text) => text.isNotEmpty && !text.startsWith('Ip:')).join('\n');
      if (text.isNotEmpty) {
        blocks.add(BankServiceBlock(text, heading: cells.any((cell) => cell.classes.contains('footoperation'))));
      }
    }
  }
  final wallet = document.querySelectorAll('div.tbn li').where((node) => _text(node).contains('(银行货币)')).firstOrNull;
  final currency = _text(wallet?.querySelector('font')).replaceFirst(RegExp(r'\s*[:：]\s*$'), '');
  final forms = <BankServiceForm>[];
  var unsupported = false;
  if (!service.global) {
    for (final form
        in document.querySelectorAll('form').where((form) => form.querySelector('[name="banksubmit"]') != null)) {
      if (service == BankService.interest && form.querySelector('[name="banknum"]') != null) continue;
      final parsed = _serviceForm(form, service, bankId!);
      if (parsed == null || currency.isEmpty) {
        unsupported = true;
      } else {
        forms.add(parsed);
      }
    }
    // JavaScript or state-changing links cannot be treated as read-only navigation.
    unsupported =
        unsupported ||
        roots.any(
          (root) => root
              .querySelectorAll('a')
              .any(
                (link) =>
                    (link.attributes['href'] ?? '').startsWith('javascript:') || link.attributes.containsKey('onclick'),
              ),
        );
  }
  final hasNext = roots.any(
    (root) => root.querySelectorAll('.pg a[href]').any((link) {
      final uri = _pluginUri(link.attributes['href']);
      if (uri == null ||
          _positiveId(uri.queryParameters['page']) != page + 1 ||
          uri.queryParameters.keys.any((key) => !{'id', 'bankid', 'mode', 'action', 'page'}.contains(key))) {
        return false;
      }
      return {
        'id',
        'bankid',
        'mode',
        'action',
      }.every((key) => uri.queryParameters[key] == request.queryParameters[key]);
    }),
  );
  final feeRate = service == BankService.remittance
      ? RegExp(r'汇款手续费率为([0-9]+(?:\.[0-9]+)?)‰').firstMatch(blocks.map((block) => block.text).join(' '))?.group(1)
      : null;
  return BankServiceData(
    service: service,
    blocks: List.unmodifiable(blocks),
    forms: List.unmodifiable(forms),
    currency: currency,
    walletBalance: _text(wallet?.querySelector('span > b')),
    unsupportedForms: unsupported,
    hasNext: hasNext,
    feeRate: feeRate,
  );
}
