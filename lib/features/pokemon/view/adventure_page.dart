import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/features/pokemon/view/battle_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The adventure (冒险) page: world map (regions) -> region maps -> map detail -> battle.
class AdventurePage extends StatefulWidget {
  /// Constructor.
  const AdventurePage({super.key});

  @override
  State<AdventurePage> createState() => _AdventurePageState();
}

class _AdventurePageState extends State<AdventurePage> {
  late final AdventureCache _cache;
  bool _loading = true;
  bool _failed = false;
  bool _needLogin = false;
  String? _failureMessage;

  /// Selected region id; null shows the world map (region list).
  String? _region;

  /// Classic mode: show every map as one flat list instead of world map -> region -> map.
  bool _classic = false;

  /// Whether a map detail sheet / battle start is already in flight, so a double tap cannot start two battles.
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    _cache = getIt.get<AdventureCache>();
    _loading = !_cache.hasData;
    unawaited(_restoreMode());
    unawaited(_load());
  }

  /// Restore the remembered world-map / classic-list choice.
  Future<void> _restoreMode() async {
    final classic = await _cache.isClassicMode();
    if (mounted && classic != _classic) setState(() => _classic = classic);
  }

  /// Switch the map list mode and remember it for the next visit.
  Future<void> _setClassicMode(bool classic) async {
    setState(() => _classic = classic);
    await _cache.setClassicMode(classic: classic);
  }

  /// Resume an unfinished battle and refresh maps/pokemon concurrently.
  Future<void> _load() async {
    // A battle cannot appear between two entries a moment apart, so a fresh "no battle" answer is reused.
    final askedForBattle = !_cache.battleCheckFresh;
    final recoverFuture = askedForBattle ? _cache.recoverBattle().run() : null;
    final mapsFuture = _cache.refreshMaps();
    // Rebuild once the pokemon list arrives so the challenge advice is up to date.
    unawaited(
      _cache.refreshPokemons().then((_) {
        if (mounted) setState(() {});
      }),
    );
    final recover = recoverFuture == null ? null : await recoverFuture;
    final maps = await mapsFuture;
    if (!mounted) return;
    // Trust the answer for a few seconds, but only when it was actually asked for.
    if (askedForBattle) {
      if (recover case Right(value: null)) _cache.markNoBattle();
    }

    if (recover case Left(:final value) when value is PokemonApiException && value.code == 401) {
      setState(() {
        _needLogin = true;
        _loading = false;
      });
      return;
    }
    BattleScene? active;
    if (recover case Right(:final value)) {
      active = value;
    }

    // Only an actually running battle is resumed: a finished scene (like the defeat the player just confirmed) would
    // otherwise pop the battle page right back open as soon as the adventure page reloads.
    if (active != null && active.isActive) {
      if (_cache.isBattleFinished(active)) {
        // A battle the player already finished but the server still keeps: end it in the background and stay here.
        unawaited(_cache.flee(active.battleId).run());
      } else {
        setState(() => _loading = false);
        await context.pushNamed(ScreenPaths.pokemonBattle, extra: BattlePageArgs.resume(active, mapId: active.mapId));
        if (mounted) await _load();
        return;
      }
    } else {
      // Nothing is running, so no finished battle can still be resumed.
      _cache.clearFinishedBattles();
    }

    maps.fold(
      (e) => setState(() {
        _loading = false;
        // Keep showing the cached list when a background refresh fails.
        if (_cache.hasData) {
          _failed = false;
          return;
        }
        _failed = true;
        _failureMessage = e.message;
      }),
      (_) => setState(() {
        _loading = false;
        _failed = false;
      }),
    );
  }

  /// Start a battle on [mapId] and return the ready scene (null + a snack bar on failure).
  ///
  /// The party is healed first when a pet needs it, the way the website sets off (`get_injured_pokemons()` then
  /// `heal_pokemon` in `rust/game/src/pages/adventure.rs`), so a fight starts from a full party. A refusal that still
  /// asks for healing is answered by healing again and retrying, so a fainted pet does not keep the player from setting
  /// off either.
  Future<BattleScene?> _startBattle(int mapId, {int? bossTypeId}) async {
    // A battle is about to run: the remembered "no battle" answer no longer holds.
    _cache.invalidateBattleCheck();
    await _cache.healParty();
    if (!mounted) return null;
    var result = await _cache.startBattle(mapId, bossTypeId: bossTypeId).run();
    if (result.isLeft() && petNeedsHealingError(result.fold((e) => e, (_) => null))) {
      await _cache.healParty();
      if (!mounted) return null;
      result = await _cache.startBattle(mapId, bossTypeId: bossTypeId).run();
    }
    return result.fold(
      (e) {
        showSnackBar(context: context, message: pokemonErrorText(context, e));
        return null;
      },
      (scene) => scene,
    );
  }

  /// Open the map detail sheet; on "start" push the battle page with the ready scene (no loading screen).
  ///
  /// The guard only covers the sheet. It used to stay set while the battle page was open and while the map list was
  /// reloaded afterwards, which silently swallowed every tap for seconds after a fight.
  Future<void> _openMap(AdventureMap map) async {
    if (_sheetOpen) return;
    (BattleScene, int?)? started;
    _sheetOpen = true;
    try {
      started = await showModalBottomSheet<(BattleScene, int?)>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _MapDetailSheet(
          map: map,
          trainerLevel: _cache.activePokemonLevel,
          onStart: ({bossTypeId}) => _startBattle(map.id, bossTypeId: bossTypeId),
        ),
      );
    } finally {
      _sheetOpen = false;
    }
    if (started == null || !mounted) return;
    await context.pushNamed(
      ScreenPaths.pokemonBattle,
      extra: BattlePageArgs.resume(started.$1, mapId: map.id, bossTypeId: started.$2),
    );
    // Refresh in the background: waiting for it here kept the page busy for another round trip or two.
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.adventure;
    final maps = _cache.maps;
    final Widget body;
    if (_needLogin) {
      body = Center(child: Text(tr.loginRequired));
    } else if (maps == null) {
      body = _failed
          ? buildRetryButton(context, () => unawaited(_load()), message: _failureMessage ?? tr.failedToLoad)
          : const CenteredCircularIndicator();
    } else if (maps.isEmpty) {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr.empty)))],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: _classic
            ? _buildClassicMaps(context, maps)
            : _region == null
            ? _buildWorldMap(context, maps)
            : _buildRegion(context, maps),
      );
    }
    final showBack = !_classic && _region != null;
    return PopScope(
      canPop: !showBack,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && showBack) setState(() => _region = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(showBack ? pokemonRegionName(_region!) : tr.title),
          leading: showBack
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _region = null))
              : null,
          actions: [
            IconButton(
              icon: Icon(_classic ? Icons.map_outlined : Icons.view_list_outlined),
              tooltip: _classic ? tr.regionMode : tr.classicMode,
              onPressed: () => unawaited(_setClassicMode(!_classic)),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: tr.refresh,
              onPressed: _loading ? null : () => unawaited(_load()),
            ),
          ],
        ),
        body: SafeArea(child: body),
      ),
    );
  }

  /// World map: one card per region, with how many adventure spots it holds.
  Widget _buildWorldMap(BuildContext context, List<AdventureMap> maps) {
    final tr = context.t.adventure;
    final counts = <String, int>{};
    for (final map in maps) {
      // Group by the display name so region synonyms (e.g. central/中央) share one card.
      final id = pokemonRegionName(map.region);
      counts[id] = (counts[id] ?? 0) + 1;
    }
    final regions = counts.keys.toList()..sort((a, b) => pokemonRegionOrder(a).compareTo(pokemonRegionOrder(b)));
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: regions.length,
      itemBuilder: (context, index) {
        final id = regions[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.public),
            title: Text(pokemonRegionName(id)),
            subtitle: Text(tr.mapCount(count: counts[id] ?? 0)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _region = id),
          ),
        );
      },
    );
  }

  /// Region maps: the adventure spots of the selected region.
  Widget _buildRegion(BuildContext context, List<AdventureMap> maps) {
    final tr = context.t.adventure;
    final regionMaps = maps.where((m) => pokemonRegionName(m.region) == _region).toList();
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: regionMaps.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              '${pokemonRegionName(_region ?? '')} · ${tr.mapCount(count: regionMaps.length)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          );
        }
        final map = regionMaps[index - 1];
        return _MapCard(map: map, trainerLevel: _cache.activePokemonLevel, onTap: () => unawaited(_openMap(map)));
      },
    );
  }

  /// Classic mode: every map as one flat list; tapping one still opens the detail sheet.
  Widget _buildClassicMaps(BuildContext context, List<AdventureMap> maps) => ListView.builder(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(8),
    itemCount: maps.length,
    itemBuilder: (context, index) =>
        _MapCard(map: maps[index], trainerLevel: _cache.activePokemonLevel, onTap: () => unawaited(_openMap(maps[index]))),
  );
}

