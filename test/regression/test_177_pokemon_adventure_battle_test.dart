import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';

/// Tests of the adventure maps and battle scene models.
void main() {
  group('adventureAdviceFor', () {
    // The thresholds mirror the website's `get_recommendation` in `rust/game/src/pages/adventure.rs`.
    test('warns when the level is far above the map', () {
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8, trainerLevel: 19), AdventureAdvice.lowReward);
      // The margin is ten levels, so one level less is still worth fighting.
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8, trainerLevel: 18), AdventureAdvice.risky);
    });

    test('recommends a map the fighting pokemon fits', () {
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8, trainerLevel: 3), AdventureAdvice.good);
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8, trainerLevel: 8), AdventureAdvice.good);
    });

    test('calls a map above the level dangerous, and one without a pokemon unknown', () {
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8, trainerLevel: 2), AdventureAdvice.danger);
      // No pokemon yet: leaving the level out is the same as passing null.
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8), AdventureAdvice.unknown);
      expect(adventureAdviceFor(minLevel: 3, maxLevel: 8, trainerLevel: 0), AdventureAdvice.unknown);
    });
  });

  group('AdventureMap', () {
    test('decodes a wild map', () {
      final map = AdventureMap.fromMap(const {
        'id': 1,
        'name': '常磐森林',
        'area_type': 'l',
        'area_type_name': '平原',
        'region': '野外',
        'pos_x': 38,
        'pos_y': 38,
        'is_enabled': true,
        'min_level': 3,
        'max_level': 8,
        'mode': 'wild',
        'wild_pokemons': [
          {'id': 10, 'name': '绿毛虫'},
          {'id': 16, 'name': '波波'},
        ],
      });
      expect(map.name, '常磐森林');
      expect(map.areaTypeName, '平原');
      expect(map.minLevel, 3);
      expect(map.maxLevel, 8);
      expect(map.mode, 'wild');
      expect(map.hasBoss, isFalse);
      expect(map.wildPokemons, hasLength(2));
      expect(map.wildPokemons.first.name, '绿毛虫');
    });

    test('decodes a boss map with bosses', () {
      final map = AdventureMap.fromMap(const {
        'id': 2,
        'name': '冠军之路',
        'area_type': 'm',
        'area_type_name': '山谷',
        'region': '北部',
        'pos_x': 30,
        'pos_y': 25,
        'is_enabled': true,
        'min_level': 45,
        'max_level': 60,
        'mode': 'boss',
        'wild_pokemons': <Map<String, dynamic>>[],
        'bosses': [
          {'pokemon_type_id': 149, 'pokemon_name': '快龙', 'level': 50, 'boss_multiplier': 1.5},
        ],
      });
      expect(map.mode, 'boss');
      expect(map.hasBoss, isTrue);
      expect(map.bosses, hasLength(1));
      expect(map.bosses!.first.pokemonName, '快龙');
      expect(map.bosses!.first.level, 50);
      expect(map.bosses!.first.bossMultiplier, 1.5);
    });
  });

  group('BattleScene', () {
    test('decodes an active battle', () {
      final scene = BattleScene.fromMap(_activeScene);
      expect(scene.isActive, isTrue);
      expect(scene.battleId, 'battle_123.456');
      expect(scene.mapName, '常磐森林');
      expect(scene.turn, 1);
      expect(scene.myPokemon.name, '皮卡丘');
      expect(scene.myPokemon.skills.first.name, '撞击');
      expect(scene.myPokemon.skills.first.usable, isTrue);
      expect(scene.wildPokemon.isBoss, isFalse);
      expect(scene.rewards, isNull);
    });

    test('decodes a victory with rewards and level-up', () {
      final scene = BattleScene.fromMap({
        ..._activeScene,
        'turn': 2,
        'status': 'victory',
        'message': '野生的波波倒下了！',
        'rewards': {'exp': 120, 'money': 80},
        'level_up': {'level_up': true, 'old_level': 10, 'new_level': 11, 'new_exp': 300},
      });
      expect(scene.isActive, isFalse);
      expect(scene.status, 'victory');
      expect(scene.rewards, isNotNull);
      expect(scene.rewards!.exp, 120);
      expect(scene.rewards!.money, 80);
      expect(scene.levelUp, isNotNull);
      expect(scene.levelUp!.newLevel, 11);
    });
  });

  group('BattleItem', () {
    test('decodes an HP potion and a PP restore item', () {
      final potion = BattleItem.fromMap(const {
        'id': 1,
        'name': '伤药',
        'img': 'hp',
        'nums': 5,
        'item_type': 1,
        'module': '',
        'addhp': 20,
      });
      expect(potion.addhp, 20);
      expect(potion.itemType, 1);

      final pp = BattleItem.fromMap(const {
        'id': 30,
        'name': 'PP回复',
        'img': 'pp',
        'nums': 2,
        'item_type': 4,
        'module': 'pp10',
      });
      expect(pp.addhp, isNull);
      expect(pp.module, 'pp10');
    });
  });
}

const _activeScene = <String, dynamic>{
  'battle_id': 'battle_123.456',
  'map_id': 1,
  'map_name': '常磐森林',
  'turn': 1,
  'my_pokemon': {
    'id': 25,
    'instance_id': 1,
    'name': '皮卡丘',
    'level': 10,
    'hp': 150,
    'max_hp': 150,
    'is_shiny': false,
    'quality': 'S',
    'skills': [
      {'id': 1, 'name': '撞击', 'power': 40, 'pp': 35, 'max_pp': 35, 'skill_type': '普通', 'category': '物攻'},
    ],
  },
  'wild_pokemon': {
    'id': 16,
    'name': '波波',
    'level': 5,
    'hp': 60,
    'max_hp': 60,
    'gender': 0,
    'is_shiny': false,
    'is_boss': false,
    'boss_multiplier': 1.0,
  },
  'status': 'active',
  'message': '野生的波波出现了！',
};
