import 'dart:convert';

import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Most keywords kept in the search history of an account.
const searchHistoryMaxCount = 20;

/// Name of the settings row holding the search history of account [uid] (0 for the guest).
///
/// A JSON list of the keywords, the latest first.
String searchHistoryKey(int uid) => 'searchHistory.$uid';

/// [history] with [keyword] searched again: trimmed, moved to the front (once), at most [searchHistoryMaxCount]
/// kept. A blank keyword changes nothing.
List<String> searchHistoryWith(List<String> history, String keyword) {
  final text = keyword.trim();
  if (text.isEmpty) {
    return history;
  }
  return [text, ...history.where((e) => e != text)].take(searchHistoryMaxCount).toList();
}

/// The keywords of [history] that start with what is typed, [input] (ignoring case and the spaces around it), the
/// latest first; the keyword typed in full is left out. Nothing for a blank [input].
List<String> searchHistorySuggestions(List<String> history, String input) {
  final text = input.trim().toLowerCase();
  if (text.isEmpty) {
    return const [];
  }
  return [
    for (final e in history)
      if (e.toLowerCase() != text && e.toLowerCase().startsWith(text)) e,
  ];
}

/// The search history of each account on this device: the keywords searched, kept per account (the guest is
/// account 0) so that switching accounts shows each its own.
final class SearchHistoryStore with LoggerMixin {
  /// Constructor.
  SearchHistoryStore(this._storage);

  final StorageProvider _storage;

  /// The keywords account [uid] searched, the latest first. An unreadable row reads as none.
  Future<List<String>> load(int uid) async {
    final String? raw;
    try {
      raw = await _storage.getString(searchHistoryKey(uid));
    } on Object catch (e) {
      error('failed to read the search history: $e');
      return const [];
    }
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final json = jsonDecode(raw);
      if (json is! List) {
        return const [];
      }
      // A set keeps the first of each keyword, in order.
      return <String>{
        for (final e in json)
          if (e is String && e.trim().isNotEmpty) e.trim(),
      }.take(searchHistoryMaxCount).toList();
    } on FormatException {
      return const [];
    }
  }

  /// The last change on its way: changes run one after another, each reading what the one before saved, so two quick
  /// ones (two chips removed in a row) do not both start from the history before them.
  Future<void> _last = Future.value();

  Future<List<String>> _change(int uid, List<String> Function(List<String> history) change) {
    final done = _last.then((_) async => _save(uid, change(await load(uid))));
    _last = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// Remember [keyword] searched by account [uid], see [searchHistoryWith]; the history saved is returned.
  Future<List<String>> add(int uid, String keyword) => _change(uid, (history) => searchHistoryWith(history, keyword));

  /// Forget [keyword] from the history of account [uid]; the history saved is returned.
  Future<List<String>> remove(int uid, String keyword) =>
      _change(uid, (history) => history.where((e) => e != keyword).toList());

  /// Forget the whole history of account [uid].
  Future<void> clear(int uid) => _change(uid, (_) => const []);

  Future<List<String>> _save(int uid, List<String> history) async {
    try {
      if (history.isEmpty) {
        await _storage.deleteKey(searchHistoryKey(uid));
      } else {
        await _storage.saveString(searchHistoryKey(uid), jsonEncode(history));
      }
    } on Object catch (e) {
      error('failed to save the search history: $e');
    }
    return history;
  }
}
