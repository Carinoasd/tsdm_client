import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/view/inventory_tab.dart';
import 'package:tsdm_client/features/pokemon/view/my_pokemon_tab.dart';
import 'package:tsdm_client/features/pokemon/view/pokemon_center_tab.dart';
import 'package:tsdm_client/features/pokemon/view/shop_tab.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_count_label.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The pokemon center (宠物中心) page: my pokemon, healing, inventory and shop.
class PokemonPage extends StatefulWidget {
  /// Constructor.
  ///
  /// [initialTab] selects the tab shown first (0 my pokemon, 1 the pokemon center, 2 inventory, 3 shop); the battle
  /// result sends a player whose pet needs healing straight to the center with it.
  const PokemonPage({this.initialTab = 0, super.key});

  /// Index of the tab shown first.
  final int initialTab;

  @override
  State<PokemonPage> createState() => _PokemonPageState();
}

class _PokemonPageState extends State<PokemonPage> with WidgetsBindingObserver, RouteAware {
  late final PokemonCubit _cubit;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cubit = PokemonCubit();
    unawaited(_cubit.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cubit.close());
    super.dispose();
  }

  /// A page opened above this one (the battle page, a pet's detail, the storage) was popped.
  ///
  /// The party can have changed while it was on top — the battle page heals it on its way out — so read it again
  /// instead of leaving the previous list on screen.
  @override
  void didPopNext() => unawaited(_cubit.refreshPokemons());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A status bar switch taken right before the app went away is often parked by the platform client; finish it here
    // instead of leaving the player with a switch that did nothing.
    if (state == AppLifecycleState.resumed) unawaited(_cubit.reconcileStatusBar());
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
    value: _cubit,
    child: BlocBuilder<PokemonCubit, PokemonState>(
      builder: (context, state) {
        final tr = context.t.pokemon;
        final (:carried, :boxed) = carriedAndBoxed(state.pokemons ?? const <Pokemon>[]);
        return DefaultTabController(
          length: 4,
          initialIndex: widget.initialTab,
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tr.title),
                  if (state.pokemons != null)
                    Text(
                      '${tr.carriedCount(count: carried)} · ${tr.boxCount(count: boxed)}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
              actions: [
                IconButton(
                  icon: Icon(MdiIcons.swordCross),
                  tooltip: context.t.adventure.title,
                  onPressed: () async {
                    await context.pushNamed(ScreenPaths.pokemonAdventure);
                    if (mounted) await _cubit.refreshAll();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: tr.refresh,
                  onPressed: state.status == PokemonStatus.loading ? null : () => unawaited(_cubit.refreshAll()),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_browser_outlined),
                  tooltip: tr.openBrowser,
                  onPressed: () async => context.dispatchAsUrl('$baseUrl/plugin.php?id=pokemon:game', external: true),
                ),
                // Both the badge refresh and the status bar pet are forum-side settings, so keep them in an overflow
                // menu instead of crowding the bar with five icons.
                PopupMenuButton<String>(
                  onSelected: (value) => unawaited(_onMenuSelected(context, state, value)),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'badge',
                      child: ListTile(
                        leading: const Icon(Icons.military_tech_outlined),
                        title: Text(tr.refreshBadge),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    // A plugin build that reports the status bar state gets one switch. The production build only has
                    // the website's web module, whose state cannot be read back, so it gets the website's two actions.
                    if (state.profile?.statusBarHidden != null)
                      CheckedPopupMenuItem(
                        value: 'statusToggle',
                        checked: state.profile?.statusBarHidden != true,
                        child: Text(tr.statusBarPet),
                      ),
                    if (state.profile?.statusBarHidden == null) ...[
                      PopupMenuItem(
                        value: 'statusHide',
                        child: ListTile(
                          leading: const Icon(Icons.visibility_off_outlined),
                          title: Text(tr.statusBarHidePet),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'statusRefresh',
                        child: ListTile(
                          leading: const Icon(Icons.refresh),
                          title: Text(tr.statusBarShowPet),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              bottom: TabBar(
                tabs: [
                  Tab(icon: const Icon(Icons.pets), text: tr.myPokemon),
                  Tab(icon: const Icon(Icons.house_outlined), text: tr.pokemonCenter),
                  Tab(icon: const Icon(Icons.backpack_outlined), text: tr.inventory),
                  Tab(icon: const Icon(Icons.storefront_outlined), text: tr.shop),
                ],
              ),
            ),
            body: switch (state.status) {
              PokemonStatus.loading => const CenteredCircularIndicator(),
              PokemonStatus.needLogin => Center(
                child: TextButton(
                  onPressed: () async {
                    await context.pushNamed(ScreenPaths.login);
                    if (mounted) await _cubit.load();
                  },
                  child: Text(tr.loginRequired),
                ),
              ),
              PokemonStatus.failure => buildRetryButton(context, () => unawaited(_cubit.load()), message: tr.failedToLoad),
              // The tabs are the app's main scrolling surfaces, so keep their content clear of the system bars.
              PokemonStatus.success => const SafeArea(
                child: TabBarView(children: [MyPokemonTab(), PokemonCenterTab(), InventoryTab(), ShopTab()]),
              ),
            },
          ),
        );
      },
    ),
  );

  /// Run the action the overflow menu picked.
  Future<void> _onMenuSelected(BuildContext context, PokemonState state, String value) async {
    switch (value) {
      case 'badge':
        await runPokemonAction(context, _cubit.refreshBadge);
      case 'statusToggle':
        await _setStatusBar(context, hide: state.profile?.statusBarHidden != true);
      case 'statusHide':
        await _setStatusBar(context, hide: true);
      case 'statusRefresh':
        await _setStatusBar(context, hide: false);
    }
  }

  /// Ask the server to show or hide the forum status bar pet and report the outcome.
  Future<void> _setStatusBar(BuildContext context, {required bool hide}) async {
    final outcome = await _cubit.setStatusBar(hide: hide);
    if (!context.mounted) return;
    final tr = context.t.pokemon;
    showSnackBar(
      context: context,
      message: switch (outcome) {
        StatusBarOutcome.hidden => tr.statusBarPetHiddenDone,
        StatusBarOutcome.shown => tr.statusBarPetShownDone,
        StatusBarOutcome.notLoggedIn => tr.statusBarNeedLogin,
        StatusBarOutcome.notApplied => tr.statusBarNotApplied,
        StatusBarOutcome.failed => context.t.general.networkError,
      },
    );
  }
}
