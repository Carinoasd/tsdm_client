import 'package:flutter/material.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Counts the carried (party) and boxed (storage) pokemon in [pokemons].
({int carried, int boxed}) carriedAndBoxed(Iterable<Pokemon> pokemons) {
  final boxed = pokemons.where((p) => p.isStored).length;
  return (carried: pokemons.length - boxed, boxed: boxed);
}

/// A small "carried: N · box: M" line shown above the pokemon lists.
class PokemonCountLabel extends StatelessWidget {
  /// Constructor.
  const PokemonCountLabel({required this.carried, required this.boxed, super.key});

  /// How many pokemon are carried in the bag.
  final int carried;

  /// How many pokemon are in the storage box.
  final int boxed;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pokemon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 16, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 6),
          Text(
            '${tr.carriedCount(count: carried)} · ${tr.boxCount(count: boxed)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
