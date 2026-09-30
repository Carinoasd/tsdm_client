part of 'models.dart';

/// A single pokemon owned by the current user.
///
/// The `list` action returns the same shape minus [stats]; the `detail` action additionally carries [stats].
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class Pokemon with PokemonMappable {
  /// Constructor.
  const Pokemon({
    required this.id,
    required this.name,
    required this.typeId,
    required this.level,
    required this.exp,
    required this.expToNextLevel,
    required this.expForCurrentLevel,
    required this.expForNextLevel,
    required this.hp,
    required this.maxHp,
    required this.gender,
    required this.isShiny,
    required this.site,
    required this.state,
    required this.stateText,
    required this.stateClass,
    required this.affection,
    required this.skills,
    required this.baseInfo,
    this.nickname,
    this.quality,
    this.stats,
  });

  /// Tolerant decode: every field is optional, missing values fall back to a safe default.
  factory Pokemon.fromMap(Map<String, dynamic> map) => Pokemon(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    level: (map['level'] as num?)?.toInt() ?? 0,
    exp: (map['exp'] as num?)?.toInt() ?? 0,
    expToNextLevel: (map['exp_to_next_level'] as num?)?.toInt() ?? 0,
    expForCurrentLevel: (map['exp_for_current_level'] as num?)?.toInt() ?? 0,
    expForNextLevel: (map['exp_for_next_level'] as num?)?.toInt() ?? 0,
    hp: (map['hp'] as num?)?.toInt() ?? 0,
    maxHp: (map['max_hp'] as num?)?.toInt() ?? 0,
    gender: (map['gender'] as num?)?.toInt() ?? 0,
    isShiny: map['is_shiny'] == true,
    site: (map['site'] as num?)?.toInt() ?? 0,
    state: (map['state'] as num?)?.toInt() ?? 0,
    stateText: map['state_text'] as String? ?? '',
    stateClass: map['state_class'] as String? ?? '',
    affection: (map['affection'] as num?)?.toInt() ?? 0,
    skills: (map['skills'] as List?)?.whereType<Map<String, dynamic>>().map(PokemonSkill.fromMap).toList() ?? const [],
    baseInfo: PokemonBaseInfo.fromMap(map['base_info'] as Map<String, dynamic>? ?? const {}),
    nickname: map['nickname'] as String?,
    quality: map['quality'] as String?,
    stats: map['stats'] == null ? null : PokemonStats.fromMap(map['stats'] as Map<String, dynamic>),
  );

  /// Unique pet id (the `pm_mypm.id` row id).
  final int id;

  /// Species name (原始名称).
  final String name;

  /// User-given nickname, when set.
  final String? nickname;

  /// Base form id (`pm_data.id`).
  final int typeId;

  /// Current level.
  final int level;

  /// Current experience.
  final int exp;

  /// Experience still needed to reach the next level.
  final int expToNextLevel;

  /// Experience threshold at the start of the current level.
  final int expForCurrentLevel;

  /// Experience threshold to reach the next level.
  final int expForNextLevel;

  /// Current HP.
  final int hp;

  /// Maximum HP.
  final int maxHp;

  /// Gender (0=雄, 1=雌, 2=无).
  final int gender;

  /// Whether the pokemon is shiny (闪光).
  final bool isShiny;

  /// Quality grade (A/B/C/D/S/SS/SS+).
  final String? quality;

  /// Position (1 = first / currently battling).
  final int site;

  /// State code (0=濒危, 1=正常, ...).
  final int state;

  /// Human-readable state text.
  final String stateText;

  /// State CSS class name.
  final String stateClass;

  /// Affection (亲密度).
  final int affection;

  /// Up to four skill slots.
  final List<PokemonSkill> skills;

  /// Base species info.
  final PokemonBaseInfo baseInfo;

  /// Ability values, only present in the `detail` response.
  final PokemonStats? stats;

  /// Display name: nickname when set, otherwise the species name.
  String get displayName => nickname == null || nickname!.isEmpty ? name : nickname!;

  /// Progress toward the next level, in [0, 1].
  double get expProgress {
    final span = expForNextLevel - expForCurrentLevel;
    if (span <= 0) return 0;
    return ((exp - expForCurrentLevel) / span).clamp(0, 1);
  }

  /// Whether the pokemon is carried in the party instead of sitting in the storage box.
  ///
  /// The plugin sorts the party with `site`: 1 is the pokemon in front, 2 a reserve, 3 the storage box, and its own
  /// checks ask for `site < 3` (see `api_switch_pokemon`).
  bool get isCarried => site < 3;

  /// Whether the pokemon sits in the storage box.
  bool get isStored => site == 3;

  /// Whether the pokemon is the one in front, i.e. the one a fight starts with.
  bool get isActive => site == 1;

  /// Pokemon states the plugin treats as negative and resets to normal when it heals the pet.
  ///
  /// Mirrors `$negative_states` in `plugin/api/user.php`. The states outside this set (兴奋 8-10, 快乐 12-14,
  /// 自恋 16-17, 愤怒 18-19) are deliberately left alone by the server heal, so they must not count as a reason to ask
  /// for one either: a state the server never resets would otherwise be healed, and reported, on every single fight.
  static const negativeStates = {0, 2, 3, 4, 5, 6, 7, 11, 15, 20, 21, 22};

  /// Whether the plugin resets [state] to normal when it heals this pokemon.
  bool get isNegativeState => negativeStates.contains(state);

  /// Whether this pokemon needs a trip to the pokemon center.
  ///
  /// True when it is carried (site 1/2) and is hurt, in a negative state, or has a skill below its maximum PP:
  /// attacking spends PP even when the pet takes no damage, and the free server heal restores all three.
  bool get needsHealing =>
      isCarried && (hp < maxHp || isNegativeState || skills.any((skill) => !skill.isEmpty && skill.pp < skill.maxPp));
}

