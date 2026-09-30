part of 'models.dart';

/// A skill a pokemon may learn, from `pokemon&action=learnable_skills`.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class LearnableSkill with LearnableSkillMappable {
  /// Constructor.
  const LearnableSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.type,
    required this.category,
    required this.power,
    required this.maxPp,
    required this.requiredLevel,
    required this.isAvailable,
  });

  /// Tolerant decode.
  factory LearnableSkill.fromMap(Map<String, dynamic> map) => LearnableSkill(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    type: map['type'] as String? ?? '',
    category: map['category'] as String? ?? '',
    power: (map['power'] as num?)?.toInt() ?? 0,
    maxPp: (map['max_pp'] as num?)?.toInt() ?? 0,
    requiredLevel: (map['required_level'] as num?)?.toInt() ?? 0,
    isAvailable: map['is_available'] == true,
  );

  /// Skill id (`pm_skill.id`).
  final int id;

  /// Skill name.
  final String name;

  /// Skill description.
  final String description;

  /// Skill type (电/超能/普通 ...).
  final String type;

  /// Category (物攻/特攻 ...).
  final String category;

  /// Power.
  final int power;

  /// Maximum PP.
  final int maxPp;

  /// Level the pokemon must reach to learn this skill.
  final int requiredLevel;

  /// Whether the pokemon's current level already allows learning it.
  final bool isAvailable;
}

/// The answer of `pokemon&action=learnable_skills`: what one pokemon can still learn.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class LearnableSkills with LearnableSkillsMappable {
  /// Constructor.
  const LearnableSkills({
    required this.pokemonId,
    required this.pokemonLevel,
    required this.availableSkills,
    required this.unlockedSkills,
  });

  /// Tolerant decode.
  factory LearnableSkills.fromMap(Map<String, dynamic> map) => LearnableSkills(
    pokemonId: (map['pokemon_id'] as num?)?.toInt() ?? 0,
    pokemonLevel: (map['pokemon_level'] as num?)?.toInt() ?? 0,
    availableSkills: _learnableSkillList(map['available_skills']),
    unlockedSkills: _learnableSkillList(map['unlocked_skills']),
  );

  /// Pet id.
  final int pokemonId;

  /// Current level of the pet.
  final int pokemonLevel;

  /// Skills whose level requirement is already met.
  final List<LearnableSkill> availableSkills;

  /// Skills that still need a higher level.
  final List<LearnableSkill> unlockedSkills;
}

/// Decode a JSON list of learnable skills.
List<LearnableSkill> _learnableSkillList(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map<String, dynamic>>().map(LearnableSkill.fromMap).toList();
}
