import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/points/models/credit_forms.dart';
import 'package:tsdm_client/features/points/repository/credit_forms_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// How [CreditFormPage] was left.
enum CreditFormExit {
  /// The forum has no form as fields for it: open the web page instead.
  web,
}

/// The text of the forum's refusal [refused] of a transfer or an exchange: the app's own for each key of the forum's
/// checks (`credit_base.php`), the forum's message for any other. [credit] (the transferred or the spent credit),
/// [minBalance] and [target] (the credit exchanged to) name what the rules are about: the forum's `values` of those
/// answers come empty.
String creditFormRefusalText(
  Translations t,
  CreditFormRefused refused, {
  required String credit,
  required int minBalance,
  String target = '',
}) {
  final tr = t.pointsPage.creditForms;
  return switch (refused.messageKey) {
    'credits_transfer_msg_locked' || 'memcp_credits_exchange_msg_locked' => tr.tooFast,
    'memcp_credits_transfer_msg_self_incorrect' => tr.selfTransfer,
    // The exchange's "balance insufficient" key is the forum's answer to an amount that costs nothing (none typed).
    'credits_transaction_amount_invalid' || 'memcp_credits_exchange_msg_balance_insufficient' => tr.amountInvalid,
    'credits_transfer_balance_insufficient' ||
    'credits_exchange_balance_insufficient' => tr.belowMin(credit: credit, min: minBalance),
    'credits_net_amount_iszero' => tr.nothingReceived,
    'memcp_credits_transfer_msg_user_incorrect' => tr.noUser,
    'credits_password_invalid' => tr.wrongPassword,
    'memcp_credits_exchange_msg_num_invalid' => tr.sameCredit,
    'credits_exchange_invalid' => tr.notExchangeable,
    'extcredits_disallowexchangeout' => tr.noExchangeOut(credit: credit),
    'extcredits_disallowexchangein' when target.isNotEmpty => tr.noExchangeIn(credit: target),
    _ when refused.message.isNotEmpty => refused.message,
    _ => tr.unknown,
  };
}

/// The transfer or the exchange of credits ([kind]) as a native form (plugin 4.1.0): the form read from the forum,
/// what the amount gives and leaves shown as it is typed, a confirmation with the login password, then one request.
///
/// [onWritten] is called when the credits may have changed (a done write, or one whose result is unknown). Pops with
/// [CreditFormExit.web] when the forum has no form as fields.
class CreditFormPage extends StatefulWidget {
  /// Constructor.
  const CreditFormPage({
    required this.kind,
    required this.onWritten,
    this.selfUsername,
    this.repository,
    super.key,
  });

  /// The form.
  final CreditFormKind kind;

  /// The credits may have changed.
  final VoidCallback onWritten;

  /// The account's own username: a transfer to it is refused before it is sent.
  final String? selfUsername;

  /// Overrides the repository (tests).
  final CreditFormsRepository? repository;

  @override
  State<CreditFormPage> createState() => _CreditFormPageState();
}

class _CreditFormPageState extends State<CreditFormPage> {
  late final CreditFormsRepository _repository = widget.repository ?? CreditFormsRepository();

  final _to = TextEditingController();
  final _amount = TextEditingController();
  final _message = TextEditingController();

  bool _loading = true;
  LoadFailure? _failure;
  String? _forumMessage;
  CreditTransferForm? _transfer;
  CreditExchangeForm? _exchange;
  int? _targetId;
  int? _sourceId;

