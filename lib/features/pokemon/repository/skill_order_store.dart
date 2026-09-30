import 'dart:convert';

import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Local, cosmetic ordering of a pokemon's skills.
///
/// The plugin returns a pokemon's skills in slot order and has no API to move one, so the order a player drags them
/// into is remembered on the device (keyed by the pokemon instance id) and applied whenever the list is shown.
final class SkillOrderStore {
  /// Storage key of the saved order of pokemon [pokemonId].
  static String keyFor(int pokemonId) => 'pokemon.skillOrder.$pokemonId';

  /// The saved skill ids of pokemon [pokemonId], in display order; empty when none was saved.
  Future<List<int>> load(int pokemonId) async {
    final raw = await getIt.get<StorageProvider>().getString(keyFor(pokemonId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<num>().map((e) => e.toInt()).toList();
    } on FormatException {
      return const [];
    }
  }

  /// Remember the display [order] of pokemon [pokemonId]'s skills.
  Future<void> save(int pokemonId, List<int> order) =>
      getIt.get<StorageProvider>().saveString(keyFor(pokemonId), jsonEncode(order));

  /// Sort [items] into [order], reading each item's skill id with [idOf].
  ///
  /// Skill ids missing from [order] keep their relative position and go last, so a newly learned skill lands at the end
  /// instead of disappearing. Works for the detail page's [PokemonSkill] and the battle's skill list alike.
  static List<T> apply<T>(List<T> items, List<int> order, int Function(T) idOf) {
    if (order.isEmpty) return items;
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    return [...items]..sort((a, b) => (rank[idOf(a)] ?? order.length).compareTo(rank[idOf(b)] ?? order.length));
  }
}
