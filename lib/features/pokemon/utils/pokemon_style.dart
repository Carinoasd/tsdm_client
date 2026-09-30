import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Accent color of a pokemon move type (属性), used to tint skill labels.
Color pokemonTypeColor(String type) => switch (type) {
  '普通' => const Color(0xFF9E9E9E),
  '格斗' => const Color(0xFFC03028),
  '飞行' => const Color(0xFF7986CB),
  '毒' => const Color(0xFF9C27B0),
  '地面' => const Color(0xFFBCAAA4),
  '岩石' => const Color(0xFF8D6E63),
  '虫' => const Color(0xFF8BC34A),
  '幽灵' => const Color(0xFF673AB7),
  '钢' => const Color(0xFF78909C),
  '火' => const Color(0xFFE53935),
  '水' => const Color(0xFF1E88E5),
  '草' => const Color(0xFF43A047),
  '电' => const Color(0xFFF9A825),
  '超能' => const Color(0xFFD81B60),
  '冰' => const Color(0xFF00ACC1),
  '龙' => const Color(0xFF3949AB),
  '恶' => const Color(0xFF546E7A),
  '妖精' => const Color(0xFFEC407A),
  _ => const Color(0xFF9E9E9E),
};

/// Emoji of a map area type (`pm_map.site`), mirroring the plugin web page.
String pokemonAreaEmoji(String areaType) => switch (areaType) {
  'l' => '🌿',
  'g' => '🌱',
  'p' => '💧',
  's' => '🌊',
  'b' => '🐚',
  'm' => '⛰️',
  'c' => '🕳️',
  'd' => '🏜️',
  'f' => '🏭',
  't' => '🏗️',
  'v' => '🏘️',
  'n' => '🏟️',
  'h' => '☁️',
  'o' => '🦑',
  'k' => '🌋',
  _ => '❓',
};

/// Accent color of a map area type, matching the web page's badges.
Color pokemonAreaColor(String areaType) => switch (areaType) {
  'l' || 'g' => const Color(0xFF43A047),
  'p' || 's' || 'b' || 'o' => const Color(0xFF1E88E5),
  'm' || 'c' => const Color(0xFF8D6E63),
  'd' => const Color(0xFFC0A16B),
  'f' || 't' => const Color(0xFF78909C),
  'v' || 'n' => const Color(0xFF8E24AA),
  'h' => const Color(0xFF039BE5),
  'k' => const Color(0xFFE53935),
  _ => const Color(0xFF9E9E9E),
};

/// Display name of a map region id (English id or legacy Chinese), mirroring the plugin.
String pokemonRegionName(String region) => switch (region) {
  'central' || '中央' => '中央地区',
  'north' || '北部' || '东北' => '北部地区',
  'east' || '东部' || '东南' => '东部地区',
  'south' || '南部' || '西南' => '南部地区',
  'west' || '西部' || '西北' => '西部地区',
  'ocean' || '海洋' => '海洋地区',
  'cave' || '洞窟' || '山洞' => '洞窟地区',
  'mountain' || '山脉' || '山谷' => '山脉地区',
  'sky' || '天空' => '天空地区',
  'desert' || '沙漠' => '沙漠地区',
  'city' || '城市' => '城市地区',
  'volcano' || '火山' => '火山地区',
  'wild' || '野外' => '野外地区',
  'special' || '特殊' => '特殊地区',
  _ => region.isEmpty ? '未知地区' : region,
};

/// Sort order of a map region, mirroring the plugin. Accepts both the raw id and the display name.
int pokemonRegionOrder(String region) =>
    switch (region.endsWith('地区') ? region.substring(0, region.length - 2) : region) {
  'central' || '中央' => 1,
  'north' || '北部' || '东北' => 2,
  'east' || '东部' || '东南' => 3,
  'south' || '南部' || '西南' => 4,
  'west' || '西部' || '西北' => 5,
  'ocean' || '海洋' => 6,
  'cave' || '洞窟' || '山洞' => 7,
  'mountain' || '山脉' || '山谷' => 8,
  'sky' || '天空' => 9,
  'desert' || '沙漠' => 10,
  'city' || '城市' => 11,
  'volcano' || '火山' => 12,
  'wild' || '野外' => 13,
  'special' || '特殊' => 14,
  _ => 99,
};

/// Difficulty of a map for a trainer with a given strongest pokemon level.
enum AdventureAdvice {
  /// The map is at or below the trainer's level.
  good,

  /// The map is a bit above the trainer's level.
  risky,

  /// The map is well above the trainer's level.
  danger,

  /// The trainer's level is so far above the map that the experience is barely worth the fight.
  lowReward,

  /// The trainer has no pokemon.
  unknown,
}

/// Advice for a map given the level of the pokemon that would fight (null when there is none).
///
/// Mirrors `get_recommendation` in the website's front-end (`rust/game/src/pages/adventure.rs`), including the "+10"
/// margin above the map's maximum level at which the fight stops being worth it.
AdventureAdvice adventureAdviceFor({required int minLevel, required int maxLevel, int? trainerLevel}) {
  if (trainerLevel == null || trainerLevel <= 0) return AdventureAdvice.unknown;
  if (trainerLevel < minLevel) return AdventureAdvice.danger;
  if (trainerLevel > maxLevel + 10) return AdventureAdvice.lowReward;
  if (trainerLevel <= maxLevel) return AdventureAdvice.good;
  return AdventureAdvice.risky;
}

/// Localized text of the state the server reports as [state].
///
/// The plugin answers a Chinese `state_text` (see `get_pokemon_state_text` in `plugin/api/pokemon.php`) and has no
/// stable code for the UI, so the client maps the numeric state it already mirrors for `Pokemon.needsHealing`. A state
/// a future plugin build adds still falls back to [serverText], which is better than showing nothing.
String pokemonStateText(BuildContext context, int state, String serverText) {
  final tr = context.t.pokemon;
  return switch (state) {
    1 => tr.stateNormal,
    2 || 3 || 4 => tr.stateSick,
    5 || 6 => tr.stateHungry,
    7 => tr.stateTired,
    8 || 9 || 10 => tr.stateExcited,
    11 => tr.stateHurt,
    12 || 13 || 14 => tr.stateHappy,
    15 => tr.statePanicked,
    16 || 17 => tr.stateVain,
    18 || 19 => tr.stateAngry,
    20 || 21 || 22 => tr.stateWeak,
    _ => serverText.isEmpty ? tr.stateCritical : serverText,
  };
}
