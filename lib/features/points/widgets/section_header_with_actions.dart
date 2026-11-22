import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The header of a section ([AppSectionHeader]'s look) with [actions] (one row of buttons) beside the title while
/// they fit on its line, and as a whole on the line below otherwise (large fonts, narrow windows): never stacked one
/// under another, never overflowing.
class SectionHeaderWithActions extends StatelessWidget {
  /// Constructor.
  const SectionHeaderWithActions({required this.title, required this.icon, required this.actions, super.key});

  /// Section title.
  final String title;

  /// Leading icon.
  final IconData icon;

  /// The buttons, in one row (a [Row] of `mainAxisSize: min`).
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: colorScheme.primary),
              sizedBoxW8H8,
              Flexible(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          // Even a line of its own too narrow (very large text): the row is shrunk, never broken or cut.
          FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: actions),
        ],
      ),
    );
  }
}
