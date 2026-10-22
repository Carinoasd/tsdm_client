import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:tsdm_client/constants/constants.dart';

/// A [WidgetSpan] of [child], a widget with text in it (a card, a quote, a table...), placed in a paragraph that
/// follows the text scale.
///
/// The paragraph lays [child] out at its width divided by the text scale and paints it scaled up by the text scale
/// (flutter/flutter#126962), so the widget as a whole already follows the text scale. Text in it would read the same
/// text scale from [MediaQuery] and be scaled a second time: a text scale of 1.3 became 1.69, cards were crowded and
/// broke lines badly. [child] is built without a text scale of its own, it is scaled once with the paragraph.
///
/// A widget without text (an image, a divider) does not need it, it is scaled once already. A button in [child] whose
/// tooltip shows text outside the span gets the text scale back with [OverlayTextScale].
///
/// [child] is never laid out in an unbounded width, see [TextWidgetSpanChild].
WidgetSpan textWidgetSpan(Widget child) => WidgetSpan(child: TextWidgetSpanChild(child));

/// The child of a [textWidgetSpan]: [child] built without a text scale of its own.
///
/// Where it is asked how it lays out in an unbounded width, it is laid out in [htmlContentMaxWidth], the widest a
/// post's content is. A paragraph lays out the widgets in it in its width, which is always bounded on the screen, but
/// it is asked how tall it is in an unbounded width when what it is in works out its own width from its content: the
/// cell of a table working out its columns, and in it a spoiler, whose header is a row. A card that fills its width
/// with a row and an expanded child (a quote, a spoiler, a hidden section, a code block, a review in a spoiler in a
/// cell) cannot lay out in an unbounded width: it threw, and the whole table was left blank.
class TextWidgetSpanChild extends StatelessWidget {
  /// Constructor.
  const TextWidgetSpanChild(this.child, {super.key});

  /// The widget in the span.
  final Widget child;

  @override
  Widget build(BuildContext context) => _SpanTextScale(
    // The text of a card in a span has no text scale, a span in that text is not scaled again: what the screen shows
    // is still scaled by the outermost paragraph.
    textScaler: _SpanTextScale.maybeOf(context) ?? MediaQuery.textScalerOf(context),
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: _BoundedWidth(child: child),
    ),
  );
}

/// [child] laid out in [htmlContentMaxWidth] instead of an unbounded width, see [TextWidgetSpanChild].
class _BoundedWidth extends SingleChildRenderObjectWidget {
  const _BoundedWidth({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBoundedWidth();
}

class _RenderBoundedWidth extends RenderProxyBox {
  static BoxConstraints _bounded(BoxConstraints constraints) => constraints.hasBoundedWidth
      ? constraints
      : constraints.copyWith(
          maxWidth: htmlContentMaxWidth,
          minWidth: constraints.minWidth.clamp(0, htmlContentMaxWidth),
        );

  static double _boundedWidth(double width) => width.isFinite ? width : htmlContentMaxWidth;

  @override
  double computeMinIntrinsicHeight(double width) => super.computeMinIntrinsicHeight(_boundedWidth(width));

  @override
  double computeMaxIntrinsicHeight(double width) => super.computeMaxIntrinsicHeight(_boundedWidth(width));

  @override
  Size computeDryLayout(BoxConstraints constraints) => super.computeDryLayout(_bounded(constraints));

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      super.computeDryBaseline(_bounded(constraints), baseline);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_bounded(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}

/// [child] with the text scale of the paragraph when it is in a [textWidgetSpan], for a button whose tooltip shows
/// text outside the span.
///
/// A tooltip reads the text scale where its button is but is painted in the overlay, not scaled with the span: in a
/// [textWidgetSpan] its text would stay at 1.0 whatever the text scale. Outside a [textWidgetSpan] [child] is left as
/// it is.
///
/// Only for a widget without text of its own (an icon button): text in [child] would be scaled twice again.
class OverlayTextScale extends StatelessWidget {
  /// Constructor.
  const OverlayTextScale({required this.child, super.key});

  /// The widget that shows text in the overlay.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textScaler = _SpanTextScale.maybeOf(context);
    if (textScaler == null) {
      return child;
    }
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child,
    );
  }
}

/// The text scale of the paragraph a [textWidgetSpan] is in.
class _SpanTextScale extends InheritedWidget {
  const _SpanTextScale({required this.textScaler, required super.child});

  final TextScaler textScaler;

  static TextScaler? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SpanTextScale>()?.textScaler;

  @override
  bool updateShouldNotify(_SpanTextScale oldWidget) => textScaler != oldWidget.textScaler;
}
