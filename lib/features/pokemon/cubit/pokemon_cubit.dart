import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';

/// Loading status of the pokemon center.
enum PokemonStatus {
  /// Loading in progress.
  loading,

  /// Loaded successfully.
  success,

  /// Failed to load.
  failure,

  /// A login is required.
  needLogin,
}

/// Result of a state-changing pokemon action.
final class PokemonActionResult {
  /// Constructor.
  const PokemonActionResult({required this.success, this.message});

  /// Whether the server accepted the action.
  final bool success;

  /// Human-readable server message, when supplied.
  final String? message;
}

/// What happened when the player asked to show or hide the forum status bar pet.
///
/// The page turns it into a localized message; the cubit has no context to localize with.
enum StatusBarOutcome {
  /// The pet was removed from the status bar.
  hidden,

  /// The party was written back into the status bar (shown again).
  shown,

  /// The session is no longer valid.
  notLoggedIn,

  /// The answer says the action did not take effect.
  notApplied,

  /// The request itself failed (network or timeout).
  failed,
}

/// A shop category: an item `type` (1-5) or the pet listing.
enum ShopCategory {
  /// All item categories.
  all(null),

  /// Recovery items.
  med(1),

  /// Poke balls.
  ball(2),

  /// Evolution stones.
  stone(3),

  /// Boost items.
  boost(4),

  /// Equipment.
  equipment(5),

  /// Pokemon for sale.
  pet(null, isPet: true);

  const ShopCategory(this.type, {this.isPet = false});

  /// The item `type` query parameter, or null for all/pets.
  final int? type;

  /// Whether this category lists pokemon instead of items.
  final bool isPet;
}

/// Immutable state of the pokemon center.
final class PokemonState {
  /// Constructor.
  const PokemonState({
    this.status = PokemonStatus.loading,
    this.config,
    this.pokemons,
    this.profile,
    this.inventory,
    this.shop,
    this.shopPets,
    this.shopCategory = ShopCategory.all,
    this.inventoryCategory = ShopCategory.all,
    this.inventoryPage = 1,
    this.shopPage = 1,
    this.actionInProgress = false,
  });

  /// Overall loading status.
  final PokemonStatus status;

  /// Global plugin config.
  final GlobalConfig? config;

  /// Current user's pokemon list.
  final List<Pokemon>? pokemons;

  /// Current user's plugin profile (money etc.).
  final PokemonUserProfile? profile;

  /// Loaded inventory page.
  final InventoryPage? inventory;

  /// Loaded shop page.
  final ShopPage? shop;

  /// Loaded pet shop page.
  final ShopPetsPage? shopPets;

  /// Currently selected shop category.
  final ShopCategory shopCategory;

  /// Currently selected inventory category.
  final ShopCategory inventoryCategory;

  /// Current inventory page number.
  final int inventoryPage;

  /// Current shop page number.
  final int shopPage;

  /// Whether a state-changing action is running.
  final bool actionInProgress;

  /// Copy with the given fields.
  PokemonState copyWith({
    PokemonStatus? status,
    GlobalConfig? config,
    List<Pokemon>? pokemons,
    PokemonUserProfile? profile,
    InventoryPage? inventory,
    ShopPage? shop,
    ShopPetsPage? shopPets,
    ShopCategory? shopCategory,
    ShopCategory? inventoryCategory,
    bool clearShop = false,
    bool clearPets = false,
    bool clearInventory = false,
    int? inventoryPage,
    int? shopPage,
    bool? actionInProgress,
  }) => PokemonState(
    status: status ?? this.status,
    config: config ?? this.config,
    pokemons: pokemons ?? this.pokemons,
    profile: profile ?? this.profile,
    inventory: clearInventory ? null : (inventory ?? this.inventory),
    shop: clearShop ? null : (shop ?? this.shop),
    shopPets: clearPets ? null : (shopPets ?? this.shopPets),
    shopCategory: shopCategory ?? this.shopCategory,
    inventoryCategory: inventoryCategory ?? this.inventoryCategory,
    inventoryPage: inventoryPage ?? this.inventoryPage,
    shopPage: shopPage ?? this.shopPage,
    actionInProgress: actionInProgress ?? this.actionInProgress,
  );
}

