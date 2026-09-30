import 'package:flutter/material.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// One small-icon grid cell shared by the inventory and the shop.
class PokemonGridCell extends StatelessWidget {
  /// Constructor.
  const PokemonGridCell({
    required this.image,
    required this.fallbackIcon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  /// Image url to show, or null to show [fallbackIcon].
  final String? image;

  /// Icon shown in place of a missing image.
  final IconData fallbackIcon;

  /// First line: the item or pokemon name.
  final String title;

  /// Second line: usually the price or the owned quantity.
  final String subtitle;

  /// Tap action; null disables the cell.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              Expanded(child: image == null ? Icon(fallbackIcon) : CachedImage(image!, fit: BoxFit.contain)),
              const SizedBox(height: 4),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
