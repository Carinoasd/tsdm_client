import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;

/// The two forms of the credits page besides the statistics: the transfer to another member and the exchange between
/// two credits of the account. The web page shows a tab for each one the forum lets the account use.
enum CreditFormKind {
  /// `op=transfer`.
  transfer('transfer'),

  /// `op=exchange`.
  exchange('exchange')
  ;

  const CreditFormKind(this.op);

  /// The `op` of the page.
  final String op;

  /// The page of the form: the web page a plugin without the fields of 4.1.0 leaves to the browser, the same url asked
  /// of plugin 4.1.0 with `tsdmv=4`.
  String get pageUrl => '$baseUrl/home.php?mod=spacecp&ac=credit&op=$op';

  /// Where the form is posted: the page's own target (the forum checks the form, the balance and the password).
  String get submitUrl => switch (this) {
    CreditFormKind.transfer => '$baseUrl/home.php?mod=spacecp&ac=credit&op=transfer',
    CreditFormKind.exchange => '$baseUrl/home.php?mod=spacecp&ac=credit&op=exchange&handlekey=credit',
  };

  /// The `type` of the page of plugin 4.1.0.
  String get type => switch (this) {
    CreditFormKind.transfer => 'credit_transfer',
    CreditFormKind.exchange => 'credit_exchange',
  };

  /// The `schema` of the page of plugin 4.1.0.
  int get schema => switch (this) {
    CreditFormKind.transfer => 72,
    CreditFormKind.exchange => 73,
  };

  /// The `message_key` the forum answers a done write with: the only success.
  String get successKey => switch (this) {
    CreditFormKind.transfer => 'credits_transfer_succeed',
    CreditFormKind.exchange => 'credits_transaction_succeed',
  };
}

/// The forms the tabs of the credits page [tabs] (`credit_base`, `schema` 52: `tabs[].op`) offer, in their order.
List<CreditFormKind> creditFormsOfTabs(Object? tabs) => [
  for (final kind in CreditFormKind.values)
    if (tsdmAppList(tabs).any((tab) => tsdmAppText(tab['op']) == kind.op)) kind,
];

/// The forms the tabs of the credits web page [document] offer (`ul.tb` links to `op=transfer`, `op=exchange`).
List<CreditFormKind> creditFormsOfDocument(uh.Document document) {
  final ops = {
    for (final link in document.querySelectorAll('ul.tb a[href]'))
      if (Uri.tryParse(link.attributes['href'] ?? '')?.queryParameters case final query?
          when query['ac'] == 'credit' && query['mod'] == 'spacecp')
        query['op'] ?? '',
  };
  return [
    for (final kind in CreditFormKind.values)
      if (ops.contains(kind.op)) kind,
  ];
}

/// One credit of the forum as a form names it.
typedef CreditInfo = ({int id, String title, String unit});

/// One credit of an exchange menu: the credit and the forum's ratio of it.
typedef ExchangeCredit = ({int id, String title, String unit, num ratio});

/// The fields of the forum's own form an answer serves (`submit.fields`) named in [names], as text.
Map<String, String> _servedFields(Object? submit, Set<String> names) => {
  for (final MapEntry(:key, :value) in tsdmAppMap(tsdmAppMap(submit)['fields']).entries)
    if (names.contains(key))
      key: switch (value) {
        final String s => s,
        final num n => '$n',
        _ => '',
      },
};

num _num(Object? value) => switch (value) {
  final num n => n,
  final String s => num.tryParse(s.trim()) ?? 0,
  _ => 0,
};

Map<int, int> _balances(Object? credits) => {
  for (final credit in tsdmAppList(credits))
    if (tsdmAppInt(credit['id']) case final id when id > 0) id: tsdmAppInt(credit['value']),
};

/// The transfer page of plugin 4.1.0 (`credit_transfer`, `schema` 72).
final class CreditTransferForm {
  const CreditTransferForm._({
    required this.uid,
    required this.credit,
    required this.balance,
    required this.minBalance,
    required this.maxAmount,
    required this.tax,
    required this.taxText,
    required this.fields,
  });