/// Cubit of the pokemon center, loading the plugin JSON API and running actions.
class PokemonCubit extends Cubit<PokemonState> {
  /// [repository] is injectable for tests.
  PokemonCubit({PokemonRepository? repository})
    : _repository = repository ?? PokemonRepository(),
      super(const PokemonState());

  final PokemonRepository _repository;

  /// Status bar state the player asked for and the server has not confirmed yet, or null when there is none.
  ///
  /// A switch survives the app going to the background, so [reconcileStatusBar] can finish it on the way back.
  bool? _pendingStatusBar;

  /// Guards against two page loads for the same slice at once.
  ///
  /// The scroll listener and the search's `loadAll*` can ask for the next page together; without the guard both would
  /// append the same page and the inventory's merged quantities would double.
  bool _loadingMoreInventory = false;
  bool _loadingMoreShop = false;

  /// Reload everything; starts all requests concurrently so the first screen only waits for the slowest one.
  Future<void> load() async {
    emit(state.copyWith(status: PokemonStatus.loading));

    final configFuture = _repository.getGlobalConfig().run();
    final pokemonsFuture = _repository.getMyPokemon().run();
    final profileFuture = _repository.getProfile().run();
    // The lists are read from their first page: pages held before belong to the list that was on screen, and keeping
    // only the page the player had reached would drop everything before it.
    final inventoryFuture = _repository.getInventory(type: state.inventoryCategory.type).run();
    final shopFuture = _repository.getShop(type: state.shopCategory.type).run();

    final config = await configFuture;
    final pokemons = await pokemonsFuture;
    final profile = await profileFuture;
    final inventory = await inventoryFuture;
    final shop = await shopFuture;

    final results = <Either<AppException, Object?>>[config, pokemons, profile, inventory, shop];
    // The five requests outlive the page when the player leaves while they are in flight; a closed cubit cannot emit.
    if (isClosed) return;
    if (results.any(_isNeedLogin)) {
      emit(state.copyWith(status: PokemonStatus.needLogin));
      return;
    }
    if (results.any((e) => e.isLeft())) {
      emit(state.copyWith(status: PokemonStatus.failure));
      return;
    }

    emit(
      state.copyWith(
        status: PokemonStatus.success,
        config: (config as Right<AppException, GlobalConfig>).value,
        pokemons: (pokemons as Right<AppException, List<Pokemon>>).value,
        profile: (profile as Right<AppException, PokemonUserProfile>).value,
        inventory: (inventory as Right<AppException, InventoryPage>).value,
        inventoryPage: 1,
        shop: (shop as Right<AppException, ShopPage>).value,
        shopPage: 1,
      ),
    );
    // The profile can lag behind the actual status bar pet (or not carry the flag at all), so read it like the website.
    await _syncStatusBarState();
  }

  /// Refresh every slice in place, without the full-page spinner; individual failures are ignored.
  Future<void> refreshAll() async {
    await Future.wait([refreshConfig(), refreshPokemons(), refreshProfile(), refreshInventory(), refreshShop()]);
  }

  /// Refresh the global config in place.
  Future<void> refreshConfig() async {
    final result = await _repository.getGlobalConfig().run();
    if (isClosed) return;
    result.fold((_) => null, (config) => emit(state.copyWith(config: config)));
  }

  /// Refresh the pokemon list in place.
  Future<void> refreshPokemons() async {
    final result = await _repository.getMyPokemon().run();
    if (isClosed) return;
    result.fold((_) => null, (pokemons) => emit(state.copyWith(pokemons: pokemons)));
  }

  /// Refresh the user profile in place.
  Future<void> refreshProfile() async {
    final result = await _repository.getProfile().run();
    if (isClosed) return;
    result.fold((_) => null, (profile) => emit(state.copyWith(profile: profile)));
  }

