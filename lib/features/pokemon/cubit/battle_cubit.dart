import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/features/pokemon/repository/skill_order_store.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/item_merge.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Loading status of a battle.
enum BattleStatus {
  /// Loading in progress.
  loading,

  /// Loaded successfully.
  success,

  /// Failed to load.
  failure,

  /// A login is required.
  needLogin,
}

/// Result of a battle action (turn/flee/capture/switch).
final class BattleActionResult {
  /// Constructor.
  const BattleActionResult({required this.success, this.message});

  /// Whether the action was accepted.
  final bool success;

  /// Server message when the action failed.
  final String? message;
}

/// Result of using an item in battle; a PP item asks for a skill selection instead of resolving a scene.
final class BattleUseItemResult {
  /// Constructor.
  const BattleUseItemResult({this.scene, this.message, this.requiresSkillSelection = false, this.availableSkills});

  /// Updated scene, when the item resolved immediately.
  final BattleScene? scene;

  /// Error message, when the item could not be used.
  final String? message;

  /// Whether a skill must be selected (PP restore items).
  final bool requiresSkillSelection;

  /// Skills the PP restore can target.
  final List<BattleSkill>? availableSkills;
}

/// Immutable state of a battle.
final class BattleState {
  /// Constructor.
  const BattleState({
    this.status = BattleStatus.loading,
    this.scene,
    this.wildGender,
    this.wildShiny,
    this.skillOrder = const [],
    this.turn = 1,
    this.actionInProgress = false,
    this.failureMessage,
  });

  /// Loading status.
  final BattleStatus status;

  /// Current battle scene.
  final BattleScene? scene;

  /// Gender of the wild pokemon from the last running turn (0=雄性, 1=雌性).
  ///
  /// The server clears `allure`, which carries the gender, when the battle ends, so the finished scene reports 0;
  /// remembering the last running value stops the opponent from flipping to male on the final hit.
  final int? wildGender;

  /// Shiny state of the wild pokemon from the last running turn.
  final bool? wildShiny;

  /// Device-local display order of the battling pokemon's skills (skill ids, empty until loaded).
  ///
  /// The plugin returns skills in slot order only; the order the player dragged them into on the detail page is applied
  /// here so the battle buttons show the same thing.
  final List<int> skillOrder;

  /// Round the battle is in, counted by the client.
  ///
  /// The plugin has no turn counter: it answers `turn: 1` while a battle is active and `0` once it is over, so the
  /// number shown is the client's own count of accepted turns and starts again at 1 after a resume.
  final int turn;

  /// Whether an action is in flight.
  final bool actionInProgress;

  /// Error message of the last failed load, shown in the failure state.
  final String? failureMessage;

  /// Copy with the given fields.
  ///
  /// [clearFailure] drops the message of an earlier failure: one set once would otherwise stay in the state for the rest
  /// of the battle.
  BattleState copyWith({
    BattleStatus? status,
    BattleScene? scene,
    int? wildGender,
    bool? wildShiny,
    List<int>? skillOrder,
    int? turn,
    bool? actionInProgress,
    String? failureMessage,
    bool clearFailure = false,
  }) => BattleState(
    status: status ?? this.status,
    scene: scene ?? this.scene,
    wildGender: wildGender ?? this.wildGender,
    wildShiny: wildShiny ?? this.wildShiny,
    skillOrder: skillOrder ?? this.skillOrder,
    turn: turn ?? this.turn,
    actionInProgress: actionInProgress ?? this.actionInProgress,
    failureMessage: clearFailure ? null : failureMessage ?? this.failureMessage,
  );
}

/// What a resume found out about a battle that was in progress.
enum BattleResumeResult {
  /// Nothing was in flight when the app came back.
  nothing,

  /// The server still has the battle, whose current scene was loaded again.
  refreshed,

  /// The server no longer has the battle: it ended while the app was away.
  gone,

  /// The battle could not be read again (network error).
  failed,
}

/// Cubit of a battle: starts/renews it and runs turn/action requests.
class BattleCubit extends Cubit<BattleState> with LoggerMixin {
  /// [repository] and [skillOrder] are injectable for tests.
  BattleCubit({PokemonRepository? repository, SkillOrderStore? skillOrder})
    : _repository = repository ?? PokemonRepository(),
      _skillOrder = skillOrder ?? SkillOrderStore(),
      super(const BattleState());

