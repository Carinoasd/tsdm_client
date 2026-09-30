import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/features/pokemon/repository/skill_order_store.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_dialogs.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_style.dart';
import 'package:tsdm_client/features/pokemon/widgets/pokemon_evolution_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Detail page of a single pokemon: abilities, skills and quick actions.
class PokemonDetailPage extends StatefulWidget {
  /// Constructor.
  const PokemonDetailPage({required this.pokemon, super.key});

  /// Basic pokemon info from the list; the full detail (with stats) is fetched here.
  final Pokemon pokemon;

  @override
  State<PokemonDetailPage> createState() => _PokemonDetailPageState();
}

class _PokemonDetailPageState extends State<PokemonDetailPage> {
  final PokemonRepository _repository = PokemonRepository();
  final SkillOrderStore _skillOrder = SkillOrderStore();
  Pokemon? _detail;
  bool _loading = true;
  bool _failed = false;
  bool _actionInProgress = false;

  /// Locally maintained skills after a learn/forget; the production detail endpoint returns empty skill slots.
  List<PokemonSkill>? _skillsOverride;

  /// Skill ids in the order the player dragged them into (device-only, the plugin has no reorder API).
  List<int> _savedOrder = const [];

  /// Effective skills: the detail's when it has any, otherwise the list item's (the `list` endpoint fills them).
  List<PokemonSkill> get _skills {
    final override = _skillsOverride;
    if (override != null) return override;
    final fromDetail = _detail?.skills.where((s) => !s.isEmpty).toList() ?? const <PokemonSkill>[];
    final base = fromDetail.isNotEmpty ? fromDetail : widget.pokemon.skills.where((s) => !s.isEmpty).toList();
    return SkillOrderStore.apply(base, _savedOrder, (s) => s.typeId);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Load the detail; when [silent] the page keeps showing the current data instead of flashing a spinner.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    final orderFuture = _skillOrder.load(widget.pokemon.id);
    final result = await _repository.getPokemonDetail(widget.pokemon.id).run();
    final order = await orderFuture;
    if (!mounted) return;
    _savedOrder = order;
    result.fold(
      (_) => setState(() {
        if (silent && _detail != null) return;
        _loading = false;
        _failed = true;
      }),
      (detail) => setState(() {
        _detail = detail;
        _loading = false;
        _failed = false;
        if (!silent) _skillsOverride = null;
      }),
    );
  }