  /// Refresh the forum-side pokemon badge; returns the server message.
  ///
  /// The forum keeps its own serialized copy of the party, so the badge (and the level under the avatar) stays stale
  /// until this is called.
  Future<PokemonActionResult> refreshBadge() async {
    // The badge and the status bar pet are one row on the forum, so keep the pet hidden when the profile says it is.
    final result = await _repository.refreshBadge(hide: state.profile?.statusBarHidden ?? false).run();
    return result.fold(
      (e) => PokemonActionResult(success: false, message: e is PokemonApiException ? e.message : null),
      (data) => PokemonActionResult(success: true, message: data['message']?.toString()),
    );
  }

  /// Set the forum status bar pet (hide it, or refresh/show it) with the call the website itself makes.
  ///
  /// `refresh_badge` answers `{message, hidden}`; a plugin build whose `refresh_badge` predates the `hide` parameter
  /// answers without that field, which is reported as `notApplied` instead of pretending the switch worked.
  ///
  /// The switch flips right away: the call takes seconds, and the platform client parks a request the OS suspends, so a
  /// player who leaves the app before the answer lands would otherwise see nothing happen. Such a switch stays
  /// [_pendingStatusBar] and [reconcileStatusBar] finishes it when the app comes back.
  Future<StatusBarOutcome> setStatusBar({required bool hide}) async {
    _pendingStatusBar = hide;
    _emitStatusBarHidden(hide);
    final result = await _repository.refreshBadge(hide: hide).run();
    if (isClosed) return StatusBarOutcome.failed;
    if (result.isLeft()) {
      final error = result.fold((e) => e, (_) => null);
      _pendingStatusBar = null;
      // Put the switch back to whatever the server still has.
      await refreshProfile();
      return error is PokemonApiException && error.code == 401
          ? StatusBarOutcome.notLoggedIn
          : StatusBarOutcome.failed;
    }
    final data = result.fold((_) => const <String, dynamic>{}, (value) => value);
    // Hiding must be confirmed by the answer; refreshing is what the request itself does.
    final applied = !hide || (statusBarHiddenFromBadge(data) ?? false);
    if (applied) {
      _pendingStatusBar = null;
    }
    await refreshProfile();
    if (isClosed) return StatusBarOutcome.failed;
    if (!applied) return StatusBarOutcome.notApplied;
    return hide ? StatusBarOutcome.hidden : StatusBarOutcome.shown;
  }

  /// Finish a status bar switch that was still in flight when the app went to the background, and read the real state
  /// back; called when the app comes back to the foreground.
  Future<void> reconcileStatusBar() async {
    final pending = _pendingStatusBar;
    _pendingStatusBar = null;
    if (pending != null) {
      await setStatusBar(hide: pending);
      return;
    }
    await refreshProfile();
    await _syncStatusBarState();
  }

  /// Show [hidden] in the profile the status bar switch reads, until the server confirms the change.
  void _emitStatusBarHidden(bool hidden) {
    final profile = state.profile;
    if (profile == null || isClosed) return;
    emit(state.copyWith(profile: profile.copyWith(statusBarHidden: hidden)));
  }

  /// Read the status bar state the way the website does (`user&action=badge_status`) and put it in the profile the
  /// switch reads; a plugin build without that action keeps whatever the profile said.
  Future<void> _syncStatusBarState() async {
    final result = await _repository.badgeStatus().run();
    if (isClosed || result.isLeft()) return;
    final hidden = statusBarHiddenFromBadge(result.fold((_) => const <String, dynamic>{}, (value) => value));
    final profile = state.profile;
    if (hidden == null || profile == null || profile.statusBarHidden == hidden) return;
    emit(state.copyWith(profile: profile.copyWith(statusBarHidden: hidden)));
  }

  /// Refresh the inventory in place, for the currently selected category.
  ///
  /// Like the shop, the list starts at its first page again rather than keeping only the page the player had reached.
  Future<void> refreshInventory() async {
    final category = state.inventoryCategory;
    final result = await _repository.getInventory(type: category.type).run();
    if (isClosed) return;
    result.fold((_) => null, (inventory) {
      if (state.inventoryCategory != category) return;
      emit(state.copyWith(inventory: inventory, inventoryPage: 1));
    });
  }

