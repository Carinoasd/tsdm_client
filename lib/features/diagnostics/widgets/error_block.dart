import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_export.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// What a widget that failed to build shows in a release or profile build ([ErrorWidget.builder]): a short message
/// and the diagnostics export, in place of the plain grey box of Flutter. The error itself is in the log, never shown.
///
/// It can land anywhere: a tiny cell, a list row, a page, above the app's theme, translations and directionality, in
/// an unbounded or an intrinsic layout. So it needs no ancestor, takes the size it is given (a small fixed one where
/// a side is unbounded), and shows what fits: the message and the button, the button as an icon alone, or only its
/// color. Building it never throws: if anything goes wrong, it is an empty box.
class ErrorBlock extends StatelessWidget {
  /// Constructor.
  const ErrorBlock({super.key});

  /// For [ErrorWidget.builder]: the error is not shown (it was logged by `FlutterError.onError` before).
  static Widget fromDetails(FlutterErrorDetails details) => const ErrorBlock();

  @override
  Widget build(BuildContext context) {
    try {
      return _build(context);
    } on Object {
      return const SizedBox.shrink();
    }
  }

  Widget _build(BuildContext context) {
    // A theme above it or the fallback one; colors that read in both brightnesses.
    final colors = Theme.of(context).colorScheme;
    final (message, export) = _texts();
    final textStyle = TextStyle(
      color: colors.onErrorContainer,
      fontSize: 14,
      height: 1.3,
      fontWeight: FontWeight.normal,
      decoration: TextDecoration.none,
      fontFamily: DefaultTextStyle.of(context).style.fontFamily,
    );

    Widget exportButton(Widget child) => Builder(
      builder: (context) => ValueListenableBuilder(
        valueListenable: diagnosticsExportBusy,
        builder: (context, busy, child) => Semantics(
          button: true,
          enabled: !busy,
          label: export,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: busy ? null : () async => exportDiagnostics(context, shareOrigin: shareOriginOf(context)),
            child: Opacity(opacity: busy ? 0.5 : 1, child: child),
          ),
        ),
        child: child,
      ),
    );

    final full = FittedBox(
      fit: BoxFit.scaleDown,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 28, color: colors.error),
              const SizedBox(height: 8),
              Text(
                message,
                style: textStyle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              exportButton(
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.error,
                    borderRadius: const BorderRadius.all(Radius.circular(18)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(export, style: textStyle.copyWith(color: colors.onError), maxLines: 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final icon = exportButton(
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Icon(Icons.error_outline, size: 24, color: colors.error),
      ),
    );

    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: ColoredBox(
        color: colors.errorContainer,
        child: _FitLayout(children: [full, icon]),
      ),
    );
  }

  /// The message and the button label, from the app's translations when they can be read here.
  static (String, String) _texts() {
    try {
      final tr = t.diagnostics;
      return (tr.errorBlock, tr.export);
    } on Object {
      return ('Something went wrong here', 'Export diagnostics');
    }
  }
}

/// Lays out the first of its children that fits the size it takes (see [_RenderFitLayout]) and shows that one only.
class _FitLayout extends MultiChildRenderObjectWidget {
  const _FitLayout({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFitLayout();
}

class _FitParentData extends ContainerBoxParentData<RenderBox> {}

/// Takes the size its constraints give, [natural] on an unbounded side; then shows its first child (the message and
/// the button) when the size is at least [_fullMin], the second (the icon) when at least [_iconMin], none below.
///
/// The children are laid out loosely in that size and centered. Its intrinsic sizes are fixed, so an intrinsic layout
/// (`IntrinsicHeight`, a table) asks it without asking a child.
class _RenderFitLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FitParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FitParentData> {
  static const natural = Size(240, 120);
  static const _fullMin = Size(96, 72);
  static const _iconMin = Size(16, 16);

  RenderBox? _shown;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FitParentData) {
      child.parentData = _FitParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => natural.width;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => natural.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(constraints);

  Size _sizeFor(BoxConstraints c) => c.constrain(
    Size(c.hasBoundedWidth ? c.maxWidth : natural.width, c.hasBoundedHeight ? c.maxHeight : natural.height),
  );

  static bool _fits(Size size, Size min) => size.width >= min.width && size.height >= min.height;

  @override
  void performLayout() {
    size = _sizeFor(constraints);
    final children = getChildrenAsList();
    final pick = switch (children.length) {
      >= 2 when _fits(size, _fullMin) => 0,
      >= 2 when _fits(size, _iconMin) => 1,
      _ => -1,
    };
    _shown = pick < 0 ? null : children[pick];
    for (final child in children) {
      if (identical(child, _shown)) {
        child.layout(BoxConstraints.loose(size), parentUsesSize: true);
        (child.parentData! as _FitParentData).offset = Offset(
          math.max(0, (size.width - child.size.width) / 2),
          math.max(0, (size.height - child.size.height) / 2),
        );
      } else {
        child.layout(const BoxConstraints.tightFor(width: 0, height: 0));
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final shown = _shown;
    if (shown == null) {
      return;
    }
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, (context, offset) {
      context.paintChild(shown, offset + (shown.parentData! as _FitParentData).offset);
    });
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final shown = _shown;
    if (shown == null) {
      return false;
    }
    final data = shown.parentData! as _FitParentData;
    return result.addWithPaintOffset(
      offset: data.offset,
      position: position,
      hitTest: (result, transformed) => shown.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final shown = _shown;
    if (shown != null) {
      visitor(shown);
    }
  }
}
