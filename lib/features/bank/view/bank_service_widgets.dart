part of 'bank_page.dart';

String _serviceTitle(BuildContext context, BankService service) {
  final tr = context.t.bank;
  return switch (service) {
    BankService.hall => tr.hall,
    BankService.term => tr.term,
    BankService.remittance => tr.remittance,
    BankService.loans => tr.loans,
    BankService.account => tr.account,
    BankService.interest => tr.settleInterest,
    BankService.overview => tr.overview,
    BankService.ranking => tr.ranking,
    BankService.exchange => tr.exchange,
  };
}

String _serviceActionTitle(BuildContext context, BankServiceForm form) {
  final tr = context.t.bank;
  return switch (form.service) {
    BankService.hall => '${tr.openAccount} · ${form.label}',
    BankService.interest => tr.settleInterest,
    BankService.term when form.operation == 'in' => tr.termDeposit,
    BankService.remittance => tr.remittance,
    BankService.loans when form.operation == 'try' => tr.loanApply,
    BankService.account when form.operation == 'cg' => tr.changePassword,
    BankService.account when form.operation == 'cl' => tr.closeAccount,
    _ => form.label,
  };
}

String _inputTitle(BuildContext context, BankInput input) {
  final tr = context.t.bank;
  return switch (input) {
    BankInput.amount => tr.amount,
    BankInput.days => tr.days,
    BankInput.recipient => tr.recipient,
    BankInput.password => tr.bankPassword,
    BankInput.passwordConfirm => tr.passwordConfirm,
    BankInput.newPassword => tr.newPassword,
    BankInput.newPasswordConfirm => tr.passwordConfirm,
  };
}

class _BankServiceDialog extends StatefulWidget {
  const _BankServiceDialog({required this.controller, required this.data, required this.form, required this.bankName});
  final BankCubit controller;
  final BankServiceData data;
  final BankServiceForm form;
  final String bankName;

  @override
  State<_BankServiceDialog> createState() => _BankServiceDialogState();
}

class _BankServiceDialogState extends State<_BankServiceDialog> {
  late final Map<BankInput, TextEditingController> _inputs = {
    for (final input in widget.form.inputs) input: TextEditingController(),
  };
  final _formKey = GlobalKey<FormState>();
  bool _confirming = false;
  bool _closed = false;

  Map<String, String> _values() => {for (final entry in _inputs.entries) entry.key.field: entry.value.text};

  void _cancel() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    for (final controller in _inputs.values) {
      controller
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  void _continue() {
    if (_closed ||
        !(ModalRoute.of(context)?.isCurrent ?? false) ||
        !widget.controller.isCurrentService(widget.data, widget.form)) {
      return;
    }
    if (!_confirming) {
      if (_formKey.currentState?.validate() != true) return;
      setState(() => _confirming = true);
      return;
    }
    final values = _values();
    if (widget.form.inputs.any((input) => !widget.form.valid(input, values))) return;
    _closed = true;
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bank;
    final current = widget.controller.isCurrentService(widget.data, widget.form);
    final fee = widget.data.estimatedFee(_inputs[BankInput.amount]?.text ?? '');
    final title = _serviceActionTitle(context, widget.form);
    return BlocListener<BankCubit, BankState>(
      bloc: widget.controller,
      listener: (context, state) {
        if (!widget.controller.isCurrentService(widget.data, widget.form)) _cancel();
      },
      child: AlertDialog(
        title: Text(_confirming ? tr.confirmTitle : title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: !current
                ? Text(tr.confirmExpired)
                : Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${widget.bankName} · $title'),
                        if (widget.data.currency.isNotEmpty) Text(widget.data.currency),
                        if (widget.form.context.isNotEmpty)
                          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(widget.form.context)),
                        if (_confirming) ...[
                          for (final entry in _inputs.entries.where((entry) => !entry.key.secret))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text('${_inputTitle(context, entry.key)}: ${entry.value.text}'),
                            ),
                          if (widget.data.blocks.isNotEmpty) Text(widget.data.blocks.first.text),
                          if (widget.data.blocks.length > 1) Text(widget.data.blocks.last.text),
                          if (widget.form.service == BankService.account && widget.form.operation == 'cl')
                            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr.closeWarning)),
                          Padding(padding: const EdgeInsets.only(top: 12), child: Text(tr.serviceTransactionNote)),
                        ] else ...[
                          for (final entry in _inputs.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: TextFormField(
                                key: ValueKey('bank-input-${entry.key.field}'),
                                controller: entry.value,
                                decoration: InputDecoration(
                                  labelText: _inputTitle(context, entry.key),
                                  helperText: entry.key == BankInput.days && widget.form.service == BankService.term
                                      ? tr.termMinimumDays
                                      : entry.key == BankInput.amount && widget.form.service == BankService.remittance
                                      ? tr.remittanceMinimum
                                      : null,
                                ),
                                obscureText: entry.key.secret,
                                enableSuggestions: !entry.key.secret,
                                autocorrect: false,
                                keyboardType: entry.key == BankInput.amount || entry.key == BankInput.days
                                    ? TextInputType.number
                                    : TextInputType.text,
                                onChanged: entry.key == BankInput.amount ? (_) => setState(() {}) : null,
                                validator: (_) => widget.form.valid(entry.key, _values())
                                    ? null
                                    : entry.key == BankInput.passwordConfirm ||
                                          entry.key == BankInput.newPasswordConfirm
                                    ? tr.passwordMismatch
                                    : tr.invalidValue,
                              ),
                            ),
                          if (widget.form.inputs.any((input) => input.secret)) Text(tr.passwordHint),
                        ],
                        if (fee != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text('${tr.estimatedFee}: $fee ${widget.data.currency}\n${tr.feeHint}'),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _cancel,
            child: Text(tr.cancel),
          ),
          if (_confirming && current)
            TextButton(onPressed: () => setState(() => _confirming = false), child: Text(tr.editInput)),
          if (current)
            FilledButton(
              key: ValueKey(_confirming ? 'bank-service-confirm' : 'bank-service-continue'),
              onPressed: _continue,
              child: Text(_confirming ? tr.confirmAction : tr.continueAction),
            ),
        ],
      ),
    );
  }
}
