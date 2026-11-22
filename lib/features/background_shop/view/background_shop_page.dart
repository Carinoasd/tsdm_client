import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';
import 'package:tsdm_client/features/background_shop/repository/background_shop_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

const _webUrl = '$baseUrl/plugin.php?id=background:memcp';

/// The actions of the app API the tabs read.
enum _Part { mine, store, slot, exchange }

/// What each write makes stale (the background plugin's pages it changes).
const Map<BackgroundShopWrite, Set<_Part>> _staleAfter = {
  BackgroundShopWrite.style: {_Part.mine},
  BackgroundShopWrite.buy: {_Part.mine, _Part.store, _Part.slot},
  BackgroundShopWrite.slot: {_Part.slot, _Part.mine},
  BackgroundShopWrite.exchange: {_Part.exchange, _Part.slot},
};

/// The member's background shop (the background plugin's 我的背景, 购买背景 and 活动商店, 背景仓库, 背景兑换), read from the
/// forum's app API (plugin 4.1.0, `status.bgshop`); every write is the background plugin's own form.
///
/// Each tab keeps what it last read and reads again only when pulled or after a write that changed it: the plugin
/// takes one request per action every few seconds.
class BackgroundShopPage extends StatefulWidget {
  /// Constructor.
  const BackgroundShopPage({this.repository, this.dataSaver, super.key});

  /// Injected for tests; the account's network client otherwise.
  final BackgroundShopRepository? repository;

  /// Injected for tests; the setting otherwise.
  final DataSaverMode? dataSaver;

  @override
  State<BackgroundShopPage> createState() => _BackgroundShopPageState();
}

class _BackgroundShopPageState extends State<BackgroundShopPage> with SingleTickerProviderStateMixin {
  late final _ShopScope _scope = _ShopScope(
    repository: widget.repository ?? BackgroundShopRepository.network(getIt.get<NetClientProvider>()),
    dataSaver:
        widget.dataSaver ??
        (getIt.isRegistered<SettingsRepository>()
            ? DataSaverMode.fromIndex(getIt.get<SettingsRepository>().currentSettings.dataSaverMode)
            : DataSaverMode.off),
    showSlots: () => _tabs.animateTo(_Part.slot.index),
  );
  late final TabController _tabs = TabController(length: _Part.values.length, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.backgroundShop;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            tooltip: context.t.general.openInBrowser,
            icon: const Icon(Icons.open_in_browser_outlined),
            onPressed: () async => context.dispatchAsUrl(_webUrl, external: true),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          tabs: [
            Tab(key: const ValueKey('bgshop-tab-mine'), text: tr.tabMine),
            Tab(key: const ValueKey('bgshop-tab-store'), text: tr.tabShop),
            Tab(key: const ValueKey('bgshop-tab-slot'), text: tr.tabSlot),
            Tab(key: const ValueKey('bgshop-tab-exchange'), text: tr.tabExchange),
          ],
        ),
      ),
      body: _ShopScopeProvider(
        scope: _scope,
        child: TabBarView(
          controller: _tabs,
          children: const [_MineTab(), _StoreTab(), _SlotTab(), _ExchangeTab()],
        ),
      ),
    );
  }
}

/// What the tabs share: the repository, one write at a time, and which tabs a write made stale.
final class _ShopScope extends ChangeNotifier {
  _ShopScope({required this.repository, required this.dataSaver, required this.showSlots});

  final BackgroundShopRepository repository;

  final DataSaverMode dataSaver;

  final VoidCallback showSlots;

  /// A write is on its way: every write control is off.
  final ValueNotifier<bool> writing = ValueNotifier(false);

  final Map<_Part, int> _stamps = {for (final p in _Part.values) p: 0};

  int stampOf(_Part part) => _stamps[part]!;

