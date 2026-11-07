import 'dart:async';

import 'package:flutter/material.dart';

/// The item of a list the keyboard moved to, if any.
class KeyboardSelection extends ChangeNotifier {
  int? _index;

  /// The selected item, null when none is.
  int? get index => _index;

  /// Moves the selection by [delta] items in a list of [count] items; it starts at the first item when there is none.
  void move(int delta, int count) {
    if (count <= 0) {
      return;
    }
    final current = _index;
    final next = current == null ? (delta > 0 ? 0 : count - 1) : (current + delta).clamp(0, count - 1);
    if (next != current) {
      _index = next;
      notifyListeners();
    }
  }

  /// Selects nothing.
  void clear() {
    if (_index != null) {
      _index = null;
      notifyListeners();
    }
  }
}

/// An item of a list the keyboard moves through: outlined while [selection] is on it, and scrolled into view then.
class KeyboardSelectable extends StatefulWidget {
  /// Constructor.
  const KeyboardSelectable({required this.selection, required this.index, required this.child, super.key});

  /// The selection of the list.
  final KeyboardSelection selection;

  /// Position of this item in the list.
  final int index;

  /// The item.
  final Widget child;

  @override
  State<KeyboardSelectable> createState() => _KeyboardSelectableState();
}

class _KeyboardSelectableState extends State<KeyboardSelectable> {
  bool _selected = false;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_onChanged);
    _selected = widget.selection.index == widget.index;
    if (_selected) {
      _scheduleReveal();
    }
  }

  @override
  void didUpdateWidget(KeyboardSelectable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection.removeListener(_onChanged);
      widget.selection.addListener(_onChanged);
    }
    _onChanged();
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final selected = widget.selection.index == widget.index;
    if (selected == _selected) {
      return;
    }
    setState(() => _selected = selected);
    if (selected) {
      _scheduleReveal();
    }
  }

  void _scheduleReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selected) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            alignment: 0.3,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_selected) {
      return widget.child;
    }
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary, width: 2),
      ),
      child: widget.child,
    );
  }
}
