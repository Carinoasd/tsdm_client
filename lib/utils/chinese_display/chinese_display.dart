import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';

/// Asset of the Simplified to Traditional dictionary.
const chineseDisplayS2tAsset = 'assets/text/opencc/s2t.txt';

/// Asset of the Traditional to Simplified dictionary.
const chineseDisplayT2sAsset = 'assets/text/opencc/t2s.txt';

/// The dictionaries, loaded the first time a mode other than [ChineseDisplayMode.off] is used.
class ChineseDisplay {
  ChineseDisplay._();

  /// The one instance.
  static final instance = ChineseDisplay._();

  ChineseConverter? _s2t;
  ChineseConverter? _t2s;
  Future<void>? _loading;

  /// Whether the dictionary of [mode] is loaded ([ChineseDisplayMode.off] needs none).
  bool isReady(ChineseDisplayMode mode) => switch (mode) {
    ChineseDisplayMode.off => true,
    ChineseDisplayMode.traditional => _s2t != null,
    ChineseDisplayMode.simplified => _t2s != null,
  };

  /// Loads the dictionary of [mode] from the assets, once.
  Future<void> load(ChineseDisplayMode mode) async {
    if (isReady(mode)) {
      return;
    }
    final loading = _loading ??= _loadAll();
    try {
      await loading;
    } on Object {
      _loading = null;
      rethrow;
    }
  }

  Future<void> _loadAll() async {
    final s2t = await rootBundle.loadString(chineseDisplayS2tAsset);
    final t2s = await rootBundle.loadString(chineseDisplayT2sAsset);
    _s2t = ChineseConverter.parse(s2t);
    _t2s = ChineseConverter.parse(t2s);
  }

  /// Uses the given converters instead of the assets.
  @visibleForTesting
  void useConverters({ChineseConverter? s2t, ChineseConverter? t2s}) {
    _s2t = s2t;
    _t2s = t2s;
    _loading = null;
  }

  /// [text] shown in [mode]; as it is while the dictionary is not loaded.
  String convert(ChineseDisplayMode mode, String text) => switch (mode) {
    ChineseDisplayMode.off => text,
    ChineseDisplayMode.traditional => _s2t?.convert(text) ?? text,
    ChineseDisplayMode.simplified => _t2s?.convert(text) ?? text,
  };
}

/// Provides the [ChineseDisplayMode] to the app and loads its dictionary.
///
/// The widgets that show forum text read it through [ChineseDisplayX.displayText], which registers them for a rebuild
/// when the mode changes or the dictionary arrives.
class ChineseDisplayHost extends StatefulWidget {
  /// Constructor.
  const ChineseDisplayHost({required this.mode, required this.child, super.key});

  /// The mode to show.
  final ChineseDisplayMode mode;

  /// The app.
  final Widget child;

  @override
  State<ChineseDisplayHost> createState() => _ChineseDisplayHostState();
}

class _ChineseDisplayHostState extends State<ChineseDisplayHost> {
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ChineseDisplayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final mode = widget.mode;
    if (ChineseDisplay.instance.isReady(mode)) {
      return;
    }
    try {
      await ChineseDisplay.instance.load(mode);
    } on Object {
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => _ChineseDisplayScope(
    mode: ChineseDisplay.instance.isReady(widget.mode) ? widget.mode : ChineseDisplayMode.off,
    child: widget.child,
  );
}

class _ChineseDisplayScope extends InheritedWidget {
  const _ChineseDisplayScope({required this.mode, required super.child});

  final ChineseDisplayMode mode;

  @override
  bool updateShouldNotify(_ChineseDisplayScope oldWidget) => mode != oldWidget.mode;
}

/// Shows forum text in the chosen script.
extension ChineseDisplayX on BuildContext {
  /// The mode in effect, [ChineseDisplayMode.off] without a [ChineseDisplayHost]. Registers a dependency.
  ChineseDisplayMode get chineseDisplayMode =>
      dependOnInheritedWidgetOfExactType<_ChineseDisplayScope>()?.mode ?? ChineseDisplayMode.off;

  /// The mode in effect, without registering a dependency (for code that runs outside `build`).
  ChineseDisplayMode get chineseDisplayModeNow =>
      getInheritedWidgetOfExactType<_ChineseDisplayScope>()?.mode ?? ChineseDisplayMode.off;

  /// [text] as the user chose to see it.
  String displayText(String text) => ChineseDisplay.instance.convert(chineseDisplayMode, text);
}
