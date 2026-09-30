part of 'battle_page.dart';

class _NeedLogin extends StatelessWidget {
  const _NeedLogin({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(child: TextButton(onPressed: onRetry, child: Text(context.t.battle.loginRequired)));
  }
}

class _BattleView extends StatelessWidget {
  const _BattleView({
    required this.scene,
    required this.busy,
    required this.onSkill,
    required this.onItem,
    required this.onCapture,
    required this.onSwitch,
    required this.onFlee,
    required this.onHealAndFlee,
    this.wildGender,
    this.wildShiny,
    this.skillOrder = const [],
    this.turn = 1,
  });

  final BattleScene scene;
  final bool busy;

  /// Gender of the wild pokemon from the last running turn; the finished scene reports the reset value.
  final int? wildGender;

  /// Shiny state of the wild pokemon from the last running turn.
  final bool? wildShiny;

  /// Device-local display order of the player's skills (skill ids, empty before it is loaded).
  final List<int> skillOrder;

  /// Round the battle is in, counted by the client: the plugin has no turn counter.
  final int turn;
  final ValueChanged<int> onSkill;
  final VoidCallback onItem;
  final VoidCallback onCapture;
  final VoidCallback onSwitch;
  final VoidCallback onFlee;
  final VoidCallback onHealAndFlee;