  /// Switch the inventory to [category] and load its first page.
  Future<void> setInventoryCategory(ShopCategory category) async {
    emit(state.copyWith(inventoryCategory: category, inventoryPage: 1, clearInventory: true));
    await refreshInventory();
  }

  /// Refresh the shop in place, for the currently selected category.
  ///
  /// The list starts at its first page again: the pages loaded after it belong to the list that was on screen, and
  /// replacing them with just the page the player had reached would drop everything before it (with `loadMore` only
  /// going forward, only a reload could bring it back).
  Future<void> refreshShop() async {
    if (state.shopCategory.isPet) {
      final result = await _repository.getShopPets().run();
      if (isClosed) return;
      // The player may have switched category while the answer was on its way: it belongs to the old one.
      result.fold((_) => null, (pets) {
        if (!state.shopCategory.isPet) return;
        emit(state.copyWith(shopPets: pets, shopPage: 1));
      });
      return;
    }
    final result = await _repository.getShop(type: state.shopCategory.type).run();
    if (isClosed) return;
    result.fold((_) => null, (shop) {
      if (state.shopCategory.isPet) return;
      emit(state.copyWith(shop: shop, shopPage: 1));
    });
  }

  /// Switch the shop to [category] and load its first page.
  Future<void> setShopCategory(ShopCategory category) async {
    emit(state.copyWith(shopCategory: category, shopPage: 1, clearShop: true, clearPets: true));
    await refreshShop();
  }

  /// Load the next page of the inventory, for the currently selected category.
  Future<void> loadMoreInventory() async {
    final current = state.inventory;
    if (_loadingMoreInventory || current == null || state.inventoryPage >= current.totalPages) return;
    _loadingMoreInventory = true;
    try {
      final next = state.inventoryPage + 1;
      final result = await _repository.getInventory(page: next, type: state.inventoryCategory.type).run();
      if (isClosed) return;
      result.fold(
        (_) => null,
        (page) {
          // The player may have switched category (or gone to another page) while this answer was on its way, and that
          // page does not belong to the list that is on screen now. `next - 1` is the page the request started from.
          if (state.inventoryPage != next - 1) return;
          emit(
            state.copyWith(
              inventory: InventoryPage(
                items: [...current.items, ...page.items],
                total: page.total,
                page: page.page,
                perPage: page.perPage,
                totalPages: page.totalPages,
              ),
              inventoryPage: next,
            ),
          );
        },
      );
    } finally {
      _loadingMoreInventory = false;
    }
  }

  /// Load every remaining page of the inventory, so a search covers all items instead of only the loaded page.
  Future<void> loadAllInventory() async {
    var guard = 0;
    while (!isClosed && guard < 50 && state.inventoryPage < (state.inventory?.totalPages ?? 1)) {
      guard++;
      final before = state.inventoryPage;
      await loadMoreInventory();
      if (state.inventoryPage == before) break;
    }
  }