  /// The form of the page answer [json] served to account [uid]; null when it lacks what the form needs (the credit,
  /// the formhash).
  static CreditTransferForm? fromJson(Map<String, dynamic> json, {required int uid}) {
    final credit = tsdmAppMap(json['credit']);
    final id = tsdmAppInt(credit['id']);
    final fields = _servedFields(json['submit'], const {'formhash', 'transfersubmit', 'handlekey'});
    if (id <= 0 || (fields['formhash'] ?? '').isEmpty) {
      return null;
    }
    final balance = tsdmAppInt(json['balance']);
    final minBalance = tsdmAppInt(json['min_balance']);
    final max = balance - minBalance;
    return CreditTransferForm._(
      uid: uid,
      credit: (id: id, title: tsdmAppText(credit['title']).trim(), unit: tsdmAppText(credit['unit']).trim()),
      balance: balance,
      minBalance: minBalance,
      maxAmount: max < 0 ? 0 : max,
      tax: _num(json['tax']),
      taxText: tsdmAppText(json['tax_percent']).trim(),
      fields: {'transfersubmit': 'true', ...fields},
    );
  }

  /// The account the page was served to.
  final int uid;

  /// The credit that is transferred.
  final CreditInfo credit;

  /// What the account has of it now.
  final int balance;

  /// What it must keep after the transfer.
  final int minBalance;

  /// The most it may transfer: [balance] above [minBalance], 0 when below.
  final int maxAmount;

  /// The forum's tax of a transfer, a fraction (0.2).
  final num tax;

  /// The tax as the page prints it (`20.00%`).
  final String taxText;

  /// The served fields of the forum's form (`formhash`, `transfersubmit`, `handlekey`).
  final Map<String, String> fields;

  /// What the member receives of [amount]: the forum's `floor(amount × (1 - tax))`.
  int received(int amount) => (amount * (1 - tax)).floor();

  /// Why [amount] cannot be sent, null when the forum would take it.
  CreditTransferProblem? problemOf(int amount) {
    if (amount <= 0) {
      return CreditTransferProblem.amount;
    }
    if (amount > maxAmount) {
      return CreditTransferProblem.balance;
    }
    if (received(amount) <= 0) {
      return CreditTransferProblem.nothingReceived;
    }
    return null;
  }

  /// The body of the form: [to] (a username), [amount], [message] and the account's login [password].
  Map<String, String> body({
    required String to,
    required int amount,
    required String message,
    required String password,
  }) => {
    ...fields,
    'to': to,
    'transferamount': '$amount',
    'transfermessage': message,
    'password': password,
  };
}

/// What keeps an amount of a transfer from being sent.
enum CreditTransferProblem {
  /// Not a positive number.
  amount,

  /// Above [CreditTransferForm.maxAmount].
  balance,

  /// Nothing left after the tax.
  nothingReceived,
}

/// The exchange page of plugin 4.1.0 (`credit_exchange`, `schema` 73).
final class CreditExchangeForm {
  const CreditExchangeForm._({
    required this.uid,
    required this.to,
    required this.from,
    required this.balances,
    required this.minBalance,
    required this.tax,
    required this.taxText,
    required this.fields,
  });

  /// The form of the page answer [json] served to account [uid]; null when it lacks the formhash. The exchanges with
  /// the other applications of the forum's user center (`out[]`) are left to the web page.
  static CreditExchangeForm? fromJson(Map<String, dynamic> json, {required int uid}) {
    final fields = _servedFields(json['submit'], const {'formhash', 'operation', 'exchangesubmit'});
    if ((fields['formhash'] ?? '').isEmpty) {
      return null;
    }
    List<ExchangeCredit> menu(Object? value) => [
      for (final credit in tsdmAppList(value))
        if ((tsdmAppInt(credit['id']), _num(credit['ratio'])) case (final id, final ratio) when id > 0 && ratio > 0)
          (
            id: id,
            title: tsdmAppText(credit['title']).trim(),
            unit: tsdmAppText(credit['unit']).trim(),
            ratio: ratio,
          ),
    ];
    return CreditExchangeForm._(
      uid: uid,
      to: menu(json['to']),
      from: menu(json['from']),
      balances: _balances(json['credits']),
      minBalance: tsdmAppInt(json['min_balance']),
      tax: _num(json['tax']),
      taxText: tsdmAppText(json['tax_percent']).trim(),
      fields: {'operation': 'exchange', 'exchangesubmit': 'true', ...fields, 'outi': ''},
    );
  }