/// One map card in the region list.
class _MapCard extends StatelessWidget {
  const _MapCard({required this.map, required this.trainerLevel, required this.onTap});

  /// The map this card shows.
  final AdventureMap map;

  /// Strongest pokemon level of the trainer, for the challenge advice; null when unknown.
  final int? trainerLevel;

  /// Called when the card is tapped.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.adventure;
    final advice = adventureAdviceFor(minLevel: map.minLevel, maxLevel: map.maxLevel, trainerLevel: trainerLevel);
    final (adviceText, adviceColor) = _adviceText(context, advice, trainerLevel);
    final areaColor = pokemonAreaColor(map.areaType);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(pokemonAreaEmoji(map.areaType), style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      map.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (map.areaTypeName.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: areaColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: areaColor.withValues(alpha: 0.5)),
                      ),
                      child: Text(map.areaTypeName, style: TextStyle(fontSize: 11, color: areaColor)),
                    ),
                ],
              ),
              if (map.mode != 'boss') ...[
                const SizedBox(height: 6),
                Text(adviceText, style: TextStyle(color: adviceColor, fontSize: 12)),
              ],
              const SizedBox(height: 2),
              Text(
                map.mode == 'boss'
                    ? '${tr.bossChallenge} · ${map.bosses?.length ?? 0}'
                    : tr.levelRange(min: map.minLevel, max: map.maxLevel),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Advice text + color for a difficulty.
(String, Color) _adviceText(BuildContext context, AdventureAdvice advice, int? trainerLevel) {
  final tr = context.t.adventure;
  final level = trainerLevel ?? 0;
  return switch (advice) {
    AdventureAdvice.good => (tr.adviceGood(level: level), Colors.green),
    AdventureAdvice.risky => (tr.adviceRisky(level: level), Colors.orange),
    AdventureAdvice.danger => (tr.adviceDanger(level: level), Colors.red),
    AdventureAdvice.lowReward => (tr.adviceLowReward, Colors.blueGrey),
    AdventureAdvice.unknown => (tr.adviceUnknown, Colors.grey),
  };
}

/// Bottom sheet showing one map's advice, basic info, wild pokemon and bosses, plus start/back.
class _MapDetailSheet extends StatefulWidget {
  const _MapDetailSheet({required this.map, required this.trainerLevel, required this.onStart});

  /// The map whose details are shown.
  final AdventureMap map;

  /// Strongest pokemon level of the trainer, for the challenge advice; null when unknown.
  final int? trainerLevel;

  /// Starts a battle (optionally a boss one) and returns the ready scene, or null on failure.
  final Future<BattleScene?> Function({int? bossTypeId}) onStart;

  @override
  State<_MapDetailSheet> createState() => _MapDetailSheetState();
}

class _MapDetailSheetState extends State<_MapDetailSheet> {
  bool _busy = false;

  Future<void> _start({int? bossTypeId}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final scene = await widget.onStart(bossTypeId: bossTypeId);
    if (!mounted) return;
    if (scene != null) {
      Navigator.of(context).pop((scene, bossTypeId));
    } else {
      setState(() => _busy = false);
    }
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.adventure;
    final map = widget.map;
    final advice = adventureAdviceFor(
      minLevel: map.minLevel,
      maxLevel: map.maxLevel,
      trainerLevel: widget.trainerLevel,
    );
    final (adviceText, adviceColor) = _adviceText(context, advice, widget.trainerLevel);
    final hasWild = map.mode != 'boss';
    final modeText = switch (map.mode) {
      'boss' => tr.modeBoss,
      'hybrid' => tr.modeHybrid,
      _ => tr.modeWild,
    };
    final bosses = map.bosses ?? const <AdventureBoss>[];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text(pokemonAreaEmoji(map.areaType), style: const TextStyle(fontSize: 24)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(map.name, style: Theme.of(context).textTheme.titleLarge)),
                ],
              ),
            ),
            if (hasWild) _section(tr.challengeAdvice, Text(adviceText, style: TextStyle(color: adviceColor))),
            _section(
              tr.basicInfo,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasWild) Text(tr.levelRange(min: map.minLevel, max: map.maxLevel)),
                  Text('${tr.terrainType}: ${map.areaTypeName}'),
                  Text('${tr.mapMode}: $modeText'),
                ],
              ),
            ),
            if (hasWild && map.wildPokemons.isNotEmpty)
              _section(
                tr.possiblePokemon,
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in map.wildPokemons)
                      Chip(visualDensity: VisualDensity.compact, label: Text(p.name)),
                  ],
                ),
              ),
            if (bosses.isNotEmpty)
              _section(
                tr.bossChallenge,
                Column(
                  children: [
                    for (final boss in bosses)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        enabled: !_busy,
                        leading: SizedBox(
                          width: 40,
                          height: 40,
                          child: CachedImage(
                            pokemonImageUrl(boss.pokemonTypeId),
                            width: 40,
                            height: 40,
                            fit: BoxFit.contain,
                          ),
                        ),
                        title: Text(boss.pokemonName),
                        subtitle: Text('${tr.level(level: boss.level)} · ×${boss.bossMultiplier}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => unawaited(_start(bossTypeId: boss.pokemonTypeId)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                children: [
                  if (hasWild)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : () => unawaited(_start()),
                        child: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(tr.startAdventure),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: Text(tr.back),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
