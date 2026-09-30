import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

/// Regression test of the party heal.
///
/// Two things have to hold: only the pokemon the plugin would actually change are asked for, and the requests run
/// together — a party that spent PP in the fight used to cost one round trip per pokemon, which is the wait the player
/// saw between two fights.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The client logs the requests it builds through the global talker, which the app initializes on startup.
  talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));

  /// A pokemon as the list endpoint returns it, carrying just the fields the heal decision reads.
  Map<String, dynamic> pet(
    int id, {
    int hp = 20,
    int maxHp = 20,
    int state = 1,
    int site = 1,
    List<Map<String, dynamic>> skills = const [],
  }) => {'id': id, 'hp': hp, 'max_hp': maxHp, 'state': state, 'site': site, 'skills': skills};

  /// Ordered list of the pokemon ids a heal was asked for.
  late List<String> healedIds;

  /// Every path the client requested, so a test can tell whether the list was fetched.
  late List<String> paths;

  /// Highest number of requests that were in flight at the same time, and the current one.
  late int maxInFlight;
  late int inFlight;

  /// How many clients the DI was asked to build, to prove that a repository keeps and reuses one.
  late int clientBuilds;

  /// Answer the pokemon API from [party]; every heal stays busy for [healDelay] to make an overlap visible.
  void useFakeApi(List<Map<String, dynamic>> party, {Duration healDelay = Duration.zero}) {
    healedIds = [];
    paths = [];
    maxInFlight = 0;
    inFlight = 0;
    clientBuilds = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            inFlight++;
            if (inFlight > maxInFlight) {
              maxInFlight = inFlight;
            }
            paths.add(options.uri.toString());
            final uri = options.uri;
            if (uri.queryParameters['action'] == 'heal') {
              healedIds.add(uri.queryParameters['pokemon_id'] ?? '');
              if (healDelay > Duration.zero) {
                await Future<void>.delayed(healDelay);
              }
            }
            inFlight--;
            handler.resolve(Response<dynamic>(requestOptions: options, statusCode: 200, data: _answer(uri, party)));
          },
        ),
      );
    final cookie = CookieProvider(const UserLoginInfo(username: 'Alice', uid: 1), const {});
    getIt
      ..registerSingleton<CookieProvider>(cookie)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<NetClientProvider>(() {
        clientBuilds++;
        return NetClientProvider.buildNoCookie(dio: dio, cookie: cookie);
      });
  }

  setUp(getIt.reset);
  tearDown(getIt.reset);

  test('the requests of one page load share a single formhash read', () async {
    // This test has to stay first in this file: the formhash is cached per session (a static), so only the first test
    // that talks to the fake forum can observe how many times the page is actually fetched.
    useFakeApi([pet(1)]);
    final repository = PokemonRepository();

    // The pet centre reads several slices at once, and every one of them needs the formhash header.
    await Future.wait<Object?>([
      repository.loadParty(),
      repository.getProfile().run(),
      repository.getGlobalConfig().run(),
    ]);

    expect(paths.where((path) => path.contains('id=pokemon:game')), hasLength(1));
  });

  test('asks only for the pokemon the plugin would change', () async {
    useFakeApi([
      pet(1),
      pet(2, hp: 4),
      pet(3, hp: 0, site: 3),
      pet(4, skills: [
        {'type_id': 9, 'pp': 1, 'max_pp': 10},
      ]),
      pet(5, state: 9),
    ]);

    final healed = await PokemonRepository().healParty();

    expect(healed, 2);
    expect(healedIds, unorderedEquals(const ['2', '4']));
  });

  test('heals the party in one round trip instead of one per pokemon', () async {
    useFakeApi([pet(1, hp: 1), pet(2, hp: 2), pet(3, hp: 3), pet(4, hp: 4)], healDelay: const Duration(milliseconds: 40));

    final stopwatch = Stopwatch()..start();
    final healed = await PokemonRepository().healParty();
    stopwatch.stop();

    expect(healed, 4);
    expect(healedIds, hasLength(4));
    // All four were in flight together, so the wait is one heal long instead of four.
    expect(maxInFlight, 4);
    expect(stopwatch.elapsedMilliseconds, lessThan(4 * 40));
  });

  test('a repository keeps one client for all of its requests', () async {
    useFakeApi([pet(1)]);
    final repository = PokemonRepository();

    await repository.loadParty();
    await repository.loadParty();

    // A client per request means a TCP + TLS handshake per request; the repository has to keep and reuse one.
    expect(clientBuilds, 1);
  });

  test('a repository renews its client after the account switched', () async {
    useFakeApi([pet(1)]);
    final repository = PokemonRepository();
    await repository.loadParty();
    expect(clientBuilds, 1);

    // The client carries the account's cookie jar, so the new account must not reuse the old one.
    await getIt.unregister<CookieProvider>();
    getIt.registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(username: 'Bob', uid: 2), const {}));
    await repository.loadParty();

    expect(clientBuilds, 2);
  });

  test('does nothing when the whole party is healthy', () async {
    useFakeApi([pet(1), pet(2), pet(3)]);

    expect(await PokemonRepository().healParty(), 0);
    expect(healedIds, isEmpty);
  });

  test('reports a plugin call that never answers instead of hanging on it', () async {
    // A request the platform client parked used to hold the page in its busy state for tens of seconds (the player sees
    // that as a hang), so the repository deadline has to turn it into an ordinary network failure.
    final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {}));
    final cookie = CookieProvider(const UserLoginInfo(username: 'Alice', uid: 1), const {});
    getIt
      ..registerSingleton<CookieProvider>(cookie)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<NetClientProvider>(() => NetClientProvider.buildNoCookie(dio: dio, cookie: cookie));

    final stopwatch = Stopwatch()..start();
    final result = await PokemonRepository(requestDeadline: const Duration(milliseconds: 50)).getProfile().run();
    stopwatch.stop();

    expect(result.isLeft(), isTrue, reason: 'a call that never answers is a failure, not a pending request');
    expect(stopwatch.elapsedMilliseconds, lessThan(2000), reason: 'and it is reported long before the platform client');
  });
}

/// The answer the fake forum gives [uri]: the party for the list, a success envelope for a heal, and a page carrying a
/// formhash for the plugin page the client reads it from.
String _answer(Uri uri, List<Map<String, dynamic>> party) {
  final action = uri.queryParameters['action'];
  if (uri.queryParameters['id'] == 'pokemon:game') {
    return '<input type="hidden" name="formhash" value="deadbeef">';
  }
  switch (action) {
    case 'list':
      return jsonEncode({
        'success': true,
        'data': {'pokemons': party},
      });
    case 'heal':
      return jsonEncode({
        'success': true,
        'data': {'message': '治疗成功', 'current_hp': 20, 'max_hp': 20, 'cost': 0},
      });
    default:
      return jsonEncode({'success': true, 'data': <String, dynamic>{}});
  }
}
