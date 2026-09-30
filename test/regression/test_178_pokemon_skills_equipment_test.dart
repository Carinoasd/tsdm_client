import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/features/pokemon/repository/skill_order_store.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Tests of the pokemon skill, equipment and pet-shop JSON models, of the localized plugin error mapping and of the
/// status bar availability flag.
///
/// Shapes are mirrored from `pokemon_system/api/pokemon.php` (`learnable_skills`, `equipment`) and
/// `pokemon_system/api/shop.php` (`pets`, `buy_pet`).
void main() {
  group('LearnableSkillsMapper', () {
    test('decodes available and unlocked skills', () {
      final skills = LearnableSkills.fromMap({
        'pokemon_id': 12,
        'pokemon_level': 20,
        'available_skills': [
          {
            'id': 7,
            'name': '电击',
            'description': '电属性的攻击',
            'type': '电',
            'category': '特攻',
            'power': 40,
            'max_pp': 30,
            'required_level': 5,
            'is_available': true,
          },
        ],
        'unlocked_skills': [
          {'id': 9, 'name': '十万伏特', 'required_level': 40, 'is_available': false},
        ],
      });
      expect(skills.pokemonId, 12);
      expect(skills.pokemonLevel, 20);
      expect(skills.availableSkills, hasLength(1));
      expect(skills.availableSkills.single.name, '电击');
      expect(skills.availableSkills.single.power, 40);
      expect(skills.availableSkills.single.maxPp, 30);
      expect(skills.availableSkills.single.isAvailable, isTrue);
      expect(skills.unlockedSkills.single.requiredLevel, 40);
      expect(skills.unlockedSkills.single.category, '');
    });

    test('tolerates missing lists', () {
      final skills = LearnableSkills.fromMap({'pokemon_id': 1});
      expect(skills.availableSkills, isEmpty);
      expect(skills.unlockedSkills, isEmpty);
    });
  });

  group('EquipmentResponseMapper', () {
    test('decodes slots, owned and shop items', () {
      final data = EquipmentResponse.fromMap({
        'pokemon_id': 5,
        'user_money': 900,
        'equipment_slots': [
          {'slot_index': 0, 'equipment_id': 0, 'item': null},
          {
            'slot_index': 1,
            'equipment_id': 42,
            'item': {
              'myitem_id': 42,
              'type_id': 3,
              'name': '力量腰带',
              'description': '增加攻击',
              'image': 'belt.png',
              'zbtype': 1,
              'equipment_hp': 0,
              'equipment_atk': 10,
              'equipment_def': 0,
              'equipment_spatk': 0,
              'equipment_spdef': 0,
              'equipment_sd': 0,
            },
          },
        ],
        'owned_items': [
          {
            'myitem_id': 43,
            'type_id': 4,
            'name': '护腕',
            'quantity': 2,
            'equipped_count': 1,
            'available_count': 1,
            'is_equipped': false,
            'equipment_atk': 5,
          },
        ],
        'shop_items': [
          {'type_id': 9, 'name': '头盔', 'price': 500, 'is_owned': false, 'can_buy': true, 'equipment_def': 8},
        ],
      });
      expect(data.pokemonId, 5);
      expect(data.userMoney, 900);
      expect(data.equipmentSlots, hasLength(2));
      expect(data.equipmentSlots.first.item, isNull);
      expect(data.equipmentSlots[1].item!.name, '力量腰带');
      expect(data.equipmentSlots[1].item!.equipmentAtk, 10);
      expect(data.ownedItems.single.availableCount, 1);
      expect(data.ownedItems.single.hasNoBonus, isFalse);
      expect(data.shopItems.single.price, 500);
      expect(data.shopItems.single.canBuy, isTrue);
    });

    test('a plain item has no bonus', () {
      final item = OwnedEquipment.fromMap({'myitem_id': 1, 'type_id': 2, 'name': 'x'});
      expect(item.hasNoBonus, isTrue);
    });
  });

  group('ShopPetsPageMapper', () {
    test('decodes a pet page', () {
      final page = ShopPetsPage.fromMap({
        'pets': [
          {
            'id': 25,
            'name': '皮卡丘',
            'type_1': '电',
            'type_2': null,
            'hp': 35,
            'atk': 55,
            'def': 40,
            'spatk': 50,
            'spdef': 50,
            'speed': 90,
            'price': 1000,
            'can_buy': true,
          },
        ],
        'total': 3,
        'page': 1,
        'per_page': 20,
        'total_pages': 1,
      });
      expect(page.pets.single.name, '皮卡丘');
      expect(page.pets.single.type2, isNull);
      expect(page.pets.single.speed, 90);
      expect(page.pets.single.canBuy, isTrue);
      expect(page.total, 3);
      expect(page.totalPages, 1);
    });
  });

  group('BuyPetResultMapper', () {
    test('decodes the purchase answer', () {
      final result = BuyPetResult.fromMap({
        'message': 'Purchase successful',
        'total_cost': 1000,
        'remaining_money': 250,
        'pokemon_name': '皮卡丘',
        'pokemon_type_id': 25,
        'site': 2,
        'quantity': 1,
      });
      expect(result.totalCost, 1000);
      expect(result.remainingMoney, 250);
      expect(result.pokemonName, '皮卡丘');
      expect(result.site, 2);
    });
  });

  group('ShopCategory', () {
    test('maps categories to query types and the pet listing', () {
      expect(ShopCategory.all.type, isNull);
      expect(ShopCategory.all.isPet, isFalse);
      expect(ShopCategory.med.type, 1);
      expect(ShopCategory.equipment.type, 5);
      expect(ShopCategory.pet.isPet, isTrue);
      expect(ShopCategory.pet.type, isNull);
    });
  });

  group('pokemonMessageHint', () {
    testWidgets("the plugin's english errors are localized", (tester) async {
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.en));
      late BuildContext context;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (innerContext) {
                context = innerContext;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Production answers an action its build does not implement with a plain english "Invalid action" (it has no
      // `toggle_status_bar`), so it must never reach the user verbatim.
      expect(pokemonMessageHint(context, 'Invalid action'), t.pokemon.actionUnsupported);
      // A battle the server no longer has reads as an explanation instead of that raw English.
      expect(pokemonMessageHint(context, 'No active battle found'), t.pokemon.battleEnded);
      expect(
        pokemonMessageHint(context, 'Skill slots are full. Please forget a skill first.'),
        t.pokemon.skillSlotsFull,
      );
      expect(pokemonMessageHint(context, 'Skill already learned'), t.pokemon.skillAlreadyLearned);
      expect(
        pokemonMessageHint(context, 'Cannot forget skill with PP not full. Current PP: 3/20'),
        t.pokemon.skillPpNotFull,
      );
      expect(pokemonMessageHint(context, '箱子容量不足，请扩展！'), t.pokemon.boxFullHint);
      // The login guard's answer (401, or a bodyless 403 on newer plugin builds) becomes the login prompt.
      expect(pokemonMessageHint(context, '需要登录'), t.pokemon.loginRequired);
      // The plugin's cross-site check, which the client retries after reading a fresh formhash.
      expect(pokemonMessageHint(context, 'formhash 校验失败，请刷新页面后重试'), t.pokemon.formHashFailed);
      // Anything else (the plugin's own chinese messages) passes through unchanged.
      expect(pokemonMessageHint(context, '徽章已刷新'), '徽章已刷新');
    });
  });

  group('pokemonStateText', () {
    testWidgets('maps the state codes the plugin mirrors to localized text', (tester) async {
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.en));
      late BuildContext context;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (innerContext) {
                context = innerContext;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The plugin's own `state_text` is Chinese; the numbers it sends mean the same in every locale, so the views read
      // those instead of what the server wrote.
      expect(pokemonStateText(context, 1, '正常'), 'Normal');
      expect(pokemonStateText(context, 9, '兴奋'), 'Excited');
      expect(pokemonStateText(context, 15, '惊慌'), 'Panicked');
      expect(pokemonStateText(context, 20, '虚弱'), 'Weak');
      // A state a future plugin build adds keeps the server's own text, which beats showing nothing.
      expect(pokemonStateText(context, 99, '未知状态'), '未知状态');
    });
  });

  group('SkillOrderStore.apply', () {
    List<BattleSkill> battleSkills(List<int> ids) => [
      for (final id in ids) BattleSkill.fromMap({'id': id, 'name': 'skill-$id'}),
    ];

    test('sorts battle skills into the saved order', () {
      final ordered = SkillOrderStore.apply(battleSkills([9, 4, 7]), [7, 4, 9], (s) => s.id);
      expect(ordered.map((s) => s.id).toList(), [7, 4, 9]);
    });

    test('skills missing from the saved order keep their place at the end', () {
      // A freshly learned skill is not in the saved order yet and must still show up, last.
      final ordered = SkillOrderStore.apply(battleSkills([9, 4, 7, 11]), [7, 4, 9], (s) => s.id);
      expect(ordered.map((s) => s.id).toList(), [7, 4, 9, 11]);
    });

    test('an empty saved order leaves the list untouched', () {
      final ordered = SkillOrderStore.apply(battleSkills([9, 4]), const [], (s) => s.id);
      expect(ordered.map((s) => s.id).toList(), [9, 4]);
    });

    test('works on the detail page skill type too', () {
      final skills = [
        PokemonSkill.fromMap({'type_id': 3}),
        PokemonSkill.fromMap({'type_id': 1}),
      ];
      final ordered = SkillOrderStore.apply(skills, [1, 3], (s) => s.typeId);
      expect(ordered.map((s) => s.typeId).toList(), [1, 3]);
    });
  });

  group('status bar state', () {
    test('the profile reports the status bar state only when the plugin supports it', () {
      // The menu entry is gated on this field: the production plugin has no status bar action and no such field.
      expect(PokemonUserProfile.fromMap({'uid': 1}).statusBarHidden, isNull);
      expect(PokemonUserProfile.fromMap({'uid': 1, 'status_bar_hidden': false}).statusBarHidden, isFalse);
      expect(PokemonUserProfile.fromMap({'uid': 1, 'status_bar_hidden': true}).statusBarHidden, isTrue);
    });
  });

  group('statusBarHiddenFromBadge', () {
    test('reads the hidden flag of the badge answer', () {
      // The website's status bar switch is `refresh_badge` with {"hide": bool}; its answer carries the new state.
      expect(statusBarHiddenFromBadge({'message': '帖子徽章已隐藏', 'hidden': true}), isTrue);
      expect(statusBarHiddenFromBadge({'message': '帖子徽章已刷新', 'hidden': false}), isFalse);
      // A build whose refresh_badge predates the parameter answers without the field.
      expect(statusBarHiddenFromBadge({'message': '徽章已刷新'}), isNull);
    });
  });

  group('Pokemon.needsHealing', () {
    Pokemon pokemon({
      int hp = 20,
      int maxHp = 20,
      int state = 1,
      int site = 1,
      List<Map<String, dynamic>> skills = const [],
    }) => Pokemon.fromMap({
      'id': 7,
      'hp': hp,
      'max_hp': maxHp,
      'state': state,
      'site': site,
      'skills': skills,
    });

    test('does nothing for a healthy carried pet', () {
      expect(pokemon().needsHealing, isFalse);
    });

    test('heals a pet that lost HP', () {
      expect(pokemon(hp: 3).needsHealing, isTrue);
    });

    test('heals a pet that only spent skill PP', () {
      expect(pokemon(skills: [{'type_id': 9, 'pp': 1, 'max_pp': 10}]).needsHealing, isTrue);
      // An empty skill slot is not a skill and must not ask for a heal on its own.
      expect(pokemon(skills: [{'type_id': 0, 'pp': 0, 'max_pp': 0}]).needsHealing, isFalse);
    });

    test('heals a pet in a negative state', () {
      for (final state in Pokemon.negativeStates) {
        expect(pokemon(state: state).needsHealing, isTrue, reason: 'state $state is negative');
        expect(pokemon(state: state).isNegativeState, isTrue, reason: 'state $state is negative');
      }
    });

    test('leaves the positive and neutral states alone', () {
      // The plugin heal only resets its negative set: 兴奋 (8-10), 快乐 (12-14), 自恋 (16-17) and 愤怒 (18-19) are
      // deliberately left as they are, so treating them as "needs healing" asks for a heal that changes nothing and
      // reports the same pet as healed on every single fight.
      for (final state in [8, 9, 10, 12, 13, 14, 16, 17, 18, 19]) {
        expect(pokemon(state: state).isNegativeState, isFalse, reason: 'state $state is not negative');
        expect(pokemon(state: state).needsHealing, isFalse, reason: 'state $state must not ask for a heal');
      }
    });

    test('knows the negative states the plugin grew over time', () {
      // 虚弱 (20-22) only joined the plugin's list later, so the set must not be the first version of it.
      expect(Pokemon.negativeStates, containsAll(const [0, 2, 3, 4, 5, 6, 7, 11, 15, 20, 21, 22]));
      for (final state in [20, 21, 22]) {
        expect(pokemon(state: state).needsHealing, isTrue, reason: 'state $state is negative');
      }
    });

    test('leaves pokemon in the storage alone', () {
      expect(pokemon(hp: 0, site: 3).needsHealing, isFalse);
    });
  });

  group('EvolutionPath', () {
    test('decodes the chain the website shows', () {
      final path = EvolutionPath.fromMap(const {
        'pokemon_id': 25,
        'pokemon_name': '皮卡丘',
        'pokemon_type1': '电',
        'pokemon_type2': null,
        'forward': [
          {'id': 26, 'name': '雷丘', 'type_1': '电', 'type_2': null, 'condition_display': '使用雷之石'},
        ],
        'backward': [
          {'id': 172, 'name': '皮丘', 'type_1': '电', 'type_2': null, 'condition_display': ''},
        ],
      });

      expect(path.pokemonName, '皮卡丘');
      expect(path.isEmpty, isFalse);
      expect(path.forward.single.name, '雷丘');
      expect(path.forward.single.conditionDisplay, '使用雷之石');
      expect(path.backward.single.id, 172);
    });

    test('a pokemon without a chain decodes to an empty one', () {
      final path = EvolutionPath.fromMap(const {'pokemon_id': 1, 'pokemon_name': 'x'});

      expect(path.isEmpty, isTrue);
    });
  });

  group('formHashOf', () {
    test('reads the formhash the plugin API asks for', () {
      // The hidden input Discuz renders in its forms.
      expect(formHashOf('<input type="hidden" name="formhash" value="880b8aa1" />'), '880b8aa1');
      // The inline script the plugin's own front-end reads it from.
      expect(formHashOf("const formhash = '43749fab'; window.fetch = ..."), '43749fab');
      expect(formHashOf('<html>no hash here</html>'), isNull);
    });
  });

  group('petNeedsHealingMessage', () {
    test('recognises the refusal that asks for the pokemon center', () {
      expect(petNeedsHealingMessage('你的宠物已晕倒，请先前往宠物中心治疗！'), isTrue);
      expect(petNeedsHealingMessage('你的宠物处于异常状态，请先前往宠物中心治疗！'), isTrue);
      expect(petNeedsHealingMessage('No active battle'), isFalse);
      expect(petNeedsHealingMessage(null), isFalse);
    });

    test('petNeedsHealingError only matches that failure', () {
      expect(petNeedsHealingError(PokemonApiException('你的宠物已晕倒，请先前往宠物中心治疗！')), isTrue);
      expect(petNeedsHealingError(PokemonApiException('No active battle')), isFalse);
      expect(petNeedsHealingError('not an exception'), isFalse);
    });
  });
}
