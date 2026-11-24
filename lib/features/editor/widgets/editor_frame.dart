import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Rounded frame around a rich editor: the writing area of the post editor, the reply bar and the template editor.
///
/// The border turns to the primary color while [focusNode] has the focus, like an outlined text field. Only the
/// look changes: the editor inside keeps its controller, focus and shortcuts.
class EditorFrame extends StatelessWidget {
  /// Constructor.
  const EditorFrame({required this.child, this.focusNode, this.padding = edgeInsetsL12T8R12B8, super.key});

  /// The editor.
  final Widget child;

  /// Focus node of the editor, to highlight the frame while writing.
  final FocusNode? focusNode;

  /// Padding between the frame and the editor.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget frame({required bool focused}) => DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(appInnerRadius),
        border: Border.all(
          color: focused ? colorScheme.primary : colorScheme.outlineVariant,
          width: focused ? 1.5 : 1,
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
    final node = focusNode;
    if (node == null) {
      return frame(focused: false);
    }
    return ListenableBuilder(
      listenable: node,
      builder: (context, _) => frame(focused: node.hasFocus),
    );
  }
}

/// Bar of editor controls under the writing area: a hairline on top, [leading] buttons scroll horizontally when the
/// room is short, [trailing] (send, collapse) stays visible at the end.
class EditorControlBar extends StatelessWidget {
  /// Constructor.
  const EditorControlBar({
    required this.leading,
    this.trailing = const [],
    this.padding = const EdgeInsets.fromLTRB(4, 4, 8, 4),
    super.key,
  });

  /// Buttons at the start, scrollable.
  final List<Widget> leading;

  /// Buttons at the end, always visible.
  final List<Widget> trailing;

  /// Padding inside the bar, the horizontal room of the page is added by the caller.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppSurfaces.of(context).bar,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: leading),
              ),
            ),
            if (trailing.isNotEmpty) ...[sizedBoxW8H8, ...trailing],
          ],
        ),
      ),
    );
  }
}
