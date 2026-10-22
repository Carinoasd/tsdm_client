import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [child] as wide as the width it is given, or as wide as itself where that width is unbounded.
///
/// An aligned block of a post (`<div align="center">`, `<p align="right">`, `<center>`) is a rich text taking the
/// whole width with its text aligned in it. It was a [Row] with the text [Expanded] in it, but a row cannot lay out a
/// flexible child in an unbounded width, which a block in the cell of a table is asked about while the table works
/// out its columns: the row threw and the table was left blank, with everything in it. This block takes the width it
/// is given when it has one and the width of its content otherwise.
class FullWidthBlock extends SingleChildRenderObjectWidget {
  /// Constructor.
  const FullWidthBlock({required Widget super.child, super.key});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFullWidthBlock();
}

class _RenderFullWidthBlock extends RenderProxyBox {
  /// The constraints of the child: tight to the whole width when it is bounded, as given when it is not.
  static BoxConstraints _childConstraints(BoxConstraints constraints) =>
      constraints.hasBoundedWidth ? constraints.tighten(width: constraints.maxWidth) : constraints;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) {
      return constraints.smallest;
    }
    return constraints.constrain(child.getDryLayout(_childConstraints(constraints)));
  }

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      child?.getDryBaseline(_childConstraints(constraints), baseline);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}
