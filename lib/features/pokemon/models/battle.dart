part of 'models.dart';

/// A battle in progress, or its result after a turn/action.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BattleScene with BattleSceneMappable {
  /// Constructor.
  const BattleScene({
    required this.battleId,
    required this.mapId,
    required this.mapName,
    required this.turn,
    required this.myPokemon,
    required this.wildPokemon,
    required this.status,
    this.message,
    this.rewards,
    this.levelUp,
  });

  /// Tolerant decode: every field is optional, missing values fall back to a safe default.
  factory BattleScene.fromMap(Map<String, dynamic> map) => BattleScene(
    battleId: map['battle_id'] as String? ?? '',
    mapId: (map['map_id'] as num?)?.toInt() ?? 0,
    mapName: map['map_name'] as String? ?? '',
    turn: (map['turn'] as num?)?.toInt() ?? 0,
    myPokemon: BattlePokemon.fromMap(map['my_pokemon'] as Map<String, dynamic>? ?? const {}),
    wildPokemon: WildPokemon.fromMap(map['wild_pokemon'] as Map<String, dynamic>? ?? const {}),
    status: map['status'] as String? ?? 'active',
    message: map['message'] as String?,
    rewards: map['rewards'] == null ? null : BattleRewards.fromMap(map['rewards'] as Map<String, dynamic>),
    levelUp: map['level_up'] == null ? null : LevelUpInfo.fromMap(map['level_up'] as Map<String, dynamic>),
  );

  /// Battle id.
  final String battleId;

  /// Map id.
  final int mapId;

  /// Map name.
  final String mapName;

  /// Current turn number.
  final int turn;

  /// The player's pokemon.
  final BattlePokemon myPokemon;

  /// The wild pokemon or boss.
  final WildPokemon wildPokemon;

  /// Battle status: `active`/`victory`/`defeat`/`fled`/`captured`.
  final String status;

  /// Latest battle message; absent in some responses (e.g. recover).
  final String? message;

  /// Rewards, when the battle ends in victory/capture.
  final BattleRewards? rewards;

  /// Level-up info, when the pokemon leveled up.
  final LevelUpInfo? levelUp;

  /// Whether the battle is still ongoing.
  bool get isActive => status == 'active';
}

/// The player's pokemon during a battle.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BattlePokemon with BattlePokemonMappable {
  /// Constructor.
  const BattlePokemon({
    required this.id,
    required this.instanceId,
    required this.level,
    required this.hp,
    required this.maxHp,
    required this.isShiny,
    required this.skills,
    this.name,
    this.quality,
  });

  /// Tolerant decode.
  factory BattlePokemon.fromMap(Map<String, dynamic> map) => BattlePokemon(
    id: (map['id'] as num?)?.toInt() ?? 0,
    instanceId: (map['instance_id'] as num?)?.toInt() ?? 0,
    level: (map['level'] as num?)?.toInt() ?? 0,
    hp: (map['hp'] as num?)?.toInt() ?? 0,
    maxHp: (map['max_hp'] as num?)?.toInt() ?? 0,
    isShiny: map['is_shiny'] == true,
    skills: (map['skills'] as List?)?.whereType<Map<String, dynamic>>().map(BattleSkill.fromMap).toList() ?? const [],
    name: map['name'] as String?,
    quality: map['quality'] as String?,
  );

  /// Species id.
  final int id;

  /// Instance id.
  final int instanceId;

  /// Name; null for a pokemon without a nickname (plugin `build_battle_response` bug).
  final String? name;

  /// Level.
  final int level;

  /// Current HP.
  final int hp;

  /// Maximum HP.
  final int maxHp;

  /// Whether shiny.
  final bool isShiny;

  /// Quality grade.
  final String? quality;

  /// Battle skills.
  final List<BattleSkill> skills;
}

/// A skill usable during battle.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BattleSkill with BattleSkillMappable {
  /// Constructor.
  const BattleSkill({
    required this.id,
    required this.power,
    required this.pp,
    required this.maxPp,
    required this.skillType,
    required this.category,
    this.name,
  });

  /// Tolerant decode.
  factory BattleSkill.fromMap(Map<String, dynamic> map) => BattleSkill(
    id: (map['id'] as num?)?.toInt() ?? 0,
    power: (map['power'] as num?)?.toInt() ?? 0,
    pp: (map['pp'] as num?)?.toInt() ?? 0,
    maxPp: (map['max_pp'] as num?)?.toInt() ?? 0,
    skillType: map['skill_type'] as String? ?? '',
    category: map['category'] as String? ?? '',
    name: map['name'] as String?,
  );

  /// Skill id.
  final int id;

  /// Skill name; null when the joined skill row is missing.
  final String? name;

  /// Power.
  final int power;

  /// Current PP.
  final int pp;

  /// Maximum PP.
  final int maxPp;

  /// Skill type.
  final String skillType;

  /// Category (物攻/特攻 ...).
  final String category;

  /// Whether the skill has PP left.
  bool get usable => pp > 0;
}