  void _stale(Set<_Part> parts) {
    for (final p in parts) {
      _stamps[p] = _stamps[p]! + 1;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    writing.dispose();
    super.dispose();
  }

  /// Send one write the user asked for, tell what it came to, and read again what it changed (whatever it came to:
  /// a refused form may be a stale form hash).
  ///
  /// When the answer tells nothing (`bgshop_unknown`, a timeout, a page that is not JSON) nothing is sent again:
  /// [verify] reads the forum again and compares with the page shown before the write (true: done, false: not done,
  /// null: still not known); when it can not tell, the member is asked to check, with a refresh at hand.
  Future<bool> send(
    BuildContext context,
    BackgroundShopWrite write,
    Future<BackgroundShopOutcome> Function() run, {
    required Future<bool?> Function() verify,
  }) async {
    if (writing.value) return false;
    writing.value = true;
    final tr = context.t.backgroundShop;
    final success = switch (write) {
      BackgroundShopWrite.style => tr.saved,
      BackgroundShopWrite.buy => tr.bought,
      BackgroundShopWrite.slot => tr.slotSet,
      BackgroundShopWrite.exchange => tr.exchangeDone,
    };
    String message;
    bool? done = false;
    try {
      var unknown = false;
      try {
        switch (await run()) {
          case BackgroundShopDone():
            done = true;
            message = success;
          case final BackgroundShopRefused refused:
            message = _refusalText(context, refused);
          case BackgroundShopUnknown():
            unknown = true;
            message = tr.unknown;
        }
      } on IdentityChangedException {
        rethrow;
      } on Exception {
        // A timeout or a failed request after sending: as unknown as an answer that is not a result.
        unknown = true;
        message = tr.unknown;
      }
      if (unknown) {
        try {
          done = await verify();
        } on Exception {
          done = null;
        }
        message = switch (done) {
          true => success,
          false => tr.notDone,
          null => tr.unknown,
        };
      }
    } on IdentityChangedException {
      done = false;
      message = tr.failed;
    } finally {
      writing.value = false;
    }
    if (context.mounted) {
      showSnackBar(
        context: context,
        message: message,
        clearPrevious: true,
        action: done == null ? SnackBarAction(label: tr.refresh, onPressed: () => _stale(_Part.values.toSet())) : null,
      );
    }
    // Not known whether it was done: the balance, what is owned and the storeroom are read again too, so the page
    // shows what is true.
    _stale({
      ..._staleAfter[write]!,
      if (done == null) ...{_Part.store, _Part.slot},
    });
    return done ?? false;
  }
}

String _refusalText(BuildContext context, BackgroundShopRefused refused) {
  final tr = context.t.backgroundShop;
  if (refused.login) return context.t.general.needLogin;
  // The plugin's words of these are codes (`err_not_enough_medals`) or about the forum, not the member.
  final own = switch (refused.key) {
    'bgshop_bg_illegal' => tr.bgIllegal,
    'bgshop_medals_insufficient' => tr.medalsInsufficient,
    'bgshop_already_exchanged' => tr.alreadyExchanged,
    'bgshop_already_owned' => tr.alreadyOwned,
    'bgshop_exchange_closed' => tr.exchangeClosed,
    'bgshop_unavailable' => tr.medalsMissing,
    'bgshop_credit_invalid' => tr.creditInvalid,
    'submit_invalid' => tr.formExpired,
    _ => null,
  };
  return own ?? (refused.message.isNotEmpty ? refused.message : tr.failed);
}

class _ShopScopeProvider extends InheritedWidget {
  const _ShopScopeProvider({required this.scope, required super.child});

  final _ShopScope scope;

  static _ShopScope of(BuildContext context) => context.getInheritedWidgetOfExactType<_ShopScopeProvider>()!.scope;

  @override
  bool updateShouldNotify(_ShopScopeProvider oldWidget) => !identical(scope, oldWidget.scope);
}

/// A tab reading one action: what it last read, loading, failed, the forum can not show it, the login asked for.
abstract class _TabState<W extends StatefulWidget, T> extends State<W> with AutomaticKeepAliveClientMixin<W> {
  _Part get part;

  late final _ShopScope scope = _ShopScopeProvider.of(context);

