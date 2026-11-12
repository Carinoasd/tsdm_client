import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';

/// Asset of the Simplified to Traditional dictionary.
const chineseDisplayS2tAsset = 'assets/text/opencc/s2t.txt';

/// Asset of the Traditional to Simplified dictionary.
const chineseDisplayT2sAsset = 'assets/text/opencc/t2s.txt';

/// The dictionaries, each loaded the first time its mode is used.
class ChineseDisplay {
  ChineseDisplay._();

  /// The one instance.
  static final instance = ChineseDisplay._();

  ChineseConverter? _s2t;
  ChineseConverter? _t2s;
  Future<void>? _loadingS2t;
  Future<void>? _loadingT2s;

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
    try {
      switch (mode) {
        case ChineseDisplayMode.traditional:
          await (_loadingS2t ??= _loadS2t());
        case ChineseDisplayMode.simplified:
          await (_loadingT2s ??= _loadT2s());
        case ChineseDisplayMode.off:
          break;
      }
    } on Object {
      if (mode == ChineseDisplayMode.traditional) {
        _loadingS2t = null;
      } else {
        _loadingT2s = null;
      }
      rethrow;
    }
  }

  Future<void> _loadS2t() async => _s2t = ChineseConverter.parse(await rootBundle.loadString(chineseDisplayS2tAsset));

  Future<void> _loadT2s() async => _t2s = ChineseConverter.parse(await rootBundle.loadString(chineseDisplayT2sAsset));

  /// Uses the given converters instead of the assets.
  @visibleForTesting
  void useConverters({ChineseConverter? s2t, ChineseConverter? t2s}) {
    _s2t = s2t;
    _t2s = t2s;
    _loadingS2t = null;
    _loadingT2s = null;
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
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to load the dictionary of $mode');
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

  /// [text] as the user chose to see it.
  String displayText(String text) => ChineseDisplay.instance.convert(chineseDisplayMode, text);

  /// The forum's [text] as the user chose to see it; the app's own [fallback] when the forum said nothing.
  String displayTextOr(String? text, String fallback) => text == null ? fallback : displayText(text);
}
