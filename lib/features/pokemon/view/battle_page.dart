import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/pokemon/cubit/battle_cubit.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/features/pokemon/repository/skill_order_store.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_dialogs.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/indicator.dart';

part 'battle_view.dart';

/// Arguments passed to [BattlePage] through the route `extra`.
class BattlePageArgs {
  /// Start a new battle.
  const BattlePageArgs.start({required this.mapId, this.bossTypeId}) : scene = null;

  /// Resume a battle already built elsewhere (recover, or started from the map detail).
  ///
  /// [mapId]/[bossTypeId] are remembered so the result dialog's "fight again" can restart the same fight.
  const BattlePageArgs.resume(this.scene, {this.mapId, this.bossTypeId});

  /// Map id for a new battle.
  final int? mapId;

  /// Boss species id for a new battle, when chosen.
  final int? bossTypeId;

  /// Scene to resume.
  final BattleScene? scene;
}

/// The battle page: turn-based fight against a wild pokemon or boss.
class BattlePage extends StatefulWidget {
  /// Constructor.
  const BattlePage({required this.args, super.key});

  /// Battle arguments.
  final BattlePageArgs args;

  @override
  State<BattlePage> createState() => _BattlePageState();
}

class _BattlePageState extends State<BattlePage> with WidgetsBindingObserver {
  late final BattleCubit _cubit;

  /// Guards the end-of-battle result dialog against being stacked twice.
  bool _resultShowing = false;

