import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Repository of the pokemon (宠物中心) plugin JSON API.
///
/// The plugin exposes a pure JSON API at `plugin.php?id=pokemon:pokemon&endpoint=X&action=Y`. Every response uses the
/// envelope `{"success": bool, "data": ..., "error": ..., "code": ...}` and is authenticated by the forum session
/// cookie, so requests go through the default [NetClientProvider] bound to the current account.
final class PokemonRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [requestDeadline] is how long one plugin call may take before it is reported as a network failure (see [_send]);
  /// a test passes a short one to exercise a call that never answers.
  PokemonRepository({Duration requestDeadline = _timeout}) : _requestDeadline = requestDeadline;

  /// Deadline of a plugin call that does not ask for another one.
  final Duration _requestDeadline;

  /// Options that keep the raw string body, accept any status code and carry [headers].
  ///
  /// The timeouts bound how long a request that the OS parked while the app was in the background may hold a page in
  /// its loading state; the platform client alone would wait much longer.
  static Options _options([Map<String, String> headers = const {}]) => Options(
    responseType: ResponseType.plain,
    validateStatus: _anyStatus,
    sendTimeout: _timeout,
    receiveTimeout: _timeout,
    headers: headers,
  );

  /// Longest a pokemon request may take before its page gives up on it.
  ///
  /// Set on the request options and applied again as a deadline in [_send]: the options only bind the platforms that
  /// honour them, and a request the platform client parked must not hold a page in its busy state until that client
  /// gives up on its own (the plugin answers a call in a second or two, apart from the map list).
  static const _timeout = Duration(seconds: 20);

  /// Deadline of the map list: on the plugin side it runs a sub-query for every map, so it is the one slow endpoint.
  static const _mapsDeadline = Duration(seconds: 60);

  /// Header the plugin's API expects for its cross-site request check.
  ///
  /// The plugin answers `formhash 校验失败，请刷新页面后重试` when a request does not carry the session's formhash, so it
  /// is read from a page of the same session (see [_ensureFormHash]) and sent with every call.
  static const _formHashHeader = 'X-Pm-Formhash';

  /// Page the session's formhash is read from; the website's own front-end reads the same value.
  static const _formHashPageUrl = '$baseUrl/plugin.php?id=pokemon:game';

  /// Formhash of the current session, cached because it is bound to the cookie session.
  static String? _formHash;

  /// A formhash read that is still in flight, so the requests of one page load share a single read of the page.
  static Future<String?>? _formHashRead;

  /// Client this repository sends its requests through, and the account it was built for.
  ///
  /// One client is kept for the repository's life so its connection (and the cookie jar inside it) is reused: building
  /// one per request pays a TCP + TLS handshake every time (measured ≈0.45s to the forum host), and a page load makes
  /// several requests in a row. The client carries that account's cookies, so another account drops it.
  NetClientProvider? _client;
  int? _clientUid;

  NetClientProvider get _net {
    final uid = getIt.get<CookieProvider>().userLoginInfo.uid;
    if (_client != null && _clientUid == uid) {
      return _client!;
    }
    _clientUid = uid;
    return _client = getIt.get<NetClientProvider>();
  }

  static bool _anyStatus(int? status) => true;

  /// Fetch the global config.
  AsyncEither<GlobalConfig> getGlobalConfig() => _getData('config&action=global_config', GlobalConfig.fromJson);

  /// Fetch the current user's pokemon list.
  AsyncEither<List<Pokemon>> getMyPokemon() =>
      _getData('pokemon&action=list', (data) => _listOf(data['pokemons'], Pokemon.fromMap));

  /// The evolution chain of species [speciesId]: what it can become and what it evolved from, with each step's
  /// condition.
  ///
  /// This is what the website's "进化路径" dialog reads (`evolution&action=evolution_path`); it is display only.
  AsyncEither<EvolutionPath> getEvolutionPath(int speciesId) =>
      _getData('evolution&action=evolution_path&pmid=$speciesId', EvolutionPath.fromMap);

  /// Fetch the full detail (with [PokemonStats]) of pokemon [id].
  AsyncEither<Pokemon> getPokemonDetail(int id) =>
      _getData('pokemon&action=detail&pokemon_id=$id', Pokemon.fromMap);

  /// Fetch the current user's plugin profile (money etc.).
  AsyncEither<PokemonUserProfile> getProfile() => _getData('user&action=profile', PokemonUserProfile.fromMap);

  /// Fetch a page of the current user's inventory.
  AsyncEither<InventoryPage> getInventory({int page = 1, int? type}) =>
      _getData('user&action=inventory&page=$page${type == null ? '' : '&type=$type'}', InventoryPage.fromMap);

  /// Fetch a page of the shop.
  AsyncEither<ShopPage> getShop({int page = 1, int? type}) =>
      _getData('shop&action=list&page=$page${type == null ? '' : '&type=$type'}', ShopPage.fromMap);

  /// Set pokemon [id] as the first (battling) pokemon.
  AsyncVoidEither setFirst(int id) => _postAction('pokemon&action=set_first&pokemon_id=$id');

  /// Move pokemon [id] to [site] (1=first, 2=bag, 3=storage).
  AsyncVoidEither movePokemon(int id, int site) => _postAction('pokemon&action=move_pokemon&pokemon_id=$id&site=$site');

  /// Rename pokemon [id] to [name].
  AsyncVoidEither rename(int id, String name) => _postAction('pokemon&action=rename', body: {'id': id, 'name': name});

  /// Release (放生) pokemon [id].
  AsyncVoidEither release(int id) => _postAction('pokemon&action=release', body: {'id': id});

  /// Fetch the skills pokemon [id] can still learn.
  AsyncEither<LearnableSkills> getLearnableSkills(int id) =>
      _getData('pokemon&action=learnable_skills&pokemon_id=$id', LearnableSkills.fromMap);

  /// Make pokemon [id] learn skill [skillId], optionally into [slotIndex].
  AsyncVoidEither learnSkill(int id, int skillId, {int? slotIndex}) => _postAction(
    'pokemon&action=learn_skill',
    body: {'pokemon_id': id, 'skill_id': skillId, 'slot_index': ?slotIndex},
  );

  /// Make pokemon [id] forget skill [skillId].
  AsyncVoidEither forgetSkill(int id, int skillId) =>
      _postAction('pokemon&action=forget_skill', body: {'pokemon_id': id, 'skill_id': skillId});

  /// Fetch the equipment of pokemon [id]: its slots, owned items and the shop.
  AsyncEither<EquipmentResponse> getEquipment(int id) =>
      _getData('pokemon&action=equipment&pokemon_id=$id', EquipmentResponse.fromMap);

  /// Equip owned item [myitemId] on pokemon [id], optionally into [slotIndex].
  AsyncVoidEither equipItem(int id, int myitemId, {int? slotIndex}) => _postAction(
    'pokemon&action=equip_item',
    body: {'pokemon_id': id, 'myitem_id': myitemId, 'slot_index': ?slotIndex},
  );

  /// Unequip the equipment in [slotIndex] (0-3) of pokemon [id].
  AsyncVoidEither unequipItem(int id, int slotIndex) =>
      _postAction('pokemon&action=unequip_item', body: {'pokemon_id': id, 'slot_index': slotIndex});

  /// Heal pokemon [id] at the pokemon center.
  AsyncEither<HealResult> heal(int id) =>
      _postData('user&action=heal&pokemon_id=$id', body: const {}, decode: HealResult.fromMap);

  /// Flee any active battle and heal pokemon [id].
  AsyncEither<HealResult> healAndFlee(int id) =>
      _postData('user&action=heal_and_flee&pokemon_id=$id', body: const {}, decode: HealResult.fromMap);

  /// The current user's party, or null when the request failed.
  Future<List<Pokemon>?> loadParty() async {
    final result = await getMyPokemon().run();
    return result.fold((_) => null, (list) => list);
  }

  /// Heal every carried pokemon that needs it; returns how many were healed.
  ///
  /// The heal is free and idempotent, so this is what the battle result and the adventure page call around a fight.
  /// Working from the pokemon list instead of one scene means a pet that sat the fight out — or one the scene named
  /// wrongly — is healed too; failures are skipped (best effort).
  ///
  /// The heals run together, so a party that spent PP during the fight costs one round trip instead of one per pokemon.
  Future<int> healParty() async {
    final pokemons = await loadParty();
    if (pokemons == null) {
      // The heal runs in the background after a fight, so a failed list read has to leave a trace somewhere.
      warning('healParty: could not read the party, nothing healed');
      return 0;
    }
    final candidates = pokemons.where((pokemon) => pokemon.needsHealing).toList();
    if (candidates.isEmpty) return 0;
    final stopwatch = Stopwatch()..start();
    final results = await Future.wait(candidates.map((pokemon) => heal(pokemon.id).run()));
    final healed = results.where((result) => result.isRight()).length;
    debug('healParty: ${candidates.length} heals in ${stopwatch.elapsedMilliseconds}ms -> $healed healed');
    return healed;
  }

  /// Refresh the forum-side pokemon badge and the status bar pet; the raw `data` holds a message and the counts.
  ///
  /// The forum stores its own serialized copy of the party, so the badge (and the level shown under the avatar) stays
  /// stale until this is called. The website's status bar switch is this same call: [hide] hides the pet instead of
  /// writing the party back, and the answer then carries `hidden`.
  AsyncEither<Map<String, dynamic>> refreshBadge({bool? hide}) =>
      _postRaw('user&action=refresh_badge', {'hide': ?hide});

  /// Read the badge and status bar pet state; the raw `data` says whether the pet is hidden.
  ///
  /// This is what the website's sidebar reads (`get_badge_status` in `rust/game/src/utils/api_client.rs`) before it
  /// switches the pet. The profile carries the same flag, but only on plugin builds that send it, so this is the
  /// reliable source; a build without the action simply answers an error and the profile value is kept.
  AsyncEither<Map<String, dynamic>> badgeStatus() => _getRaw('user&action=badge_status');

  /// Use item [itemId], optionally on pokemon [pokemonId].
  AsyncVoidEither useItem(int itemId, {int? pokemonId}) => _postAction(
    'user&action=use_item',
    body: {'item_id': itemId, 'pokemon_id': ?pokemonId},
  );

  /// Buy [quantity] of shop item [itemId].
  AsyncEither<BuyResult> buy(int itemId, int quantity) =>
      _postData('shop&action=buy', body: {'item_id': itemId, 'quantity': quantity}, decode: BuyResult.fromMap);

  /// Fetch a page of the pet (pokemon) shop.
  AsyncEither<ShopPetsPage> getShopPets({int page = 1}) =>
      _getData('shop&action=pets&page=$page', ShopPetsPage.fromMap);

  /// Buy [quantity] of pet species [typeId].
  AsyncEither<BuyPetResult> buyPet(int typeId, {int quantity = 1}) => _postData(
    'shop&action=buy_pet',
    body: {'pokemon_type_id': typeId, 'quantity': quantity},
    decode: BuyPetResult.fromMap,
  );

  /// Fetch the adventure maps.
  AsyncEither<List<AdventureMap>> getMaps() => _getData(
    'battle&action=maps',
    (data) => _listOf(data['maps'], AdventureMap.fromMap),
    deadline: _mapsDeadline,
  );

  /// Resume an active battle; null when there is none (the server answers 404 for that).
  AsyncEither<BattleScene?> recoverBattle() => _send((headers) async {
    final resp = await _net
        .get('$pokemonApiBase&endpoint=battle&action=recover', options: _options(headers))
        .run();
    return switch (resp) {
      Left(:final value) => left<AppException, BattleScene?>(value),
      Right(:final value) => _decodeEnvelope(value).fold(
        (e) => (e is PokemonApiException && e.code == 404)
            ? right<AppException, BattleScene?>(null)
            : left<AppException, BattleScene?>(e),
        (data) => _decode(data, BattleScene.fromMap, value),
      ),
    };
  });

  /// Start a battle on map [mapId], optionally against boss [bossTypeId].
  AsyncEither<BattleScene> startBattle(int mapId, {int? bossTypeId}) => _postData(
    'battle&action=start',
    body: {'map_id': mapId, 'boss_pokemon_type_id': ?bossTypeId},
    decode: BattleScene.fromMap,
  );

  /// Use skill [skillId] in battle [battleId].
  AsyncEither<BattleScene> turn(String battleId, int skillId) =>
      _postData('battle&action=turn', body: {'battle_id': battleId, 'skill_id': skillId}, decode: BattleScene.fromMap);

  /// Flee battle [battleId].
  AsyncEither<BattleScene> flee(String battleId) =>
      _postData('battle&action=flee', body: {'battle_id': battleId}, decode: BattleScene.fromMap);

  /// Throw the ball [ballId] at the wild pokemon.
  AsyncEither<BattleScene> capture(int ballId) =>
      _postData('battle&action=capture', body: {'ball_id': ballId}, decode: BattleScene.fromMap);

  /// Switch the battling pokemon (optionally to [pokemonId]).
  AsyncEither<BattleScene> switchPokemon(String battleId, {int? pokemonId}) => _postData(
    'battle&action=switch_pokemon',
    body: {'battle_id': battleId, 'pokemon_id': ?pokemonId},
    decode: BattleScene.fromMap,
  );

  /// Use item [itemId] in battle; the raw `data` is either a [BattleScene] or a skill-selection response for PP items.
  AsyncEither<Map<String, dynamic>> useBattleItem(int itemId) =>
      _postRaw('battle&action=use_item', {'item_id': itemId});

  /// Use PP-restore item [itemId] on skill [skillId] in battle.
  AsyncEither<BattleScene> useBattleItemOnSkill(int itemId, int skillId) => _postData(
    'battle&action=use_item_on_skill',
    body: {'item_id': itemId, 'skill_id': skillId},
    decode: BattleScene.fromMap,
  );

  /// Fetch items usable in battle.
  AsyncEither<List<BattleItem>> getBattleItems() =>
      _getData('battle&action=get_battle_items', (data) => _listOf(data['items'], BattleItem.fromMap));

  /// GET the JSON envelope of [endpoint] and decode its `data` object with [decode].
  AsyncEither<T> _getData<T>(
    String endpoint,
    T Function(Map<String, dynamic>) decode, {
    Duration? deadline,
  }) => _send((headers) async {
    final resp = await _net
        .get('$pokemonApiBase&endpoint=$endpoint', options: _options(headers))
        .run();
    return switch (resp) {
      Left(:final value) => left<AppException, T>(value),
      Right(:final value) => _decodeEnvelope(value).fold((e) => left<AppException, T>(e), (data) => _decode(data, decode, value)),
    };
  }, deadline: deadline);

  /// POST [endpoint] (optionally with a JSON [body]) and ignore the response `data`.
  AsyncVoidEither _postAction(String endpoint, {Map<String, dynamic>? body}) => _send<void>((headers) async {
    final resp = await _net
        .postJson(
          '$pokemonApiBase&endpoint=$endpoint',
          data: jsonEncode(body ?? const <String, dynamic>{}),
          headers: headers,
        )
        .run();
    return switch (resp) {
      Left(:final value) => left<AppException, void>(value),
      Right(:final value) => _decodeEnvelope(value).fold(
        (e) => left<AppException, void>(e),
        (_) => right<AppException, void>(null),
      ),
    };
  });

  /// POST [endpoint] with a JSON [body] and decode its `data` object with [decode].
  AsyncEither<T> _postData<T>(
    String endpoint, {
    required Map<String, dynamic> body,
    required T Function(Map<String, dynamic>) decode,
  }) => _send((headers) async {
    final resp = await _net
        .postJson('$pokemonApiBase&endpoint=$endpoint', data: jsonEncode(body), headers: headers)
        .run();
    return switch (resp) {
      Left(:final value) => left<AppException, T>(value),
      Right(:final value) => _decodeEnvelope(value).fold((e) => left<AppException, T>(e), (data) => _decode(data, decode, value)),
    };
  });

  /// Send [request] with the session formhash attached, reading it again and retrying once when the server calls it
  /// stale (the plugin ties it to the session, which the forum may renew).
  ///
  /// The call runs under [deadline], so a request the platform client parked is reported as a network failure instead
  /// of holding its page in a busy state until that client gives up on its own.
  AsyncEither<T> _send<T>(
    Future<Either<AppException, T>> Function(Map<String, String> headers) request, {
    Duration? deadline,
  }) => AsyncEither(
    () async {
      final limit = deadline ?? _requestDeadline;
      final first = await _withDeadline(request(await _formHashHeaders()), limit);
      final error = first.fold((e) => e, (_) => null);
      // Any other failure (including the login guard) is reported as it came.
      if (error is! PokemonApiException || !(error.message ?? '').contains('formhash')) return first;
      final retryHeaders = await _formHashHeaders(refresh: true);
      if (retryHeaders.isEmpty) return first;
      return _withDeadline(request(retryHeaders), limit);
    },
  );

  /// Run [request] under [deadline], reporting a call that never answered as a network failure.
  Future<Either<AppException, T>> _withDeadline<T>(Future<Either<AppException, T>> request, Duration deadline) =>
      request.timeout(deadline, onTimeout: () => left<AppException, T>(HttpRequestFailedException(null)));

  /// Headers every plugin request needs; empty when the session's formhash could not be read.
  Future<Map<String, String>> _formHashHeaders({bool refresh = false}) async {
    final hash = await _ensureFormHash(refresh: refresh);
    return {_formHashHeader: ?hash};
  }

  /// The session's formhash, read from a plugin page when it is not cached yet.
  ///
  /// A page load starts several requests at once and they all need the header, so a read that is already in flight is
  /// shared instead of fetching the page once per request.
  Future<String?> _ensureFormHash({bool refresh = false}) {
    if (refresh) {
      _formHashRead = null;
      return _readFormHash();
    }
    final cached = _formHash;
    if (cached != null) return Future.value(cached);
    return _formHashRead ??= _readFormHash();
  }

  /// Read the formhash from the plugin page and remember it; a failed read is not cached.
  Future<String?> _readFormHash() async {
    try {
      // The page read runs under the same deadline as the call that waits for it: a parked read must not hold it.
      final resp = await _net
          .get(_formHashPageUrl, options: _options())
          .run()
          .timeout(
            _requestDeadline,
            onTimeout: () => left<AppException, Response<dynamic>>(HttpRequestFailedException(null)),
          );
      if (resp.isLeft()) return null;
      final hash = formHashOf('${resp.fold((_) => '', (value) => value.data)}');
      if (hash == null) {
        warning('failed to read the formhash from $_formHashPageUrl');
        return null;
      }
      _formHash = hash;
      return hash;
    } finally {
      _formHashRead = null;
    }
  }

  /// POST [endpoint] with a JSON [body] and return its `data` object as a raw map.
  AsyncEither<Map<String, dynamic>> _postRaw(String endpoint, Map<String, dynamic> body) => _send((headers) async {
    final resp = await _net
        .postJson('$pokemonApiBase&endpoint=$endpoint', data: jsonEncode(body), headers: headers)
        .run();
    return switch (resp) {
      Left(:final value) => left<AppException, Map<String, dynamic>>(value),
      Right(:final value) => _decodeEnvelope(value),
    };
  });

  /// GET [endpoint] and return its `data` object as a raw map.
  AsyncEither<Map<String, dynamic>> _getRaw(String endpoint) => _send((headers) async {
    final resp = await _net.get('$pokemonApiBase&endpoint=$endpoint', options: _options(headers)).run();
    return switch (resp) {
      Left(:final value) => left<AppException, Map<String, dynamic>>(value),
      Right(:final value) => _decodeEnvelope(value),
    };
  });

  /// Decode a `data` object with [decode], turning any parse error into a [ServerRespFailure] instead of a thrown error.
  ///
  /// Catches `Object` (not just `Exception`) because a wrong-typed field makes dart_mappable throw a `TypeError`, which
  /// is an `Error`; letting it escape would leave the page stuck loading forever.
  Either<AppException, T> _decode<T>(Map<String, dynamic> data, T Function(Map<String, dynamic>) decode, Response<dynamic> resp) {
    try {
      return right<AppException, T>(decode(data));
    } on Object catch (e) {
      final preview = jsonEncode(data);
      talker.error('failed to decode pokemon api data: $e; data: ${preview.length > 200 ? preview.substring(0, 200) : preview}');
      return left<AppException, T>(ServerRespFailure(status: resp.statusCode, message: '$e'));
    }
  }

  /// Decode the raw `{success, data, error, code}` envelope into its `data` map, or a [PokemonApiException].
  Either<AppException, Map<String, dynamic>> _decodeEnvelope(Response<dynamic> resp) {
    final data = resp.data;
    final text = data is String ? data : jsonEncode(data);
    // The plugin's login guard answers without a body (401 on older builds, 403 on newer ones), which is not JSON:
    // report it as the login problem it is, so the pages show their login prompt instead of a decode error.
    if (text.trim().isEmpty && (resp.statusCode == 401 || resp.statusCode == 403)) {
      return left(PokemonApiException('需要登录', code: 401));
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return left(ServerRespFailure(status: resp.statusCode, message: 'unexpected pokemon api response'));
      }
      if (decoded['success'] != true) {
        final message = decoded['error']?.toString() ?? 'pokemon api error';
        final code = (decoded['code'] as num?)?.toInt();
        // The plugin answers with this envelope for its own bugs too (for example the broken box module, which fails
        // with a plain 500), so log the endpoint to make an exported log useful. A 404 is the normal "no active battle"
        // answer for `recover`, so it only gets a debug line instead of a warning.
        final line =
            'pokemon api error: $message (code=$code, status=${resp.statusCode}) at ${resp.requestOptions.uri}';
        if (code == 404) {
          talker.debug(line);
        } else {
          talker.warning(line);
        }
        return left(PokemonApiException(message, code: code));
      }
      final body = decoded['data'];
      if (body == null) {
        return right(<String, dynamic>{});
      }
      if (body is Map<String, dynamic>) {
        return right(body);
      }
      return left(ServerRespFailure(status: resp.statusCode, message: 'unexpected pokemon api data'));
    } on Object catch (e) {
      talker.error(
        'failed to decode pokemon api response: $e (status=${resp.statusCode}) at ${resp.requestOptions.uri}',
      );
      return left(ServerRespFailure(status: resp.statusCode, message: '$e'));
    }
  }

  /// Decode a JSON list of objects into a typed list.
  List<T> _listOf<T>(Object? raw, T Function(Map<String, dynamic>) decode) {
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().map(decode).toList();
  }
}

/// The formhash of a page of the forum: the hidden input Discuz renders for its forms, or the inline script the
/// plugin's own front-end reads the value from.
///
/// The plugin's API rejects a request that does not carry the session's formhash in the `X-Pm-Formhash` header, so the
/// client reads it from a page of the same session. Kept pure so the two shapes stay covered by a test.
String? formHashOf(String html) {
  final input = RegExp(r'formhash"\s*value="(\w+)"').firstMatch(html);
  if (input != null) return input.group(1);
  return RegExp(r"formhash\s*=\s*'(\w+)'").firstMatch(html)?.group(1);
}

/// Whether the badge answer reports the forum status bar pet as hidden; null when this plugin build does not say.
///
/// The website's status bar switch is this same `refresh_badge` call with `{"hide": bool}`; a build whose
/// `refresh_badge` predates that parameter answers without the field, so the caller can tell an old build from a
/// switch that failed.
bool? statusBarHiddenFromBadge(Map<String, dynamic> data) => data['hidden'] as bool?;
