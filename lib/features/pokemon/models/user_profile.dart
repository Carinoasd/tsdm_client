part of 'models.dart';

/// Profile of the current user inside the pokemon plugin.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class PokemonUserProfile with PokemonUserProfileMappable {
  /// Constructor.
  const PokemonUserProfile({
    required this.uid,
    required this.username,
    this.groupId,
    this.isAdmin,
    this.isNewPlayer,
    this.money,
    this.adventureStrength,
    this.strengthLevel,
    this.wins,
    this.losses,
    this.totalBattles,
    this.totalPokemons,
    this.totalItems,
    this.npcid,
    this.statusBarHidden,
  });

  /// Tolerant decode: every field is optional, missing values fall back to null.
  factory PokemonUserProfile.fromMap(Map<String, dynamic> map) => PokemonUserProfile(
    uid: (map['uid'] as num?)?.toInt() ?? 0,
    username: map['username'] as String? ?? '',
    groupId: (map['group_id'] as num?)?.toInt(),
    isAdmin: map['is_admin'] as bool?,
    isNewPlayer: map['is_new_player'] as bool?,
    money: (map['money'] as num?)?.toInt(),
    adventureStrength: (map['adventure_strength'] as num?)?.toInt(),
    strengthLevel: (map['strength_level'] as num?)?.toInt(),
    wins: (map['wins'] as num?)?.toInt(),
    losses: (map['losses'] as num?)?.toInt(),
    totalBattles: (map['total_battles'] as num?)?.toInt(),
    totalPokemons: (map['total_pokemons'] as num?)?.toInt(),
    totalItems: (map['total_items'] as num?)?.toInt(),
    npcid: (map['npcid'] as num?)?.toInt(),
    statusBarHidden: map['status_bar_hidden'] as bool?,
  );

  /// Forum user id.
  final int uid;

  /// Forum username.
  final String username;

  /// User group id.
  final int? groupId;

  /// Whether the user is a plugin admin.
  final bool? isAdmin;

  /// Whether the user has not started the plugin yet.
  final bool? isNewPlayer;

  /// In-game money (宠物币); null for a new player.
  final int? money;

  /// Adventure strength.
  final int? adventureStrength;

  /// Adventure strength level.
  final int? strengthLevel;

  /// Win count.
  final int? wins;

  /// Loss count.
  final int? losses;

  /// Total battles.
  final int? totalBattles;

  /// Owned pokemon count.
  final int? totalPokemons;

  /// Owned item count.
  final int? totalItems;

  /// Pokemon currently in battle (0 = none).
  final int? npcid;

  /// Whether the status bar is hidden.
  final bool? statusBarHidden;
}

/// Result of a heal (治疗) action.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class HealResult with HealResultMappable {
  /// Constructor.
  const HealResult({required this.message, required this.currentHp, required this.maxHp, required this.cost});

  /// Tolerant decode.
  factory HealResult.fromMap(Map<String, dynamic> map) => HealResult(
    message: map['message'] as String? ?? '',
    currentHp: (map['current_hp'] as num?)?.toInt() ?? 0,
    maxHp: (map['max_hp'] as num?)?.toInt() ?? 0,
    cost: (map['cost'] as num?)?.toInt() ?? 0,
  );

  /// Server message, e.g. "xxx已治疗，花费 0 金币".
  final String message;

  /// HP after healing.
  final int currentHp;

  /// Maximum HP.
  final int maxHp;

  /// Cost of the healing.
  final int cost;
}
