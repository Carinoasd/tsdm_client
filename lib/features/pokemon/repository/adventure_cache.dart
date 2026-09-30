import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Cross-page cache of the adventure data.
///
/// The maps endpoint is slow (the plugin runs one sub-query for every map), so the map list is kept across page
/// entries:
/// re-entering the adventure page shows the cached list at once and refreshes it in the background instead of blocking
/// on a full-page spinner every time.
final class AdventureCache {
  /// Constructor.
  AdventureCache({PokemonRepository? repository}) : _repository = repository ?? PokemonRepository();

  final PokemonRepository _repository;

  List<AdventureMap>? _maps;

  List<Pokemon>? _pokemons;

  /// Account the remembered data belongs to.
  ///
  /// This cache is a singleton, so without the check a player who switches account would see the previous account's
  /// maps, party and finished battles.
  int? _accountUid;

  /// When the server last answered that there is no battle at all.
  ///
  /// The adventure page is entered again and again (returning from a fight, hopping between tabs) and every entry asks
  /// the server whether a battle is running. A battle cannot appear between two entries a moment apart, so the answer
  /// is reused for [_battleCheckWindow].
  DateTime? _noBattleAt;

  /// How long a "no battle" answer is trusted.
  static const _battleCheckWindow = Duration(seconds: 10);

  /// Whether the "is a battle running?" check can be skipped: the server answered it moments ago.
  bool get battleCheckFresh => _noBattleAt != null && DateTime.now().difference(_noBattleAt!) < _battleCheckWindow;

  /// Remember that the server answered "no battle" just now.
  void markNoBattle() => _noBattleAt = DateTime.now();

  /// Forget that answer: a battle may well be running now.
  void invalidateBattleCheck() => _noBattleAt = null;

  /// Forget what was remembered for another account.
  void _forgetOtherAccount() {
    final uid = getIt.get<CookieProvider>().userLoginInfo.uid;
    if (_accountUid == uid) return;
    _accountUid = uid;
    _maps = null;
    _pokemons = null;
    _finishedBattles.clear();
    _noBattleAt = null;
  }

  /// The last fetched map list, or null before the first successful load.
  List<AdventureMap>? get maps {
    _forgetOtherAccount();
    return _maps;
  }

  /// Whether a map list has been fetched at least once.
  bool get hasData {
    _forgetOtherAccount();
    return _maps != null;
  }

  /// The level of the pokemon a fight would start with, or null before the list is loaded / when it is empty.
  ///
  /// That is the pokemon in front (`site` 1). The website's own map advice reads the first pokemon of the list
  /// (`get_recommendation` in `rust/game/src/pages/adventure.rs`), which is the same one — and it is the pet a fight
  /// actually starts with, so the advice is about the right pet.
  int? get activePokemonLevel {
    _forgetOtherAccount();
    final list = _pokemons;
    if (list == null || list.isEmpty) return null;
    return list.firstWhere((p) => p.isActive, orElse: () => list.first).level;
  }

  /// Refresh the remembered pokemon list (best effort), used for the challenge advice.
  Future<void> refreshPokemons() async {
    _forgetOtherAccount();
    final result = await _repository.getMyPokemon().run();
    result.fold((_) => null, (list) => _pokemons = list);
  }

  /// Fetch the maps and remember them; the previous list is kept when the fetch fails.
  Future<Either<AppException, List<AdventureMap>>> refreshMaps() async {
    _forgetOtherAccount();
    final result = await _repository.getMaps().run();
    result.fold((_) => null, (maps) => _maps = maps);
    return result;
  }

  /// Resume an active battle, if any (the server answers 404 when there is none).
  AsyncEither<BattleScene?> recoverBattle() => _repository.recoverBattle();

  /// Start a battle on [mapId], optionally against boss [bossTypeId].
  AsyncEither<BattleScene> startBattle(int mapId, {int? bossTypeId}) =>
      _repository.startBattle(mapId, bossTypeId: bossTypeId);

  /// Flee battle [battleId]; best effort, the plugin rolls for the escape to succeed.
  AsyncEither<BattleScene> flee(String battleId) => _repository.flee(battleId);

  /// Heal every carried pokemon that needs it; returns how many were healed.
  Future<int> healParty() => _repository.healParty();

  /// Battles the player already finished in this app run.
  ///
  /// The plugin does not always clear a battle when the player loses it (it keeps it while a usable backup pokemon
  /// exists, see `BattleCubit.finishDefeat`), so the adventure page must not resume these: it ends them instead.
  final Set<String> _finishedBattles = {};

  /// Key identifying [scene]'s battle in [_finishedBattles].
  ///
  /// `battleId` is empty in the end-of-battle responses, so the map, the opponent and the player's pokemon are used.
  static String battleKey(BattleScene scene) =>
      '${scene.mapId}-${scene.wildPokemon.id}-${scene.myPokemon.instanceId}';

  /// Remember that [scene]'s battle is over.
  void markBattleFinished(BattleScene scene) {
    _forgetOtherAccount();
    _finishedBattles.add(battleKey(scene));
  }

  /// Whether [scene]'s battle is one the player already finished.
  bool isBattleFinished(BattleScene scene) {
    _forgetOtherAccount();
    return _finishedBattles.contains(battleKey(scene));
  }

  /// Forget every finished battle; called once the server reports no active battle at all.
  void clearFinishedBattles() => _finishedBattles.clear();

  /// Storage key remembering whether the player prefers the flat "classic" map list.
  static const keyClassicMode = 'pokemon.adventureClassic';

  /// Whether the player last chose the flat classic map list (instead of the world map / region view).
  Future<bool> isClassicMode() async =>
      (await getIt.get<StorageProvider>().getString(keyClassicMode)) == 'true';

  /// Remember the chosen map list mode.
  Future<void> setClassicMode({required bool classic}) =>
      getIt.get<StorageProvider>().saveString(keyClassicMode, classic ? 'true' : 'false');
}