  T? page;
  bool failed = false;
  bool unavailable = false;
  bool loginRequired = false;
  int _generation = 0;
  int _stamp = 0;

  @override
  bool get wantKeepAlive => true;

  Future<BackgroundShopAnswer<T>> read();

  @override
  void initState() {
    super.initState();
    _stamp = scope.stampOf(part);
    scope.addListener(_onStale);
    unawaited(load());
  }

  @override
  void dispose() {
    scope.removeListener(_onStale);
    super.dispose();
  }

  void _onStale() {
    final stamp = scope.stampOf(part);
    if (stamp != _stamp) {
      _stamp = stamp;
      unawaited(load());
    }
  }

  Future<void> load() async {
    final generation = ++_generation;
    setState(() => failed = false);
    try {
      final answer = await read();
      if (!mounted || generation != _generation) return;
      setState(() {
        loginRequired = false;
        switch (answer) {
          case BackgroundShopLoaded(:final page):
            this.page = page;
            unavailable = false;
          case BackgroundShopUnavailable():
            page = null;
            unavailable = true;
        }
      });
    } on BackgroundShopLoginRequired {
      if (mounted && generation == _generation) setState(() => loginRequired = true);
    } on Exception {
      if (mounted && generation == _generation) setState(() => failed = true);
    }
  }

  /// The page, or what is shown without one.
  Widget buildPage(BuildContext context, T page);

  /// What is shown when the forum can not show the tab.
  String unavailableText(BuildContext context) => context.t.medalTitleTools.unsupported;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final page = this.page;
    if (loginRequired) {
      return ToolsStateView(onRetry: load, message: context.t.general.needLogin);
    }
    if (page == null) {
      return ToolsStateView(
        onRetry: load,
        failed: failed,
        message: unavailable ? unavailableText(context) : null,
        webUrl: unavailable ? _webUrl : null,
      );
    }
    return ValueListenableBuilder(valueListenable: scope.writing, builder: (context, _, _) => buildPage(context, page));
  }
}

/// A preview of a background: held back by the data saver until tapped.
class _Preview extends StatefulWidget {
  const _Preview(this.url, {required this.width, required this.height});

  final String? url;
  final double width;
  final double height;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool _asked = false;
  DataSaverMode? _listening;

  @override
  void dispose() {
    if (_listening != null) NetworkUsage.unmetered.removeListener(_onNetwork);
    super.dispose();
  }

  void _onNetwork() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mode = _ShopScopeProvider.of(context).dataSaver;
    if (mode == DataSaverMode.meteredOnly && _listening == null) {
      _listening = mode;
      NetworkUsage.unmetered.addListener(_onNetwork);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final url = widget.url;
    Widget child;
    if (url == null) {
      child = Icon(Icons.image_not_supported_outlined, color: colorScheme.outline);
    } else if (!_asked && (DataSaver.holdsBack(context, mode) ?? true)) {
      child = IconButton(
        tooltip: context.t.imageGallery.tapToLoad,
        icon: Icon(Icons.image_outlined, color: colorScheme.outline),
        onPressed: () => setState(() => _asked = true),
      );
    } else {
      child = CachedImage(url, width: widget.width, height: widget.height, fit: BoxFit.contain);
    }
    return AppInsetBlock(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Center(child: child),
      ),
    );
  }
}

String _until(BuildContext context, {required bool permanent, required int expiration}) =>
    permanent ? context.t.backgroundShop.forever : context.t.backgroundShop.until(date: toolsDate(expiration));

String _positionLabel(BuildContext context, BackgroundPosition position) =>
    position == BackgroundPosition.content ? context.t.backgroundShop.content : context.t.backgroundShop.sidebar;

// ---------------------------------------------------------------- my backgrounds

class _MineTab extends StatefulWidget {
  const _MineTab();

  @override
  State<_MineTab> createState() => _MineTabState();
}

class _MineTabState extends _TabState<_MineTab, BackgroundMine> {
  @override
  _Part get part => _Part.mine;

