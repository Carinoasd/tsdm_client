import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// A small HP bar with the `HP x/y` label, shared by the pokemon lists.
class PokemonHpBar extends StatelessWidget {
  /// Constructor.
  const PokemonHpBar({required this.hp, required this.maxHp, super.key});

  /// Current HP.
  final int hp;

  /// Maximum HP.
  final int maxHp;

  @override
  Widget build(BuildContext context) {
    final ratio = maxHp <= 0 ? 0.0 : (hp / maxHp).clamp(0.0, 1.0);
    final color = ratio > 0.5 ? Colors.green : ratio > 0.2 ? Colors.orange : Colors.red;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              color: color,
              backgroundColor: color.withValues(alpha: 0.2),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('${context.t.pokemon.hp} $hp/$maxHp', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
