import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/title_shop/cubit/title_shop_cubit.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Height of a title artwork for one unit of width: the forum's titles are 184x100.
const double titleShopImageRatio = 100 / 184;

/// Native secondary title shop. A bought title is added to My titles and never equipped automatically.
class TitleShopPage extends StatefulWidget {
  /// An injected [controller] is owned by its caller.
  const TitleShopPage({super.key, this.controller, this.imageBuilder});

  /// Optional controller for deterministic tests.
  final TitleShopCubit? controller;

  /// Optional image renderer; production reuses [CachedImage].
  final Widget Function(String? url)? imageBuilder;

  @override
  State<TitleShopPage> createState() => _TitleShopPageState();
}

class _TitleShopPageState extends State<TitleShopPage> {
  late final TitleShopCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = TitleShopCubit(
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => TitleShopRepository.network(getIt.get<NetClientProvider>()),
      );
      _authSubscription = listenAccountChanges(
        auth,
        onLoggingIn: _cubit.invalidate,
        onChanged: () {
          _cubit.invalidate();
          unawaited(_cubit.load());
        },
      );
    }
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  /// Title artwork, [width] wide at the 184x100 ratio of the forum titles, contained and never cropped.
  Widget _image(String? url, double width) {
    final height = width * titleShopImageRatio;
    return AppInsetBlock(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: width,
        height: height,
        child:
            widget.imageBuilder?.call(url) ??
            (url == null
                ? Icon(Icons.image_not_supported_outlined, color: Theme.of(context).colorScheme.outline)
                : CachedImage(url, width: width, height: height, fit: BoxFit.contain)),
      ),
    );
  }

  Future<void> _buy(TitleShopCatalog page, TitleShopItem item) async {
    if (_dialogOpen || !_cubit.canPurchase(page, item)) return;
    final controller = _cubit;
    final tr = context.t.titleShop;
    setState(() => _dialogOpen = true);
    try {
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              // Large text or a long name scrolls the title and content; Cancel and Buy stay pinned below.
              scrollable: true,
              title: Row(
                children: [
                  const AppIconTile(Icons.shopping_cart_outlined, size: 36),
                  sizedBoxW12H12,
                  Expanded(child: Text(tr.purchaseTitle)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Fixed size (no LayoutBuilder): the dialog lays out with intrinsic sizes.
                  Center(child: _image(item.imageUrl, 138)),
                  sizedBoxW12H12,
                  Text(
                    item.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  sizedBoxW4H4,
                  _PriceLine(
                    text: tr.idAndPrice(id: item.id, price: item.price),
                  ),
                  sizedBoxW12H12,
                  // Prefer the server's own sentence: it carries the exact price and currency.
                  AppInsetBlock(
                    outlined: true,
                    child: Text(item.form?.confirmText ?? tr.purchaseConfirm(price: item.price)),
                  ),
                  sizedBoxW12H12,
                  AppNoticeBanner(message: tr.notEquipped),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
                FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(tr.purchase)),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted || !identical(controller, _cubit) || !controller.canPurchase(page, item)) return;
      await controller.purchase(expected: page, item: item);
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Widget _result(TitlePurchaseResult result, TranslationsTitleShopEn tr) {
    final (text, tone, icon) = switch (result.outcome) {
      TitlePurchaseOutcome.purchased => (
        tr.purchased(name: result.name),
        AppNoticeTone.info,
        Icons.check_circle_outline,
      ),
      TitlePurchaseOutcome.rejected => (tr.rejected(name: result.name), AppNoticeTone.error, Icons.error_outline),
      TitlePurchaseOutcome.unconfirmed => (
        tr.unconfirmed(name: result.name),
        AppNoticeTone.warning,
        Icons.help_outline,
      ),
      TitlePurchaseOutcome.termsChanged => (
        tr.termsChanged(name: result.name),
        AppNoticeTone.warning,
        Icons.price_change_outlined,
      ),
      TitlePurchaseOutcome.unavailable => (
        tr.unavailableNow(name: result.name),
        AppNoticeTone.warning,
        Icons.remove_shopping_cart_outlined,
      ),
    };
    final message = result.message;
    return Padding(
      padding: const EdgeInsets.only(bottom: appSurfaceGap),
      child: AppNoticeBanner(
        key: const ValueKey('title-shop-result'),
        tone: tone,
        icon: icon,
        // The forum's own message, when any, stays selectable under the app's summary.
        title: message?.isNotEmpty ?? false ? text : null,
        message: message?.isNotEmpty ?? false ? message! : text,
        selectable: message?.isNotEmpty ?? false,
      ),
    );
  }

  Widget _status(TitleShopState state, TitleShopCatalog page, TitleShopItem item, TranslationsTitleShopEn tr) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (item.status) {
      TitleShopStatus.purchasable when state.purchasingId == item.id => const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      TitleShopStatus.purchasable => FilledButton.tonalIcon(
        onPressed: _dialogOpen || state.purchasingId != null ? null : () => _buy(page, item),
        icon: const Icon(Icons.shopping_cart_outlined),
        label: Text(tr.purchase),
      ),
      TitleShopStatus.owned => _StatusPill(
        icon: Icons.check,
        label: tr.owned,
        color: colorScheme.primaryContainer,
        foreground: colorScheme.onPrimaryContainer,
      ),
      TitleShopStatus.unavailable => _StatusPill(
        icon: Icons.block_outlined,
        label: item.statusText ?? tr.unavailable,
        color: colorScheme.surfaceContainerHighest,
        foreground: colorScheme.onSurfaceVariant,
      ),
    };
  }

  Widget _item(TitleShopState state, TitleShopCatalog page, TitleShopItem item, TranslationsTitleShopEn tr) {
    final textTheme = Theme.of(context).textTheme;
    final status = _status(state, page, item, tr);
    final details = <Widget>[
      Text(item.name, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      sizedBoxW4H4,
      _PriceLine(
        text: tr.idAndPrice(id: item.id, price: item.price),
      ),
    ];
    return AppSurface(
      key: ValueKey('title-${item.id}'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Artwork beside the text while both stay readable, above it on narrow screens or with large text.
          final scale = MediaQuery.textScalerOf(context).scale(1);
          if (constraints.maxWidth >= 400 * scale) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _image(item.imageUrl, 138),
                sizedBoxW12H12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [...details, sizedBoxW12H12, status],
                  ),
                ),
              ],
            );
          }
          final imageWidth = (constraints.maxWidth - 16).clamp(0.0, 184.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: _image(item.imageUrl, imageWidth)),
              sizedBoxW12H12,
              ...details,
              sizedBoxW12H12,
              Align(alignment: AlignmentDirectional.centerStart, child: status),
            ],
          );
        },
      ),
    );
  }

  Widget _header(TitleShopCatalog page) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: appSurfaceGap),
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (page.balance case final balance?)
              Row(
                children: [
                  const AppIconTile(Icons.account_balance_wallet_outlined, size: 36),
                  sizedBoxW12H12,
                  Expanded(
                    child: Text(balance, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            if (page.balance != null && page.intro.isNotEmpty) sizedBoxW12H12,
            for (final (index, line) in page.intro.indexed)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
                child: Text(line, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pager(TitleShopState state, TitleShopCatalog page, TranslationsTitleShopEn tr) => Padding(
    padding: const EdgeInsets.only(top: appSurfaceGap),
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton.icon(
          onPressed: page.previousUrl == null || state.purchasingId != null
              ? null
              : () => _cubit.load(page.previousUrl),
          icon: const Icon(Icons.chevron_left),
          label: Text(tr.previous),
        ),
        AppInsetBlock(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(tr.page(number: page.page)),
        ),
        TextButton(
          onPressed: page.nextUrl == null || state.purchasingId != null ? null : () => _cubit.load(page.nextUrl),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Text(tr.next), sizedBoxW4H4, const Icon(Icons.chevron_right, size: 18)],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => BlocBuilder<TitleShopCubit, TitleShopState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.titleShop;
      final page = state.page;
      final result = state.result;
      final Widget body;
      if (state.loading) {
        body = const CenteredCircularIndicator();
      } else if (state.loginRequired) {
        body = AppStateView(
          icon: Icons.login,
          message: tr.loginRequired,
          action: FilledButton.tonalIcon(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load();
            },
            icon: const Icon(Icons.login),
            label: Text(context.t.loginPage.login),
          ),
        );
      } else if (state.failed || page == null) {
        body = AppCenteredList(
          maxWidth: appFormMaxWidth,
          builder: (context, padding, _) => ListView(
            padding: padding.copyWith(top: 12, bottom: 12),
            children: [
              if (result != null) _result(result, tr),
              buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad),
            ],
          ),
        );
      } else {
        final items = page.items;
        body = RefreshIndicator(
          onRefresh: _cubit.load,
          child: AppCenteredList(
            builder: (context, padding, width) {
              final columns = appColumnsFor(width);
              final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
              return ListView(
                key: ValueKey(state.url),
                padding: padding.copyWith(top: 12, bottom: 12),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (result != null) _result(result, tr),
                  if (page.balance != null || page.intro.isNotEmpty) _header(page),
                  if (!page.supported)
                    AppStateView(
                      icon: Icons.storefront_outlined,
                      message: page.message?.isNotEmpty ?? false ? page.message! : tr.unsupported,
                      scrollable: false,
                      action: TextButton.icon(
                        onPressed: () async => context.dispatchAsUrl(state.url, external: true),
                        icon: const Icon(Icons.open_in_browser_outlined),
                        label: Text(tr.openBrowser),
                      ),
                    )
                  else if (items.isEmpty)
                    AppStateView(icon: Icons.storefront_outlined, message: tr.empty, scrollable: false),
                  for (var row = 0; row < appRowCount(items.length, columns); row++)
                    Padding(
                      padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                      child: AppColumnsRow(
                        row: row,
                        columns: columns,
                        count: items.length,
                        gap: gap,
                        itemBuilder: (context, index) => _item(state, page, items[index], tr),
                      ),
                    ),
                  if (page.supported) _pager(state, page, tr),
                ],
              );
            },
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          actions: [
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: state.loading || state.purchasingId != null ? null : _cubit.load,
            ),
            IconButton(
              tooltip: tr.openBrowser,
              icon: const Icon(Icons.open_in_browser_outlined),
              onPressed: () async => context.dispatchAsUrl(state.url, external: true),
            ),
          ],
        ),
        body: SafeArea(child: body),
      );
    },
  );
}

/// ID and price of a title, never shortened: the price is what the user pays.
class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.sell_outlined, size: 16, color: colorScheme.primary),
        ),
        sizedBoxW4H4,
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Owned or unavailable state of a title, in place of the buy button.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label, required this.color, required this.foreground});

  final IconData icon;
  final String label;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => AppInsetBlock(
    color: color,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: foreground),
        sizedBoxW8H8,
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground)),
        ),
      ],
    ),
  );
}
