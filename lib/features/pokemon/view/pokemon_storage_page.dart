import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_search_field.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The pokemon storage (仓库): pokemon not carried in the bag, with a name search.
class PokemonStoragePage extends StatefulWidget {
  /// Constructor.
  const PokemonStoragePage({super.key});

  @override
  State<PokemonStoragePage> createState() => _PokemonStoragePageState();
}

class _PokemonStoragePageState extends State<PokemonStoragePage> {
  final PokemonRepository _repository = PokemonRepository();
  List<Pokemon>? _pokemons;
  bool _loading = true;
  bool _failed = false;
  bool _actionInProgress = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final result = await _repository.getMyPokemon().run();
    if (!mounted) return;
    result.fold(
      (e) => setState(() {
        _failed = true;
        _loading = false;
      }),
      (list) => setState(() {
        _pokemons = list.where((p) => p.isStored).toList();
        _loading = false;
      }),
    );
  }

  Future<void> _putInBag(Pokemon pokemon) async {
    if (_actionInProgress) return;
    setState(() => _actionInProgress = true);
    final tr = context.t.pokemon;
    try {
      final result = await _repository.movePokemon(pokemon.id, 2).run();
      if (!mounted) return;
      final message = result.fold((e) => pokemonErrorText(context, e), (_) => tr.actionSuccess);
      showSnackBar(context: context, message: message);
      if (result.isRight()) await _load();
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  /// A pokemon matches when its displayed name (possibly a nickname) or its species name contains the query.
  bool _matches(Pokemon p) => _query.isEmpty || p.displayName.contains(_query) || p.name.contains(_query);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pokemon;
    final pokemons = (_pokemons ?? const <Pokemon>[]).where(_matches).toList();
    final Widget body;
    if (_loading) {
      body = const CenteredCircularIndicator();
    } else if (_failed) {
      body = buildRetryButton(context, () => unawaited(_load()), message: tr.failedToLoad);
    } else {
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: PokemonSearchField(hintText: tr.searchPokemon, onChanged: (value) => setState(() => _query = value)),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: pokemons.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr.empty)))],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(8),
                      itemCount: pokemons.length,
                      itemBuilder: (context, index) {
                        final pokemon = pokemons[index];
                        return Card(
                          child: ListTile(
                            onTap: () async {
                              await context.pushNamed(ScreenPaths.pokemonDetail, extra: pokemon);
                              if (mounted) await _load();
                            },
                            leading: SizedBox(
                              width: 48,
                              height: 48,
                              child: CachedImage(
                                pokemonImageUrl(pokemon.typeId),
                                width: 48,
                                height: 48,
                                fit: BoxFit.contain,
                              ),
                            ),
                            title: Text(pokemon.displayName, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${tr.level(level: pokemon.level)} · ${pokemonStateText(context, pokemon.state, pokemon.stateText)}'),
                            trailing: FilledButton.tonal(
                              onPressed: _actionInProgress ? null : () => unawaited(_putInBag(pokemon)),
                              child: Text(tr.putInBag),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.storage),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: tr.refresh, onPressed: _loading ? null : () => unawaited(_load())),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}
