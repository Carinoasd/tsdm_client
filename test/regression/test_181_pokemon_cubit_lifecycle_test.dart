import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/pokemon/cubit/battle_cubit.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

/// Regression test of the pokemon centre's page cubit lifecycle.
///
/// The page fires its load and may well be gone before the answers arrive — the forum takes seconds to answer and the
/// player taps through the menu meanwhile. The status bar switch has the same problem from the other side: its request
/// can be parked by the platform client when the app goes to the background, so the switch must not depend on the
/// answer arriving while the app is still in the foreground.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));

  /// The status bar state the fake forum keeps, so its switch and its profile agree.
  late bool serverStatusBarHidden;

  /// Paths of the requests the cubit made, so a test can tell what an action touched.
  late List<String> paths;

  /// Answer every request after [delay] from a forum that keeps [serverStatusBarHidden].
  ///
  /// With [turnFails] a battle turn loses the transport (no answer at all); [recoverDelay] holds the read-back after
  /// such a failure open; [recoveredScene] is what that read-back finds and [startedScene] what the next battle start
  /// answers, so a scene that changed while an answer was lost can be told apart from the one that was read back.
  /// [turnDelay] holds a battle turn open and [pageTwoDelay] the second page of a list, so a newer action or a category
  /// switch can overtake them.
  void useFakeForum({
    Duration delay = Duration.zero,
    bool turnFails = false,
    Duration turnDelay = Duration.zero,
    Duration pageTwoDelay = Duration.zero,
    Duration recoverDelay = Duration.zero,
    Map<String, dynamic>? recoveredScene,
    Map<String, dynamic>? startedScene,
  }) {
    serverStatusBarHidden = false;
    paths = [];

    String answer(Uri uri, Object? body) {
      final action = uri.queryParameters['action'];
      // The page the client reads the session formhash from.
      if (uri.queryParameters['id'] == 'pokemon:game') {
        return '<input type="hidden" name="formhash" value="deadbeef">';
      }
      if (action == 'recover' && recoveredScene != null) {
        return jsonEncode({'success': true, 'data': recoveredScene});
      }
      if (action == 'start' && startedScene != null) {
        return jsonEncode({'success': true, 'data': startedScene});
      }
      if (action == 'flee') {
        // A flee needs the battle id, which the end-of-battle answer lacks: only a caller that kept it can end the fight.
        final id = body is String ? (jsonDecode(body) as Map<String, dynamic>)['battle_id'] : null;
        final ended = id is String && id.isNotEmpty;
        return jsonEncode({
          'success': ended,
          'data': {'message': '已逃跑'},
          if (!ended) 'error': '不存在的战斗',
        });
      }
      if (action == 'refresh_badge') {
        final hide = body is String ? (jsonDecode(body) as Map<String, dynamic>)['hide'] : null;
        if (hide is bool) serverStatusBarHidden = hide;
        return jsonEncode({
          'success': true,
          'data': {'message': '已设置', 'hidden': serverStatusBarHidden},
        });
      }
      if (action == 'profile') {
        return jsonEncode({
          'success': true,
          'data': {'status_bar_hidden': serverStatusBarHidden},
        });
      }
      // Two pages of shop and bag items, so a load-more can advance the page counter.
      if (action == 'inventory' || (action == 'list' && uri.queryParameters['endpoint'] == 'shop')) {
        final page = int.tryParse(uri.queryParameters['page'] ?? '1') ?? 1;
        return jsonEncode({
          'success': true,
          'data': {'items': <Object>[], 'total': 30, 'page': page, 'per_page': 20, 'total_pages': 2},
        });
      }
      if (action == 'list') {
        return jsonEncode({
          'success': true,
          'data': {'pokemons': <Object>[]},
        });
      }
      return jsonEncode({'success': true, 'data': <String, dynamic>{}});
    }

    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            paths.add(options.uri.toString());
            if (delay > Duration.zero) {
              await Future<void>.delayed(delay);
            }
            if (options.uri.queryParameters['action'] == 'recover' && recoverDelay > Duration.zero) {
              await Future<void>.delayed(recoverDelay);
            }
            if (options.uri.queryParameters['action'] == 'turn' && turnDelay > Duration.zero) {
              await Future<void>.delayed(turnDelay);
            }
            if (options.uri.queryParameters['page'] == '2' && pageTwoDelay > Duration.zero) {
              await Future<void>.delayed(pageTwoDelay);
            }
            // A transport failure has no answer at all, which is what the client has to treat as a network problem.
            if (turnFails && options.uri.queryParameters['action'] == 'turn') {
              handler.reject(DioException(requestOptions: options, type: DioExceptionType.connectionTimeout));
              return;
            }
            handler.resolve(
              Response<dynamic>(requestOptions: options, statusCode: 200, data: answer(options.uri, options.data)),
            );
          },
        ),
      );
    final cookie = CookieProvider(const UserLoginInfo(username: 'Alice', uid: 1), const {});
    getIt
      ..registerSingleton<CookieProvider>(cookie)
      ..registerSingleton<AdventureCache>(AdventureCache())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<NetClientProvider>(NetClientProvider.buildNoCookie(dio: dio, cookie: cookie));
  }

  setUp(getIt.reset);
  tearDown(getIt.reset);

  test('a load that outlives its cubit does not emit into the closed one', () async {
    useFakeForum(delay: const Duration(milliseconds: 50));
    final cubit = PokemonCubit();

    final load = cubit.load();
    // The player leaves the page while the five requests are still in flight.
    await cubit.close();

    // Before the guard this completed with "Bad state: Cannot emit new states after calling close".
    await expectLater(load, completes);
  });

  test('the status bar switch flips before the slow forum answers', () async {
    useFakeForum(delay: const Duration(milliseconds: 200));
    final cubit = PokemonCubit();
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.profile?.statusBarHidden, isFalse);

    final switched = cubit.setStatusBar(hide: true);

    // The switch reads this value, and it has to show the new state while the call is still on its way.
    expect(cubit.state.profile?.statusBarHidden, isTrue);
    expect(serverStatusBarHidden, isFalse);

    await switched;
    expect(serverStatusBarHidden, isTrue);
    expect(cubit.state.profile?.statusBarHidden, isTrue);
  });

  test('an item action sends it and refreshes what it can change', () async {
    useFakeForum();
    final cubit = PokemonCubit();
    addTearDown(cubit.close);
    await cubit.load();
    paths.clear();

    final result = await cubit.useItem(42, pokemonId: 7);

    expect(result.success, isTrue);
    expect(paths.where((path) => path.contains('action=use_item')), hasLength(1));
    // Using an item changes the bag and, for an item aimed at one pet, the party.
    expect(paths.where((path) => path.contains('action=inventory')), hasLength(1));
    expect(paths.where((path) => path.contains('action=list')), hasLength(1));
  });

  test('the fight-again path heals the pet that just fought without reading the party again', () async {
    useFakeForum();
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    cubit.resume(
      BattleScene.fromMap(const {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 3, 'max_hp': 20},
        'wild_pokemon': {'id': 25},
      }),
    );
    paths.clear();

    await cubit.fightAgain(3);

    // The scene knows that pet is hurt, so the heal needs no party list; the next battle is asked for straight after.
    expect(paths.where((path) => path.contains('action=heal')), hasLength(1));
    expect(paths.where((path) => path.contains('action=list')), isEmpty);
    expect(paths.where((path) => path.contains('action=start')), hasLength(1));
  });

  test('reconcile reads the real state back', () async {
    useFakeForum();
    final cubit = PokemonCubit();
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.profile?.statusBarHidden, isFalse);

    // The row changed without the app knowing (another device, or a switch the platform client parked).
    serverStatusBarHidden = true;

    await cubit.reconcileStatusBar();

    expect(cubit.state.profile?.statusBarHidden, isTrue);
  });

  test('an action that loses its answer reads the battle back', () async {
    useFakeForum(
      turnFails: true,
      // The turn did land server-side: the wild pokemon is one hit from fainting, which the player's stale scene
      // does not know yet.
      recoveredScene: {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 1, 'max_hp': 18},
      },
    );
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    cubit.resume(
      BattleScene.fromMap(const {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 18, 'max_hp': 18},
      }),
    );

    final result = await cubit.useSkill(0);
    // A transport failure carries no server message, which is how the page tells it apart from a refusal.
    expect(result.success, isFalse);
    expect(result.message, isNull);
    // The read-back runs after the failed action; wait for it instead of assuming how long it takes.
    for (var i = 0; i < 200 && cubit.state.scene?.wildPokemon.hp != 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(paths.where((path) => path.contains('action=recover')), hasLength(1));
    expect(cubit.state.scene?.wildPokemon.hp, 1);
  });

  test('a battle read-back a newer action overtook is dropped', () async {
    const started = {
      'battle_id': 'battle_2',
      'map_id': 3,
      'status': 'active',
      'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
      'wild_pokemon': {'id': 25, 'hp': 9, 'max_hp': 18},
    };
    useFakeForum(
      turnFails: true,
      recoverDelay: const Duration(milliseconds: 150),
      // What the read-back finds: the turn did land server-side.
      recoveredScene: {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 1, 'max_hp': 18},
      },
      startedScene: started,
    );
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    cubit.resume(
      BattleScene.fromMap(const {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 18, 'max_hp': 18},
      }),
    );

    final failed = await cubit.useSkill(0);
    expect(failed.success, isFalse);

    // The player starts the next battle while the read-back is still in flight.
    await cubit.start(3);
    expect(cubit.state.scene?.battleId, 'battle_2');

    // It lands after the newer scene and must not paint over it.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(cubit.state.scene?.battleId, 'battle_2');
    expect(cubit.state.scene?.wildPokemon.hp, 9);
  });

  test('ends a lost battle the end scene no longer names', () async {
    useFakeForum();
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    // The running scene carries the battle id (the pet itself may already be gone from the answer)...
    cubit.resume(
      BattleScene.fromMap(const {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 0, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 1, 'max_hp': 18},
      }),
    );

    // ...while the end-of-battle answer has neither, so `heal_and_flee` and `flee` would both be sent with nothing.
    final result = await cubit.finishDefeat(
      BattleScene.fromMap(const {
        'battle_id': '',
        'map_id': 3,
        'status': 'defeat',
        'my_pokemon': {'instance_id': 0, 'hp': 0, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 1, 'max_hp': 18},
      }),
    );

    expect(result.success, isTrue, reason: 'the battle has to be ended with the id the running scene kept');
    expect(paths.where((path) => path.contains('action=flee')), hasLength(1));
    expect(paths.where((path) => path.contains('heal_and_flee')), isEmpty);
  });

  test('does not report a battle as ended when nothing could end it', () async {
    useFakeForum();
    final cubit = BattleCubit();
    addTearDown(cubit.close);

    // The battle was never seen running, and the end answer names neither the battle nor the pokemon.
    final result = await cubit.finishDefeat(
      BattleScene.fromMap(const {
        'battle_id': '',
        'map_id': 3,
        'status': 'defeat',
        'my_pokemon': {'instance_id': 0, 'hp': 0, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 1, 'max_hp': 18},
      }),
    );

    expect(result.success, isFalse, reason: 'the battle may still be running on the server');
  });

  test('a refresh reads the lists from their first page again', () async {
    useFakeForum();
    final cubit = PokemonCubit();
    addTearDown(cubit.close);
    await cubit.load();

    // The player scrolled one page into both lists.
    await cubit.loadMoreShop();
    await cubit.loadMoreInventory();
    expect(cubit.state.shopPage, 2);
    expect(cubit.state.inventoryPage, 2);
    paths.clear();

    await cubit.refreshShop();
    await cubit.refreshInventory();

    // The pages loaded before belong to the list that was on screen: a refresh asks for the first page again and moves
    // the counter back with it (keeping only the page the player had reached would drop everything before it, and
    // loadMore only goes forward).
    expect(paths.where((path) => path.contains('endpoint=shop') && path.contains('page=1')), hasLength(1));
    expect(paths.where((path) => path.contains('action=inventory') && path.contains('page=1')), hasLength(1));
    expect(cubit.state.shopPage, 1);
    expect(cubit.state.inventoryPage, 1);
  });

  test('a load-more the player switched category under is dropped', () async {
    useFakeForum(pageTwoDelay: const Duration(milliseconds: 150));
    final cubit = PokemonCubit();
    addTearDown(cubit.close);
    await cubit.load();

    // The player scrolls to the end of the first page of both lists...
    final inventoryMore = cubit.loadMoreInventory();
    final shopMore = cubit.loadMoreShop();
    // ...and picks another category while the second pages are still on their way.
    await cubit.setInventoryCategory(ShopCategory.ball);
    await cubit.setShopCategory(ShopCategory.ball);
    await Future.wait([inventoryMore, shopMore]);

    // Those pages belong to the lists of the old category: appending them would show them under the new one and skip
    // the new list's own second page. The page counter cannot tell, since the switch reset it to 1, the very page the
    // load-more started from.
    expect(cubit.state.inventoryCategory, ShopCategory.ball);
    expect(cubit.state.inventoryPage, 1);
    expect(cubit.state.shopCategory, ShopCategory.ball);
    expect(cubit.state.shopPage, 1);
  });

  test('a stale action that loses its answer does not read the battle back', () async {
    useFakeForum(
      turnFails: true,
      turnDelay: const Duration(milliseconds: 150),
      startedScene: {
        'battle_id': 'battle_2',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 9, 'max_hp': 18},
      },
    );
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    cubit.resume(
      BattleScene.fromMap(const {
        'battle_id': 'battle_1',
        'map_id': 3,
        'status': 'active',
        'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 18, 'max_hp': 18},
      }),
    );

    final stale = cubit.useSkill(0);
    // A newer action takes the screen while the turn is still on its way.
    await cubit.start(3);
    final result = await stale;
    expect(result.success, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // The read-back would take the newer action's generation and could paint a scene from before it over the screen.
    expect(paths.where((path) => path.contains('action=recover')), isEmpty);
    expect(cubit.state.scene?.battleId, 'battle_2');
  });

  test('fight again heals the pet the running scene named when the end scene lost its id', () async {
    useFakeForum();
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    cubit
      ..resume(
        BattleScene.fromMap(const {
          'battle_id': 'battle_1',
          'map_id': 3,
          'status': 'active',
          'my_pokemon': {'instance_id': 7, 'hp': 20, 'max_hp': 20},
          'wild_pokemon': {'id': 25, 'hp': 18, 'max_hp': 18},
        }),
      )
      // The end-of-battle answer names neither the battle nor the pet, but the pet is hurt.
      ..resume(
        BattleScene.fromMap(const {
          'battle_id': '',
          'map_id': 3,
          'status': 'victory',
          'my_pokemon': {'instance_id': 0, 'hp': 3, 'max_hp': 20},
          'wild_pokemon': {'id': 25, 'hp': 0, 'max_hp': 18},
        }),
      );
    paths.clear();

    await cubit.fightAgain(3);

    expect(paths.where((path) => path.contains('action=heal') && path.contains('pokemon_id=7')), hasLength(1));
    expect(paths.where((path) => path.contains('pokemon_id=0')), isEmpty);
    expect(paths.where((path) => path.contains('action=start')), hasLength(1));
  });

  test('fight again heals the party when no scene named the pet', () async {
    useFakeForum();
    final cubit = BattleCubit();
    addTearDown(cubit.close);
    // The battle was never seen running, and the end answer does not name the pet.
    cubit.resume(
      BattleScene.fromMap(const {
        'battle_id': '',
        'map_id': 3,
        'status': 'victory',
        'my_pokemon': {'instance_id': 0, 'hp': 3, 'max_hp': 20},
        'wild_pokemon': {'id': 25, 'hp': 0, 'max_hp': 18},
      }),
    );
    paths.clear();

    await cubit.fightAgain(3);

    // Healing pokemon 0 would fail silently; the party list names the pets that need it instead.
    expect(paths.where((path) => path.contains('pokemon_id=0')), isEmpty);
    expect(paths.where((path) => path.contains('action=list')), hasLength(1));
    expect(paths.where((path) => path.contains('action=start')), hasLength(1));
  });
}
