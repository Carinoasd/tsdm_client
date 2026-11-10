import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/magic/cubit/magic_center_cubit.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';
import 'package:tsdm_client/features/magic/view/magic_dialogs.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The forum's magic shop and the account's magic items: buy and use through the forum's own windows.
class MagicCenterPage extends StatefulWidget {
  /// An injected [controller] is owned by its caller.
  const MagicCenterPage({super.key, this.controller, this.imageBuilder});

  /// Optional controller for deterministic tests.
  final MagicCenterCubit? controller;

  /// Optional image renderer; production reuses [CachedImage].
  final Widget Function(String? url)? imageBuilder;

  @override
  State<MagicCenterPage> createState() => _MagicCenterPageState();
}

class _MagicCenterPageState extends State<MagicCenterPage> {
  late final MagicCenterCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;
  bool _dialogOpen = false;
  final Map<MagicList, ScrollController> _scroll = {for (final list in MagicList.values) list: ScrollController()};

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = MagicCenterCubit(
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => MagicRepository.network(getIt.get<NetClientProvider>()),
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
    for (final c in _scroll.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _image(String? url, double size) => SizedBox.square(
    dimension: size,
    child:
        widget.imageBuilder?.call(url) ??
        (url == null
            ? Icon(Icons.auto_fix_high_outlined, color: Theme.of(context).colorScheme.outline)
            : CachedImage(url, width: size, height: size, fit: BoxFit.contain)),
  );

  Future<void> _open(MagicItem item, {required bool buy}) async {
    if (_dialogOpen || !_cubit.ready) return;
    final tr = context.t.magicCenter;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _dialogOpen = true);
    try {
      MagicForm? form;
      try {
        form = await _cubit.openWindow(item, buy: buy);
      } on MagicFormUnsupported {
        if (!mounted) return;
        await showMagicUnsupportedDialog(context, item: item, image: _image(item.imageUrl, 48));
        return;
      } on MagicForumMessage catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message.isEmpty ? tr.windowFailed : e.message)));
        return;
      } on Object {
        messenger.showSnackBar(SnackBar(content: Text(tr.windowFailed)));
        return;
      }
      if (form == null || !mounted) return;
      final values = await showMagicFormDialog(context, form: form, item: item, image: _image(item.imageUrl, 48));
      if (values == null || !mounted) return;
      await _cubit.submit(form, values, name: item.name);
      // The result banner heads the list: bring it into view.
      final scroll = _scroll[buy ? MagicList.shop : MagicList.box]!;
      if (mounted && scroll.hasClients) {
        await scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Widget _result(MagicOperationResult result, TranslationsMagicCenterEn tr) {
    final (String text, AppNoticeTone tone, IconData icon) = switch (result.kind) {
      MagicResultKind.succeeded => (
        result.buy ? tr.bought(name: result.name) : tr.used(name: result.name),
        AppNoticeTone.info,
        Icons.check_circle_outline,
      ),
      MagicResultKind.rejected => (tr.rejected(name: result.name), AppNoticeTone.error, Icons.block_outlined),
      MagicResultKind.login => (context.t.general.needLogin, AppNoticeTone.error, Icons.login),
      MagicResultKind.unknown => (tr.unknown(name: result.name), AppNoticeTone.warning, Icons.help_outline),
    };
    final message = result.message;
    return Padding(
      padding: const EdgeInsets.only(bottom: appSurfaceGap),
      child: AppNoticeBanner(
        key: const ValueKey('magic-result'),
        tone: tone,
        icon: icon,
        title: message.isNotEmpty ? text : null,
        message: message.isNotEmpty ? context.displayText(message) : text,
        selectable: message.isNotEmpty,
      ),
    );
  }

  Widget _item(MagicCenterState state, MagicItem item, MagicList list, TranslationsMagicCenterEn tr) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final busy = state.busy || _dialogOpen;
    final Widget action;
    final String figure;
    if (list == MagicList.shop) {
      figure = context.displayText(item.priceText);
      action = item.buyable
          ? FilledButton.tonalIcon(
              key: ValueKey('magic-buy-${item.identifier}'),
              onPressed: busy ? null : () => _open(item, buy: true),
              icon: const Icon(Icons.shopping_cart_outlined),
              label: Text(tr.buy),
            )
          : Text(tr.soldOut, style: textTheme.labelLarge?.copyWith(color: colorScheme.outline));
    } else {
      figure = item.count == null ? '' : tr.owned(count: item.count!);
      action = FilledButton.tonalIcon(
        key: ValueKey('magic-use-${item.magicId}'),
        onPressed: busy ? null : () => _open(item, buy: false),
        icon: const Icon(Icons.auto_fix_high_outlined),
        label: Text(tr.use),
      );
    }
    return AppSurface(
      key: ValueKey('magic-${list.name}-${item.identifier}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInsetBlock(padding: const EdgeInsets.all(8), child: _image(item.imageUrl, 48)),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.displayText(item.name),
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (item.description.isNotEmpty) ...[
                  sizedBoxW4H4,
                  Text(
                    context.displayText(item.description),
                    style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
                sizedBoxW8H8,
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    if (figure.isNotEmpty)
                      Text(
                        figure,
                        style: textTheme.titleSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                      ),
                    action,
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(MagicListPage page) {
    final textTheme = Theme.of(context).textTheme;
    Widget line(IconData icon, String text) => Row(
      children: [
        AppIconTile(icon, size: 32),
        sizedBoxW12H12,
        Expanded(child: Text(text, style: textTheme.titleSmall)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: appSurfaceGap),
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (page.balance.isNotEmpty) line(Icons.account_balance_wallet_outlined, context.displayText(page.balance)),
            if (page.balance.isNotEmpty && page.capacity.isNotEmpty) sizedBoxW8H8,
            if (page.capacity.isNotEmpty) line(Icons.backpack_outlined, context.displayText(page.capacity)),
          ],
        ),
      ),
    );
  }

  Widget _pager(MagicCenterState state, MagicListPage page, TranslationsMagicCenterEn tr) {
    if (page.previousUrl == null && page.nextUrl == null) return const SizedBox.shrink();
    void go(String? url) => page.list == MagicList.shop ? _cubit.load(shopUrl: url) : _cubit.load(boxUrl: url);
    return Padding(
      padding: const EdgeInsets.only(top: appSurfaceGap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: tr.previous,
            onPressed: page.previousUrl == null || state.busy ? null : () => go(page.previousUrl),
            icon: const Icon(Icons.chevron_left),
          ),
          Text('${page.page}'),
          IconButton(
            tooltip: tr.next,
            onPressed: page.nextUrl == null || state.busy ? null : () => go(page.nextUrl),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _list(MagicCenterState state, MagicListPage page, TranslationsMagicCenterEn tr) {
    final items = page.items;
    return RefreshIndicator(
      onRefresh: _cubit.load,
      child: AppCenteredList(
        builder: (context, padding, width) {
          final columns = appColumnsFor(width);
          final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
          return ListView(
            key: PageStorageKey('magic-${page.list.name}'),
            controller: _scroll[page.list],
            padding: padding.copyWith(top: 12, bottom: 12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (state.result case final result?) _result(result, tr),
              // A refresh that failed keeps the lists it had, under the failure.
              if (state.failed)
                Padding(
                  padding: const EdgeInsets.only(bottom: appSurfaceGap),
                  child: AppNoticeBanner(
                    key: const ValueKey('magic-load-failed'),
                    tone: AppNoticeTone.error,
                    message: context.t.general.failedToLoad,
                    actions: [
                      TextButton(onPressed: () => unawaited(_cubit.load()), child: Text(context.t.general.retry)),
                    ],
                  ),
                ),
              if (page.balance.isNotEmpty || page.capacity.isNotEmpty) _header(page),
              if (items.isEmpty) AppStateView(icon: Icons.auto_fix_high_outlined, message: tr.empty, scrollable: false),
              for (var row = 0; row < appRowCount(items.length, columns); row++)
                Padding(
                  padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                  child: AppColumnsRow(
                    row: row,
                    columns: columns,
                    count: items.length,
                    gap: gap,
                    itemBuilder: (context, index) => _item(state, items[index], page.list, tr),
                  ),
                ),
              _pager(state, page, tr),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<MagicCenterCubit, MagicCenterState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.magicCenter;
      final shop = state.shop;
      final box = state.box;
      Widget body(MagicListPage? page) {
        if (state.loginRequired) {
          return AppStateView(
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
        }
        if (state.message case final message?) {
          return AppStateView(
            icon: Icons.storefront_outlined,
            message: message.isEmpty ? context.t.general.failedToLoad : message,
            action: TextButton.icon(
              onPressed: () async => context.dispatchAsUrl(magicShopUrl, external: true),
              icon: const Icon(Icons.open_in_browser_outlined),
              label: Text(tr.openBrowser),
            ),
          );
        }
        if (page == null && state.loading) return const CenteredCircularIndicator();
        if (page == null) {
          return AppCenteredList(
            maxWidth: appFormMaxWidth,
            builder: (context, padding, _) => ListView(
              padding: padding.copyWith(top: 12, bottom: 12),
              children: [
                if (state.result case final result?) _result(result, tr),
                buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad),
              ],
            ),
          );
        }
        return _list(state, page, tr);
      }

      return DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr.title),
            actions: [
              IconButton(
                tooltip: tr.refresh,
                icon: const Icon(Icons.refresh),
                onPressed: state.loading || state.busy ? null : _cubit.load,
              ),
              IconButton(
                tooltip: tr.openBrowser,
                icon: const Icon(Icons.open_in_browser_outlined),
                onPressed: () async => context.dispatchAsUrl(magicShopUrl, external: true),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(kTextTabBarHeight + 4),
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(key: const ValueKey('magic-tab-shop'), text: tr.shop),
                      Tab(key: const ValueKey('magic-tab-mine'), text: tr.mine),
                    ],
                  ),
                  SizedBox(
                    height: 4,
                    child: state.loading || state.busy ? const LinearProgressIndicator() : null,
                  ),
                ],
              ),
            ),
          ),
          body: SafeArea(
            child: TabBarView(children: [body(shop), body(box)]),
          ),
        ),
      );
    },
  );
}
