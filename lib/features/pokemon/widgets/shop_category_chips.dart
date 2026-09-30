import 'package:flutter/material.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';

/// The horizontally scrolling category chips shared by the shop and the inventory.
class PokemonCategoryChips extends StatelessWidget {
  /// Constructor.
  const PokemonCategoryChips({required this.categories, required this.selected, required this.onSelected, super.key});

  /// Available categories with their labels, in display order.
  final List<(ShopCategory, String)> categories;

  /// The category currently shown as selected.
  final ShopCategory selected;

  /// Called when the user taps a category.
  final ValueChanged<ShopCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          for (final (category, label) in categories)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(label),
                selected: selected == category,
                onSelected: (_) => onSelected(category),
              ),
            ),
        ],
      ),
    );
  }
}