  /// Whether leaving the page already asked for the party heal, so the back handler does not ask a second time.
  bool _healingOnLeave = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cubit = BattleCubit();
    final args = widget.args;
    if (args.scene != null) {
      _cubit.resume(args.scene!);
    } else {
      unawaited(_cubit.start(args.mapId!, bossTypeId: args.bossTypeId));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cubit.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) unawaited(_handleResumed());
  }

  /// Handle the app coming back to the foreground.
  ///
  /// A request the OS parked while the app was away can keep the buttons disabled for as long as the platform client
  /// allows, so the cubit drops that wait and reads the battle from the server again.
  Future<void> _handleResumed() async {
    final result = await _cubit.onAppResumed();
    if (!mounted) return;
    switch (result) {
      case BattleResumeResult.nothing:
        return;
      case BattleResumeResult.refreshed:
        showSnackBar(context: context, message: context.t.battle.resynced);
      case BattleResumeResult.gone:
        showSnackBar(context: context, message: context.t.battle.endedWhileAway);
        context.pop();
      case BattleResumeResult.failed:
        _showError(context.t.general.networkError);
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
    value: _cubit,
    child: BlocListener<BattleCubit, BattleState>(
      listenWhen: (previous, current) =>
          current.scene != null && !current.scene!.isActive && (previous.scene?.isActive ?? false),
      listener: (context, state) => unawaited(_showResult(state.scene!)),
      child: BlocBuilder<BattleCubit, BattleState>(
        builder: (context, state) {
          final scene = state.scene;
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) {
                return;
              }
              unawaited(_handleBack());
            },
            child: Scaffold(
            appBar: AppBar(
              title: Text(
                scene == null
                    ? context.t.battle.title
                    : '${scene.mapName} · ${context.t.battle.turn(turn: state.turn)}',
              ),
            ),
            body: switch (state.status) {
              // Keep the current battle on screen while the next one starts (no full-page spinner flash).
              BattleStatus.loading when scene != null =>
                _buildBattleView(
                  scene,
                  busy: true,
                  wildGender: state.wildGender,
                  wildShiny: state.wildShiny,
                  skillOrder: state.skillOrder,
                  turn: state.turn,
                ),
              BattleStatus.loading => const CenteredCircularIndicator(),
              BattleStatus.needLogin => _NeedLogin(onRetry: () => unawaited(_cubit.start(widget.args.mapId!, bossTypeId: widget.args.bossTypeId))),
              BattleStatus.failure => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(state.failureMessage ?? context.t.battle.failedToLoad, textAlign: TextAlign.center),
                    ),
                    const SizedBox(height: 8),
                    if (widget.args.mapId != null)
                      // A pet that needs healing cannot be sent out, and the client already healed and retried once:
                      // point at the centre instead of offering a retry that would fail the same way.
                      if (petNeedsHealingMessage(state.failureMessage))
                        FilledButton(
                          onPressed: () => unawaited(context.pushNamed(ScreenPaths.pokemon, extra: 1)),
                          child: Text(context.t.battle.goToCenter),
                        )
                      // The server no longer has this battle (it ended on its own, or another client took it over):
                      // asking again would fail the same way, so go back to the map instead.
                      else if (battleAlreadyOverMessage(state.failureMessage))
                        FilledButton(
                          onPressed: _leaveHealingParty,
                          child: Text(context.t.battle.backToMap),
                        )
                      else
                        TextButton(
                          onPressed: () => unawaited(
                            _cubit.start(widget.args.mapId!, bossTypeId: widget.args.bossTypeId),
                          ),
                          child: Text(context.t.general.retry),
                        ),
                  ],
                ),
              ),
              BattleStatus.success when scene == null => const CenteredCircularIndicator(),
              BattleStatus.success =>
                _buildBattleView(
                  scene!,
                  busy: state.actionInProgress,
                  wildGender: state.wildGender,
                  wildShiny: state.wildShiny,
                  skillOrder: state.skillOrder,
                  turn: state.turn,
                ),
            },
            ),
          );
        },
      ),
    ),
  );

  Widget _buildBattleView(
    BattleScene scene, {
    required bool busy,
    int? wildGender,
    bool? wildShiny,
    List<int> skillOrder = const [],
    int turn = 1,
  }) => _BattleView(
    scene: scene,
    busy: busy,
    wildGender: wildGender,
    wildShiny: wildShiny,
    skillOrder: skillOrder,
    turn: turn,
    onSkill: (id) => unawaited(_useSkill(id)),
    onItem: () => unawaited(_useItem()),
    onCapture: () => unawaited(_capture()),
    onSwitch: () => unawaited(_switch()),
    onFlee: () => unawaited(_flee()),
    onHealAndFlee: () => unawaited(_healAndFlee()),
  );

  Future<void> _useSkill(int skillId) async {
    final result = await _cubit.useSkill(skillId);
    if (!mounted) return;
    if (!result.success) _showError(result.message);
  }

  Future<void> _flee() async {
    final result = await _cubit.flee();
    if (!mounted) return;
    if (!result.success) {
      _showError(result.message);
      return;
    }
    // The plugin rolls for the escape and the wild pokemon hits back when it fails, so a flee that left the battle
    // running has to say so instead of looking like the tap was ignored.
    final scene = _cubit.state.scene;
    if (scene != null && scene.isActive) _showSnack(scene.message ?? context.t.battle.fleeFailed);
  }

  /// Leave the battle and heal the battling pokemon at the center, then close the battle page.
  Future<void> _healAndFlee() async {
    final result = await _cubit.healAndFlee();
    if (!mounted) return;
    if (!result.success) {
      _showError(result.message);
      return;
    }
    _showSnack(result.message ?? context.t.pokemon.actionSuccess);
    context.pop();
  }

  void _showSnack(String message) => showSnackBar(context: context, message: message);

  Future<void> _switch() async {
    final scene = _cubit.state.scene;
    if (scene == null) return;
    final pokemons = await _cubit.loadPokemons();
    if (!mounted) return;
    final currentId = scene.myPokemon.instanceId;
    final usable = pokemons.where((p) => p.hp > 0 && p.state != 0 && p.isCarried && p.id != currentId).toList();
    if (usable.isEmpty) {
      _showError(context.t.battle.noSwitchable);
      return;
    }
    final picked = await showModalBottomSheet<Pokemon>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(context.t.battle.switchPokemon)),
            for (final p in usable)
              ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 40,
                  child: CachedImage(pokemonImageUrl(p.typeId), width: 40, height: 40, fit: BoxFit.contain),
                ),
                title: Text(p.displayName),
                subtitle: Text('${context.t.pokemon.level(level: p.level)} · ${context.t.pokemon.hp} ${p.hp}/${p.maxHp}'),
                onTap: () => Navigator.of(context).pop(p),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final result = await _cubit.switchPokemon(pokemonId: picked.id);
    if (!mounted) return;
    if (!result.success) _showError(result.message);
  }

  /// Handle the back navigation: ask whether to flee when the battle is still active.
  /// Leave the battle page, asking for the party heal first.
  ///
  /// The plugin never heals a pokemon on its own, so every way out of this page goes through here: the result dialog's
  /// "ok" and the back button used to differ, which left a party that was hurt in the fight unhealed on one of them. The
  /// pop does not wait for the answer (the heal is best effort and takes a round trip).
  void _leaveHealingParty() {
    if (!mounted) return;
    if (!_healingOnLeave) {
      _healingOnLeave = true;
      unawaited(_cubit.healParty());
    }
    context.pop();
  }

  Future<void> _handleBack() async {
    final scene = _cubit.state.scene;
    if (scene == null || !scene.isActive) {
      // The fight is over (or never started): leaving is the same as the result dialog's "ok".
      _leaveHealingParty();
      return;
    }
    final tr = context.t.battle;
    final leave = await showPokemonConfirmDialog(
      context: context,
      icon: Icons.directions_run,
      title: tr.flee,
      message: tr.confirmFlee,
      confirmLabel: tr.flee,
      dangerous: true,
    );
    if (!leave || !mounted) return;
    final result = await _cubit.flee();
    if (!mounted) return;
    if (!result.success) {
      _showError(result.message);
      return;
    }
    final current = _cubit.state.scene;
    if (current != null && current.isActive) {
      // The escape failed (and the wild pokemon answered), so stay here: leaving would let the battle run on unseen.
      // The result dialog takes over instead once a flee does succeed.
      _showSnack(current.message ?? context.t.battle.fleeFailed);
      return;
    }
  }

  Future<void> _capture() async {
    final balls = await _cubit.loadBalls();
    if (!mounted) return;
    if (balls.isEmpty) {
      _showError(context.t.battle.noBalls);
      return;
    }
    final ball = await showModalBottomSheet<InventoryItem>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(context.t.battle.capture)),
            for (final item in balls)
              ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 40,
                  child: item.image.isEmpty
                      ? const Icon(Icons.catching_pokemon)
                      : CachedImage(pokemonItemImageUrl(item.image), width: 40, height: 40, fit: BoxFit.contain),
                ),
                title: Text(item.name),
                subtitle: Text('×${item.quantity}'),
                onTap: () => Navigator.of(context).pop(item),
              ),
          ],
        ),
      ),
    );
    if (ball == null || !mounted) return;
    final result = await _cubit.capture(ball.typeId);
    if (!mounted) return;
    if (!result.success) _showError(result.message);
  }

  Future<void> _useItem() async {
    final items = await _cubit.loadBattleItems();
    if (!mounted) return;
    if (items.isEmpty) {
      _showError(context.t.battle.noItems);
      return;
    }
    final item = await showModalBottomSheet<BattleItem>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(context.t.battle.items)),
            for (final i in items)
              ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 40,
                  child: CachedImage(pokemonItemImageUrl(i.img), width: 40, height: 40, fit: BoxFit.contain),
                ),
                title: Text(i.name),
                subtitle: Text('×${i.nums}'),
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (item == null || !mounted) return;
    final result = await _cubit.useItem(item.id);
    if (!mounted) return;
    if (result.requiresSkillSelection) {
      final skill = await _pickSkill(result.availableSkills ?? const <BattleSkill>[]);
      if (skill == null || !mounted) return;
      final r2 = await _cubit.useItemOnSkill(item.id, skill.id);
      if (!mounted) return;
      if (!r2.success) _showError(r2.message);
    } else if (result.message != null) {
      _showError(result.message);
    }
  }

  Future<BattleSkill?> _pickSkill(List<BattleSkill> skills) async {
    if (skills.isEmpty) return null;
    // Same device-local order as the skill buttons.
    final ordered = SkillOrderStore.apply(skills, _cubit.state.skillOrder, (s) => s.id);
    return showModalBottomSheet<BattleSkill>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(context.t.battle.useOnSkill)),
            for (final skill in ordered)
              ListTile(
                title: Text(skill.name ?? ''),
                subtitle: Text('PP ${skill.pp}/${skill.maxPp}'),
                onTap: () => Navigator.of(context).pop(skill),
              ),
          ],
        ),
      ),
    );
  }

  void _showError(String? message) {
    showSnackBar(
      context: context,
      message: pokemonMessageHint(context, message ?? context.t.general.networkError),
    );
  }

  Future<void> _showResult(BattleScene scene) async {
    if (_resultShowing) return;
    _resultShowing = true;
    try {
      final tr = context.t.battle;
      final title = switch (scene.status) {
        'victory' => tr.victory,
        'captured' => tr.captured,
        'fled' => tr.fled,
        'defeat' => tr.defeat,
        _ => scene.status,
      };
      final lines = <String>[
        if ((scene.message ?? '').isNotEmpty) scene.message!,
        if (scene.rewards != null) tr.rewards(exp: scene.rewards!.exp, money: scene.rewards!.money),
        if (scene.levelUp != null && scene.levelUp!.levelUp) tr.levelUp(level: scene.levelUp!.newLevel),
      ];
      // The forum stores its own copy of the party, so push the badge when the battle changed it.
      if ((scene.levelUp?.levelUp ?? false) || scene.status == 'captured') {
        unawaited(_cubit.refreshBadge());
      }
      final mapId = widget.args.mapId;
      final again = await showDialog<bool>(
        context: context,
        builder: (context) => CustomAlertDialog.sync(
          title: AppDialogTitle(icon: Icons.emoji_events_outlined, title: title),
          content: Text(lines.join('\n')),
          actions: [
            TextButton(onPressed: () => context.pop(false), child: Text(tr.ok)),
            // A successful escape only needs an acknowledgement; there is nothing there to fight again.
            if (mapId != null && scene.status != 'fled')
              FilledButton(onPressed: () => context.pop(true), child: Text(tr.again)),
          ],
        ),
      );
      if (!mounted) return;
      // A defeat does not always end the server-side battle (the plugin keeps it while a usable backup pokemon exists),
      // which would make the adventure page resume the finished battle. End it here instead of leaving the player to
      // flee by hand; the battle is remembered so the adventure page never resumes it even if ending it failed.
      if (scene.status == 'defeat') {
        getIt.get<AdventureCache>().markBattleFinished(scene);
        final result = await _cubit.finishDefeat(scene);
        if (!mounted) return;
        if (!result.success) _showError(result.message);
      }
      if (mapId != null && again == true) {
        // Healing happens inside, after the page is already marked busy, so the tap is acknowledged immediately; only
        // the pet that just fought is healed (the scene knows its HP and PP).
        await _cubit.fightAgain(mapId, bossTypeId: widget.args.bossTypeId);
        return;
      }
      // Leaving the fight heals the party too, but the pop must not wait for it: the battle can leave a pokemon hurt,
      // out of skill PP or in an abnormal state and the server heal is free, so run it in the background.
      _leaveHealingParty();
    } finally {
      _resultShowing = false;
    }
  }
}
