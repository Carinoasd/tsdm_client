import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/features/pokemon/utils/item_merge.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_count_label.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';

/// Tests of the pokemon helpers that need neither a network nor a widget: the inventory merge, the carried/box counter
/// and the adventure cache's bookkeeping of the battles the player already finished.
void main() {
  // The adventure cache is a singleton that checks the account before it hands out what it remembered.
  setUp(() {
    getIt.registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(username: 'Alice', uid: 1), const {}));
  });
  tearDown(getIt.reset);

  InventoryItem item(int typeId, {int quantity = 1, int nums = 1}) =>
      InventoryItem.fromMap({'type_id': typeId, 'quantity': quantity, 'nums': nums});

  Pokemon pokemon(int id, {int site = 1}) => Pokemon.fromMap({'id': id, 'site': site});

  group('mergeInventoryItems', () {
    test('sums the stacks of one item and keeps the order it first appeared in', () {
      final merged = mergeInventoryItems([
        item(3, quantity: 2, nums: 5),
        item(1),
        item(3, quantity: 4, nums: 6),
      ]);

      expect(merged.map((i) => i.typeId).toList(), [3, 1]);
      expect(merged.first.quantity, 6);
      expect(merged.first.nums, 11);
    });

    test('leaves a lone stack alone', () {
      final merged = mergeInventoryItems([item(7, quantity: 3, nums: 2)]);

      expect(merged, hasLength(1));
      expect(merged.single.quantity, 3);
      expect(merged.single.nums, 2);
    });

    test('an empty page stays empty', () => expect(mergeInventoryItems(const []), isEmpty));
  });

  group('carriedAndBoxed', () {
    test('counts the carried pokemon apart from the ones in the storage box', () {
      final counts = carriedAndBoxed([pokemon(1), pokemon(2, site: 2), pokemon(3, site: 3), pokemon(4, site: 3)]);

      expect(counts.carried, 2);
      expect(counts.boxed, 2);
    });
  });

  group('AdventureCache finished battles', () {
    BattleScene scene({int mapId = 3, int wildId = 25, int instanceId = 7}) => BattleScene.fromMap({
      'map_id': mapId,
      'wild_pokemon': {'id': wildId},
      'my_pokemon': {'instance_id': instanceId},
    });

    test('remembers the battle it was told about, and only that one', () {
      final cache = AdventureCache();
      final battle = scene();
      expect(cache.isBattleFinished(battle), isFalse);

      cache.markBattleFinished(battle);

      expect(cache.isBattleFinished(battle), isTrue);
      // The same map against another wild pokemon, or with another of the player's pokemon, is a different battle.
      expect(cache.isBattleFinished(scene(wildId: 26)), isFalse);
      expect(cache.isBattleFinished(scene(instanceId: 8)), isFalse);
      expect(cache.isBattleFinished(scene(mapId: 4)), isFalse);
    });

    test('forgets every finished battle once the server reports none at all', () {
      final cache = AdventureCache()
        ..markBattleFinished(scene())
        ..clearFinishedBattles();

      expect(cache.isBattleFinished(scene()), isFalse);
    });

    test('forgets what the previous account remembered', () async {
      final cache = AdventureCache()..markBattleFinished(scene());

      // The cache is a singleton, so switching account must not hand the previous one's battles to the new player.
      await getIt.unregister<CookieProvider>();
      getIt.registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(username: 'Bob', uid: 2), const {}));

      expect(cache.isBattleFinished(scene()), isFalse);
    });
  });
}