  @override
  Future<BackgroundShopAnswer<BackgroundMine>> read() => scope.repository.mine();

  @override
  Widget buildPage(BuildContext context, BackgroundMine page) {
    final inUse = [page.content, page.sidebar].nonNulls.toList();
    return ToolsBody(
      onRefresh: load,
      children: [
        if (inUse.isEmpty)
          AppStateView(message: context.t.backgroundShop.noBackground, scrollable: false)
        else
          for (final background in inUse) ...[
            _StyleCard(
              // A new answer starts the form again from what the forum stored.
              key: ObjectKey(background),
              background: background,
              choices: page.choices,
              enabled: !scope.writing.value,
              onSave: (values) => scope.send(
                context,
                BackgroundShopWrite.style,
                () => scope.repository.saveStyle(page.uid, background.form!, values),
                verify: () async => switch (await scope.repository.mine()) {
                  BackgroundShopLoaded(:final page) => backgroundStyleSaved(
                    background.position == BackgroundPosition.content ? page.content : page.sidebar,
                    values,
                  ),
                  BackgroundShopUnavailable() => null,
                },
              ),
            ),
            const SizedBox(height: appSurfaceGap),
          ],
      ],
    );
  }
}

class _StyleCard extends StatefulWidget {
  const _StyleCard({
    required this.background,
    required this.choices,
    required this.enabled,
    required this.onSave,
    super.key,
  });

  final BackgroundInUse background;
  final Map<String, List<BackgroundChoice>> choices;
  final bool enabled;
  final Future<bool> Function(Map<String, String> values) onSave;

  @override
  State<_StyleCard> createState() => _StyleCardState();
}

class _StyleCardState extends State<_StyleCard> {
  late final Map<String, String> _values = {...?widget.background.form?.values};

