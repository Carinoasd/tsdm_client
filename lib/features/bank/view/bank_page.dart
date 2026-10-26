import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
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
import 'package:tsdm_client/widgets/app_surface.dart';

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

  /// The record whose confirmation page is being read (a term withdrawal): its button shows the wait.
  BankServiceForm? _reading;

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
      String? notice;
      if (form.confirmUrl != null) {
        // A term withdrawal: the forum's confirmation page is read first, so its notice is shown before anything is
        // entered, and a reason the forum gives instead (the record is gone, the account frozen) ends here.
        final ({String notice, String reason})? page;
        setState(() => _reading = form);
        try {
          page = await controller.readConfirmation(data, form);
        } on Object catch (e) {
          // A page the app cannot take is not a failed read: the website is the way then, a retry otherwise.
          if (mounted) {
            final tr = context.t.bank;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(e is FormatException ? tr.unsupported : tr.confirmLoadFailed)));
          }
          return;
        } finally {
          if (mounted) setState(() => _reading = null);
        }
        if (!mounted || page == null || !identical(controller, _cubit) || !controller.isCurrentService(data, form)) {
          return;
        }
        if (page.reason.isNotEmpty) {
          final reason = page.reason;
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(_serviceActionTitle(context, form)),
              content: AppNoticeBanner(message: reason, tone: AppNoticeTone.warning, selectable: true),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.bank.cancel))],
            ),
          );
          return;
        }
        notice = page.notice;
      }
      if (!mounted) return;
      final values = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => _BankServiceDialog(
          controller: controller,
          data: data,
          form: form,
          bankName: bankName,
          notice: notice ?? '',
        ),
      );
      if (!mounted || values == null || !identical(controller, _cubit) || !controller.isCurrentService(data, form)) {
        return;
      }
      try {
        await controller.submitService(expected: data, form: form, values: values, notice: notice);
      } finally {
        values.clear();
      }
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Widget _services(BankState state, {required bool disabled}) {
    final bank = state.bank;
    final value = state.service?.name ?? ((bank?.hasAccount ?? false) ? 'current' : null);
    return Padding(
      padding: const EdgeInsets.only(bottom: appSurfaceGap),
      child: InputDecorator(
        // Nothing picked: the label rests in the field as its placeholder instead of floating above a duplicate hint.
        isEmpty: value == null,
        decoration: appPickerDecoration(context, label: context.t.bank.services, icon: Icons.apps_outlined),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('bank-service-picker'),
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(appInnerRadius),
            value: value,
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

  Widget _bankTile(ForumBank item, {required bool disabled}) {
    final tr = context.t.bank;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      padding: EdgeInsets.zero,
      child: ListTile(
        key: ValueKey('bank-${item.id}'),
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        leading: const AppIconTile(Icons.account_balance_outlined),
        title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.description.isNotEmpty) Text(item.description),
            sizedBoxW4H4,
            AppInfoPill(
              icon: item.hasAccount ? Icons.check_circle_outline : Icons.remove_circle_outline,
              label: item.hasAccount ? tr.opened : tr.notOpened,
            ),
          ],
        ),
        trailing: Icon(Icons.chevron_right, color: colorScheme.outline),
        onTap: disabled ? null : () => _cubit.selectBank(item),
      ),
    );
  }

  Widget _serviceContent(BankState state, {required bool disabled}) {
    final tr = context.t.bank;
    final data = state.serviceData;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BankHeader(
          icon: _serviceIcon(state.service!),
          title: [
            if (!state.service!.global && state.bank != null) state.bank!.name,
            _serviceTitle(context, state.service!),
          ].join(' · '),
          onBack: disabled ? null : _cubit.load,
          backLabel: tr.backToBanks,
        ),
        if (data != null) ...[
          if (data.unavailable.isNotEmpty) ...[
            sizedBoxW12H12,
            AppNoticeBanner(message: data.unavailable, tone: AppNoticeTone.warning, selectable: true),
          ],
          if (data.walletBalance.isNotEmpty) ...[
            sizedBoxW12H12,
            _BankValue(
              icon: Icons.account_balance_wallet_outlined,
              label: tr.availableBalance,
              value: '${data.walletBalance} ${data.currency}'.trim(),
            ),
          ],
          for (final form in data.forms) ...[
            sizedBoxW12H12,
            AppSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (form.context.isNotEmpty) ...[
                    AppInsetBlock(child: Text(form.context)),
                    sizedBoxW12H12,
                  ],
                  FilledButton(
                    onPressed: disabled ? null : () => _serviceTransaction(data, form),
                    child: identical(form, _reading)
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox.square(
                                key: ValueKey('bank-service-reading'),
                                dimension: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              sizedBoxW8H8,
                              Flexible(child: Text(_serviceActionTitle(context, form), textAlign: TextAlign.center)),
                            ],
                          )
                        : Text(_serviceActionTitle(context, form), textAlign: TextAlign.center),
                  ),
                ],
              ),
            ),
          ],
          if (data.blocks.isNotEmpty) ...[
            sizedBoxW12H12,
            AppSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (index, block) in data.blocks.indexed)
                    Padding(
                      padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
                      child: Text(
                        block.text,
                        style: block.heading ? textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold) : null,
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (data.webOnlyRecords) ...[
            sizedBoxW12H12,
            AppNoticeBanner(message: tr.loanWebOnly, icon: Icons.open_in_browser_outlined),
          ],
          if (data.unsupportedForms) ...[
            sizedBoxW12H12,
            AppNoticeBanner(message: tr.unsupported, tone: AppNoticeTone.warning),
          ],
          if (data.hasNext || state.servicePage > 1) ...[
            sizedBoxW8H8,
            _BankPager(
              page: state.servicePage,
              previousLabel: tr.previous,
              nextLabel: tr.next,
              onPrevious: disabled || state.servicePage <= 1
                  ? null
                  : () => _cubit.loadService(state.service!, page: state.servicePage - 1),
              onNext: disabled || !data.hasNext
                  ? null
                  : () => _cubit.loadService(state.service!, page: state.servicePage + 1),
            ),
          ],
        ],
        sizedBoxW8H8,
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: disabled
                ? null
                : () async => context.dispatchAsUrl(
                    bankServiceUrl(state.service!, bankId: state.bank?.id, page: state.servicePage),
                    external: true,
                  ),
            icon: const Icon(Icons.open_in_browser_outlined),
            label: Text(tr.openWebsite),
          ),
        ),
      ],
    );
  }

  Widget _savings(ForumBank bank, BankSavings savings, {required bool disabled}) {
    final tr = context.t.bank;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(tr.savings, icon: Icons.savings_outlined, padding: const EdgeInsets.only(bottom: 8)),
          if (savings.summary.isNotEmpty) AppInsetBlock(child: Text(savings.summary)),
          if (savings.walletBalance.isNotEmpty || savings.interest.isNotEmpty) ...[
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (savings.walletBalance.isNotEmpty)
                  _BankValue(
                    icon: Icons.account_balance_wallet_outlined,
                    label: tr.availableBalance,
                    value: '${savings.walletBalance} ${savings.currency}'.trim(),
                  ),
                if (savings.interest.isNotEmpty)
                  _BankValue(icon: Icons.trending_up_outlined, label: tr.interest, value: savings.interest),
              ],
            ),
          ],
          if (savings.notices.isNotEmpty) ...[
            sizedBoxW8H8,
            AppNoticeBanner(message: savings.notices, selectable: true),
          ],
          sizedBoxW12H12,
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
            AppNoticeBanner(message: tr.unsupported, tone: AppNoticeTone.warning),
          sizedBoxW4H4,
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: disabled
                  ? null
                  : () async => context.dispatchAsUrl(bankPageUrl(bankId: bank.id, action: 'cur'), external: true),
              icon: const Icon(Icons.open_in_browser_outlined),
              label: Text(tr.openWebsite),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logs(BankState state, {required bool disabled}) {
    final tr = context.t.bank;
    final logs = state.logs;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(tr.logs, icon: Icons.receipt_long_outlined, padding: const EdgeInsets.only(bottom: 8)),
          if (state.logsFailed) ...[
            AppNoticeBanner(message: tr.logsFailed, tone: AppNoticeTone.error),
            sizedBoxW8H8,
          ],
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
            sizedBoxW12H12,
            if (logs.entries.isEmpty)
              AppStateView(icon: Icons.receipt_long_outlined, message: tr.emptyLogs, scrollable: false),
            for (final (index, entry) in logs.entries.indexed)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 6),
                child: AppInsetBlock(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.message),
                      if (entry.time.isNotEmpty) ...[
                        sizedBoxW4H4,
                        Row(
                          children: [
                            Icon(Icons.schedule_outlined, size: 14, color: colorScheme.outline),
                            sizedBoxW4H4,
                            Flexible(
                              child: Text(
                                entry.time,
                                style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            sizedBoxW8H8,
            _BankPager(
              page: state.logPage,
              previousLabel: tr.previous,
              nextLabel: tr.next,
              onPrevious: disabled || state.logPage <= 1
                  ? null
                  : () => _cubit.loadLogs(received: state.received, page: state.logPage - 1),
              onNext: disabled || !logs.hasNext
                  ? null
                  : () => _cubit.loadLogs(received: state.received, page: state.logPage + 1),
            ),
          ],
        ],
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
              child: AppCenteredList(
                builder: (context, padding, width) {
                  final columns = appColumnsFor(width);
                  final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
                  final banks = state.banks;
                  return ListView(
                    padding: padding.copyWith(top: 12, bottom: 12),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      if (state.busy)
                        const Padding(
                          padding: EdgeInsets.only(bottom: appSurfaceGapCompact),
                          child: LinearProgressIndicator(),
                        ),
                      if (state.serviceChanged)
                        Padding(
                          padding: const EdgeInsets.only(bottom: appSurfaceGap),
                          child: AppNoticeBanner(message: tr.serviceChanged, tone: AppNoticeTone.warning),
                        ),
                      if (state.unconfirmed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: appSurfaceGap),
                          child: AppNoticeBanner(
                            message: tr.unconfirmed,
                            tone: AppNoticeTone.warning,
                            icon: Icons.help_outline,
                          ),
                        ),
                      if (state.reply.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: appSurfaceGap),
                          child: AppNoticeBanner(
                            key: const ValueKey('bank-reply'),
                            message: tr.forumReply(message: state.reply),
                            icon: Icons.forum_outlined,
                            selectable: true,
                          ),
                        ),
                      if (state.loginRequired)
                        AppStateView(
                          icon: Icons.login,
                          message: tr.loginRequired,
                          scrollable: false,
                          action: FilledButton.tonalIcon(
                            onPressed: disabled
                                ? null
                                : () async {
                                    await context.pushNamed(ScreenPaths.login);
                                    if (mounted) await _cubit.load();
                                  },
                            icon: const Icon(Icons.login),
                            label: Text(context.t.loginPage.login),
                          ),
                        )
                      else ...[
                        if (state.uid != null) _services(state, disabled: disabled),
                        if (state.failed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: appSurfaceGap),
                            child: AppNoticeBanner(message: tr.loadFailed, tone: AppNoticeTone.error),
                          ),
                        if (state.service != null)
                          _serviceContent(state, disabled: disabled)
                        else if (bank == null) ...[
                          AppSectionHeader(tr.chooseBank, icon: Icons.account_balance_outlined),
                          for (var row = 0; row < appRowCount(banks.length, columns); row++)
                            Padding(
                              padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                              child: AppColumnsRow(
                                row: row,
                                columns: columns,
                                count: banks.length,
                                gap: gap,
                                itemBuilder: (context, index) => _bankTile(banks[index], disabled: disabled),
                              ),
                            ),
                        ] else ...[
                          _BankHeader(
                            icon: Icons.account_balance_outlined,
                            title: bank.name,
                            onBack: disabled ? null : _cubit.load,
                            backLabel: tr.backToBanks,
                          ),
                          sizedBoxW12H12,
                          if (!bank.hasAccount)
                            AppNoticeBanner(message: tr.notOpened, icon: Icons.no_accounts_outlined)
                          else if (columns > 1)
                            // Savings and records side by side on wide windows.
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: savings == null ? sizedBoxEmpty : _savings(bank, savings, disabled: disabled),
                                ),
                                SizedBox(width: gap),
                                Expanded(child: _logs(state, disabled: disabled)),
                              ],
                            )
                          else ...[
                            if (savings != null) ...[
                              _savings(bank, savings, disabled: disabled),
                              SizedBox(height: gap),
                            ],
                            _logs(state, disabled: disabled),
                          ],
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: OutlinedButton.icon(
                                onPressed: disabled
                                    ? null
                                    : () async => context.dispatchAsUrl(bankPageUrl(bankId: bank.id), external: true),
                                icon: const Icon(Icons.open_in_browser_outlined),
                                label: Text(tr.otherServices),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ],
                  );
                },
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
        title: _BankDialogTitle(
          icon: _confirming
              ? Icons.fact_check_outlined
              : widget.operation == BankOperation.deposit
              ? Icons.savings_outlined
              : Icons.account_balance_wallet_outlined,
          title: _confirming ? tr.confirmTitle : operation,
        ),
        content: _confirming
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppInsetBlock(
                    outlined: true,
                    padding: edgeInsetsL12T12R12B12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.bankName,
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        sizedBoxW8H8,
                        Text(
                          '$operation: ${_amount.text.trim()} ${widget.savings.currency}'.trim(),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  sizedBoxW12H12,
                  AppNoticeBanner(message: tr.transactionNote, tone: AppNoticeTone.warning, icon: Icons.info_outline),
                ],
              )
            : Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_balance_outlined, size: 18, color: Theme.of(context).colorScheme.outline),
                        sizedBoxW8H8,
                        Expanded(child: Text(widget.bankName)),
                      ],
                    ),
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
                      decoration: InputDecoration(
                        labelText: tr.amount,
                        suffixText: widget.savings.currency,
                        prefixIcon: const Icon(Icons.payments_outlined),
                        filled: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                      ),
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
                      decoration: InputDecoration(
                        labelText: tr.bankPassword,
                        prefixIcon: const Icon(Icons.lock_outline),
                        filled: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                      ),
                      validator: (value) => value == null || value.isEmpty ? tr.passwordRequired : null,
                      onFieldSubmitted: (_) => _continue(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr.passwordHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
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
