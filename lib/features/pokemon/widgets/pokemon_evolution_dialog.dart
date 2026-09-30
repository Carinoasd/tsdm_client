import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Show the evolution chain of species [speciesId] the way the website's "进化路径" dialog does: what the pokemon can
/// become and what it evolved from, with each step's condition.
///
/// Display only, exactly like the website: it reads `evolution&action=evolution_path` and never triggers an evolution.
Future<void> showPokemonEvolutionPath(BuildContext context, PokemonRepository repository, int speciesId) async {
  final result = await repository.getEvolutionPath(speciesId).run();
  if (!context.mounted) return;
  final path = result.fold((_) => null, (value) => value);
  if (path == null) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.t.pokemon.evolutionPath),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (path.isEmpty) Text(context.t.pokemon.evolutionNone),
            if (path.backward.isNotEmpty) ...[
              Text(context.t.pokemon.evolutionBackward, style: Theme.of(context).textTheme.labelLarge),
              for (final step in path.backward) _EvolutionStepTile(step: step),
            ],
            if (path.forward.isNotEmpty) ...[
              if (path.backward.isNotEmpty) const SizedBox(height: 12),
              Text(context.t.pokemon.evolutionForward, style: Theme.of(context).textTheme.labelLarge),
              for (final step in path.forward) _EvolutionStepTile(step: step),
            ],
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => context.pop(), child: Text(context.t.battle.ok))],
    ),
  );
}

/// One row of the evolution dialog: the form's sprite, its name and the condition to reach it.
class _EvolutionStepTile extends StatelessWidget {
  const _EvolutionStepTile({required this.step});

  /// The evolution step to show.
  final EvolutionStep step;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        CachedImage(pokemonSmallImageUrl(step.id), width: 36, height: 36, fit: BoxFit.contain),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.name, style: Theme.of(context).textTheme.bodyLarge),
              if (step.conditionDisplay.isNotEmpty)
                Text(step.conditionDisplay, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}