  Future<void> _setFirst() async {
    if (_actionInProgress) return;
    setState(() => _actionInProgress = true);
    final tr = context.t.pokemon;
    try {
      final result = await _repository.setFirst(widget.pokemon.id).run();
      if (!mounted) return;
      final success = result.isRight();
      _showSnack(success ? tr.actionSuccess : tr.actionFailed);
      if (success) context.pop(true);
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _forget(PokemonSkill skill) async {
    if (_actionInProgress) return;
    final tr = context.t.pokemon;
    final pokemon = _detail ?? widget.pokemon;
    final confirmed = await showPokemonConfirmDialog(
      context: context,
      icon: Icons.remove_circle_outline,
      title: tr.forgetSkill,
      message: tr.forgetConfirm(name: pokemon.displayName, skill: skill.name),
      confirmLabel: tr.forgetSkill,
    );
    if (!confirmed || !mounted) return;
    setState(() => _actionInProgress = true);
    try {
      final result = await _repository.forgetSkill(pokemon.id, skill.typeId).run();
      if (!mounted) return;
      result.fold((e) => _showSnack(pokemonErrorText(context, e)), (_) => _showSnack(tr.skillForgotten));
      if (result.isRight()) {
        setState(() => _skillsOverride = _skills.where((s) => s.typeId != skill.typeId).toList());
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _learn() async {
    if (_actionInProgress) return;
    final pokemon = _detail ?? widget.pokemon;
    setState(() => _actionInProgress = true);
    final result = await _repository.getLearnableSkills(pokemon.id).run();
    if (!mounted) return;
    setState(() => _actionInProgress = false);
    result.fold(
      (e) => _showSnack(pokemonErrorText(context, e)),
      (skills) => unawaited(_pickLearnable(pokemon, skills)),
    );
  }

  Future<void> _pickLearnable(Pokemon pokemon, LearnableSkills learnable) async {
    final tr = context.t.pokemon;
    if (learnable.availableSkills.isEmpty && learnable.unlockedSkills.isEmpty) {
      _showSnack(tr.noLearnableSkills);
      return;
    }
    final picked = await showModalBottomSheet<LearnableSkill>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(tr.learnSkill)),
              if (learnable.availableSkills.isNotEmpty) ...[
                _sheetHeader(context, tr.availableSkills),
                for (final skill in learnable.availableSkills)
                  ListTile(
                    leading: const Icon(Icons.add_circle_outline),
                    title: Text(skill.name),
                    subtitle: Text(
                      '${skill.type} · ${skill.category} · ${tr.skillPower}: ${skill.power} · '
                      'PP ${skill.maxPp}',
                    ),
                    onTap: () => Navigator.of(context).pop(skill),
                  ),
              ],
              if (learnable.unlockedSkills.isNotEmpty) ...[
                _sheetHeader(context, tr.unlockedSkills),
                for (final skill in learnable.unlockedSkills)
                  ListTile(
                    enabled: false,
                    leading: const Icon(Icons.lock_outline),
                    title: Text(skill.name),
                    subtitle: Text(
                      '${tr.skillRequiredLevel(level: skill.requiredLevel)} · ${skill.type} · '
                      '${tr.skillPower}: ${skill.power}',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _learnSelected(pokemon, picked);
  }

  Widget _sheetHeader(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );

  /// Move a skill in the list (drag to reorder) and remember the new order on this device.
  void _reorderSkills(int oldIndex, int newIndex) {
    final skills = [..._skills];
    // ReorderableListView reports the target index before the dragged item is removed.
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final moved = skills.removeAt(oldIndex);
    skills.insert(target, moved);
    setState(() => _skillsOverride = skills);
    unawaited(_skillOrder.save(widget.pokemon.id, skills.map((s) => s.typeId).toList()));
  }

  Future<void> _learnSelected(Pokemon pokemon, LearnableSkill skill) async {
    // Four slots is the plugin's limit: with all of them used, ask which one to replace first.
    if (_skills.length >= 4) {
      await _replaceSkill(pokemon, skill);
      return;
    }
    await _learnSkill(pokemon, skill);
  }

  /// Ask which of the pokemon's skills to forget, then learn [skill] in its place.
  Future<void> _replaceSkill(Pokemon pokemon, LearnableSkill skill) async {
    final tr = context.t.pokemon;
    final current = _skills;
    final picked = await showModalBottomSheet<PokemonSkill>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(tr.replaceSkillTitle), subtitle: Text(skill.name)),
            const Divider(height: 1),
            for (final s in current)
              ListTile(
                // The plugin only forgets a skill whose PP is full.
                enabled: s.pp >= s.maxPp,
                leading: Icon(s.pp >= s.maxPp ? Icons.remove_circle_outline : Icons.lock_outline),
                title: Text(s.name),
                subtitle: Text('PP ${s.pp}/${s.maxPp}${s.pp >= s.maxPp ? '' : ' · ${tr.skillPpNotFull}'}'),
                onTap: s.pp >= s.maxPp ? () => Navigator.of(context).pop(s) : null,
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _forgetThenLearn(pokemon, picked, skill);
  }

  /// Forget [oldSkill], then learn [newSkill]; both steps update the local skill list optimistically.
  Future<void> _forgetThenLearn(Pokemon pokemon, PokemonSkill oldSkill, LearnableSkill newSkill) async {
    final tr = context.t.pokemon;
    setState(() => _actionInProgress = true);
    try {
      final forgotten = await _repository.forgetSkill(pokemon.id, oldSkill.typeId).run();
      if (!mounted) return;
      final forgetError = forgotten.fold((e) => e, (_) => null);
      if (forgetError != null) {
        _showSnack(pokemonErrorText(context, forgetError));
        return;
      }
      setState(() => _skillsOverride = _skills.where((s) => s.typeId != oldSkill.typeId).toList());
      final learned = await _repository.learnSkill(pokemon.id, newSkill.id).run();
      if (!mounted) return;
      learned.fold((e) => _showSnack(pokemonErrorText(context, e)), (_) => _showSnack(tr.skillLearned));
      if (learned.isRight()) setState(() => _skillsOverride = [..._skills, _localSkill(newSkill)]);
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  /// Learn [skill] when a free slot is available.
  Future<void> _learnSkill(Pokemon pokemon, LearnableSkill skill) async {
    final tr = context.t.pokemon;
    setState(() => _actionInProgress = true);
    try {
      final result = await _repository.learnSkill(pokemon.id, skill.id).run();
      if (!mounted) return;
      result.fold((e) => _showSnack(pokemonErrorText(context, e)), (_) => _showSnack(tr.skillLearned));
      // The production detail endpoint returns empty skill slots, so show the learnt skill at once.
      if (result.isRight()) setState(() => _skillsOverride = [..._skills, _localSkill(skill)]);
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  /// The local skill entry for a freshly learned [skill].
  PokemonSkill _localSkill(LearnableSkill skill) => PokemonSkill(
    typeId: skill.id,
    pp: skill.maxPp,
    name: skill.name,
    skillType: skill.type,
    category: skill.category,
    level: skill.requiredLevel,
    power: skill.power,
    maxPp: skill.maxPp,
  );

  /// Open the equipment page, then reload the detail because equipping changes the stats.
  Future<void> _openEquipment(Pokemon pokemon) async {
    await context.pushNamed(ScreenPaths.pokemonEquipment, extra: pokemon);
    if (mounted) await _load(silent: true);
  }

  void _showSnack(String? message) {
    showSnackBar(context: context, message: message ?? context.t.pokemon.actionFailed);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pokemon;
    final pokemon = _detail ?? widget.pokemon;
    final stats = pokemon.stats;
    final skills = _skills;
    // The production detail endpoint omits `site`; fall back to the list item so the first pet is not offered
    // "set first".
    final isActive = (_detail?.site ?? 0) == 0 ? widget.pokemon.isActive : _detail!.isActive;
    return Scaffold(
      appBar: AppBar(title: Text(pokemon.displayName)),
      // A landscape cutout (the front camera) sits on the left or right edge, so inset every side, not just the bottom
      // the way a navigation bar alone would need. The app bar insets itself already.
      body: SafeArea(
        child: _loading
            ? const CenteredCircularIndicator()
            : _failed
            ? Center(child: TextButton(onPressed: _load, child: Text(context.t.general.retry)))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: CachedImage(pokemonImageUrl(pokemon.typeId), width: 128, height: 128, fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(tr.level(level: pokemon.level), style: Theme.of(context).textTheme.titleMedium),
                        if (pokemon.isShiny) Chip(visualDensity: VisualDensity.compact, label: Text(tr.shiny)),
                        if (pokemon.quality != null)
                          Chip(visualDensity: VisualDensity.compact, label: Text('${tr.quality}: ${pokemon.quality}')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${tr.exp}: ${pokemon.exp} / ${pokemon.expForNextLevel} · '
                    '${tr.expToNext(exp: pokemon.expToNextLevel)}',
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: pokemon.expProgress),
                  const SizedBox(height: 8),
                  Text('${tr.state}: ${pokemonStateText(context, pokemon.state, pokemon.stateText)} · ${tr.affection}: ${pokemon.affection}'),
                  Text('${tr.hp} ${pokemon.hp}/${pokemon.maxHp}'),
                  if (stats != null) ...[
                    const SizedBox(height: 16),
                    Text(tr.stats, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _StatChip(label: tr.hp, value: stats.hp),
                        _StatChip(label: tr.attack, value: stats.attack),
                        _StatChip(label: tr.defense, value: stats.defense),
                        _StatChip(label: tr.spAttack, value: stats.spAttack),
                        _StatChip(label: tr.spDefense, value: stats.spDefense),
                        _StatChip(label: tr.speed, value: stats.speed),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: Text(tr.skills, style: Theme.of(context).textTheme.titleMedium)),
                      TextButton.icon(
                        onPressed: _actionInProgress ? null : _learn,
                        icon: const Icon(Icons.add),
                        label: Text(tr.learnSkill),
                      ),
                    ],
                  ),
                  if (skills.isEmpty)
                    ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(tr.noSkills))
                  else
                    // Drag to reorder: the plugin has no API for it, so the order is only remembered on this device.
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorder: _reorderSkills,
                      children: [
                        for (var i = 0; i < skills.length; i++)
                          ListTile(
                            key: ValueKey(skills[i].typeId),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.bolt_outlined),
                            title: Text(skills[i].name),
                            subtitle: Text.rich(
                              TextSpan(
                                children: [
                                  if (skills[i].skillType.isNotEmpty)
                                    TextSpan(
                                      text: skills[i].skillType,
                                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                        color: pokemonTypeColor(skills[i].skillType),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  TextSpan(
                                    text:
                                        '${skills[i].skillType.isEmpty ? '' : ' '}${skills[i].category} · '
                                        'PP ${skills[i].pp}/${skills[i].maxPp} · ${tr.skillPower}: ${skills[i].power}',
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.chevron_right, size: 18),
                                ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                              ],
                            ),
                            onTap: _actionInProgress ? null : () => unawaited(_forget(skills[i])),
                          ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _actionInProgress ? null : () => unawaited(_openEquipment(pokemon)),
                      icon: const Icon(Icons.shield_outlined),
                      label: Text(tr.equipment),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _actionInProgress
                          ? null
                          : () => unawaited(showPokemonEvolutionPath(context, _repository, pokemon.typeId)),
                      icon: const Icon(Icons.account_tree_outlined),
                      label: Text(tr.evolutionPath),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!isActive)
                    FilledButton.icon(
                      onPressed: _actionInProgress ? null : _setFirst,
                      icon: const Icon(Icons.star_outline),
                      label: Text(tr.setFirst),
                    ),
                ],
              ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('$label: $value'),
    );
  }
}
