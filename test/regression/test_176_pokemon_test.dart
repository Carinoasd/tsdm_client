import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';

/// Tests of the pokemon (宠物中心) plugin JSON models and image url builders.
///
/// The plugin answers `plugin.php?id=pokemon:pokemon&endpoint=X&action=Y` with a `{success, data, ...}` envelope whose
/// `data` object shapes are mirrored here from `pokemon_system/api/*.php`.
void main() {
  group('PokemonMapper', () {
    test('decodes a list item', () {
      final pokemon = Pokemon.fromMap(_pokemonMap);
      expect(pokemon.id, 123);
      expect(pokemon.name, '皮卡丘');
      expect(pokemon.typeId, 25);
      expect(pokemon.level, 50);
      expect(pokemon.isShiny, isFalse);
      expect(pokemon.stateText, '正常');
      expect(pokemon.displayName, '皮卡丘');
      expect(pokemon.skills, hasLength(4));
      expect(pokemon.skills.first.name, '撞击');
      expect(pokemon.skills.last.isEmpty, isTrue);
      expect(pokemon.baseInfo.type1, '电');
      expect(pokemon.baseInfo.type2, isNull);
      expect(pokemon.stats, isNull);
    });

    test('uses the nickname when set', () {
      final pokemon = Pokemon.fromMap({..._pokemonMap, 'nickname': '雷电球'});
      expect(pokemon.displayName, '雷电球');
    });

    test('decodes the detail stats', () {
      final pokemon = Pokemon.fromMap({
        ..._pokemonMap,
        'stats': {'hp': 150, 'attack': 80, 'defense': 60, 'sp_attack': 95, 'sp_defense': 70, 'speed': 100},
      });
      expect(pokemon.stats, isNotNull);
      expect(pokemon.stats!.spAttack, 95);
      expect(pokemon.stats!.spDefense, 70);
      expect(pokemon.stats!.speed, 100);
    });

    test('computes the exp progress', () {
      final pokemon = Pokemon.fromMap(_pokemonMap);
      // exp 12500, current-level threshold 12000, next-level threshold 12500.
      expect(pokemon.expProgress, closeTo(1.0, 0.001));
    });
  });

  group('PokemonUserProfileMapper', () {
    test('decodes the profile', () {
      final profile = PokemonUserProfile.fromMap({'uid': 2234424, 'username': '猫猫祟祟', 'money': 260});
      expect(profile.uid, 2234424);
      expect(profile.username, '猫猫祟祟');
      expect(profile.money, 260);
    });
  });

  group('ShopPageMapper', () {
    test('decodes items with the effect type renamed from "type"', () {
      final page = ShopPage.fromMap(_shopPageMap);
      expect(page.items, hasLength(1));
      final item = page.items.first;
      expect(item.name, '伤药');
      expect(item.price, 100);
      expect(item.canBuy, isTrue);
      expect(item.effect.effectType, 'heal');
      expect(item.effect.addhp, 20);
    });
  });

  group('InventoryPageMapper', () {
    test('decodes the inventory', () {
      final page = InventoryPage.fromMap(_inventoryPageMap);
      expect(page.items, hasLength(1));
      expect(page.items.first.name, '伤药');
      expect(page.items.first.quantity, 10);
      expect(page.items.first.canUse, isTrue);
    });
  });

  group('GlobalConfig', () {
    test('decodes a well-typed config', () {
      final config = GlobalConfig.fromJson({'is_open': true, 'version': '3.0.0-rc1', 'medical_price': 10});
      expect(config.isOpen, isTrue);
      expect(config.version, '3.0.0-rc1');
      expect(config.medicalPrice, 10);
    });

    test('tolerates string and numeric values', () {
      final config = GlobalConfig.fromJson({
        'is_open': '1',
        'version': 300,
        'medical_price': '20',
        'is_enable_catch': '0',
      });
      expect(config.isOpen, isTrue);
      expect(config.version, '300');
      expect(config.medicalPrice, 20);
      expect(config.isEnableCatch, isFalse);
    });
  });

  group('tolerant decode (missing fields)', () {
    test('InventoryItem tolerates a missing nums field (production report)', () {
      final item = InventoryItem.fromMap(const {
        'id': 97332,
        'type_id': 2,
        'item_type': 4,
        'name': '奇异糖果',
        'image': 'lvupitem',
        'quantity': 36,
        'type_name': '强化道具',
        'can_use': true,
      });
      expect(item.name, '奇异糖果');
      expect(item.nums, 0);
      expect(item.quantity, 36);
    });

    test('Pokemon tolerates a missing site field (detail response)', () {
      final pokemon = Pokemon.fromMap(const {
        'id': 345908,
        'name': '火红不倒翁',
        'nickname': '火红不倒翁',
        'type_id': 554,
        'level': 5,
        'hp': 23,
        'max_hp': 23,
        'gender': 1,
        'is_shiny': false,
      });
      expect(pokemon.name, '火红不倒翁');
      expect(pokemon.site, 0);
      expect(pokemon.level, 5);
      expect(pokemon.skills, isEmpty);
    });
  });

  group('pokemon image urls', () {
    test('build the cdn and local image urls', () {
      expect(pokemonImageUrl(25), 'https://img.tsdm39.com/Pokemon/pm/25.gif');
      expect(pokemonBattleBackImageUrl(25), 'https://img.tsdm39.com/Pokemon/pmb/25.gif');
      expect(
        pokemonSmallImageUrl(25),
        'https://www.tsdm39.com/source/plugin/pokemon/images/spm/25.gif',
      );
      expect(
        pokemonItemImageUrl('hp'),
        'https://www.tsdm39.com/source/plugin/pokemon/images/item/hp.gif',
      );
    });
  });
}