  /// Height of the battle log box: proportional to the screen and scaled with the font, but fixed so a longer message
  /// cannot resize the box and move the fighters and the action area around.
  double _logHeight(BuildContext context, BoxConstraints constraints) =>
      MediaQuery.textScalerOf(context).scale(1) * (constraints.maxHeight * 0.12).clamp(56.0, 96.0);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.battle;
    // The plugin returns skills in slot order; apply the device-local order the player set on the detail page.
    final skills = SkillOrderStore.apply(
      scene.myPokemon.skills.where((s) => s.id != 0).toList(),
      skillOrder,
      (s) => s.id,
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                // The fighters and the log are inside the page scroll view, so insetting this padding keeps them clear
                // of a landscape cutout (the front camera) without another SafeArea layer.
                padding: EdgeInsets.fromLTRB(
                  12 + MediaQuery.paddingOf(context).left,
                  8,
                  12 + MediaQuery.paddingOf(context).right,
                  8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The two pokemon sit diagonally, like the games: the wild one at the top-left and mine at the
                    // bottom-right, with the battle log between them. Stacking them vertically (instead of one row)
                    // also keeps the layout usable on small screens.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _Fighter(
                        image: pokemonBattleBackImageUrl(scene.wildPokemon.id),
                        name: scene.wildPokemon.name ?? '',
                        level: scene.wildPokemon.level,
                        hp: scene.wildPokemon.hp,
                        maxHp: scene.wildPokemon.maxHp,
                        boss: scene.wildPokemon.isBoss ?? false,
                        gender: wildGender ?? scene.wildPokemon.gender,
                        shiny: wildShiny ?? scene.wildPokemon.isShiny,
                        spriteSize: _battleSpriteSize(constraints),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Battle log between the two pokemon. The box keeps a fixed height so a longer message cannot
                    // resize it and move the fighters and the action area around while the player watches the fight.
                    SizedBox(
                      height: _logHeight(context, constraints),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(context).dividerColor),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          (scene.message ?? '').isEmpty ? tr.turn(turn: turn) : scene.message!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _Fighter(
                        image: pokemonImageUrl(scene.myPokemon.id),
                        name: scene.myPokemon.name ?? '',
                        level: scene.myPokemon.level,
                        hp: scene.myPokemon.hp,
                        maxHp: scene.myPokemon.maxHp,
                        boss: false,
                        spriteSize: _battleSpriteSize(constraints),
                      ),
                    ),
                  ],
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Keep the action area the same height whether or not a request is running: an inserted bar would
                      // push the buttons down (and past the bottom of the view on a short screen) while it is shown.
                      SizedBox(
                        height: 2,
                        child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(onPressed: busy ? null : () => onSkill(0), child: Text(tr.normalAttack)),
                      ),
                      if (skills.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisExtent: 56,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                          itemCount: skills.length,
                          itemBuilder: (context, index) {
                            final skill = skills[index];
                            return FilledButton.tonal(
                              onPressed: busy || !skill.usable ? null : () => onSkill(skill.id),
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(text: skill.name ?? ''),
                                    if (skill.skillType.isNotEmpty) ...[
                                      const TextSpan(text: '\n'),
                                      TextSpan(
                                        text: skill.skillType,
                                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          color: pokemonTypeColor(skill.skillType),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                    TextSpan(
                                      text:
                                          '${skill.skillType.isEmpty ? '\n' : ' '}${skill.category} · '
                                          'PP ${skill.pp}/${skill.maxPp} · '
                                          '${context.t.pokemon.skillPower}: ${skill.power}',
                                      style: Theme.of(context).textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 8),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 48,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: 4,
                        itemBuilder: (context, index) => switch (index) {
                          0 => FilledButton.tonalIcon(
                            onPressed: busy ? null : onItem,
                            icon: const Icon(Icons.backpack_outlined),
                            label: Text(tr.items),
                          ),
                          1 => FilledButton.tonalIcon(
                            onPressed: busy ? null : onCapture,
                            icon: const Icon(Icons.catching_pokemon),
                            label: Text(tr.capture),
                          ),
                          2 => FilledButton.tonalIcon(
                            onPressed: busy ? null : onSwitch,
                            icon: const Icon(Icons.swap_horiz),
                            label: Text(tr.switchPokemon),
                          ),
                          // The last cell holds two smaller buttons so heal-and-flee and flee stay on one row while the
                          // pair still fills the cell like every other button.
                          _ => Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: busy ? null : onHealAndFlee,
                                  icon: const Icon(Icons.medical_services_outlined, size: 18),
                                  label: Text(
                                    context.t.pokemon.healAndFlee,
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: busy ? null : onFlee,
                                  icon: const Icon(Icons.directions_run, size: 18),
                                  label: Text(tr.flee, style: Theme.of(context).textTheme.labelSmall),
                                ),
                              ),
                            ],
                          ),
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fighter extends StatelessWidget {
  const _Fighter({
    required this.image,
    required this.name,
    required this.level,
    required this.hp,
    required this.maxHp,
    required this.boss,
    this.gender,
    this.shiny = false,
    this.spriteSize = 64,
  });

  final String image;
  final String name;
  final int level;
  final int hp;
  final int maxHp;
  final bool boss;

  /// Gender (0=雄性, 1=雌性); null hides the symbol (the player's own pokemon).
  final int? gender;

  /// Whether the pokemon is shiny.
  final bool shiny;

  /// Sprite edge length; scales with the screen.
  final double spriteSize;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pokemon;
    final ratio = maxHp <= 0 ? 0.0 : (hp / maxHp).clamp(0.0, 1.0);
    final color = ratio > 0.5 ? Colors.green : ratio > 0.2 ? Colors.orange : Colors.red;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: spriteSize * 2.6),
      child: Column(
        children: [
          if (boss) Chip(visualDensity: VisualDensity.compact, label: Text(context.t.battle.boss)),
          CachedImage(image, width: spriteSize, height: spriteSize, fit: BoxFit.contain),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: name.isEmpty ? tr.level(level: level) : '$name · ${tr.level(level: level)}'),
              if (shiny)
                const WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.auto_awesome, size: 14, color: Colors.amber),
                  ),
                ),
              if (gender == 0 || gender == 1)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Text(
                      gender == 0 ? '♂' : '♀',
                      style: TextStyle(color: gender == 0 ? Colors.blue : Colors.pink, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 8,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.2),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${tr.hp} $hp/$maxHp', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        ],
      ),
    );
  }
}

/// Sprite size for the battle fighters: scales with the screen so they fit at the top corners on any phone.
///
/// The width share is generous enough to keep the fighters filling a tall screen (a small sprite left a wide empty gap
/// between the battle area and the action buttons), while the height share still wins in landscape.
double _battleSpriteSize(BoxConstraints constraints) {
  final byWidth = constraints.maxWidth / 4;
  final byHeight = constraints.maxHeight / 6;
  return (byWidth < byHeight ? byWidth : byHeight).clamp(48.0, 132.0);
}
