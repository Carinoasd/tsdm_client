import 'package:flutter/foundation.dart';

/// A floor picked to be quoted in a reply.
@immutable
final class MultiQuoteEntry {
  /// Constructor.
  const MultiQuoteEntry({required this.pid, required this.replyAction});

  /// Post id of the floor.
  final String pid;

  /// The floor's quoting reply link (`repquote`), the one the forum's reply window tells the quote of the floor from.
  final String replyAction;
}

/// The floors picked to be quoted in one reply, in the order they were picked (the order of the quotes).
///
/// Lives as long as the thread page: turning pages keeps the floors picked.
final class MultiQuoteSelection extends ChangeNotifier {
  /// Most floors quoted in one reply (the forum limits the length of the message, not the quotes).
  static const maxEntries = 10;

  final List<MultiQuoteEntry> _entries = [];
  bool _active = false;
  bool _busy = false;

  /// Whether the quotes of the floors picked are being fetched: the picking can not change meanwhile.
  bool get busy => _busy;

  set busy(bool value) {
    if (_busy == value) {
      return;
    }
    _busy = value;
    notifyListeners();
  }

  /// Whether the floors are being picked.
  bool get active => _active;

  /// The floors picked, in the order they were picked.
  List<MultiQuoteEntry> get entries => List.unmodifiable(_entries);

  /// Count of floors picked.
  int get length => _entries.length;

  /// Whether the floor [pid] is picked.
  bool contains(String pid) => _entries.any((e) => e.pid == pid);

  /// Start picking, with [first] picked.
  void begin(MultiQuoteEntry first) {
    _active = true;
    if (!contains(first.pid) && _entries.length < maxEntries) {
      _entries.add(first);
    }
    notifyListeners();
  }

  /// Pick [entry], or take it back when picked. False when it can not be picked: [maxEntries] floors are.
  bool toggle(MultiQuoteEntry entry) {
    if (_busy) {
      return true;
    }
    final at = _entries.indexWhere((e) => e.pid == entry.pid);
    if (at >= 0) {
      _entries.removeAt(at);
    } else if (_entries.length >= maxEntries) {
      return false;
    } else {
      _entries.add(entry);
    }
    notifyListeners();
    return true;
  }

  /// Stop picking, nothing picked any more.
  void exit() {
    if (_busy) {
      return;
    }
    if (!_active && _entries.isEmpty) {
      return;
    }
    _active = false;
    _entries.clear();
    notifyListeners();
  }
}