/// The wild pokemon or boss being fought.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class WildPokemon with WildPokemonMappable {
  /// Constructor.
  const WildPokemon({
    required this.id,
    required this.level,
    required this.hp,
    required this.maxHp,
    required this.gender,
    required this.isShiny,
    this.name,
    this.isBoss,
    this.bossMultiplier,
  });

  /// Tolerant decode.
  factory WildPokemon.fromMap(Map<String, dynamic> map) => WildPokemon(
    id: (map['id'] as num?)?.toInt() ?? 0,
    level: (map['level'] as num?)?.toInt() ?? 0,
    hp: (map['hp'] as num?)?.toInt() ?? 0,
    maxHp: (map['max_hp'] as num?)?.toInt() ?? 0,
    gender: (map['gender'] as num?)?.toInt() ?? 0,
    isShiny: map['is_shiny'] == true,
    name: map['name'] as String?,
    isBoss: map['is_boss'] as bool?,
    bossMultiplier: (map['boss_multiplier'] as num?)?.toDouble(),
  );

  /// Species id.
  final int id;

  /// Name; null when the species row is missing.
  final String? name;

  /// Level.
  final int level;

  /// Current HP.
  final int hp;

  /// Maximum HP.
  final int maxHp;

  /// Gender.
  final int gender;

  /// Whether shiny.
  final bool isShiny;

  /// Whether a boss; absent in the idle base shape.
  final bool? isBoss;

  /// Stat multiplier; only present for bosses.
  final double? bossMultiplier;
}

/// Battle rewards.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BattleRewards with BattleRewardsMappable {
  /// Constructor.
  const BattleRewards({required this.exp, required this.money});

  /// Tolerant decode.
  factory BattleRewards.fromMap(Map<String, dynamic> map) => BattleRewards(
    exp: (map['exp'] as num?)?.toInt() ?? 0,
    money: (map['money'] as num?)?.toInt() ?? 0,
  );

  /// Experience gained.
  final int exp;

  /// Money gained.
  final int money;
}

/// Level-up information.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class LevelUpInfo with LevelUpInfoMappable {
  /// Constructor.
  const LevelUpInfo({required this.levelUp, required this.oldLevel, required this.newLevel, required this.newExp});

  /// Tolerant decode.
  factory LevelUpInfo.fromMap(Map<String, dynamic> map) => LevelUpInfo(
    levelUp: map['level_up'] == true,
    oldLevel: (map['old_level'] as num?)?.toInt() ?? 0,
    newLevel: (map['new_level'] as num?)?.toInt() ?? 0,
    newExp: (map['new_exp'] as num?)?.toInt() ?? 0,
  );

  /// Whether the pokemon leveled up.
  final bool levelUp;

  /// Previous level.
  final int oldLevel;

  /// New level.
  final int newLevel;

  /// New experience total.
  final int newExp;
}

/// An item usable during battle (HP/PP restore), from `battle/get_battle_items`.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BattleItem with BattleItemMappable {
  /// Constructor.
  const BattleItem({
    required this.id,
    required this.name,
    required this.img,
    required this.nums,
    required this.itemType,
    required this.module,
    this.addhp,
  });

  /// Tolerant decode.
  factory BattleItem.fromMap(Map<String, dynamic> map) => BattleItem(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    img: map['img'] as String? ?? '',
    nums: (map['nums'] as num?)?.toInt() ?? 0,
    itemType: (map['item_type'] as num?)?.toInt() ?? 0,
    module: map['module'] as String? ?? '',
    addhp: (map['addhp'] as num?)?.toInt(),
  );

  /// Item type id (`pm_itemdata.id`).
  final int id;

  /// Item name.
  final String name;

  /// Icon filename.
  final String img;

  /// Owned quantity.
  final int nums;

  /// Item category (1=HP药水, 4=PP恢复).
  final int itemType;

  /// Effect module (`pp5`/`pp10`/...).
  final String module;

  /// HP restored (HP potions only).
  final int? addhp;
}