  /// A confirmation is open or a write is on its way: nothing else is sent.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _to.addListener(_changed);
    _amount.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    _message.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    switch (widget.kind) {
      case CreditFormKind.transfer:
        _apply(await _repository.fetchTransfer().run(), (form) => _transfer = form);
      case CreditFormKind.exchange:
        _apply(await _repository.fetchExchange().run(), (form) {
          _exchange = form;
          final target = form.to.where((e) => e.id == _targetId).firstOrNull ?? form.to.first;
          _targetId = target.id;
          _sourceId =
              (form.from.where((e) => e.id == _sourceId && e.id != target.id).firstOrNull ??
                      form.from.where((e) => e.id != target.id).firstOrNull ??
                      form.from.first)
                  .id;
        });
    }
  }

  void _apply<T>(Either<AppException, CreditFormAnswer<T>> answer, void Function(T form) take) {
    if (!mounted) {
      return;
    }
    switch (answer) {
      case Left(:final value):
        setState(() {
          _loading = false;
          _failure = LoadFailure.of(value);
        });
        if (_transfer != null || _exchange != null) {
          // The form shown stays (a stale formhash is refused again, nothing taken).
          showSnackBar(context: context, message: context.t.general.failedToLoad, clearPrevious: true);
        }
      case Right(value: CreditFormReady(:final form)):
        setState(() {
          _loading = false;
          _forumMessage = null;
          take(form);
        });
      case Right(value: CreditFormMessage(:final message)):
        setState(() {
          _loading = false;
          _forumMessage = message;
          _transfer = null;
          _exchange = null;
        });
      case Right(value: CreditFormWebOnly()):
        Navigator.of(context).pop(CreditFormExit.web);
    }
  }

  /// What the form shown has of the credit a write takes: the transferred one, the source of the exchange.
  int? get _spentBalance => switch ((_transfer, _exchange)) {
    (final form?, _) => form.balance,
    (_, final form?) => form.balances[_sourceId],
    _ => null,
  };

  int? get _typedAmount {
    final text = _amount.text.trim();
    return text.isEmpty ? null : int.tryParse(text);
  }

  bool get _toSelf {
    final self = widget.selfUsername;
    return self != null && self.isNotEmpty && _to.text.trim() == self;
  }

  Future<void> _pickUser() async {
    final name = await showMentionPicker(context, username: _to.text.trim());
    if (name != null && mounted) {
      _to.text = name;
    }
  }

  /// Ask for the confirmation of [rows] and the login password; null when left.
  Future<String?> _confirm(String title, IconData icon, List<(String, String)> rows, String action) =>
      showDialog<String>(
        context: context,
        builder: (_) => _ConfirmDialog(title: title, icon: icon, rows: rows, action: action),
      );

  Future<void> _sendTransfer(CreditTransferForm form) async {
    final amount = _typedAmount;
    final to = _to.text.trim();
    if (_busy || amount == null || to.isEmpty || _toSelf || form.problemOf(amount) != null) {
      return;
    }
    final tr = context.t.pointsPage.creditForms;
    String credits(int n) => tr.credit(credit: n, unit: _creditName(context, form.credit.title, form.credit.unit));
    setState(() => _busy = true);
    try {
      final password = await _confirm(tr.confirmTransfer, Icons.send_outlined, [
        (tr.to, to),
        (tr.amount, credits(amount)),
        (tr.received, credits(form.received(amount))),
        (tr.tax, form.taxText),
        (tr.remain, credits(form.balance - amount)),
      ], tr.transfer);
      if (password == null || !mounted) {
        return;
      }
      final outcome = await _repository.transfer(
        form,
        to: to,
        amount: amount,
        message: _message.text.trim(),
        password: password,
      );
      if (mounted) {
        await _settle(outcome, credit: form.credit.title, minBalance: form.minBalance);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _sendExchange(CreditExchangeForm form, ExchangeCredit target, ExchangeCredit source) async {
    final amount = _typedAmount;
    if (_busy || amount == null || form.problemOf(target, source, amount) != null) {
      return;
    }
    final tr = context.t.pointsPage.creditForms;
    final cost = form.cost(target, source, amount);
    setState(() => _busy = true);
    try {
      final password = await _confirm(tr.confirmExchange, Icons.swap_horiz_outlined, [
        (tr.target, tr.credit(credit: amount, unit: _creditName(context, target.title, target.unit))),
        (tr.cost, tr.credit(credit: cost, unit: _creditName(context, source.title, source.unit))),
        (tr.tax, form.taxText),
        (
          tr.remain,
          tr.credit(credit: form.balanceOf(source) - cost, unit: _creditName(context, source.title, source.unit)),
        ),
      ], tr.exchange);
      if (password == null || !mounted) {
        return;
      }
      final outcome = await _repository.exchange(
        form,
        target: target,
        source: source,
        amount: amount,
        password: password,
      );
      if (mounted) {
        await _settle(outcome, credit: source.title, minBalance: form.minBalance, target: target.title);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _settle(
    CreditFormOutcome outcome, {
    required String credit,
    required int minBalance,
    String target = '',
  }) async {
    final tr = context.t.pointsPage.creditForms;
    switch (outcome) {
      case CreditFormDone():
        widget.onWritten();
        showSnackBar(
          context: context,
          message: widget.kind == CreditFormKind.transfer ? tr.transferDone : tr.exchangeDone,
        );
        Navigator.of(context).pop();
      case CreditFormRefused():
        showSnackBar(
          context: context,
          message: creditFormRefusalText(
            context.t,
            outcome,
            credit: context.displayText(credit),
            minBalance: minBalance,
            target: context.displayText(target),
          ),
          clearPrevious: true,
        );
        if (outcome.messageKey
            case 'credits_transfer_balance_insufficient' || 'credits_exchange_balance_insufficient') {
          // The balance changed since the form was read.
          await _load();
        }
      case CreditFormExpired():
        // Nothing was taken (the forum refuses a wrong formhash first): a new formhash, and the user sends again. A
        // balance lower than before says otherwise (a 503 of something in between, after the write).
        final before = _spentBalance;
        await _load();
        final after = _spentBalance;
        if (!mounted) {
          return;
        }
        if (before != null && after != null && after < before) {
          widget.onWritten();
          _amount.clear();
          showSnackBar(context: context, message: tr.unknown, clearPrevious: true);
        } else {
          showSnackBar(context: context, message: tr.expired, clearPrevious: true);
        }
      case CreditFormAccountChanged():
        showSnackBar(context: context, message: tr.accountChanged, clearPrevious: true);
        Navigator.of(context).pop();
      case CreditFormUnknown():
        // It may have been carried out: never sent again by itself, the balances read again.
        widget.onWritten();
        _amount.clear();
        await _load();
        if (mounted) {
          showSnackBar(context: context, message: tr.unknown, clearPrevious: true);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pointsPage.creditForms;
    final Widget body;
    if (_loading && _transfer == null && _exchange == null) {
      body = const CenteredCircularIndicator();
    } else if (_failure != null && _transfer == null && _exchange == null) {
      body = FailureView(failure: _failure, onRetry: _load);
    } else if (_forumMessage case final message?) {
      body = AppStateView(icon: Icons.block_outlined, message: message);
    } else {
      body = AppCenteredList(
        builder: (context, side, _) => SingleChildScrollView(
          padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
          child: switch ((_transfer, _exchange)) {
            (final form?, _) => _transferForm(context, form),
            (_, final form?) => _exchangeForm(context, form),
            _ => sizedBoxEmpty,
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.kind == CreditFormKind.transfer ? tr.transfer : tr.exchange),
        bottom: _loading && (_transfer != null || _exchange != null)
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      body: SafeArea(bottom: false, child: body),
    );
  }

  InputDecoration _decoration(String label, {String? error, Widget? suffix}) => InputDecoration(
    labelText: label,
    errorText: error,
    filled: true,
    suffixIcon: suffix,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
  );

  Widget _amountField(String? error) => TextField(
    controller: _amount,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
    decoration: _decoration(context.t.pointsPage.creditForms.amount, error: error),
  );

  Widget _transferForm(BuildContext context, CreditTransferForm form) {
    final tr = context.t.pointsPage.creditForms;
    String credits(int n) => tr.credit(credit: n, unit: _creditName(context, form.credit.title, form.credit.unit));
    final amount = _typedAmount;
    final problem = amount == null ? null : form.problemOf(amount);
    final ready = amount != null && problem == null && _to.text.trim().isNotEmpty && !_toSelf;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ValueRow(tr.balance, credits(form.balance)),
              _ValueRow(tr.maxAmount, credits(form.maxAmount)),
              _ValueRow(tr.tax, form.taxText),
            ],
          ),
        ),
        sizedBoxW12H12,
        TextField(
          controller: _to,
          textInputAction: TextInputAction.next,
          decoration: _decoration(
            tr.to,
            error: _toSelf ? tr.selfTransfer : null,
            suffix: IconButton(
              tooltip: tr.pickUser,
              icon: const Icon(Icons.alternate_email_outlined),
              onPressed: _pickUser,
            ),
          ),
        ),
        sizedBoxW12H12,
        _amountField(switch (problem) {
          CreditTransferProblem.amount => tr.amountInvalid,
          CreditTransferProblem.balance => tr.overMax,
          CreditTransferProblem.nothingReceived => tr.nothingReceived,
          null => null,
        }),
        if (amount != null && problem == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ValueRow(tr.received, credits(form.received(amount))),
                _ValueRow(tr.remain, credits(form.balance - amount)),
              ],
            ),
          ),
        sizedBoxW12H12,
        TextField(
          controller: _message,
          minLines: 1,
          maxLines: 4,
          decoration: _decoration(tr.message),
        ),
        sizedBoxW12H12,
        FilledButton.icon(
          onPressed: ready && !_busy && !_loading ? () => _sendTransfer(form) : null,
          icon: const Icon(Icons.send_outlined),
          label: Text(tr.transfer),
        ),
      ],
    );
  }

  Widget _exchangeForm(BuildContext context, CreditExchangeForm form) {
    final tr = context.t.pointsPage.creditForms;
    final target = form.to.where((e) => e.id == _targetId).firstOrNull ?? form.to.first;
    final source = form.from.where((e) => e.id == _sourceId).firstOrNull ?? form.from.first;
    String credits(int n, ExchangeCredit credit) =>
        tr.credit(credit: n, unit: _creditName(context, credit.title, credit.unit));
    final amount = _typedAmount;
    final problem = target.id == source.id
        ? CreditExchangeProblem.same
        : (amount == null ? null : form.problemOf(target, source, amount));
    final cost = amount == null || problem != null ? null : form.cost(target, source, amount);
    DropdownMenuItem<int> item(ExchangeCredit credit) => DropdownMenuItem(
      value: credit.id,
      child: Text('${context.displayText(credit.title)}  ${form.balanceOf(credit)}'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          initialValue: target.id,
          items: [for (final credit in form.to) item(credit)],
          onChanged: (id) => setState(() => _targetId = id),
          decoration: _decoration(tr.target),
        ),
        sizedBoxW12H12,
        DropdownButtonFormField<int>(
          initialValue: source.id,
          items: [for (final credit in form.from) item(credit)],
          onChanged: (id) => setState(() => _sourceId = id),
          decoration: _decoration(tr.source, error: problem == CreditExchangeProblem.same ? tr.sameCredit : null),
        ),
        sizedBoxW12H12,
        _amountField(switch (problem) {
          CreditExchangeProblem.amount => tr.amountInvalid,
          CreditExchangeProblem.balance => tr.belowMin(
            credit: context.displayText(source.title),
            min: form.minBalance,
          ),
          CreditExchangeProblem.same || null => null,
        }),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (cost != null) ...[
                _ValueRow(tr.cost, credits(cost, source)),
                _ValueRow(tr.remain, credits(form.balanceOf(source) - cost, source)),
              ],
              _ValueRow(tr.tax, form.taxText),
            ],
          ),
        ),
        sizedBoxW12H12,
        FilledButton.icon(
          onPressed: cost != null && !_busy && !_loading ? () => _sendExchange(form, target, source) : null,
          icon: const Icon(Icons.swap_horiz_outlined),
          label: Text(tr.exchange),
        ),
      ],
    );
  }
}

/// What follows a number of a credit: its title, and its unit when the forum gives one.
String _creditName(BuildContext context, String title, String unit) =>
    [context.displayText(title), unit].where((e) => e.isNotEmpty).join(' ');

/// A label and its value on one line.
class _ValueRow extends StatelessWidget {
  const _ValueRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ),
          sizedBoxW8H8,
          Expanded(child: Text(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The confirmation of a transfer or an exchange: what it does ([rows]) and the login password the forum asks for.
/// Pops with the password.
class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.title, required this.icon, required this.rows, required this.action});

  final String title;
  final IconData icon;
  final List<(String, String)> rows;
  final String action;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isNotEmpty) {
      Navigator.pop(context, _password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pointsPage.creditForms;
    return AlertDialog(
      scrollable: true,
      title: AppDialogTitle(icon: widget.icon, title: widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (label, value) in widget.rows) _ValueRow(label, value),
          sizedBoxW12H12,
          TextField(
            controller: _password,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            keyboardType: TextInputType.visiblePassword,
            inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr.password,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: _password.text.isEmpty ? null : _submit, child: Text(widget.action)),
      ],
    );
  }
}
