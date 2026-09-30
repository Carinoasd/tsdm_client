import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_count_label.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_hp_bar.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_search_field.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// "Pokemon center" tab: heal pokemon (with a name search), carried and boxed kept apart.
class PokemonCenterTab extends StatefulWidget {
  /// Constructor.
  const PokemonCenterTab({super.key});

  @override
  State<PokemonCenterTab> createState() => _PokemonCenterTabState();
}

class _PokemonCenterTabState extends State<PokemonCenterTab> {
  String _query = '';

  /// A pokemon matches when its displayed name (possibly a nickname) or its species name contains the query.
  bool _matches(Pokemon p) => _query.isEmpty || p.displayName.contains(_query) || p.name.contains(_query);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PokemonCubit>().state;
    final tr = context.t.pokemon;
    final all = state.pokemons ?? const <Pokemon>[];
    final (:carried, :boxed) = carriedAndBoxed(all);
    final matched = all.where(_matches).toList();
    final carriedList = matched.where((p) => p.isCarried).toList();
    final boxedList = matched.where((p) => p.isStored).toList();
    return Column(
      children: [
        PokemonCountLabel(carried: carried, boxed: boxed),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: PokemonSearchField(hintText: tr.searchPokemon, onChanged: (value) => setState(() => _query = value)),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => context.read<PokemonCubit>().refreshAll(),
            child: matched.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr.empty)))],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(8),
                    children: [
                      // Carried pokemon first, then the ones sitting in the storage box.
                      if (carriedList.isNotEmpty) _sectionHeader(context, tr.carried, carriedList.length),
                      for (final p in carriedList) _tile(context, p),
                      if (boxedList.isNotEmpty) _sectionHeader(context, tr.storage, boxedList.length),
                      for (final p in boxedList) _tile(context, p),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// A small header separating the carried pokemon from the boxed ones.
  Widget _sectionHeader(BuildContext context, String title, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
    child: Text('$title · $count', style: Theme.of(context).textTheme.titleSmall),
  );

  /// One pokemon row with the heal and heal-and-flee actions.
  Widget _tile(BuildContext context, Pokemon pokemon) {
    final tr = context.t.pokemon;
    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 48,
          height: 48,
          child: CachedImage(pokemonImageUrl(pokemon.typeId), width: 48, height: 48, fit: BoxFit.contain),
        ),
        title: Text(pokemon.displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tr.level(level: pokemon.level)} · ${tr.state}: ${pokemonStateText(context, pokemon.state, pokemon.stateText)}'),
            const SizedBox(height: 2),
            PokemonHpBar(hp: pokemon.hp, maxHp: pokemon.maxHp),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.medical_services_outlined),
              tooltip: tr.heal,
              onPressed: () => unawaited(_heal(context, pokemon, flee: false)),
            ),
            IconButton(
              icon: const Icon(Icons.airline_stops),
              tooltip: tr.healAndFlee,
              onPressed: () => unawaited(_heal(context, pokemon, flee: true)),
            ),
          ],
        ),
      ),
    );
  }

  /// Heal [pokemon] at the center, reporting the result with the app's standard floating snack bar.
  Future<void> _heal(BuildContext context, Pokemon pokemon, {required bool flee}) async {
    final tr = context.t.pokemon;
    final cubit = context.read<PokemonCubit>();
    final result = await (flee ? cubit.healAndFlee(pokemon.id) : cubit.heal(pokemon.id));
    if (!context.mounted) return;
    final message = result.success
        ? (result.message ?? tr.actionSuccess)
        : (result.message ?? context.t.general.networkError);
    showSnackBar(context: context, message: message);
  }
}