  /// Load the next page of the shop, for the currently selected category (items or pets).
  Future<void> loadMoreShop() async {
    if (_loadingMoreShop) return;
    final totalPages = state.shopCategory.isPet ? (state.shopPets?.totalPages ?? 1) : (state.shop?.totalPages ?? 1);
    if (state.shopPage >= totalPages) return;
    _loadingMoreShop = true;
    try {
      if (state.shopCategory.isPet) {
        final current = state.shopPets;
        if (current == null) return;
        final next = state.shopPage + 1;
        final result = await _repository.getShopPets(page: next).run();
        if (isClosed) return;
        result.fold(
          (_) => null,
          (page) {
            // The player may have switched category while this answer was on its way: it does not belong to that list.
            if (!state.shopCategory.isPet || state.shopPage != next - 1) return;
            emit(
              state.copyWith(
                shopPets: ShopPetsPage(
                  pets: [...current.pets, ...page.pets],
                  total: page.total,
                  page: page.page,
                  perPage: page.perPage,
                  totalPages: page.totalPages,
                ),
                shopPage: next,
              ),
            );
          },
        );
        return;
      }
      final current = state.shop;
      if (current == null) return;
      final next = state.shopPage + 1;
      final result = await _repository.getShop(page: next, type: state.shopCategory.type).run();
      if (isClosed) return;
      result.fold(
        (_) => null,
        (page) {
          // The player may have switched category while this answer was on its way: it does not belong to that list.
          if (state.shopCategory.isPet || state.shopPage != next - 1) return;
          emit(
            state.copyWith(
              shop: ShopPage(
                items: [...current.items, ...page.items],
                total: page.total,
                page: page.page,
                perPage: page.perPage,
                totalPages: page.totalPages,
              ),
              shopPage: next,
            ),
          );
        },
      );
    } finally {
      _loadingMoreShop = false;
    }
  }

  /// Load every remaining page of the shop, so a search covers all entries instead of only the loaded page.
  Future<void> loadAllShop() async {
    var guard = 0;
    while (!isClosed && guard < 50) {
      final totalPages = state.shopCategory.isPet ? (state.shopPets?.totalPages ?? 1) : (state.shop?.totalPages ?? 1);
      if (state.shopPage >= totalPages) break;
      guard++;
      final before = state.shopPage;
      await loadMoreShop();
      if (state.shopPage == before) break;
    }
  }

  /// Set pokemon [id] as the first pokemon.
  Future<PokemonActionResult> setFirst(int id) async {
    final result = await _runVoid(() => _repository.setFirst(id));
    if (result.success) await refreshPokemons();
    return result;
  }

  /// Move pokemon [id] to [site] (1=first, 2=bag, 3=storage).
  Future<PokemonActionResult> movePokemon(int id, int site) async {
    final result = await _runVoid(() => _repository.movePokemon(id, site));
    if (result.success) await refreshPokemons();
    return result;
  }

  /// Rename pokemon [id] to [name].
  Future<PokemonActionResult> rename(int id, String name) async {
    final result = await _runVoid(() => _repository.rename(id, name));
    if (result.success) await refreshPokemons();
    return result;
  }

  /// Release pokemon [id].
  Future<PokemonActionResult> release(int id) async {
    final result = await _runVoid(() => _repository.release(id));
    if (result.success) await refreshPokemons();
    return result;
  }

  /// Heal pokemon [id].
  Future<PokemonActionResult> heal(int id) => _heal(id, flee: false);

  /// Flee any active battle and heal pokemon [id].
  Future<PokemonActionResult> healAndFlee(int id) => _heal(id, flee: true);

