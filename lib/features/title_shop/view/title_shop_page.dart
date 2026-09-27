import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/title_shop/cubit/title_shop_cubit.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

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
      _authSubscription = auth.status.listen((status) {
        _cubit.invalidate();
        if (status is! AuthStatusLoading) unawaited(_cubit.load());
      });
    }
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Widget _image(String? url) => SizedBox(
    width: 96,
    height: 32,
    child:
        widget.imageBuilder?.call(url) ??
        (url == null
            ? const Icon(Icons.image_not_supported_outlined)
            : CachedImage(url, width: 96, height: 32, fit: BoxFit.contain)),
  );

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
              title: Text(tr.purchaseTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  // Prefer the server's own sentence: it carries the exact price and currency.
                  Text(item.form?.confirmText ?? tr.purchaseConfirm(price: item.price)),
                  const SizedBox(height: 8),
                  Text(tr.notEquipped, style: Theme.of(context).textTheme.bodySmall),
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
    final colors = Theme.of(context).colorScheme;
    final (text, color) = switch (result.outcome) {
      TitlePurchaseOutcome.purchased => (tr.purchased(name: result.name), colors.primaryContainer),
      TitlePurchaseOutcome.rejected => (tr.rejected(name: result.name), colors.errorContainer),
      TitlePurchaseOutcome.unconfirmed => (tr.unconfirmed(name: result.name), colors.tertiaryContainer),
      TitlePurchaseOutcome.termsChanged => (tr.termsChanged(name: result.name), colors.tertiaryContainer),
      TitlePurchaseOutcome.unavailable => (tr.unavailableNow(name: result.name), colors.surfaceContainerHighest),
    };
    return Card(
      key: const ValueKey('title-shop-result'),
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text),
            if (result.message?.isNotEmpty ?? false) ...[const SizedBox(height: 4), Text(result.message!)],
          ],
        ),
      ),
    );
  }

  Widget _item(TitleShopState state, TitleShopCatalog page, TitleShopItem item, TranslationsTitleShopEn tr) {
    final status = switch (item.status) {
      TitleShopStatus.purchasable when state.purchasingId == item.id => const SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      TitleShopStatus.purchasable => FilledButton.tonalIcon(
        onPressed: _dialogOpen || state.purchasingId != null ? null : () => _buy(page, item),
        icon: const Icon(Icons.shopping_cart_outlined),
        label: Text(tr.purchase),
      ),
      TitleShopStatus.owned => Chip(avatar: const Icon(Icons.check, size: 18), label: Text(tr.owned)),
      TitleShopStatus.unavailable => Text(item.statusText ?? tr.unavailable),
    };
    return Card(
      key: ValueKey('title-${item.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _image(item.imageUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(tr.idAndPrice(id: item.id, price: item.price)),
                  const SizedBox(height: 8),
                  status,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
        body = Center(
          child: TextButton(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load();
            },
            child: Text(tr.loginRequired),
          ),
        );
      } else if (state.failed || page == null) {
        body = ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (result != null) _result(result, tr),
            buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad),
          ],
        );
      } else {
        body = RefreshIndicator(
          onRefresh: _cubit.load,
          child: ListView(
            key: ValueKey(state.url),
            padding: const EdgeInsets.all(12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (result != null) _result(result, tr),
              for (final line in page.intro) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line)),
              if (page.balance case final balance?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(balance, style: Theme.of(context).textTheme.labelLarge),
                ),
              if (!page.supported)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(page.message?.isNotEmpty ?? false ? page.message! : tr.unsupported),
                )
              else if (page.items.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Text(tr.empty)),
              for (final item in page.items) _item(state, page, item, tr),
              if (page.supported)
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: page.previousUrl == null || state.purchasingId != null
                          ? null
                          : () => _cubit.load(page.previousUrl),
                      child: Text(tr.previous),
                    ),
                    Text(tr.page(number: page.page)),
                    TextButton(
                      onPressed: page.nextUrl == null || state.purchasingId != null
                          ? null
                          : () => _cubit.load(page.nextUrl),
                      child: Text(tr.next),
                    ),
                  ],
                ),
            ],
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
