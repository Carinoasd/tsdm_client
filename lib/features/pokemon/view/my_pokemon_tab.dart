import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_dialogs.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_count_label.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_hp_bar.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// "My pokemon" tab: list of owned pokemon with management actions.
class MyPokemonTab extends StatelessWidget {
  /// Constructor.
  const MyPokemonTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PokemonCubit>().state;
    final tr = context.t.pokemon;
    final all = state.pokemons ?? const <Pokemon>[];
    final pokemons = all.where((p) => p.isCarried).toList();
    final (:carried, :boxed) = carriedAndBoxed(all);
    return RefreshIndicator(
      onRefresh: () => context.read<PokemonCubit>().refreshAll(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        children: [
          PokemonCountLabel(carried: carried, boxed: boxed),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.archive_outlined),
            title: Text(tr.storage),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await context.pushNamed(ScreenPaths.pokemonStorage);
              if (context.mounted) await context.read<PokemonCubit>().refreshPokemons();
            },
          ),
          const Divider(height: 1),
          if (pokemons.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr.empty)))
          else
            for (final pokemon in pokemons) _PokemonTile(pokemon: pokemon),
        ],
      ),
    );
  }
}

class _PokemonTile extends StatelessWidget {
  const _PokemonTile({required this.pokemon});

  final Pokemon pokemon;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pokemon;
    final isFirst = pokemon.isActive;
    return Card(
      child: ListTile(
        onTap: () async {
          await context.pushNamed(ScreenPaths.pokemonDetail, extra: pokemon);
          if (context.mounted) await context.read<PokemonCubit>().refreshPokemons();
        },
        leading: SizedBox(
          width: 48,
          height: 48,
          child: CachedImage(pokemonImageUrl(pokemon.typeId), width: 48, height: 48, fit: BoxFit.contain),
        ),
        title: Row(
          children: [
            Flexible(child: Text(pokemon.displayName, overflow: TextOverflow.ellipsis)),
            if (pokemon.isShiny) const Icon(Icons.auto_awesome, size: 16, color: Colors.amber),
            if (isFirst) ...[
              const SizedBox(width: 4),
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(tr.first),
                labelStyle: const TextStyle(fontSize: 11),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tr.level(level: pokemon.level)} · ${tr.state}: ${pokemonStateText(context, pokemon.state, pokemon.stateText)}'),
            const SizedBox(height: 2),
            PokemonHpBar(hp: pokemon.hp, maxHp: pokemon.maxHp),
          ],
        ),
        trailing: PopupMenuButton<_PokemonAction>(
          onSelected: (action) => _onAction(context, action),
          itemBuilder: (context) => [
            PopupMenuItem(value: _PokemonAction.setFirst, child: Text(tr.setFirst)),
            PopupMenuItem(value: _PokemonAction.rename, child: Text(tr.rename)),
            PopupMenuItem(value: _PokemonAction.toStorage, child: Text(tr.toStorage)),
            PopupMenuItem(value: _PokemonAction.release, child: Text(tr.release)),
          ],
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, _PokemonAction action) async {
    final cubit = context.read<PokemonCubit>();
    switch (action) {
      case _PokemonAction.setFirst:
        await runPokemonAction(context, () => cubit.setFirst(pokemon.id));
      case _PokemonAction.rename:
        await _rename(context, cubit);
      case _PokemonAction.toStorage:
        await runPokemonAction(context, () => cubit.movePokemon(pokemon.id, 3));
      case _PokemonAction.release:
        await _release(context, cubit);
    }
  }

  Future<void> _rename(BuildContext context, PokemonCubit cubit) async {
    final tr = context.t.pokemon;
    final name = await showPokemonInputDialog(
      context: context,
      icon: Icons.drive_file_rename_outline,
      title: tr.rename,
      initialValue: pokemon.displayName,
      confirmLabel: tr.rename,
      hintText: tr.rename,
      maxLength: 20,
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    await runPokemonAction(context, () => cubit.rename(pokemon.id, name));
  }

  Future<void> _release(BuildContext context, PokemonCubit cubit) async {
    final tr = context.t.pokemon;
    final confirmed = await showPokemonConfirmDialog(
      context: context,
      icon: Icons.delete_outline,
      title: tr.release,
      message: tr.releaseConfirm(name: pokemon.displayName),
      confirmLabel: tr.release,
      dangerous: true,
    );
    if (!confirmed || !context.mounted) return;
    await runPokemonAction(context, () => cubit.release(pokemon.id));
  }
}

enum _PokemonAction { setFirst, rename, toStorage, release }
