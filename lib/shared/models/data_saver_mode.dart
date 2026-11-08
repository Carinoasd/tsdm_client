import 'package:flutter/widgets.dart';
import 'package:tsdm_client/utils/network_usage.dart';

/// When the data saver holds back the large pictures: those of the floors (a placeholder to tap instead) and the
/// thumbnails of the thread lists (none). Avatars load as usual, and a picture already cached shows whatever this says.
///
/// Stored by its index (`SettingsKeys.dataSaverMode`).
enum DataSaverMode {
  /// Never, the pictures load as their own settings say.
  off,

  /// On a network that counts the data ([NetworkUsage]): mobile data, a hotspot.
  meteredOnly,

  /// Always.
  always
  ;

  /// The value stored as [index]; [off] for anything else (a backup from a newer version).
  static DataSaverMode fromIndex(int index) => index >= 0 && index < values.length ? values[index] : DataSaverMode.off;
}

/// Whether the data saver holds the pictures back on a page, decided once for each page (its [ModalRoute]).
///
/// With [DataSaverMode.meteredOnly] a page holds them back from the moment it is on a metered network, and keeps
/// doing so when the network becomes free again (Wi-Fi): nothing loads by itself then, the pages opened from that
/// moment on load as usual. A page that came while the network was free starts holding them back once the network
/// counts the data.
abstract final class DataSaver {
  /// What each page decided: held back, or not and the [_meteredSpells] it saw then.
  static final _decisions = Expando<_Decision>('data saver');

  /// How many times the network became metered so far in this run, counted whether or not a picture was built then:
  /// a page that decided "not held back" holds back once this grew since (it was on a metered network meanwhile).
  static int _meteredSpells = 0;

  static bool _watching = false;

  static void _watch() {
    if (_watching) {
      return;
    }
    _watching = true;
    NetworkUsage.unmetered.addListener(() {
      if (NetworkUsage.unmetered.value == false) {
        _meteredSpells++;
      }
    });
  }

  /// Whether the pictures of the page of [context] are held back with [mode]; null while the network is not known yet
  /// (the first answer of [NetworkUsage] is coming). Asks [NetworkUsage] again when its answer is old.
  ///
  /// A widget that shows them listens to [NetworkUsage.unmetered] with [DataSaverMode.meteredOnly] and asks again on
  /// each change.
  static bool? holdsBack(BuildContext context, DataSaverMode mode) {
    switch (mode) {
      case DataSaverMode.off:
        return false;
      case DataSaverMode.always:
        return true;
      case DataSaverMode.meteredOnly:
        _watch();
        NetworkUsage.refreshIfStale();
        final unmetered = NetworkUsage.unmetered.value;
        final metered = unmetered == null ? null : !unmetered;
        final route = ModalRoute.of(context);
        if (route == null) {
          return metered;
        }
        final decision = _decisions[route];
        if (decision == null) {
          if (metered != null) {
            _decisions[route] = _Decision(held: metered, spells: _meteredSpells);
          }
          return metered;
        }
        if (!decision.held && ((metered ?? false) || decision.spells != _meteredSpells)) {
          decision.held = true;
        }
        return decision.held;
    }
  }
}

final class _Decision {
  _Decision({required this.held, required this.spells});

  bool held;

  final int spells;
}

/// Makes the page of [child] decide on the data saver as soon as it is built ([DataSaver.holdsBack]), not when its
/// first picture is: a page opened on Wi-Fi that went through mobile data before its pictures were built holds them
/// back as well. Builds [child] as it is (a change of the route rebuilds nothing below).
class DataSaverPageDecision extends StatefulWidget {
  /// Constructor.
  const DataSaverPageDecision({required this.mode, required this.child, super.key});

  /// The data saver set.
  final DataSaverMode mode;

  /// The content.
  final Widget child;

  @override
  State<DataSaverPageDecision> createState() => _DataSaverPageDecisionState();
}

class _DataSaverPageDecisionState extends State<DataSaverPageDecision> {
  bool _listening = false;

  void _decide() {
    if (mounted) {
      DataSaver.holdsBack(context, widget.mode);
    }
  }

  void _follow() {
    final follows = widget.mode == DataSaverMode.meteredOnly;
    if (follows && !_listening) {
      // Until the first answer of the network, and for each change after it (cheap: no rebuild).
      NetworkUsage.unmetered.addListener(_decide);
      _listening = true;
    } else if (!follows && _listening) {
      NetworkUsage.unmetered.removeListener(_decide);
      _listening = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
    if (widget.mode == DataSaverMode.meteredOnly) {
      DataSaver.holdsBack(context, widget.mode);
    }
  }

  @override
  void didUpdateWidget(DataSaverPageDecision oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _follow();
      _decide();
    }
  }

  @override
  void dispose() {
    if (_listening) {
      NetworkUsage.unmetered.removeListener(_decide);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
