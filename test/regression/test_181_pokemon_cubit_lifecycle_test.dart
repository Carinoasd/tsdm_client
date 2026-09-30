import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/pokemon/cubit/battle_cubit.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
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
  /// With [turnFails] a battle turn loses the transport (no answer at all), and [recoveredScene] is what the read-back
  /// after such a failure finds: this is how a scene that changed while the answer was lost is modeled.
  void useFakeForum({
    Duration delay = Duration.zero,
    bool turnFails = false,
    Map<String, dynamic>? recoveredScene,
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
    // The read-back runs after the failed action, so give it its turn.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(paths.where((path) => path.contains('action=recover')), hasLength(1));
    expect(cubit.state.scene?.wildPokemon.hp, 1);
  });
}
