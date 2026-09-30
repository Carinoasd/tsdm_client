import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/item_merge.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_grid_cell.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_search_field.dart';
import 'package:tsdm_client/features/pokemon/widgets/shop_category_chips.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// "Inventory" tab: browse items by category, search, and use them on pokemon.
class InventoryTab extends StatefulWidget {
  /// Constructor.
  const InventoryTab({super.key});

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  final ScrollController _scrollController = ScrollController();
  String _query = '';
  bool _grid = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// Load the next page when the list nears its end. The threshold matches the shop tab.
  Future<void> _onScroll() async {
    if (_loadingMore || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 200) return;
    setState(() => _loadingMore = true);
    try {
      await context.read<PokemonCubit>().loadMoreInventory();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Search only filters what is loaded, so pull the remaining pages first.
  void _onSearch(String value) {
    setState(() => _query = value);
    if (_query.isEmpty) return;
    unawaited(context.read<PokemonCubit>().loadAllInventory());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PokemonCubit>().state;
    final cubit = context.read<PokemonCubit>();
    final tr = context.t.pokemon;
    final categories = <(ShopCategory, String)>[
      (ShopCategory.all, tr.shopCategoryAll),
      (ShopCategory.med, tr.shopCategoryMed),
      (ShopCategory.ball, tr.shopCategoryBall),
      (ShopCategory.stone, tr.shopCategoryStone),
      (ShopCategory.boost, tr.shopCategoryBoost),
      (ShopCategory.equipment, tr.shopCategoryEquipment),
    ];
    final all = mergeInventoryItems(state.inventory?.items ?? const <InventoryItem>[]);
    final items = _query.isEmpty
        ? all
        : all.where((e) => e.name.contains(_query) || e.description.contains(_query)).toList();
    return Column(
      children: [
        PokemonCategoryChips(
          categories: categories,
          selected: state.inventoryCategory,
          onSelected: (category) => unawaited(cubit.setInventoryCategory(category)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          child: Row(
            children: [
              Expanded(child: PokemonSearchField(hintText: tr.searchItems, onChanged: _onSearch)),
              IconButton(
                tooltip: _grid ? tr.viewList : tr.viewGrid,
                icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
                onPressed: () => setState(() => _grid = !_grid),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: cubit.refreshAll,
            child: items.isEmpty
                ? ListView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr.empty)))],
                  )
                : _grid
                ? GridView.builder(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisExtent: 104,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: items.length + 1,
                    itemBuilder: (context, index) => index >= items.length
                        ? _footer()
                        : PokemonGridCell(
                            image: items[index].image.isEmpty ? null : pokemonItemImageUrl(items[index].image),
                            fallbackIcon: Icons.inventory_2_outlined,
                            title: items[index].name,
                            subtitle: '×${items[index].quantity}',
                            onTap: items[index].canUse ? () => unawaited(_use(items[index])) : null,
                          ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(8),
                    itemCount: items.length + 1,
                    itemBuilder: (context, index) {
                      if (index >= items.length) return _footer();
                      final item = items[index];
                      return Card(
                        child: ListTile(
                          leading: SizedBox(
                            width: 40,
                            height: 40,
                            child: item.image.isEmpty
                                ? const Icon(Icons.inventory_2_outlined)
                                : CachedImage(
                                    pokemonItemImageUrl(item.image),
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.contain,
                                  ),
                          ),
                          title: Text(item.name),
                          subtitle: Text(
                            item.description.isEmpty ? '×${item.quantity}' : '${item.description}\n×${item.quantity}',
                          ),
                          trailing: item.canUse
                              ? FilledButton.tonal(onPressed: () => _use(item), child: Text(tr.use))
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// Trailing loading cell shown while the next page is fetched.
  Widget _footer() => Padding(
    padding: const EdgeInsets.all(12),
    child: Center(
      child: _loadingMore
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const SizedBox.shrink(),
    ),
  );

  /// Use [item]; a pokemon-targeted item first asks which pokemon.
  Future<void> _use(InventoryItem item) async {
    final cubit = context.read<PokemonCubit>();
    final pokemons = cubit.state.pokemons ?? const <Pokemon>[];
    if (pokemons.isEmpty) {
      await runPokemonAction(context, () => cubit.useItem(item.typeId));
      return;
    }
    if (!mounted) return;
    final pokemon = await showModalBottomSheet<Pokemon>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(context.t.pokemon.useOn)),
            for (final p in pokemons)
              ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 40,
                  child: CachedImage(pokemonImageUrl(p.typeId), width: 40, height: 40, fit: BoxFit.contain),
                ),
                title: Text(p.displayName),
                subtitle: Text('${context.t.pokemon.hp} ${p.hp}/${p.maxHp}'),
                onTap: () => Navigator.of(context).pop(p),
              ),
          ],
        ),
      ),
    );
    if (pokemon == null || !mounted) return;
    await runPokemonAction(context, () => cubit.useItem(item.typeId, pokemonId: pokemon.id));
  }
}