  final PokemonRepository _repository;

  final SkillOrderStore _skillOrder;

  /// Bumped when a resume invalidates the answers of requests that were still in flight.
  int _generation = 0;

  /// The last scene the server reported while the battle was still running.
  ///
  /// The end-of-battle answer carries no battle id, and may leave the pokemon's id at 0, but ending the battle on the
  /// server needs both, so the running values are kept (as the gender and the shiny state are).
  BattleScene? _runningScene;

  /// Round counter of the current battle; the plugin itself does not count turns.
  int _turn = 1;

  /// Start a new battle on map [mapId], optionally against boss [bossTypeId].
  ///
  /// With [keepScene] and an existing scene, the current scene stays on screen (the UI only disables its buttons) while
  /// the new battle starts, instead of flashing a full-page spinner. A refusal that asks for healing is answered by
  /// healing the party once and retrying, which [retryAfterHeal] guards against looping.
  Future<void> start(int mapId, {int? bossTypeId, bool keepScene = false, bool retryAfterHeal = true}) async {
    final keep = keepScene && state.scene != null;
    // Starting a battle makes anything read back before it stale, exactly like a resume does.
    final generation = ++_generation;
    _turn = 1;
    emit(state.copyWith(status: keep ? null : BattleStatus.loading, actionInProgress: keep, turn: _turn));
    final result = await _repository.startBattle(mapId, bossTypeId: bossTypeId).run();
    if (isClosed) return;
    switch (result) {
      case Left(:final value):
        // A fainted or abnormal battling pet is refused before the fight starts: heal the party (free) and try once
        // more, so the player does not have to walk to the centre for something the client can do itself.
        if (retryAfterHeal && petNeedsHealingError(value)) {
          await healParty();
          if (isClosed) return;
          await start(mapId, bossTypeId: bossTypeId, keepScene: keepScene, retryAfterHeal: false);
          return;
        }
        emit(
          state.copyWith(
            status: _isNeedLogin(value) ? BattleStatus.needLogin : BattleStatus.failure,
            failureMessage: _messageOf(value),
            actionInProgress: false,
          ),
        );
      case Right(:final value):
        // The client started this battle itself, so it is not one the adventure page already saw end: on the same map
        // against the same species with the same own pokemon the key repeats.
        getIt.get<AdventureCache>().forgetFinishedBattle(value);
        _emitSceneIfCurrent(value, generation, status: BattleStatus.success, actionInProgress: false);
    }
  }

  /// Resume an already-active battle from [scene].
  void resume(BattleScene scene) {
    _emitScene(scene, status: BattleStatus.success);
  }

  /// Use skill [skillId].
  Future<BattleActionResult> useSkill(int skillId) => _runAction(() => _repository.turn(state.scene!.battleId, skillId));

  /// Flee the battle.
  Future<BattleActionResult> flee() => _runAction(() => _repository.flee(state.scene!.battleId));