  /// The account the page was served to.
  final int uid;

  /// The credits that may be exchanged to.
  final List<ExchangeCredit> to;

  /// The credits that may be spent.
  final List<ExchangeCredit> from;

  /// What the account has of each credit, by id.
  final Map<int, int> balances;

  /// What the spent credit must keep after the exchange.
  final int minBalance;

  /// The forum's tax of an exchange, a fraction (0.2).
  final num tax;

  /// The tax as the page prints it (`20.00%`).
  final String taxText;

  /// The served fields of the forum's form.
  final Map<String, String> fields;

  /// Whether there is anything to exchange: two different credits.
  bool get usable => to.any((t) => from.any((f) => f.id != t.id));

  /// What [amount] of [target] costs of [source]: the forum's own formula (`credit_base.php`), in its order, rounded
  /// up when the target's ratio is below the source's and down otherwise.
  int cost(ExchangeCredit target, ExchangeCredit source, int amount) {
    final r = amount * target.ratio / source.ratio * (1 + tax);
    return target.ratio < source.ratio ? r.ceil() : r.floor();
  }

  /// What the account has of [credit].
  int balanceOf(ExchangeCredit credit) => balances[credit.id] ?? 0;

  /// Why [amount] of [target] from [source] cannot be sent, null when the forum would take it.
  CreditExchangeProblem? problemOf(ExchangeCredit target, ExchangeCredit source, int amount) {
    if (target.id == source.id) {
      return CreditExchangeProblem.same;
    }
    if (amount <= 0) {
      return CreditExchangeProblem.amount;
    }
    final spent = cost(target, source, amount);
    if (spent <= 0) {
      return CreditExchangeProblem.amount;
    }
    if (balanceOf(source) - spent < minBalance) {
      return CreditExchangeProblem.balance;
    }
    return null;
  }

  /// The body of the form: [amount] of [target] from [source], with the account's login [password].
  Map<String, String> body({
    required ExchangeCredit target,
    required ExchangeCredit source,
    required int amount,
    required String password,
  }) => {
    ...fields,
    'tocredits': '${target.id}',
    'fromcredits': '${source.id}',
    'exchangeamount': '$amount',
    'password': password,
  };
}

/// What keeps an exchange from being sent.
enum CreditExchangeProblem {
  /// The same credit on both sides.
  same,

  /// Not a positive number, or nothing to spend for it.
  amount,

  /// The spent credit would fall below [CreditExchangeForm.minBalance].
  balance,
}

/// What the forum answered a transfer or an exchange with.
sealed class CreditFormOutcome {
  const CreditFormOutcome();
}

/// Done: the forum's success key.
final class CreditFormDone extends CreditFormOutcome {
  /// Constructor.
  const CreditFormDone();
}

/// Refused with the forum's [messageKey] and [message]: nothing was taken.
final class CreditFormRefused extends CreditFormOutcome {
  /// Constructor.
  const CreditFormRefused({required this.messageKey, required this.message});

  /// The Discuz! language key.
  final String messageKey;

  /// The forum's message, plain text.
  final String message;

  /// The login password was wrong.
  bool get wrongPassword => messageKey == 'credits_password_invalid';
}

/// The form expired (a wrong formhash: the forum's HTTP 503 page): nothing was taken; the form is read again and the
/// user sends it again.
final class CreditFormExpired extends CreditFormOutcome {
  /// Constructor.
  const CreditFormExpired();
}

/// The answer was of another account: the account changed meanwhile.
final class CreditFormAccountChanged extends CreditFormOutcome {
  /// Constructor.
  const CreditFormAccountChanged();
}

/// Nothing known (no answer, a timed out request, an answer the app does not know): the write may have been carried
/// out. Never sent again by itself: the balances are read again.
final class CreditFormUnknown extends CreditFormOutcome {
  /// Constructor.
  const CreditFormUnknown();
}
