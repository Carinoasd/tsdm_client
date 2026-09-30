part of 'models.dart';

/// One step of a pokemon's evolution chain, as `evolution&action=evolution_path` reports it.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class EvolutionStep with EvolutionStepMappable {
  /// Constructor.
  const EvolutionStep({required this.id, required this.name, required this.type1, required this.type2, required this.conditionDisplay});

  /// Tolerant decode.
  factory EvolutionStep.fromMap(Map<String, dynamic> map) => EvolutionStep(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    type1: map['type_1'] as String? ?? '',
    type2: map['type_2'] as String?,
    conditionDisplay: map['condition_display'] as String? ?? '',
  );

  /// Species id of this form.
  final int id;

  /// Name of this form.
  final String name;

  /// Primary type of this form.
  final String type1;

  /// Secondary type of this form, null when it has only one.
  final String? type2;

  /// Condition to reach this form, as the server words it (empty when there is none).
  final String conditionDisplay;
}

/// The evolution chain of a pokemon: what it can become, and what it evolved from.
///
/// Only ever read, and the website shows the same thing in its "进化路径" dialog.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class EvolutionPath with EvolutionPathMappable {
  /// Constructor.
  const EvolutionPath({
    required this.pokemonId,
    required this.pokemonName,
    required this.pokemonType1,
    required this.pokemonType2,
    required this.forward,
    required this.backward,
  });

  /// Tolerant decode.
  factory EvolutionPath.fromMap(Map<String, dynamic> map) => EvolutionPath(
    pokemonId: (map['pokemon_id'] as num?)?.toInt() ?? 0,
    pokemonName: map['pokemon_name'] as String? ?? '',
    pokemonType1: map['pokemon_type1'] as String? ?? '',
    pokemonType2: map['pokemon_type2'] as String?,
    forward: _stepsOf(map['forward']),
    backward: _stepsOf(map['backward']),
  );

  /// The species the chain was asked for.
  final int pokemonId;

  /// Name of that species.
  final String pokemonName;

  /// Primary type of that species.
  final String pokemonType1;

  /// Secondary type of that species, null when it has only one.
  final String? pokemonType2;

  /// Forms this pokemon can evolve into.
  final List<EvolutionStep> forward;

  /// Forms this pokemon evolved from.
  final List<EvolutionStep> backward;

  /// Whether there is no chain to show at all.
  bool get isEmpty => forward.isEmpty && backward.isEmpty;
}

/// Decode a step list the tolerant way: a missing or mistyped list is an empty one.
List<EvolutionStep> _stepsOf(Object? raw) => [
  for (final step in raw is List ? raw : const <Object>[])
    if (step is Map<String, dynamic>) EvolutionStep.fromMap(step),
];