const _pokemonMap = <String, dynamic>{
  'id': 123,
  'name': '皮卡丘',
  'nickname': null,
  'type_id': 25,
  'level': 50,
  'exp': 12500,
  'exp_to_next_level': 0,
  'exp_for_current_level': 12000,
  'exp_for_next_level': 12500,
  'hp': 120,
  'max_hp': 150,
  'gender': 1,
  'is_shiny': false,
  'quality': 'S',
  'site': 1,
  'state': 1,
  'state_text': '正常',
  'state_class': 'normal',
  'affection': 100,
  'skills': [
    {'type_id': 1, 'pp': 35, 'name': '撞击', 'skill_type': '普通', 'category': '物攻', 'level': 1, 'power': 40, 'max_pp': 35},
    {'type_id': 2, 'pp': 25, 'name': '十万伏特', 'skill_type': '电', 'category': '特攻', 'level': 26, 'power': 90, 'max_pp': 15},
    {'type_id': 0, 'pp': 0, 'name': '', 'skill_type': '', 'category': '', 'level': 0, 'power': 0, 'max_pp': 0},
    {'type_id': 0, 'pp': 0, 'name': '', 'skill_type': '', 'category': '', 'level': 0, 'power': 0, 'max_pp': 0},
  ],
  'base_info': {'id': 25, 'name': '皮卡丘', 'type_1': '电', 'type_2': null, 'image': '', 'description': '老鼠宝可梦'},
};

const _shopPageMap = <String, dynamic>{
  'items': [
    {
      'id': 1,
      'name': '伤药',
      'description': '回复 20 点 HP',
      'type_id': 1,
      'type_name': '回复药',
      'image': 'hp',
      'price': 100,
      'stock': 99,
      'effect': {'description': '回复 20 点 HP', 'type': 'heal', 'addhp': 20, 'addexp': 0, 'addlv': 0},
      'can_buy': true,
    },
  ],
  'total': 1,
  'page': 1,
  'per_page': 20,
  'total_pages': 1,
};

const _inventoryPageMap = <String, dynamic>{
  'items': [
    {
      'id': 1,
      'type_id': 1,
      'item_type': 1,
      'name': '伤药',
      'description': '回复 20 点 HP',
      'image': 'hp',
      'quantity': 10,
      'nums': 10,
      'type_name': '回复药',
      'can_use': true,
      'addhp': 20,
    },
  ],
  'total': 1,
  'page': 1,
  'per_page': 20,
  'total_pages': 1,
};