  Widget _segments(String field) {
    final choices = widget.choices[field] ?? const <BackgroundChoice>[];
    if (choices.length < 2) return const SizedBox.shrink();
    final selected = choices.any((c) => c.value == _values[field]) ? _values[field] : null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SegmentedButton<String>(
        key: ValueKey('bgshop-${widget.background.position.name}-$field'),
        segments: [for (final c in choices) ButtonSegment(value: c.value, label: Text(c.label))],
        selected: {?selected},
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        onSelectionChanged: widget.enabled && widget.background.form != null
            ? (v) => setState(() => _values[field] = v.firstOrNull ?? _values[field] ?? '')
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.background;
    final form = background.form;
    final textTheme = Theme.of(context).textTheme;
    final stretch = widget.choices[BackgroundStyleFields.stretch]?.firstOrNull;
    return AppSurface(
      key: ValueKey('bgshop-mine-${background.position.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _positionLabel(context, background.position),
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          sizedBoxW8H8,
          Center(child: _Preview(background.imageUrl, width: 240, height: 135)),
          sizedBoxW8H8,
          Text(
            _until(context, permanent: background.permanent, expiration: background.expiration),
            style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (form != null) ...[
            for (final field in BackgroundStyleFields.always) _segments(field),
            if (stretch != null)
              CheckboxListTile(
                key: ValueKey('bgshop-${background.position.name}-stretch'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(stretch.label),
                value: _values[BackgroundStyleFields.stretch] == stretch.value,
                onChanged: widget.enabled
                    ? (v) => setState(() => _values[BackgroundStyleFields.stretch] = v ?? false ? stretch.value : '')
                    : null,
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                key: ValueKey('bgshop-${background.position.name}-save'),
                onPressed: widget.enabled ? () => unawaited(widget.onSave(Map.of(_values))) : null,
                child: Text(context.t.backgroundShop.save),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- the shop and the event shop

class _StoreTab extends StatefulWidget {
  const _StoreTab();

  @override
  State<_StoreTab> createState() => _StoreTabState();
}

class _StoreTabState extends _TabState<_StoreTab, BackgroundStore> {
  final _search = TextEditingController();
  BackgroundStoreMode _mode = BackgroundStoreMode.shop;
  int _pageNo = 1;

  /// Whether the event shop is open, as the last answer of either list said.
  bool _specialOn = false;
  String _specialTitle = '';

  @override
  _Part get part => _Part.store;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Future<BackgroundShopAnswer<BackgroundStore>> read() async {
    final answer = await scope.repository.store(mode: _mode, keyword: _search.text.trim(), page: _pageNo);
    if (answer case BackgroundShopLoaded(:final page)) {
      _specialOn = page.specialOn;
      _specialTitle = page.specialTitle;
    } else if (_mode == BackgroundStoreMode.special) {
      // The event shop closed meanwhile: back to the shop.
      _specialOn = false;
      _mode = BackgroundStoreMode.shop;
      return read();
    }
    return answer;
  }

  void _go({BackgroundStoreMode? mode, int page = 1}) {
    _mode = mode ?? _mode;
    _pageNo = page;
    unawaited(load());
  }

  String _offerText(BuildContext context, BackgroundOffer offer) {
    final tr = context.t.backgroundShop;
    final credit = '${context.displayText(offer.creditTitle)}${offer.creditUnit}';
    return switch (offer.kind) {
      BackgroundPlanKind.month => tr.perMonth(price: offer.price, credit: credit),
      BackgroundPlanKind.year => tr.perYear(price: offer.price, credit: credit),
      BackgroundPlanKind.forever => tr.forGood(price: offer.price, credit: credit),
    };
  }

  Future<void> _buy(BackgroundStore page, BackgroundStoreItem item) async {
    final form = page.buy;
    if (form == null || !item.buyable || scope.writing.value) return;
    final choice = await showDialog<({BackgroundPosition position, BackgroundOffer offer, int months})>(
      context: context,
      builder: (context) => _ShopScopeProvider(
        scope: scope,
        child: _BuyDialog(page: page, item: item, offerText: (o) => _offerText(context, o)),
      ),
    );
    if (choice == null || !mounted) return;
    await scope.send(
      context,
      BackgroundShopWrite.buy,
      () => scope.repository.buy(page.uid, form, item, choice.position, choice.offer, choice.months),
      // The same page again: the balance and what is owned, against what was shown.
      verify: () async =>
          switch (await scope.repository.store(mode: page.mode, keyword: page.keyword, page: page.paging.page)) {
            BackgroundShopLoaded(page: final after) => backgroundPurchaseDone(
              before: item,
              balanceBefore: page.balanceOf(choice.offer.creditId),
              after: after,
              offer: choice.offer,
            ),
            BackgroundShopUnavailable() => null,
          },
    );
  }

  Widget _card(BuildContext context, BackgroundStore page, BackgroundStoreItem item) {
    final tr = context.t.backgroundShop;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final status = item.nonsale
        ? tr.nonsale
        : item.ownedForever
        ? tr.ownedForever
        : item.ownedUntil != null
        ? tr.ownedUntil(date: toolsDate(item.ownedUntil!))
        : null;
    return AppSurface(
      key: ValueKey('bgshop-store-${item.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Preview(item.imageUrl, width: 128, height: 72),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.displayText(item.name),
                      style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text('#${item.id}', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                    sizedBoxW4H4,
                    for (final offer in item.offers) Text(_offerText(context, offer), style: textTheme.bodyMedium),
                    if (status != null) Text(status, style: textTheme.bodySmall?.copyWith(color: colorScheme.primary)),
                  ],
                ),
              ),
            ],
          ),
          if (item.buyable)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                key: ValueKey('bgshop-buy-${item.id}'),
                onPressed: !scope.writing.value && page.buy != null ? () => unawaited(_buy(page, item)) : null,
                child: Text(tr.buy),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context, BackgroundStore page) {
    final tr = context.t.backgroundShop;
    return ToolsBody(
      onRefresh: load,
      children: [
        if (_specialOn) ...[
          SegmentedButton<BackgroundStoreMode>(
            key: const ValueKey('bgshop-store-mode'),
            segments: [
              ButtonSegment(value: BackgroundStoreMode.shop, label: Text(tr.tabShop)),
              ButtonSegment(
                value: BackgroundStoreMode.special,
                label: Text(_specialTitle.isEmpty ? tr.tabShop : context.displayText(_specialTitle)),
              ),
            ],
            selected: {page.mode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => _go(mode: v.first),
          ),
          sizedBoxW8H8,
        ],
        TextField(
          key: const ValueKey('bgshop-search'),
          controller: _search,
          textInputAction: TextInputAction.search,
          maxLength: 50,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          decoration: InputDecoration(
            hintText: tr.search,
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            isDense: true,
            counterText: '',
          ),
          onSubmitted: (_) => _go(),
        ),
        if (page.credits.isNotEmpty) ...[
          sizedBoxW8H8,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in page.credits)
                AppInfoPill(
                  icon: Icons.account_balance_wallet_outlined,
                  label: '${context.displayText(c.title)} ${c.balance}${c.unit}',
                ),
            ],
          ),
        ],
        sizedBoxW12H12,
        if (page.items.isEmpty)
          AppStateView(message: tr.empty, scrollable: false)
        else
          for (final item in page.items) ...[_card(context, page, item), const SizedBox(height: appSurfaceGap)],
        ToolsPager(
          paging: page.paging,
          enabled: !scope.writing.value,
          onPage: (n) => _go(page: n),
        ),
      ],
    );
  }
}

/// The purchase, which is its own confirmation: where, how to pay, how long, what it costs and what is left.
class _BuyDialog extends StatefulWidget {
  const _BuyDialog({required this.page, required this.item, required this.offerText});

  final BackgroundStore page;
  final BackgroundStoreItem item;
  final String Function(BackgroundOffer offer) offerText;

  @override
  State<_BuyDialog> createState() => _BuyDialogState();
}

class _BuyDialogState extends State<_BuyDialog> {
  BackgroundPosition _position = BackgroundPosition.content;
  late BackgroundOffer _offer = widget.item.offers.first;
  final _months = TextEditingController(text: '1');

  @override
  void dispose() {
    _months.dispose();
    super.dispose();
  }

  int? get _monthCount {
    if (_offer.kind != BackgroundPlanKind.month) return 1;
    final n = int.tryParse(_months.text.trim());
    return n == null || n < 1 || n > _offer.maxMonths ? null : n;
  }

  Widget _row(String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(width: 72, child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
        Expanded(child: value),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.backgroundShop;
    final colorScheme = Theme.of(context).colorScheme;
    final months = _monthCount;
    final cost = months == null ? null : _offer.cost(months);
    final balance = widget.page.balanceOf(_offer.creditId);
    final left = cost == null || balance == null ? null : balance - cost;
    final credit = '${context.displayText(_offer.creditTitle)}${_offer.creditUnit}';
    final ok = cost != null && cost <= BackgroundOffer.maxCost && (left == null || left >= 0);
    return AlertDialog(
      scrollable: true,
      title: Text(context.displayText(widget.item.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: _Preview(widget.item.imageUrl, width: 240, height: 135)),
          sizedBoxW12H12,
          _row(
            tr.position,
            SegmentedButton<BackgroundPosition>(
              key: const ValueKey('bgshop-buy-position'),
              segments: [
                for (final p in BackgroundPosition.values)
                  ButtonSegment(value: p, label: Text(_positionLabel(context, p))),
              ],
              selected: {_position},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _position = v.first),
            ),
          ),
          if (widget.item.offers.length > 1)
            _row(
              tr.plan,
              DropdownButton<BackgroundOffer>(
                key: const ValueKey('bgshop-buy-plan'),
                isExpanded: true,
                value: _offer,
                items: [
                  for (final o in widget.item.offers) DropdownMenuItem(value: o, child: Text(widget.offerText(o))),
                ],
                onChanged: (o) => setState(() => _offer = o ?? _offer),
              ),
            )
          else
            _row(tr.plan, Text(widget.offerText(_offer))),
          if (_offer.kind == BackgroundPlanKind.month)
            _row(
              tr.months,
              TextField(
                key: const ValueKey('bgshop-buy-months'),
                controller: _months,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
                decoration: const InputDecoration(isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
          _row(
            tr.cost,
            Text(
              key: const ValueKey('bgshop-buy-cost'),
              cost == null ? '—' : '$cost $credit',
            ),
          ),
          if (left != null)
            _row(
              tr.balanceAfter,
              Text(
                key: const ValueKey('bgshop-buy-left'),
                '$left $credit',
                style: left < 0 ? TextStyle(color: colorScheme.error) : null,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(
          key: const ValueKey('bgshop-buy-confirm'),
          onPressed: ok ? () => Navigator.of(context).pop((position: _position, offer: _offer, months: months)) : null,
          child: Text(tr.buy),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- the storeroom

class _SlotTab extends StatefulWidget {
  const _SlotTab();

  @override
  State<_SlotTab> createState() => _SlotTabState();
}

class _SlotTabState extends _TabState<_SlotTab, BackgroundSlots> {
  int _pageNo = 1;

  @override
  _Part get part => _Part.slot;

  @override
  Future<BackgroundShopAnswer<BackgroundSlots>> read() => scope.repository.slots(page: _pageNo);

  Widget _card(BuildContext context, BackgroundSlots page, BackgroundSlot slot) {
    final tr = context.t.backgroundShop;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final form = page.set;
    return AppSurface(
      key: ValueKey('bgshop-slot-${slot.sid}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Preview(slot.imageUrl, width: 128, height: 72),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slot.name.isEmpty ? tr.staffImage : context.displayText(slot.name),
                      style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _until(context, permanent: slot.permanent, expiration: slot.expiration),
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          sizedBoxW8H8,
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final position in BackgroundPosition.values)
                if (slot.inUse(position))
                  Chip(
                    key: ValueKey('bgshop-slot-${slot.sid}-${position.name}-inuse'),
                    avatar: const Icon(Icons.check, size: 18),
                    label: Text('${_positionLabel(context, position)} · ${tr.inUse}'),
                  )
                else
                  FilledButton.tonal(
                    key: ValueKey('bgshop-slot-${slot.sid}-${position.name}'),
                    onPressed: form != null && !scope.writing.value
                        ? () => unawaited(
                            scope.send(
                              context,
                              BackgroundShopWrite.slot,
                              () => scope.repository.useSlot(page.uid, form, slot, position, page.paging.page),
                              verify: () async => switch (await scope.repository.slots(page: page.paging.page)) {
                                BackgroundShopLoaded(page: final after) => backgroundSlotInUse(
                                  after,
                                  slot.sid,
                                  position,
                                ),
                                BackgroundShopUnavailable() => null,
                              },
                            ),
                          )
                        : null,
                    child: Text(position == BackgroundPosition.content ? tr.useAsContent : tr.useAsSidebar),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context, BackgroundSlots page) => ToolsBody(
    onRefresh: load,
    children: [
      if (page.slots.isEmpty)
        AppStateView(message: context.t.backgroundShop.slotEmpty, scrollable: false)
      else
        for (final slot in page.slots) ...[_card(context, page, slot), const SizedBox(height: appSurfaceGap)],
      ToolsPager(
        paging: page.paging,
        enabled: !scope.writing.value,
        onPage: (n) {
          _pageNo = n;
          unawaited(load());
        },
      ),
    ],
  );
}

// ---------------------------------------------------------------- the exchange by medals

class _ExchangeTab extends StatefulWidget {
  const _ExchangeTab();

  @override
  State<_ExchangeTab> createState() => _ExchangeTabState();
}

class _ExchangeTabState extends _TabState<_ExchangeTab, BackgroundExchange> {
  @override
  _Part get part => _Part.exchange;

  @override
  Future<BackgroundShopAnswer<BackgroundExchange>> read() => scope.repository.exchange();

  @override
  String unavailableText(BuildContext context) => context.t.backgroundShop.exchangeClosed;

  String _days(BuildContext context, int days) =>
      days > 0 ? context.t.backgroundShop.days(days: days) : context.t.backgroundShop.forever;

  Future<void> _exchange(BackgroundExchange page, BackgroundCampaign campaign, BackgroundCampaignChoice choice) async {
    final form = page.form;
    if (form == null || scope.writing.value) return;
    final tr = context.t.backgroundShop;
    final ok = await showToolsConfirm(
      context,
      title: context.displayText(choice.name),
      confirm: tr.exchange,
      content: [
        Center(
          child: _ShopScopeProvider(scope: scope, child: _Preview(choice.imageUrl, width: 240, height: 135)),
        ),
        sizedBoxW12H12,
        Text(_days(context, campaign.days)),
        sizedBoxW12H12,
        AppNoticeBanner(tone: AppNoticeTone.warning, message: tr.exchangeOnce),
      ],
    );
    if (!ok || !mounted) return;
    final done = await scope.send(
      context,
      BackgroundShopWrite.exchange,
      () => scope.repository.exchangeFor(page.uid, form, campaign, choice.id),
      verify: () async => switch (await scope.repository.exchange()) {
        BackgroundShopLoaded(page: final after) => backgroundExchanged(after, campaign.id),
        BackgroundShopUnavailable() => null,
      },
    );
    if (done) scope.showSlots();
  }

  Widget _card(BuildContext context, BackgroundExchange page, BackgroundCampaign campaign) {
    final tr = context.t.backgroundShop;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      key: ValueKey('bgshop-campaign-${campaign.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(campaign.id, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (campaign.exchanged)
                Text(tr.exchanged, style: textTheme.labelLarge?.copyWith(color: colorScheme.primary)),
            ],
          ),
          Text(
            '${tr.medals(owned: campaign.ownedMedals, need: campaign.minMedals)} · ${_days(context, campaign.days)}',
            style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          if (campaign.medals.isNotEmpty) ...[
            sizedBoxW8H8,
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in campaign.medals)
                  Tooltip(
                    message: context.displayText(m.name),
                    child: Opacity(
                      opacity: m.owned ? 1 : 0.35,
                      child: ToolsImage(m.imageUrl, width: 22, height: 36),
                    ),
                  ),
              ],
            ),
          ],
          for (final choice in campaign.backgrounds) ...[
            sizedBoxW8H8,
            Row(
              children: [
                _Preview(choice.imageUrl, width: 96, height: 54),
                sizedBoxW12H12,
                Expanded(child: Text(context.displayText(choice.name))),
                if (choice.owned)
                  Text(tr.alreadyOwned, style: textTheme.bodySmall?.copyWith(color: colorScheme.primary))
                else if (!campaign.exchanged)
                  FilledButton.tonal(
                    key: ValueKey('bgshop-exchange-${campaign.id}-${choice.id}'),
                    onPressed: campaign.eligible && page.form != null && !scope.writing.value
                        ? () => unawaited(_exchange(page, campaign, choice))
                        : null,
                    child: Text(tr.exchange),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context, BackgroundExchange page) {
    // An event without a background to choose offers nothing to do (the website's page of it is empty too).
    final campaigns = page.campaigns.where((c) => c.backgrounds.isNotEmpty).toList();
    return ToolsBody(
      onRefresh: load,
      children: [
        if (campaigns.isEmpty)
          AppStateView(message: context.t.backgroundShop.exchangeEmpty, scrollable: false)
        else
          for (final c in campaigns) ...[_card(context, page, c), const SizedBox(height: appSurfaceGap)],
      ],
    );
  }
}

/// For tests: the parts a write makes stale.
@visibleForTesting
Set<String> backgroundShopStaleAfter(BackgroundShopWrite write) => {for (final p in _staleAfter[write]!) p.name};