/// One skill slot of a pokemon.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class PokemonSkill with PokemonSkillMappable {
  /// Constructor.
  const PokemonSkill({
    required this.typeId,
    required this.pp,
    required this.name,
    required this.skillType,
    required this.category,
    required this.level,
    required this.power,
    required this.maxPp,
  });

  /// Tolerant decode.
  factory PokemonSkill.fromMap(Map<String, dynamic> map) => PokemonSkill(
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    pp: (map['pp'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    skillType: map['skill_type'] as String? ?? '',
    category: map['category'] as String? ?? '',
    level: (map['level'] as num?)?.toInt() ?? 0,
    power: (map['power'] as num?)?.toInt() ?? 0,
    maxPp: (map['max_pp'] as num?)?.toInt() ?? 0,
  );

  /// Skill id (`pm_skill.id`); 0 for an empty slot.
  final int typeId;

  /// Current PP.
  final int pp;

  /// Skill name (empty for an empty slot).
  final String name;

  /// Skill type (电/超能/普通 ...).
  final String skillType;

  /// Category (物攻/特攻 ...).
  final String category;

  /// Required level to learn.
  final int level;

  /// Power.
  final int power;

  /// Maximum PP.
  final int maxPp;

  /// Whether this slot holds a real skill.
  bool get isEmpty => typeId == 0;
}

/// Base species info from the `pm_data` table.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class PokemonBaseInfo with PokemonBaseInfoMappable {
  /// Constructor.
  const PokemonBaseInfo({
    required this.id,
    required this.name,
    required this.type1,
    this.type2,
    this.image,
    this.description,
  });

  /// Tolerant decode.
  factory PokemonBaseInfo.fromMap(Map<String, dynamic> map) => PokemonBaseInfo(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    type1: map['type_1'] as String? ?? '',
    type2: map['type_2'] as String?,
    image: map['image'] as String?,
    description: map['description'] as String?,
  );

  /// Species id (`pm_data.id`).
  final int id;

  /// Species name.
  final String name;

  /// Primary type (电/水/火 ...).
  @MappableField(key: 'type_1')
  final String type1;

  /// Secondary type, when present.
  @MappableField(key: 'type_2')
  final String? type2;

  /// Image filename; empty on the server side, build the url from the species id instead.
  final String? image;

  /// Pokédex description.
  final String? description;
}

/// Ability values of a pokemon.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class PokemonStats with PokemonStatsMappable {
  /// Constructor.
  const PokemonStats({
    required this.hp,
    required this.attack,
    required this.defense,
    required this.spAttack,
    required this.spDefense,
    required this.speed,
  });

  /// Tolerant decode.
  factory PokemonStats.fromMap(Map<String, dynamic> map) => PokemonStats(
    hp: (map['hp'] as num?)?.toInt() ?? 0,
    attack: (map['attack'] as num?)?.toInt() ?? 0,
    defense: (map['defense'] as num?)?.toInt() ?? 0,
    spAttack: (map['sp_attack'] as num?)?.toInt() ?? 0,
    spDefense: (map['sp_defense'] as num?)?.toInt() ?? 0,
    speed: (map['speed'] as num?)?.toInt() ?? 0,
  );

  /// HP.
  final int hp;

  /// Attack.
  final int attack;

  /// Defense.
  final int defense;

  /// Special attack.
  final int spAttack;

  /// Special defense.
  final int spDefense;

  /// Speed.
  final int speed;
}
