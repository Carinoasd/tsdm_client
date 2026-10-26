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

IconData _serviceIcon(BankService service) => switch (service) {
  BankService.hall => Icons.store_mall_directory_outlined,
  BankService.term => Icons.lock_clock_outlined,
  BankService.remittance => Icons.send_outlined,
  BankService.loans => Icons.request_quote_outlined,
  BankService.account => Icons.manage_accounts_outlined,
  BankService.interest => Icons.trending_up_outlined,
  BankService.overview => Icons.summarize_outlined,
  BankService.ranking => Icons.leaderboard_outlined,
  BankService.exchange => Icons.currency_exchange_outlined,
};

/// Back to the bank list, then the icon and name of the bank or service shown.
class _BankHeader extends StatelessWidget {
  const _BankHeader({required this.icon, required this.title, required this.onBack, required this.backLabel});

  final IconData icon;
  final String title;
  final VoidCallback? onBack;
  final String backLabel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(onPressed: onBack, icon: const Icon(Icons.arrow_back), label: Text(backLabel)),
      sizedBoxW4H4,
      Row(
        children: [
          AppIconTile(icon, size: 44),
          sizedBoxW12H12,
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    ],
  );
}

/// A labelled amount (balance, interest): caption above, the value in bold, never shortened.
class _BankValue extends StatelessWidget {
  const _BankValue({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppInsetBlock(
      color: colorScheme.surfaceContainerHigh,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          sizedBoxW8H8,
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                Text(value, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Previous / page / next of the bank records and service pages; the total is not known.
class _BankPager extends StatelessWidget {
  const _BankPager({
    required this.page,
    required this.previousLabel,
    required this.nextLabel,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final String previousLabel;
  final String nextLabel;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 4,
    children: [
      TextButton(
        onPressed: onPrevious,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [const Icon(Icons.chevron_left, size: 18), sizedBoxW4H4, Text(previousLabel)],
        ),
      ),
      AppInsetBlock(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text('$page'),
      ),
      TextButton(
        onPressed: onNext,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Text(nextLabel), sizedBoxW4H4, const Icon(Icons.chevron_right, size: 18)],
        ),
      ),
    ],
  );
}

/// Icon tile and title of the bank dialogs; the title wraps instead of being cut.
class _BankDialogTitle extends StatelessWidget {
  const _BankDialogTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      AppIconTile(icon, size: 36),
      sizedBoxW12H12,
      Expanded(child: Text(title)),
    ],
  );
}

/// Filled, rounded decoration of the bank form fields.
InputDecoration _bankFieldDecoration(String label, {String? helperText}) => InputDecoration(
  labelText: label,
  helperText: helperText,
  helperMaxLines: 3,
  errorMaxLines: 3,
  filled: true,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
);

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
  const _BankServiceDialog({
    required this.controller,
    required this.data,
    required this.form,
    required this.bankName,
    this.notice = '',
  });
  final BankCubit controller;
  final BankServiceData data;
  final BankServiceForm form;
  final String bankName;

  /// The confirmation page's own notice (a term withdrawal), shown with the record.
  final String notice;

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
        title: _BankDialogTitle(
          icon: _confirming ? Icons.fact_check_outlined : _serviceIcon(widget.form.service),
          title: _confirming ? tr.confirmTitle : title,
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: !current
                ? AppNoticeBanner(message: tr.confirmExpired, tone: AppNoticeTone.warning)
                : Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppInsetBlock(
                          outlined: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${widget.bankName} · $title',
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              if (widget.data.currency.isNotEmpty)
                                Text(
                                  widget.data.currency,
                                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (widget.form.context.isNotEmpty)
                          Padding(padding: const EdgeInsets.only(top: 8), child: Text(widget.form.context)),
                        if (widget.notice.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: AppNoticeBanner(
                              key: const ValueKey('bank-service-notice'),
                              message: widget.notice,
                              tone: AppNoticeTone.warning,
                              icon: Icons.info_outline,
                            ),
                          ),
                        sizedBoxW8H8,
                        if (_confirming) ...[
                          AppInsetBlock(
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final entry in _inputs.entries.where((entry) => !entry.key.secret))
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Text(
                                      '${_inputTitle(context, entry.key)}: ${entry.value.text}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                if (widget.data.blocks.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(widget.data.blocks.first.text),
                                  ),
                                if (widget.data.blocks.length > 1)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(widget.data.blocks.last.text),
                                  ),
                              ],
                            ),
                          ),
                          if (widget.form.service == BankService.account && widget.form.operation == 'cl')
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: AppNoticeBanner(message: tr.closeWarning, tone: AppNoticeTone.error),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: AppNoticeBanner(
                              message: tr.serviceTransactionNote,
                              tone: AppNoticeTone.warning,
                              icon: Icons.info_outline,
                            ),
                          ),
                        ] else ...[
                          for (final entry in _inputs.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: TextFormField(
                                key: ValueKey('bank-input-${entry.key.field}'),
                                controller: entry.value,
                                decoration: _bankFieldDecoration(
                                  _inputTitle(context, entry.key),
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
                          if (widget.form.inputs.any((input) => input.secret))
                            Text(
                              tr.passwordHint,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                        if (fee != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: AppInsetBlock(
                              outlined: true,
                              child: Text('${tr.estimatedFee}: $fee ${widget.data.currency}\n${tr.feeHint}'),
                            ),
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
