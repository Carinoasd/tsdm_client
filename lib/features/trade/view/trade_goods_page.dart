import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/trade/models/trade_models.dart';
import 'package:tsdm_client/features/trade/repository/trade_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// Open the page of the goods [pid] of the trade thread [tid].
///
/// [goods] is the goods as the thread page listed it (its price tells whether it is sold for credit alone);
/// [creditUnit] the site's trade credit. Buying is offered only with [canBuy] (the thread page's card, not an offline
/// copy nor a notice's post); [onBought] runs after an order was placed, paid or not (the thread page reloads its
/// list).
Future<void> openTradeGoodsPage(
  BuildContext context, {
  required int tid,
  required int pid,
  TradeGoods? goods,
  SpecialCredit? creditUnit,
  bool canBuy = false,
  VoidCallback? onBought,
}) async {
  final repository = context.readOrNull<TradeRepository>();
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RootPage(
        ScreenPaths.tradeGoods,
        TradeGoodsPage(
          tid: tid,
          pid: pid,
          goods: goods,
          creditUnit: creditUnit,
          canBuy: canBuy,
          onBought: onBought,
          repository: repository,
        ),
      ),
    ),
  );
}

/// The page of a goods ([TradeGoodsDetail]) and buying it.
///
/// A goods sold for the trade credit alone is bought here: the order form's quantity, receiver's fields (only those
/// the forum shows) and message, then a confirmation with the credit it takes, the balance and the login password
/// the forum asks to pay; the order and its payment are each sent once. A goods sold for money is bought on the
/// website.
class TradeGoodsPage extends StatefulWidget {
  /// Constructor.
  const TradeGoodsPage({
    required this.tid,
    required this.pid,
    this.goods,
    this.creditUnit,
    this.canBuy = false,
    this.onBought,
    this.repository,
    this.currentUid,
    super.key,
  });

  /// The thread.
  final int tid;

  /// The goods' floor.
  final int pid;

  /// The goods as the thread page listed it.
  final TradeGoods? goods;

  /// The site's trade credit.
  final SpecialCredit? creditUnit;

  /// Offer buying.
  final bool canBuy;

  /// After an order was placed (paid or not) or may have been: the thread page reloads its list.
  final VoidCallback? onBought;

  /// The repository (tests); the app's client otherwise.
  final TradeRepository? repository;

  /// The account in use (tests); the app's authentication otherwise.
  final int? Function()? currentUid;

  @override
  State<TradeGoodsPage> createState() => _TradeGoodsPageState();
}

class _TradeGoodsPageState extends State<TradeGoodsPage> {
  late final TradeRepository _repository = widget.repository ?? TradeRepository.network(getIt.get<NetClientProvider>());

  bool _loading = true;
  bool _failed = false;
  TradeGoodsDetail? _detail;
  String? _message;

  /// Buying is under way (its dialogs included): the button waits.
  bool _busy = false;

  /// A request of buying is in flight.
  bool _sending = false;

  String get _url => tradeGoodsUrl(tid: widget.tid, pid: widget.pid);

  /// The account in use, when the app knows it.
  int? get _uid => (widget.currentUid ?? () => context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid)();

