import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_dialogs.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_grid_cell.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_search_field.dart';
import 'package:tsdm_client/features/pokemon/widgets/shop_category_chips.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// "Shop" tab: browse and buy items by category (or whole pokemon), with search and a grid mode.
class ShopTab extends StatefulWidget {
  /// Constructor.
  const ShopTab({super.key});

  @override
  State<ShopTab> createState() => _ShopTabState();
}

class _ShopTabState extends State<ShopTab> {
  final ScrollController _controller = ScrollController();
  bool _loadingMore = false;
  bool _grid = false;
  String _query = '';
  ShopCategory? _lastCategory;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// Load the next page when the list nears its end (pagination).
  Future<void> _onScroll() async {
    if (_loadingMore || !_controller.hasClients) return;
    final position = _controller.position;
    if (position.pixels < position.maxScrollExtent - 200) return;
    setState(() => _loadingMore = true);
    try {
      await context.read<PokemonCubit>().loadMoreShop();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Search only filters what is loaded, so pull the remaining pages first.
  void _onSearch(String value) {
    setState(() => _query = value);
    if (_query.isEmpty) return;
    unawaited(context.read<PokemonCubit>().loadAllShop());
  }

  /// Scroll back to the top when the selected category changes, so the new list starts at its head.
  void _resetIfCategoryChanged(ShopCategory category) {
    if (_lastCategory == category) return;
    _lastCategory = category;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) _controller.jumpTo(0);
    });
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PokemonCubit>().state;
    final cubit = context.read<PokemonCubit>();
    final tr = context.t.pokemon;
    _resetIfCategoryChanged(state.shopCategory);
    final categories = <(ShopCategory, String)>[
      (ShopCategory.all, tr.shopCategoryAll),
      (ShopCategory.med, tr.shopCategoryMed),
      (ShopCategory.ball, tr.shopCategoryBall),
      (ShopCategory.stone, tr.shopCategoryStone),
      (ShopCategory.boost, tr.shopCategoryBoost),
      (ShopCategory.equipment, tr.shopCategoryEquipment),
      (ShopCategory.pet, tr.shopCategoryPet),
    ];
    return Column(
      children: [
        if (state.profile != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.monetization_on_outlined),
                const SizedBox(width: 8),
                Text('${tr.money}: ${state.profile!.money ?? 0}'),
              ],
            ),
          ),
        PokemonCategoryChips(
          categories: categories,
          selected: state.shopCategory,
          onSelected: (category) => unawaited(cubit.setShopCategory(category)),
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
            child: state.shopCategory.isPet ? _buildPets(context, state) : _buildItems(context, state),
          ),
        ),
      ],
    );
  }

  /// The items currently shown: the loaded page filtered by the search query.
  List<ShopItem> _visibleItems(PokemonState state) {
    final items = state.shop?.items ?? const <ShopItem>[];
    if (_query.isEmpty) return items;
    return items.where((e) => e.name.contains(_query) || e.description.contains(_query)).toList();
  }

  /// The pets currently shown: the loaded page filtered by the search query.
  List<ShopPet> _visiblePets(PokemonState state) {
    final pets = state.shopPets?.pets ?? const <ShopPet>[];
    if (_query.isEmpty) return pets;
    return pets.where((e) => e.name.contains(_query)).toList();
  }

  /// Placeholder list used when there is nothing to show.
  Widget _empty() => ListView(
    controller: _controller,
    physics: const AlwaysScrollableScrollPhysics(),
    children: [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(context.t.pokemon.empty)))],
  );

  Widget _buildItems(BuildContext context, PokemonState state) {
    final tr = context.t.pokemon;
    final items = _visibleItems(state);
    if (items.isEmpty) return _empty();
    if (_grid) {
      return GridView.builder(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 116,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: items.length + 1,
        itemBuilder: (context, index) => index >= items.length
            ? _footer()
            : PokemonGridCell(
                image: items[index].image.isEmpty ? null : pokemonItemImageUrl(items[index].image),
                fallbackIcon: Icons.shopping_bag_outlined,
                title: items[index].name,
                subtitle: '${tr.price}: ${items[index].price}',
                onTap: items[index].canBuy ? () => _buy(items[index]) : null,
              ),
      );
    }
    return ListView.builder(
      controller: _controller,
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
                  ? const Icon(Icons.shopping_bag_outlined)
                  : CachedImage(pokemonItemImageUrl(item.image), width: 40, height: 40, fit: BoxFit.contain),
            ),
            title: Text(item.name),
            subtitle: Text('${tr.price}: ${item.price}\n${item.description}'),
            trailing: FilledButton.tonal(onPressed: item.canBuy ? () => _buy(item) : null, child: Text(tr.buy)),
          ),
        );
      },
    );
  }

  Widget _buildPets(BuildContext context, PokemonState state) {
    final tr = context.t.pokemon;
    final pets = _visiblePets(state);
    if (pets.isEmpty) return _empty();
    if (_grid) {
      return GridView.builder(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 120,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: pets.length + 1,
        itemBuilder: (context, index) => index >= pets.length
            ? _footer()
            : PokemonGridCell(
                image: pokemonImageUrl(pets[index].id),
                fallbackIcon: Icons.catching_pokemon,
                title: pets[index].name,
                subtitle: '${tr.price}: ${pets[index].price}',
                onTap: pets[index].canBuy ? () => _buyPet(pets[index]) : null,
              ),
      );
    }
    return ListView.builder(
      controller: _controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: pets.length + 1,
      itemBuilder: (context, index) {
        if (index >= pets.length) return _footer();
        final pet = pets[index];
        final types = pet.type2 == null || pet.type2!.isEmpty ? pet.type1 : '${pet.type1}/${pet.type2}';
        return Card(
          child: ListTile(
            leading: SizedBox(
              width: 40,
              height: 40,
              child: CachedImage(pokemonImageUrl(pet.id), width: 40, height: 40, fit: BoxFit.contain),
            ),
            title: Text(pet.name),
            subtitle: Text(
              '$types\n'
              '${tr.hp} ${pet.hp} · ${tr.attack} ${pet.atk} · ${tr.defense} ${pet.def} · ${tr.speed} ${pet.speed}\n'
              '${tr.price}: ${pet.price}',
            ),
            isThreeLine: true,
            trailing: FilledButton.tonal(onPressed: pet.canBuy ? () => _buyPet(pet) : null, child: Text(tr.buy)),
          ),
        );
      },
    );
  }

  Future<void> _buy(ShopItem item) async {
    // Use the tab's own (stable) context and grab the cubit before the dialog: the list item's context may already be
    // gone by the time the dialog closes and the list rebuilds.
    final cubit = context.read<PokemonCubit>();
    final tr = context.t.pokemon;
    final quantityText = await showPokemonInputDialog(
      context: context,
      icon: Icons.shopping_cart_outlined,
      title: '${tr.buy}: ${item.name}',
      initialValue: '1',
      confirmLabel: tr.buy,
      hintText: tr.quantity,
      keyboardType: TextInputType.number,
    );
    if (quantityText == null || !mounted) return;
    final quantity = int.tryParse(quantityText) ?? 1;
    if (quantity <= 0) return;
    await runPokemonAction(context, () => cubit.buy(item.id, quantity));
  }

  Future<void> _buyPet(ShopPet pet) async {
    final cubit = context.read<PokemonCubit>();
    final tr = context.t.pokemon;
    final confirmed = await showPokemonConfirmDialog(
      context: context,
      icon: Icons.shopping_cart_outlined,
      title: tr.buy,
      message: tr.buyPetConfirm(name: pet.name, price: pet.price),
      confirmLabel: tr.buy,
    );
    if (!confirmed || !mounted) return;
    await runPokemonAction(context, () => cubit.buyPet(pet.id));
  }
}