  /// Flee the battle and heal the battling pokemon at the center.
  Future<BattleActionResult> healAndFlee() async {
    final instanceId = state.scene!.myPokemon.instanceId;
    // Without the instance id the request would ask the server to heal pokemon 0; fail early instead.
    if (instanceId <= 0) {
      return const BattleActionResult(success: false);
    }
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await _repository.healAndFlee(instanceId).run();
      return result.fold(
        (e) => BattleActionResult(success: false, message: _messageOf(e)),
        (heal) => BattleActionResult(success: true, message: heal.message),
      );
    } on Object catch (e) {
      return BattleActionResult(success: false, message: '$e');
    } finally {
      if (!isClosed) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Best-effort refresh of the forum-side pokemon badge after a battle that changed the party.
  ///
  /// The forum keeps its own serialized copy of the party, so the badge (and the level shown under the avatar) would
  /// stay stale after a level up or a capture otherwise.
  Future<void> refreshBadge() async {
    await _repository.refreshBadge().run();
  }

  /// Heal the battling pokemon at the center.
  ///
  /// The heal is free on the server and only allowed once the battle is over, so the battle result calls it before
  /// leaving the page. The plugin never heals a pokemon on its own — a fight the player leaves without this stays
  /// unhealed — which is why every way out of the battle page has to go through it.
  Future<BattleActionResult> healPet(int instanceId) async {
    final result = await _repository.heal(instanceId).run();
    if (isClosed) return const BattleActionResult(success: false);
    return result.fold(
      (e) => BattleActionResult(success: false, message: _messageOf(e)),
      (heal) => BattleActionResult(success: true, message: heal.message),
    );
  }

  /// Heal every carried pokemon that needs it once a battle is over; returns how many were healed.
  ///
  /// The server heal is free and restores HP, the skill PP and abnormal states; working from the list instead of the
  /// finished scene means a pet the scene named wrongly — or one that sat the fight out — is healed as well. The heals
  /// run together, so a party that spent PP during the fight costs a single round trip.
  Future<int> healParty() => _repository.healParty();

  /// Fight again on [mapId]: acknowledge the tap at once, heal the pet that just fought, then start the next battle.
  ///
  /// The busy state comes first so the page reacts to the tap while the heal runs; the heal used to happen before any
  /// feedback, which read as a frozen button. Only the pet in the current scene is healed — the scene carries its HP and
  /// PP, so this needs no extra list request — and the rest of the party is taken care of when the player leaves.
  Future<void> fightAgain(int mapId, {int? bossTypeId}) async {
    emit(state.copyWith(actionInProgress: true));
    final scene = state.scene;
    if (scene != null && _scenePetNeedsHealing(scene)) {
      await healPet(scene.myPokemon.instanceId);
      if (isClosed) return;
    }
    await start(mapId, bossTypeId: bossTypeId, keepScene: true);
  }

  /// Whether the pokemon in [scene] should be healed before another fight: hurt, or out of skill PP.
  ///
  /// The scene does not carry the pet's state, so the abnormal states are left to the refusal-and-retry path of [start].
  static bool _scenePetNeedsHealing(BattleScene scene) =>
      scene.myPokemon.hp < scene.myPokemon.maxHp ||
      scene.myPokemon.skills.any((skill) => skill.pp < skill.maxPp);

  /// Handle the app coming back to the foreground.
  ///
  /// A request the OS parked while the app was away can hold the page in its busy state for a long time, so stop that
  /// wait and read the battle again from the server. The answers of requests that were in flight are dropped.
  Future<BattleResumeResult> onAppResumed() async {
    if (!state.actionInProgress) return BattleResumeResult.nothing;
    _generation++;
    emit(state.copyWith(actionInProgress: false));
    final result = await _repository.recoverBattle().run();
    if (isClosed) return BattleResumeResult.failed;
    if (result.isLeft()) return BattleResumeResult.failed;
    final scene = result.fold((_) => null, (value) => value);
    if (scene == null) {
      // The battle ended while the app was away: heal whatever the party needs, since nothing else will.
      unawaited(healParty());
      return BattleResumeResult.gone;
    }
    _emitScene(scene, status: BattleStatus.success, actionInProgress: false);
    return BattleResumeResult.refreshed;
  }

  /// Read the battle again after an action failed on the transport.
  ///
  /// The answer of the failed action never arrived, so what it did server-side is unknown (a turn, a switch, a capture
  /// may or may not have happened); the page has to show the server's own scene instead of the one the player acted on.
  /// A battle the server no longer has is left alone: the page's own handling reports that on the next action.
  Future<void> resync() async {
    final generation = _generation;
    final result = await _repository.recoverBattle().run();
    if (isClosed || result.isLeft()) return;
    final scene = result.fold((_) => null, (value) => value);
    if (scene == null) return;
    // An action the player started while the battle was being read back owns the screen now.
    if (state.actionInProgress) return;
    _emitSceneIfCurrent(scene, generation, status: BattleStatus.success, actionInProgress: false);
  }

  /// Throw the ball [ballId].
  Future<BattleActionResult> capture(int ballId) => _runAction(() => _repository.capture(ballId));

  /// Switch to another pokemon, optionally choosing [pokemonId].
  Future<BattleActionResult> switchPokemon({int? pokemonId}) =>
      _runAction(() => _repository.switchPokemon(state.scene!.battleId, pokemonId: pokemonId));

  /// Use PP-restore item [itemId] on skill [skillId].
  Future<BattleActionResult> useItemOnSkill(int itemId, int skillId) =>
      _runAction(() => _repository.useBattleItemOnSkill(itemId, skillId));

  /// Use item [itemId] in battle; returns the scene or asks for a skill selection.
  Future<BattleUseItemResult> useItem(int itemId) async {
    // A new action owns the screen from here on, so a read-back started earlier must not paint over its answer.
    final generation = ++_generation;
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await _repository.useBattleItem(itemId).run();
      return result.fold(
        (e) => BattleUseItemResult(message: _messageOf(e)),
        (data) {
          if (data['requires_skill_selection'] == true) {
            return BattleUseItemResult(
              requiresSkillSelection: true,
              availableSkills: _listOf(data['available_skills'], BattleSkill.fromMap),
            );
          }
          try {
            final scene = BattleScene.fromMap(data);
            // A stale answer (a resume or a newer action came in) must not touch the round count or the scene.
            if (generation == _generation) {
              if (scene.isActive) _turn++;
              if (!isClosed) _emitSceneIfCurrent(scene, generation);
            }
            return BattleUseItemResult(scene: scene);
          } on Object {
            return const BattleUseItemResult(message: 'unexpected battle item response');
          }
        },
      );
    } on Object catch (e) {
      return BattleUseItemResult(message: '$e');
    } finally {
      // The busy state belongs to the action that is actually running: a stale answer must not unlock the page.
      if (!isClosed && generation == _generation) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Fetch items usable in battle.
  Future<List<BattleItem>> loadBattleItems() async {
    final result = await _repository.getBattleItems().run();
    return result.fold((_) => const <BattleItem>[], (items) => items);
  }

  /// Fetch the balls (type=2 items) the player owns, merged by type.
  Future<List<InventoryItem>> loadBalls() async {
    final result = await _repository.getInventory(type: 2).run();
    return result.fold((_) => const <InventoryItem>[], (page) => mergeInventoryItems(page.items));
  }

  /// Fetch the player's pokemon list (for the switch picker).
  Future<List<Pokemon>> loadPokemons() async {
    final result = await _repository.getMyPokemon().run();
    return result.fold((_) => const <Pokemon>[], (pokemons) => pokemons);
  }

  /// Run a battle action that resolves a [BattleScene].
  Future<BattleActionResult> _runAction(AsyncEither<BattleScene> Function() action) async {
    // A new action owns the screen from here on, so a read-back started earlier must not paint over its answer.
    final generation = ++_generation;
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await action().run();
      return result.fold(
        (e) {
          // The answer never arrived, so the scene on screen may no longer be the server's: read it again instead of
          // leaving the player acting on a stale one.
          if (_messageOf(e) == null) unawaited(resync());
          return BattleActionResult(success: false, message: _messageOf(e));
        },
        (scene) {
          // A turn the server accepted and that left the battle running is one more round; ending it does not count. A
          // resume (or a newer action) makes this answer stale, and a stale answer must not touch the round count.
          if (generation == _generation) {
            if (scene.isActive) _turn++;
            if (!isClosed) _emitSceneIfCurrent(scene, generation);
          }
          return const BattleActionResult(success: true);
        },
      );
    } on Object catch (e) {
      return BattleActionResult(success: false, message: '$e');
    } finally {
      // The busy state belongs to the action that is actually running: a stale answer must not unlock the page.
      if (!isClosed && generation == _generation) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Emit [scene], remembering the wild pokemon's gender and shiny state while the battle is still running.
  ///
  /// A finished scene reports the gender the server reset when it cleared the battle state, so the last running values
  /// are kept in the state for the view to fall back on.
  void _emitScene(BattleScene scene, {BattleStatus? status, bool? actionInProgress}) {
    // Most callers reach this from an answer that was in flight; the page may be gone by then.
    if (isClosed) return;
    final otherPokemon = scene.myPokemon.instanceId != state.scene?.myPokemon.instanceId;
    emit(
      state.copyWith(
        status: status,
        scene: scene,
        clearFailure: true,
        wildGender: scene.isActive ? scene.wildPokemon.gender : null,
        wildShiny: scene.isActive ? scene.wildPokemon.isShiny : null,
        turn: _turn,
        actionInProgress: actionInProgress,
      ),
    );
    // The device-local skill order belongs to one pokemon, so re-read it whenever the battling one changes.
    if (otherPokemon) unawaited(_loadSkillOrder(scene.myPokemon.instanceId));
    // Keep the last scene that named its battle: ending a battle on the server needs a battle id, and the end-of-battle
    // answer (and a scene without one) cannot provide it.
    if (scene.battleId.isNotEmpty) _runningScene = scene;
  }

  /// Emit [scene] unless the app resumed while the answer was in flight, which made that answer stale.
  void _emitSceneIfCurrent(BattleScene scene, int generation, {BattleStatus? status, bool? actionInProgress}) {
    if (generation != _generation) return;
    _emitScene(scene, status: status, actionInProgress: actionInProgress);
  }

  /// Load the device-local skill order of pokemon [instanceId] into the state.
  Future<void> _loadSkillOrder(int instanceId) async {
    final List<int> order;
    try {
      order = await _skillOrder.load(instanceId);
    } on Object {
      // The device-local skill order is a nicety: a storage that cannot be read must never take the battle down.
      return;
    }
    if (isClosed) return;
    emit(state.copyWith(skillOrder: order));
  }

  /// End a battle the player lost, so the server stops keeping it active.
  ///
  /// The plugin answers `status: 'defeat'` **without** clearing the battle while the player still owns a usable backup
  /// pokemon (`battle.php`: only the no-backup case calls `clear_battle_state`), so the adventure page would resume the
  /// finished battle and the player had to flee by hand. `heal_and_flee` clears the battle unconditionally and heals
  /// the pokemon for free, so it goes first; the randomized `flee` is the fallback.
  Future<BattleActionResult> finishDefeat(BattleScene scene) async {
    // The end-of-battle answer carries no battle id and may leave the pokemon's id at 0, so the last running scene fills
    // them in: without a usable id nothing could end the battle the server still keeps.
    final running = _runningScene;
    final instanceId = scene.myPokemon.instanceId > 0 ? scene.myPokemon.instanceId : running?.myPokemon.instanceId ?? 0;
    final battleId = scene.battleId.isNotEmpty ? scene.battleId : running?.battleId ?? '';

    AppException? healError;
    if (instanceId > 0) {
      final healed = await _repository.healAndFlee(instanceId).run();
      if (isClosed) return const BattleActionResult(success: false);
      if (healed.isRight()) {
        return healed.fold(
          (_) => const BattleActionResult(success: true),
          (data) => BattleActionResult(success: true, message: data.message),
        );
      }
      // The server had already cleared the battle (no usable backup, or another client ended it): heal directly, so the
      // pet is restored even when there is nothing left to end.
      healError = healed.fold((e) => e, (_) => null);
      if (battleAlreadyOverError(healError)) {
        return healPet(instanceId);
      }
    }

    if (battleId.isEmpty) {
      // Nothing left to end the battle with. The party is healed anyway, but the battle may well still be running on the
      // server, so this is not reported as done (only "the battle is already over" is).
      await healParty();
      return BattleActionResult(success: false, message: _messageOf(healError ?? HttpRequestFailedException(null)));
    }

    final fled = await _repository.flee(battleId).run();
    if (isClosed) return const BattleActionResult(success: false);
    // The pet could not be named, so its own heal was skipped: heal whatever the party needs once the battle is over.
    if (instanceId <= 0) await healParty();
    return fled.fold(
      (e) => BattleActionResult(success: false, message: _messageOf(e)),
      (fledScene) => BattleActionResult(success: true, message: fledScene.message),
    );
  }

  /// Message of a pokemon api failure: only the server's own business message, so the UI can show a friendly hint
  /// for network/timeout errors instead of raw exception text.
  String? _messageOf(AppException e) => e is PokemonApiException ? e.message : null;

  bool _isNeedLogin(AppException e) => e is PokemonApiException && e.code == 401;

  List<T> _listOf<T>(Object? raw, T Function(Map<String, dynamic>) decode) {
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().map(decode).toList();
  }
}
