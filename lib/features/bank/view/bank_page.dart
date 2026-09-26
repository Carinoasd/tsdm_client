import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

part 'bank_service_widgets.dart';

/// Forum bank services and account records for the signed-in account.
class BankPage extends StatefulWidget {
  /// An injected [controller] is owned by its caller.
  const BankPage({super.key, this.controller});

  /// Optional controller for deterministic tests.
  final BankCubit? controller;

  @override
  State<BankPage> createState() => _BankPageState();
}

class _BankPageState extends State<BankPage> {
  late BankCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = BankCubit(
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => BankRepository.network(getIt.get<NetClientProvider>()),
      );
      _authSubscription = auth.status.listen((status) {
        _cubit.invalidate();
        if (status is! AuthStatusLoading) unawaited(_cubit.load());
      });
    }
    unawaited(_cubit.load());
  }

  @override
  void didUpdateWidget(BankPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _cubit.invalidate();
      unawaited(_authSubscription?.cancel());
      _authSubscription = null;
      if (oldWidget.controller == null) unawaited(_cubit.close());
      _start();
    }
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Future<void> _transact(ForumBank bank, BankSavings savings, BankOperation operation) async {
    if (_dialogOpen || !_cubit.isCurrent(savings) || _cubit.state.busy || savings.form == null) return;
    // Capture the controller too: replacing an injected controller cannot reuse an old confirmation.
    final controller = _cubit;
    setState(() => _dialogOpen = true);
    try {
      final input = await showDialog<({String amount, String password})>(
        context: context,
        builder: (context) => _BankTransactionDialog(
          controller: controller,
          savings: savings,
          bankName: bank.name,
          operation: operation,
        ),
      );
      if (!mounted || input == null || !identical(controller, _cubit) || !controller.isCurrent(savings)) return;
      await controller.submit(
        expected: savings,
        operation: operation,
        amount: input.amount,
        password: input.password,
      );
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Future<void> _serviceTransaction(BankServiceData data, BankServiceForm form) async {
    if (_dialogOpen || !_cubit.isCurrentService(data, form)) return;
    final controller = _cubit;
    final bankName = controller.state.bank!.name;
    setState(() => _dialogOpen = true);
    try {
      final values = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => _BankServiceDialog(controller: controller, data: data, form: form, bankName: bankName),
      );
      if (!mounted || values == null || !identical(controller, _cubit) || !controller.isCurrentService(data, form)) {
        return;
      }
      try {
        await controller.submitService(expected: data, form: form, values: values);
      } finally {
        values.clear();
      }
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Widget _services(BankState state, {required bool disabled}) {
    final bank = state.bank;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InputDecorator(
        decoration: InputDecoration(labelText: context.t.bank.services, border: const OutlineInputBorder()),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('bank-service-picker'),
            isExpanded: true,
            isDense: true,
            value: state.service?.name ?? ((bank?.hasAccount ?? false) ? 'current' : null),
            hint: Text(context.t.bank.services),
            onChanged: disabled
                ? null
                : (value) {
                    if (value == 'current') {
                      unawaited(_cubit.selectBank(bank!));
                    } else if (value != null) {
                      unawaited(_cubit.loadService(BankService.values.byName(value)));
                    }
                  },
            items: [
              if (bank?.hasAccount ?? false) DropdownMenuItem(value: 'current', child: Text(context.t.bank.savings)),
              for (final service in BankService.values.where(
                (service) =>
                    service == state.service ||
                    service.global ||
                    bank != null && (bank.hasAccount || service == BankService.hall),
              ))
                DropdownMenuItem(
                  key: ValueKey('bank-service-${service.name}'),
                  value: service.name,
                  child: Text(_serviceTitle(context, service)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serviceContent(BankState state, {required bool disabled}) {
    final tr = context.t.bank;
    final data = state.serviceData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: disabled ? null : _cubit.load,
            icon: const Icon(Icons.arrow_back),
            label: Text(tr.backToBanks),
          ),
        ),
        Text(
          [
            if (!state.service!.global && state.bank != null) state.bank!.name,
            _serviceTitle(context, state.service!),
          ].join(' · '),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (data != null) ...[
          if (data.unavailable.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(data.unavailable)),
          if (data.walletBalance.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('${tr.availableBalance}: ${data.walletBalance} ${data.currency}'),
            ),
          for (final form in data.forms)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (form.context.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(form.context)),
                    FilledButton(
                      onPressed: disabled ? null : () => _serviceTransaction(data, form),
                      child: Text(_serviceActionTitle(context, form)),
                    ),
                  ],
                ),
              ),
            ),
          for (final block in data.blocks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              child: Text(block.text, style: block.heading ? Theme.of(context).textTheme.titleMedium : null),
            ),
          if (data.unsupportedForms) Padding(padding: const EdgeInsets.all(12), child: Text(tr.unsupported)),
          if (data.hasNext || state.servicePage > 1)
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: disabled || state.servicePage <= 1
                      ? null
                      : () => _cubit.loadService(state.service!, page: state.servicePage - 1),
                  child: Text(tr.previous),
                ),
                Text('${state.servicePage}'),
                TextButton(
                  onPressed: disabled || !data.hasNext
                      ? null
                      : () => _cubit.loadService(state.service!, page: state.servicePage + 1),
                  child: Text(tr.next),
                ),
              ],
            ),
        ],
        TextButton.icon(
          onPressed: disabled
              ? null
              : () async => context.dispatchAsUrl(
                  bankServiceUrl(state.service!, bankId: state.bank?.id, page: state.servicePage),
                  external: true,
                ),
          icon: const Icon(Icons.open_in_browser_outlined),
          label: Text(tr.openWebsite),
        ),
      ],
    );
  }

  Widget _savings(ForumBank bank, BankSavings savings, {required bool disabled}) {
    final tr = context.t.bank;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.savings, style: Theme.of(context).textTheme.titleMedium),
            if (savings.summary.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(savings.summary),
            ],
            if (savings.walletBalance.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${tr.availableBalance}: ${savings.walletBalance} ${savings.currency}'.trim()),
            ],
            if (savings.interest.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${tr.interest}: ${savings.interest}'),
            ],
            if (savings.notices.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(savings.notices),
            ],
            const SizedBox(height: 16),
            if (savings.form != null)
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('bank-deposit'),
                    onPressed: disabled ? null : () => _transact(bank, savings, BankOperation.deposit),
                    icon: const Icon(Icons.savings_outlined),
                    label: Text(tr.deposit),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('bank-withdraw'),
                    onPressed: disabled ? null : () => _transact(bank, savings, BankOperation.withdraw),
                    icon: const Icon(Icons.account_balance_wallet_outlined),
                    label: Text(tr.withdraw),
                  ),
                ],
              )
            else
              Text(tr.unsupported),
            TextButton.icon(
              onPressed: disabled
                  ? null
                  : () async => context.dispatchAsUrl(bankPageUrl(bankId: bank.id, action: 'cur'), external: true),
              icon: const Icon(Icons.open_in_browser_outlined),
              label: Text(tr.openWebsite),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logs(BankState state, {required bool disabled}) {
    final tr = context.t.bank;
    final logs = state.logs;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.logs, style: Theme.of(context).textTheme.titleMedium),
            if (state.logsFailed) Text(tr.logsFailed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(tr.ownLogs),
                  selected: logs != null && !state.received,
                  onSelected: disabled ? null : (_) => unawaited(_cubit.loadLogs()),
                ),
                ChoiceChip(
                  label: Text(tr.receivedLogs),
                  selected: logs != null && state.received,
                  onSelected: disabled ? null : (_) => unawaited(_cubit.loadLogs(received: true)),
                ),
              ],
            ),
            if (logs != null) ...[
              const SizedBox(height: 12),
              if (logs.entries.isEmpty) Text(tr.emptyLogs),
              for (final entry in logs.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.message),
                  subtitle: entry.time.isEmpty ? null : Text(entry.time),
                ),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: disabled || state.logPage <= 1
                        ? null
                        : () => _cubit.loadLogs(received: state.received, page: state.logPage - 1),
                    child: Text(tr.previous),
                  ),
                  Text('${state.logPage}'),
                  TextButton(
                    onPressed: disabled || !logs.hasNext
                        ? null
                        : () => _cubit.loadLogs(received: state.received, page: state.logPage + 1),
                    child: Text(tr.next),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<BankCubit, BankState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.bank;
      final bank = state.bank;
      final savings = state.savings;
      final disabled = state.busy || _dialogOpen;
      return PopScope(
        canPop: !state.submitting,
        child: Scaffold(
          appBar: AppBar(
            leading: state.submitting && Navigator.of(context).canPop()
                ? IconButton(
                    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: null,
                    icon: const BackButtonIcon(),
                  )
                : null,
            title: Text(tr.title),
            actions: [
              IconButton(
                tooltip: tr.refresh,
                onPressed: disabled ? null : _cubit.refresh,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: tr.openWebsite,
                onPressed: disabled
                    ? null
                    : () async => context.dispatchAsUrl(
                        state.service == null
                            ? bankPageUrl(bankId: bank?.id, action: bank == null ? null : 'cur')
                            : bankServiceUrl(state.service!, bankId: bank?.id, page: state.servicePage),
                        external: true,
                      ),
                icon: const Icon(Icons.open_in_browser_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: () async {
                if (!disabled) await _cubit.refresh();
              },
              child: ListView(
                padding: const EdgeInsets.all(12),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (state.busy) const LinearProgressIndicator(),
                  if (state.unconfirmed)
                    Card(
                      child: Padding(padding: const EdgeInsets.all(16), child: Text(tr.unconfirmed)),
                    ),
                  if (state.loginRequired)
                    TextButton(
                      onPressed: disabled
                          ? null
                          : () async {
                              await context.pushNamed(ScreenPaths.login);
                              if (mounted) await _cubit.load();
                            },
                      child: Text(tr.loginRequired),
                    )
                  else ...[
                    if (state.uid != null) _services(state, disabled: disabled),
                    if (state.failed)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(tr.loadFailed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    if (state.service != null)
                      _serviceContent(state, disabled: disabled)
                    else if (bank == null) ...[
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(tr.chooseBank, style: Theme.of(context).textTheme.titleMedium),
                      ),
                      for (final item in state.banks)
                        Card(
                          child: ListTile(
                            key: ValueKey('bank-${item.id}'),
                            leading: const Icon(Icons.account_balance_outlined),
                            title: Text(item.name),
                            subtitle: Text(
                              [
                                if (item.description.isNotEmpty) item.description,
                                if (item.hasAccount) tr.opened else tr.notOpened,
                              ].join('\n'),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: disabled ? null : () => _cubit.selectBank(item),
                          ),
                        ),
                    ] else ...[
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: disabled ? null : _cubit.load,
                          icon: const Icon(Icons.arrow_back),
                          label: Text(tr.backToBanks),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(bank.name, style: Theme.of(context).textTheme.titleLarge),
                      ),
                      if (!bank.hasAccount)
                        Padding(padding: const EdgeInsets.all(12), child: Text(tr.notOpened))
                      else ...[
                        if (savings != null) _savings(bank, savings, disabled: disabled),
                        _logs(state, disabled: disabled),
                      ],
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: OutlinedButton.icon(
                          onPressed: disabled
                              ? null
                              : () async => context.dispatchAsUrl(bankPageUrl(bankId: bank.id), external: true),
                          icon: const Icon(Icons.open_in_browser_outlined),
                          label: Text(tr.otherServices),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Input and explicit confirmation share one route, so cancellation never submits.
class _BankTransactionDialog extends StatefulWidget {
  const _BankTransactionDialog({
    required this.controller,
    required this.savings,
    required this.bankName,
    required this.operation,
  });

  final BankCubit controller;
  final BankSavings savings;
  final String bankName;
  final BankOperation operation;

  @override
  State<_BankTransactionDialog> createState() => _BankTransactionDialogState();
}

class _BankTransactionDialogState extends State<_BankTransactionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _password = TextEditingController();
  bool _confirming = false;
  bool _closing = false;

  @override
  void dispose() {
    _amount.dispose();
    _password.dispose();
    super.dispose();
  }

  void _cancel() {
    // A system-back or barrier dismissal can leave the dialog mounted during its exit animation.
    // Do not let a concurrent account change pop the page underneath it.
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _continue() {
    if (_confirming || _closing) return;
    if (!widget.controller.isCurrent(widget.savings)) {
      _cancel();
      return;
    }
    if (_formKey.currentState!.validate()) {
      FocusScope.of(context).unfocus();
      setState(() => _confirming = true);
    }
  }

  void _confirm() {
    if (_closing) return;
    if (!widget.controller.isCurrent(widget.savings)) {
      _cancel();
      return;
    }
    _closing = true;
    Navigator.of(context).pop((amount: _amount.text.trim(), password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bank;
    final operation = widget.operation == BankOperation.deposit ? tr.deposit : tr.withdraw;
    return BlocListener<BankCubit, BankState>(
      bloc: widget.controller,
      listener: (context, state) {
        if (!widget.controller.isCurrent(widget.savings)) _cancel();
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(_confirming ? tr.confirmTitle : operation),
        content: _confirming
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.bankName, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  Text('$operation: ${_amount.text.trim()} ${widget.savings.currency}'.trim()),
                  const SizedBox(height: 16),
                  Text(tr.transactionNote),
                ],
              )
            : Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.bankName),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('bank-amount'),
                      controller: _amount,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      inputFormatters: [
                        // Reject the whole edit: stripping a decimal point or truncating a pasted amount
                        // would silently turn it into a different transaction.
                        TextInputFormatter.withFunction(
                          (previous, next) => RegExp(r'^[0-9]{0,18}$').hasMatch(next.text) ? next : previous,
                        ),
                      ],
                      decoration: InputDecoration(labelText: tr.amount, suffixText: widget.savings.currency),
                      validator: (value) =>
                          widget.savings.form?.accepts(value?.trim() ?? '') ?? false ? null : tr.invalidAmount,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('bank-password'),
                      controller: _password,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(labelText: tr.bankPassword),
                      validator: (value) => value == null || value.isEmpty ? tr.passwordRequired : null,
                      onFieldSubmitted: (_) => _continue(),
                    ),
                    const SizedBox(height: 8),
                    Text(tr.passwordHint, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
        actions: [
          TextButton(onPressed: _cancel, child: Text(tr.cancel)),
          FilledButton(
            key: ValueKey(_confirming ? 'bank-confirm' : 'bank-continue'),
            onPressed: _confirming ? _confirm : _continue,
            child: Text(_confirming ? tr.confirmAction : tr.continueAction),
          ),
        ],
      ),
    );
  }
}