  Future<PokemonActionResult> _heal(int id, {required bool flee}) async {
    // Optimistically heal the pokemon in place so the UI reacts immediately.
    final pokemon = _findPokemon(id);
    if (pokemon != null) {
      _replacePokemon(_healedCopy(pokemon));
    }
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await (flee ? _repository.healAndFlee(id) : _repository.heal(id)).run();
      final actionResult = switch (result) {
        Left(:final value) => PokemonActionResult(success: false, message: _messageOf(value)),
        Right(:final value) => PokemonActionResult(success: true, message: value.message),
      };
      if (!actionResult.success) await refreshPokemons();
      return actionResult;
    } on Object catch (e) {
      return PokemonActionResult(success: false, message: '$e');
    } finally {
      if (!isClosed) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Use item [itemId], optionally on pokemon [pokemonId].
  Future<PokemonActionResult> useItem(int itemId, {int? pokemonId}) async {
    final result = await _runVoid(() => _repository.useItem(itemId, pokemonId: pokemonId));
    if (result.success) await Future.wait([refreshInventory(), refreshPokemons()]);
    return result;
  }

  /// Buy [quantity] of shop item [itemId].
  Future<PokemonActionResult> buy(int itemId, int quantity) async {
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await _repository.buy(itemId, quantity).run();
      final actionResult = switch (result) {
        Left(:final value) => PokemonActionResult(success: false, message: _messageOf(value)),
        Right(:final value) => PokemonActionResult(success: true, message: value.message),
      };
      if (actionResult.success) {
        await Future.wait([refreshShop(), refreshProfile()]);
      } else if (actionResult.message == null) {
        // A purchase that lost its answer may have gone through: read the money and the bag back before the player
        // tries again.
        await _reloadAfterLostAnswer();
        await refreshShop();
      }
      return actionResult;
    } on Object catch (e) {
      return PokemonActionResult(success: false, message: '$e');
    } finally {
      if (!isClosed) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Buy [quantity] of pet species [typeId].
  Future<PokemonActionResult> buyPet(int typeId, {int quantity = 1}) async {
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await _repository.buyPet(typeId, quantity: quantity).run();
      final actionResult = switch (result) {
        Left(:final value) => PokemonActionResult(success: false, message: _messageOf(value)),
        Right(:final value) => PokemonActionResult(success: true, message: value.message),
      };
      if (actionResult.success) {
        await Future.wait([refreshShop(), refreshProfile(), refreshPokemons()]);
      } else if (actionResult.message == null) {
        // A purchase that lost its answer may have gone through: read the money, the bag and the party back before the
        // player tries again.
        await _reloadAfterLostAnswer();
        await refreshShop();
        await refreshPokemons();
      }
      return actionResult;
    } on Object catch (e) {
      return PokemonActionResult(success: false, message: '$e');
    } finally {
      if (!isClosed) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Run a void action and report success/failure.
  Future<PokemonActionResult> _runVoid(AsyncVoidEither Function() action) async {
    emit(state.copyWith(actionInProgress: true));
    try {
      final result = await action().run();
      final message = result.fold(_messageOf, (_) => null);
      // A write that lost its answer may or may not have happened on the server, so read the money and the bag back
      // before the player tries again.
      if (result.isLeft() && message == null) unawaited(_reloadAfterLostAnswer());
      return PokemonActionResult(success: result.isRight(), message: message);
    } on Object catch (e) {
      unawaited(_reloadAfterLostAnswer());
      return PokemonActionResult(success: false, message: '$e');
    } finally {
      if (!isClosed) emit(state.copyWith(actionInProgress: false));
    }
  }

  /// Read back what a write with a lost answer may have changed: the money and the bag.
  Future<void> _reloadAfterLostAnswer() async {
    await refreshProfile();
    await refreshInventory();
  }

  /// Find a pokemon by id in the current state, or null.
  Pokemon? _findPokemon(int id) {
    final pokemons = state.pokemons;
    if (pokemons == null) return null;
    for (final pokemon in pokemons) {
      if (pokemon.id == id) return pokemon;
    }
    return null;
  }

  /// Replace the pokemon with the same id as [updated] in the current state.
  void _replacePokemon(Pokemon updated) {
    final pokemons = state.pokemons;
    if (pokemons == null) return;
    emit(state.copyWith(pokemons: [for (final pokemon in pokemons) pokemon.id == updated.id ? updated : pokemon]));
  }

  /// Optimistically healed copy of [pokemon]: HP to max, and a negative state reset to normal.
  ///
  /// The views read the state code rather than the server's Chinese `state_text`, so the state itself is all there is
  /// to reset here.
  Pokemon _healedCopy(Pokemon pokemon) {
    final reset = pokemon.hp <= 0 || pokemon.isNegativeState;
    return pokemon.copyWith(hp: pokemon.maxHp, state: reset ? 1 : pokemon.state);
  }

  /// Message of a pokemon api failure: only the server's own business message, so the UI can show a friendly hint
  /// for network/timeout errors instead of raw exception text.
  String? _messageOf(AppException e) => e is PokemonApiException ? e.message : null;

  bool _isNeedLogin(Either<AppException, Object?> e) =>
      e is Left<AppException, Object?> && e.value is PokemonApiException && (e.value as PokemonApiException).code == 401;
}