  String get _unit => switch (widget.creditUnit) {
    final SpecialCredit unit => '${unit.title}${unit.unit}',
    null => '',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await _repository.fetchGoods(tid: widget.tid, pid: widget.pid);
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _detail = page.page;
        _message = page.message;
      });
    } on Exception catch (e) {
      talker.warning('failed to load goods ${widget.tid}/${widget.pid}: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _openInBrowser(String url) async => context.dispatchAsUrl(url, external: true);

  Future<void> _showMessage(String message) =>
      showMessageSingleButtonDialog(context: context, title: context.t.specialThread.trade.buy, message: message);

  /// Run the request [request] of buying, the button spinning meanwhile.
  Future<T> _send<T>(Future<T> Function() request) async {
    setState(() => _sending = true);
    try {
      return await request();
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  /// The account in use is still the one [servedUid] was served to; tells the user otherwise.
  bool _sameAccount(int? servedUid) {
    final uid = _uid;
    if (uid != null && uid == servedUid) {
      return true;
    }
    showSnackBar(context: context, message: context.t.specialThread.accountChanged);
    return false;
  }

  Future<void> _buy(TradeGoodsDetail detail) async {
    final url = detail.buyUrl;
    if (_busy || url == null) {
      return;
    }
    final tr = context.t;
    setState(() => _busy = true);
    try {
      final TradePage<TradeBuyForm> page;
      try {
        page = await _send(() => _repository.fetchBuyForm(url));
      } on Exception catch (e) {
        talker.warning('failed to load the order form $url: $e');
        if (mounted) {
          showSnackBar(context: context, message: tr.general.failedToLoad);
        }
        return;
      }
      if (!mounted) {
        return;
      }
      final form = page.page;
      if (form == null) {
        if (page.message case final message?) {
          await _showMessage(message);
        } else {
          await _openInBrowser(url);
        }
        return;
      }
      if (!_sameAccount(form.servedUid)) {
        return;
      }
      if (!form.creditOnly) {
        await _openInBrowser(url);
        return;
      }
      final order = await showDialog<_Order>(
        context: context,
        builder: (_) => _OrderDialog(form: form, subject: detail.subject, stock: detail.stock, unit: _unit),
      );
      if (order == null || !mounted) {
        return;
      }
      final password = await _askPassword(form, detail.subject, order.number);
      if (password == null || !mounted || !_sameAccount(form.servedUid)) {
        return;
      }
      final placed = await _send(
        () => _repository.order(
          form,
          form.orderBody(number: order.number, message: order.message, values: order.values),
        ),
      );
      if (!mounted) {
        return;
      }
      switch (placed) {
        case TradeOrderCreated(:final orderId):
          await _pay(form, detail.subject, order.number, orderId, password);
          // The order holds the stock, paid or not: the thread page's list changed.
          widget.onBought?.call();
        case TradeRefused(:final message, :final verification):
          if (verification) {
            await _showMessage(tr.specialThread.trade.verification);
            await _openInBrowser(url);
          } else {
            await _showMessage(message.isEmpty ? tr.specialThread.refused : message);
          }
        case TradePaid() || TradeUnknown():
          // The order may have been placed: the account's orders tell.
          final open = await showQuestionDialog(
            context: context,
            title: tr.specialThread.trade.openOrder,
            message: tr.specialThread.trade.unknown,
          );
          if (open ?? false) {
            await _openInBrowser(tradeOrdersUrl);
          }
          widget.onBought?.call();
          await _load();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _askPassword(TradeBuyForm form, String subject, int number) => showDialog<String>(
    context: context,
    builder: (_) => _PayDialog(form: form, subject: subject, number: number, unit: _unit),
  );

  /// Pay the order [orderId] with [password]; asks again for the password after a refusal, until paid or left.
  Future<void> _pay(TradeBuyForm form, String subject, int number, String orderId, String password) async {
    final tr = context.t.specialThread.trade;
    var secret = password;
    while (mounted) {
      if (!_sameAccount(form.servedUid)) {
        return;
      }
      final paid = await _send(() => _repository.pay(orderId: orderId, formHash: form.formHash, password: secret));
      if (!mounted) {
        return;
      }
      switch (paid) {
        case TradePaid():
          showSnackBar(context: context, message: tr.bought);
          await _load();
          return;
        case TradeRefused(:final message):
          final again = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: AppDialogTitle(icon: Icons.error_outline, title: tr.notPaid, error: true),
              content: SelectableText(message.isEmpty ? context.t.specialThread.refused : message),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr.openOrder)),
                TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr.payAgain)),
              ],
            ),
          );
          if (!mounted) {
            return;
          }
          if (again == false) {
            await _openInBrowser(tradeOrderUrl(orderId));
          }
          if (again != true) {
            await _load();
            return;
          }
          final next = await _askPassword(form, subject, number);
          if (next == null || !mounted) {
            await _load();
            return;
          }
          secret = next;
        case TradeOrderCreated() || TradeUnknown():
          final open = await showQuestionDialog(context: context, title: tr.openOrder, message: tr.unknown);
          if (!mounted) {
            return;
          }
          if (open ?? false) {
            await _openInBrowser(tradeOrderUrl(orderId));
          }
          await _load();
          return;
      }
    }
  }

  Widget? _buyBar(TradeGoodsDetail detail) {
    final tr = context.t.specialThread.trade;
    if (!widget.canBuy || detail.removed) {
      return null;
    }
    final Widget button;
    if (detail.soldOut) {
      button = FilledButton.tonal(onPressed: null, child: Text(tr.soldOut));
    } else if (detail.buyUrl case final url?) {
      final money = (widget.goods?.price ?? 0) > 0;
      button = money
          ? FilledButton.tonalIcon(
              onPressed: () async => _openInBrowser(url),
              icon: const Icon(Icons.open_in_browser_outlined),
              label: Text(tr.buyInBrowser),
            )
          : FilledButton.icon(
              onPressed: _busy ? null : () async => _buy(detail),
              icon: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularIndicator())
                  : const Icon(Icons.shopping_cart_outlined),
              label: Text(tr.buy),
            );
    } else {
      return null;
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(width: double.infinity, child: button),
      ),
    );
  }

  Widget _content(TradeGoodsDetail detail) {
    final tr = context.t.specialThread.trade;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    if (detail.removed) {
      return Center(
        child: Text(tr.removed, style: textTheme.bodyLarge?.copyWith(color: colorScheme.outline)),
      );
    }
    final picture = detail.thumb ?? detail.image;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (picture != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(appInnerRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: CachedImage(picture, fit: BoxFit.contain),
            ),
          ),
          sizedBoxW12H12,
        ],
        SelectableText(detail.subject, style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        sizedBoxW8H8,
        for (final price in detail.prices)
          Text(price, style: textTheme.titleMedium?.copyWith(color: colorScheme.primary)),
        for (final price in detail.costPrices)
          Text(
            price,
            style: textTheme.bodySmall?.copyWith(color: colorScheme.outline, decoration: TextDecoration.lineThrough),
          ),
        sizedBoxW12H12,
        if (detail.sellerName.isNotEmpty)
          AppInsetBlock(
            color: colorScheme.surfaceContainerHigh,
            child: InkWell(
              onTap: detail.sellerUid <= 0
                  ? null
                  : () async => context.dispatchAsUrl('$baseUrl/home.php?mod=space&uid=${detail.sellerUid}'),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundImage: CachedImageProvider(
                      detail.sellerAvatar ?? noAvatarUrl,
                      fallbackImageUrl: noAvatarUrl,
                      usage: ImageUsageInfoUserAvatar(detail.sellerName),
                    ),
                  ),
                  sizedBoxW8H8,
                  Text(tr.seller, style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline)),
                  sizedBoxW8H8,
                  Expanded(child: Text(detail.sellerName, style: textTheme.titleSmall)),
                ],
              ),
            ),
          ),
        sizedBoxW8H8,
        for (final row in detail.rows) _Row(row.label, row.value),
        if (detail.descriptionHtml.isNotEmpty) ...[const Divider(height: 24), MunchedHtml(detail.descriptionHtml)],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_failed) {
      body = Center(
        child: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(context.t.general.loadFailedAndRetry),
        ),
      );
    } else if (detail == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(_message ?? context.t.general.failedToLoad, textAlign: TextAlign.center),
        ),
      );
    } else {
      body = RefreshIndicator(onRefresh: _load, child: _content(detail));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.subject ?? widget.goods?.subject ?? context.t.specialThread.trade.title),
        actions: [
          IconButton(
            tooltip: context.t.specialThread.openInBrowser,
            onPressed: () async => _openInBrowser(_url),
            icon: const Icon(Icons.open_in_browser_outlined),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: detail == null ? null : _buyBar(detail),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

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

/// What the order dialog filled in.
typedef _Order = ({int number, String message, Map<String, String> values});

/// The order form: the quantity, the receiver's fields the forum shows, the message, and what it costs.
class _OrderDialog extends StatefulWidget {
  const _OrderDialog({required this.form, required this.subject, required this.stock, required this.unit});

  final TradeBuyForm form;
  final String subject;
  final int? stock;
  final String unit;

  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  int _number = 1;
  late final _message = TextEditingController(text: widget.form.defaults['buyermsg'] ?? '');
  late final Map<String, TextEditingController> _fields = {
    for (final f in widget.form.fields) f.name: TextEditingController(text: f.value),
  };

  @override
  void dispose() {
    _message.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _max => widget.stock != null && widget.stock! > 0 ? widget.stock : null;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.trade;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius));
    final total = widget.form.total(_number);
    final balance = widget.form.balance;
    final short = balance != null && total > balance;
    return AlertDialog(
      scrollable: true,
      title: AppDialogTitle(icon: Icons.shopping_cart_outlined, title: widget.subject),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(tr.quantity, style: textTheme.bodyLarge)),
              IconButton(
                onPressed: _number > 1 ? () => setState(() => _number--) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_number', style: textTheme.titleMedium),
              IconButton(
                onPressed: _max == null || _number < _max! ? () => setState(() => _number++) : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          for (final field in widget.form.fields) ...[
            sizedBoxW8H8,
            TextField(
              controller: _fields[field.name],
              maxLength: field.maxLength,
              decoration: InputDecoration(labelText: field.label, filled: true, border: border, counterText: ''),
            ),
          ],
          sizedBoxW8H8,
          TextField(
            controller: _message,
            minLines: 2,
            maxLines: 5,
            // The forum takes at most 200 characters.
            maxLength: 200,
            decoration: InputDecoration(
              labelText: widget.form.messageLabel.isEmpty ? tr.message : widget.form.messageLabel,
              filled: true,
              border: border,
            ),
          ),
          _Row(tr.cost, tr.credit(credit: total, unit: widget.unit)),
          if (balance != null) _Row(tr.balance, tr.credit(credit: balance, unit: widget.unit)),
          if (short)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(tr.insufficient, style: textTheme.bodyMedium?.copyWith(color: colorScheme.error)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.general.cancel)),
        FilledButton(
          onPressed: short
              ? null
              : () => Navigator.pop<_Order>(context, (
                  number: _number,
                  message: _message.text.trim(),
                  values: {for (final e in _fields.entries) e.key: e.value.text.trim()},
                )),
          child: Text(tr.next),
        ),
      ],
    );
  }
}

/// The confirmation: what is bought, the credit it takes, the balance before and after, and the login password the
/// forum asks to pay. Pops with the password.
class _PayDialog extends StatefulWidget {
  const _PayDialog({required this.form, required this.subject, required this.number, required this.unit});

  final TradeBuyForm form;
  final String subject;
  final int number;
  final String unit;

  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
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
    if (_password.text.isEmpty) {
      return;
    }
    Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.trade;
    final total = widget.form.total(widget.number);
    final balance = widget.form.balance;
    return AlertDialog(
      scrollable: true,
      title: AppDialogTitle(icon: Icons.shopping_cart_checkout_outlined, title: tr.confirmTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${widget.subject} × ${widget.number}', style: Theme.of(context).textTheme.titleSmall),
          sizedBoxW8H8,
          _Row(tr.cost, tr.credit(credit: total, unit: widget.unit)),
          if (balance != null) ...[
            _Row(tr.balance, tr.credit(credit: balance, unit: widget.unit)),
            _Row(tr.after, tr.credit(credit: balance - total, unit: widget.unit)),
          ],
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
        FilledButton(onPressed: _password.text.isEmpty ? null : _submit, child: Text(tr.pay)),
      ],
    );
  }
}
