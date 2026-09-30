part of 'models.dart';

/// A map (冒险地图) the player can adventure in.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class AdventureMap with AdventureMapMappable {
  /// Constructor.
  const AdventureMap({
    required this.id,
    required this.name,
    required this.areaType,
    required this.areaTypeName,
    required this.region,
    required this.posX,
    required this.posY,
    required this.isEnabled,
    required this.minLevel,
    required this.maxLevel,
    required this.mode,
    required this.wildPokemons,
    this.bosses,
  });

  /// Tolerant decode.
  factory AdventureMap.fromMap(Map<String, dynamic> map) => AdventureMap(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    areaType: map['area_type'] as String? ?? '',
    areaTypeName: map['area_type_name'] as String? ?? '',
    region: map['region'] as String? ?? '',
    posX: (map['pos_x'] as num?)?.toInt() ?? 0,
    posY: (map['pos_y'] as num?)?.toInt() ?? 0,
    isEnabled: map['is_enabled'] == true,
    minLevel: (map['min_level'] as num?)?.toInt() ?? 0,
    maxLevel: (map['max_level'] as num?)?.toInt() ?? 0,
    mode: map['mode'] as String? ?? 'wild',
    wildPokemons:
        (map['wild_pokemons'] as List?)?.whereType<Map<String, dynamic>>().map(AdventureWildPokemon.fromMap).toList() ??
        const [],
    bosses: (map['bosses'] as List?)?.whereType<Map<String, dynamic>>().map(AdventureBoss.fromMap).toList(),
  );

  /// Map id (`pm_map.id`).
  final int id;

  /// Map name.
  final String name;

  /// Area type letter (l/g/p/s/...).
  final String areaType;

  /// Human-readable area type name.
  final String areaTypeName;

  /// Region name (中央/北部/海洋/...).
  final String region;

  /// Horizontal position on the region map.
  final int posX;

  /// Vertical position on the region map.
  final int posY;

  /// Whether the map is enabled.
  final bool isEnabled;

  /// Minimum wild level.
  final int minLevel;

  /// Maximum wild level.
  final int maxLevel;

  /// Map mode (`wild` or `boss`).
  final String mode;

  /// Wild pokemon that appear here.
  final List<AdventureWildPokemon> wildPokemons;

  /// Boss list, only present in `boss` mode.
  final List<AdventureBoss>? bosses;

  /// Whether the map has a boss challenge.
  bool get hasBoss => bosses?.isNotEmpty ?? false;
}

/// A wild pokemon that appears on a map.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class AdventureWildPokemon with AdventureWildPokemonMappable {
  /// Constructor.
  const AdventureWildPokemon({required this.id, required this.name});

  /// Tolerant decode.
  factory AdventureWildPokemon.fromMap(Map<String, dynamic> map) => AdventureWildPokemon(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
  );

  /// Species id (`pm_data.id`).
  final int id;

  /// Species name.
  final String name;
}

/// A boss on a map.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class AdventureBoss with AdventureBossMappable {
  /// Constructor.
  const AdventureBoss({
    required this.pokemonTypeId,
    required this.pokemonName,
    required this.level,
    required this.bossMultiplier,
  });

  /// Tolerant decode.
  factory AdventureBoss.fromMap(Map<String, dynamic> map) => AdventureBoss(
    pokemonTypeId: (map['pokemon_type_id'] as num?)?.toInt() ?? 0,
    pokemonName: map['pokemon_name'] as String? ?? '',
    level: (map['level'] as num?)?.toInt() ?? 0,
    bossMultiplier: (map['boss_multiplier'] as num?)?.toDouble() ?? 1.0,
  );

  /// Species id (`pm_data.id`) of the boss.
  final int pokemonTypeId;

  /// Boss name.
  final String pokemonName;

  /// Boss level.
  final int level;

  /// Stat multiplier.
  final double bossMultiplier;
}

/// The maps list response.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class MapsResponse with MapsResponseMappable {
  /// Constructor.
  const MapsResponse({required this.maps, required this.total});

  /// Maps.
  final List<AdventureMap> maps;

  /// Total number of maps.
  final int total;
}
