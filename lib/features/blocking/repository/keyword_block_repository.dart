import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart' show UserBlockListStatus;
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

export 'package:tsdm_client/features/blocking/repository/user_block_repository.dart' show UserBlockListStatus;

/// A keyword blocked locally by one account.
final class BlockedKeyword {
  /// Constructor.
  const BlockedKeyword({required this.keyword, required this.createdAt, this.appliesToPosts = true});

  /// The keyword as saved: trimmed, never empty.
  final String keyword;

  /// Whether floors (post body and signature) containing the keyword are hidden too, not only thread titles and
  /// notices.
  final bool appliesToPosts;

  /// Time of adding.
  final DateTime createdAt;

  /// The keyword compared to content, see [foldKeywordText].
  String get key => foldKeywordText(keyword);

  /// Copy with [appliesToPosts] changed.
  BlockedKeyword withAppliesToPosts({required bool value}) =>
      BlockedKeyword(keyword: keyword, createdAt: createdAt, appliesToPosts: value);

  /// Encode as one entry of the settings row.
  String encode() =>
      jsonEncode(<String, Object>{'k': keyword, 'p': appliesToPosts, 'at': createdAt.millisecondsSinceEpoch});

  /// Decode one entry of the settings row, null if malformed.
  static BlockedKeyword? decode(String data) {
    try {
      final m = jsonDecode(data);
      if (m is! Map<String, dynamic>) {
        return null;
      }
      final k = m['k'];
      final p = m['p'];
      final at = m['at'];
      if (k is! String) {
        return null;
      }
      final keyword = k.trim();
      if (keyword.isEmpty || keyword.runes.length > KeywordBlockRepository.maxLength) {
        return null;
      }
      final milliseconds = at is int ? at : 0;
      if (milliseconds < -8640000000000000 || milliseconds > 8640000000000000) {
        return null;
      }
      return BlockedKeyword(
        keyword: keyword,
        appliesToPosts: p is! bool || p,
        createdAt: DateTime.fromMillisecondsSinceEpoch(milliseconds),
      );
    } on FormatException {
      return null;
    }
  }
}

/// [keyword] as saved: without the surrounding white space.
String normalizeBlockedKeyword(String keyword) => keyword.trim();

/// [text] as keywords and content are compared: full width ASCII letters, digits and signs as their half width forms
/// (`ＡＢＣ１` as `abc1`), every run of white space other than a line break (the full width space included) as one
/// space, and lower case.
///
/// Line breaks are kept: they separate the lines of a floor (see `postContentPlainText`), which a keyword never spans.
String foldKeywordText(String text) {
  var changed = false;
  final folded = List<int>.of(text.codeUnits);
  for (var i = 0; i < folded.length; i++) {
    final c = folded[i];
    if (c >= 0xFF01 && c <= 0xFF5E) {
      folded[i] = c - 0xFEE0;
      changed = true;
    } else if (c == 0x3000) {
      folded[i] = 0x20;
      changed = true;
    }
  }
  final half = changed ? String.fromCharCodes(folded) : text;
  return half.replaceAll(_spacesButLineBreak, ' ').toLowerCase();
}

final _spacesButLineBreak = RegExp(r'[^\S\n]+');

/// The local keyword list of one account.
///
/// Unlike the user block list nothing is held back while the list is not known: no keyword hides anything then.
@immutable
final class KeywordBlockList {
  /// Constructor.
  KeywordBlockList({
    required this.ownerUid,
    required List<BlockedKeyword> keywords,
    List<String> unreadableEntries = const [],
    this.status = UserBlockListStatus.ready,
  }) : keywords = List.unmodifiable(keywords),
       unreadableEntries = List.unmodifiable(unreadableEntries),
       titleKeys = List.unmodifiable(keywords.map((e) => e.key)),
       postKeys = List.unmodifiable(keywords.where((e) => e.appliesToPosts).map((e) => e.key));

  /// Empty and known list of [ownerUid].
  const KeywordBlockList.empty(this.ownerUid)
    : keywords = const [],
      unreadableEntries = const [],
      titleKeys = const [],
      postKeys = const [],
      status = UserBlockListStatus.ready;

  /// List of [ownerUid] that is not known (yet), see [status]: hides nothing.
  const KeywordBlockList.unknown(this.ownerUid, {required this.status})
    : keywords = const [],
      unreadableEntries = const [],
      titleKeys = const [],
      postKeys = const [];

  /// Uid of the account owning this list, null for guest (always empty).
  final int? ownerUid;

  /// Keywords, latest added first.
  final List<BlockedKeyword> keywords;

  /// Stored entries this version can not read, written back unchanged on every change.
  final List<String> unreadableEntries;

  /// Keywords matched against thread titles and notices, folded by [foldKeywordText].
  final List<String> titleKeys;

  /// Keywords matched against floors, folded by [foldKeywordText].
  final List<String> postKeys;

  /// Whether the list is known.
  final UserBlockListStatus status;

  /// Whether [uid] is the owner: content of the owner is never hidden.
  bool isOwner(int? uid) => uid != null && uid > 0 && uid == ownerUid;

  /// Same as [isOwner] with the uid as string (as parsed from html).
  bool isOwnerString(String? uid) => isOwner(uid == null ? null : int.tryParse(uid));

  /// Whether a thread titled [title] by [authorUid] is hidden.
  bool hidesTitle(String? title, {String? authorUid}) =>
      title != null && titleKeys.isNotEmpty && !isOwnerString(authorUid) && containsKeyword(title, titleKeys);

  /// Whether a floor whose plain text, folded by [foldKeywordText], is [foldedText] is hidden.
  bool hidesPostFoldedText(String foldedText) => postKeys.any(foldedText.contains);

  /// Whether the keyword [keyword] is in the list, compared like content.
  bool contains(String keyword) => titleKeys.contains(foldKeywordText(normalizeBlockedKeyword(keyword)));
}

/// Whether [text] contains one of the [keys] (folded by [foldKeywordText]), compared as [foldKeywordText] does.
bool containsKeyword(String text, List<String> keys) {
  if (keys.isEmpty) {
    return false;
  }
  final folded = foldKeywordText(text);
  return keys.any(folded.contains);
}

/// The stored keyword list could not be read; nothing was changed.
final class KeywordBlockStorageException implements Exception {
  /// Constructor.
  const KeywordBlockStorageException(this.cause);

  /// Underlying error.
  final Object cause;

  @override
  String toString() => 'KeywordBlockStorageException($cause)';
}

/// Result of a change of the keyword list.
enum KeywordBlockResult {
  /// Saved.
  ok,

  /// Empty after trimming, nothing changed.
  empty,

  /// Longer than [KeywordBlockRepository.maxLength], nothing changed.
  tooLong,

  /// Already in the list (compared as [foldKeywordText] does), nothing changed.
  duplicate,

  /// The list holds [KeywordBlockRepository.maxCount] keywords already, nothing changed.
  limitReached,

  /// Not in the list, nothing changed.
  notFound,

  /// No account or invalid uid.
  invalid,

  /// The current account changed after the action was started; nothing was changed.
  accountChanged,

  /// The stored list could not be read or written.
  storageError,
}

/// Local-only keyword block.
///
/// Each account owns a separate list stored as one row of the settings table named `keywordBlockList.<ownerUid>` (a
/// json string list, see [BlockedKeyword.encode]), the same way as the user block list.
final class KeywordBlockRepository with LoggerMixin {
  /// Constructor.
  KeywordBlockRepository(this._storage);

  final StorageProvider _storage;

  /// Settings row name prefix.
  static const keyPrefix = 'keywordBlockList.';

  /// Max number of keywords of one account.
  static const maxCount = 200;

  /// Max length of one keyword.
  static const maxLength = 50;

  /// Settings row name of [ownerUid].
  static String keyOf(int ownerUid) => '$keyPrefix$ownerUid';

  final _changes = PublishSubject<KeywordBlockList>();

  Future<void> _writeQueue = Future.value();

  /// Emits the new list of an account after every change made through this repository.
  Stream<KeywordBlockList> get changes => _changes.stream;

  /// Load the list of [ownerUid], empty for null or invalid owners.
  ///
  /// Throws [KeywordBlockStorageException] when the stored row can not be read.
  Future<KeywordBlockList> load(int? ownerUid) async {
    if (ownerUid == null || ownerUid <= 0) {
      return KeywordBlockList.empty(ownerUid);
    }
    final List<String> raw;
    try {
      final stored = await _storage.getStringList(keyOf(ownerUid));
      raw = stored == null ? const [] : List<String>.of(stored);
    } on Object catch (e) {
      error('failed to load keyword block list: $e');
      throw KeywordBlockStorageException(e);
    }
    final keywords = <BlockedKeyword>[];
    final unreadable = <String>[];
    final seen = <String>{};
    for (final entry in raw) {
      final keyword = BlockedKeyword.decode(entry);
      if (keyword == null) {
        unreadable.add(entry);
      } else if (seen.add(keyword.key)) {
        keywords.add(keyword);
      }
    }
    return KeywordBlockList(ownerUid: ownerUid, keywords: keywords, unreadableEntries: unreadable);
  }

  /// Watch the list of [ownerUid]: current value first, then every change.
  ///
  /// A change saved while the first read is pending is emitted instead of the (possibly older) read result.
  Stream<KeywordBlockList> watch(int? ownerUid) {
    if (ownerUid == null || ownerUid <= 0) {
      return Stream.value(KeywordBlockList.empty(ownerUid));
    }
    late final StreamController<KeywordBlockList> controller;
    StreamSubscription<KeywordBlockList>? changesSub;
    controller = StreamController<KeywordBlockList>(
      onListen: () {
        var loaded = false;
        KeywordBlockList? pending;
        changesSub = _changes.stream.where((e) => e.ownerUid == ownerUid).listen((list) {
          if (loaded) {
            controller.add(list);
          } else {
            pending = list;
          }
        });
        unawaited(
          load(ownerUid).then(
            (list) {
              loaded = true;
              if (!controller.isClosed) {
                controller.add(pending ?? list);
              }
            },
            onError: (Object e, StackTrace st) {
              loaded = true;
              if (controller.isClosed) {
                return;
              }
              if (pending != null) {
                controller.add(pending!);
              } else {
                controller.addError(e, st);
              }
            },
          ),
        );
      },
      onCancel: () async {
        await changesSub?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _save(KeywordBlockList list) async {
    final owner = list.ownerUid!;
    if (list.keywords.isEmpty && list.unreadableEntries.isEmpty) {
      await _storage.deleteKey(keyOf(owner));
    } else {
      await _storage.saveStringList(keyOf(owner), [
        ...list.keywords.map((e) => e.encode()),
        ...list.unreadableEntries,
      ]);
    }
    _changes.add(list);
  }

  /// Add [keyword] to the list of [ownerUid].
  Future<KeywordBlockResult> add({
    required int? ownerUid,
    required String keyword,
    bool appliesToPosts = true,
    DateTime? now,
  }) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return KeywordBlockResult.invalid;
    }
    final value = normalizeBlockedKeyword(keyword);
    if (value.isEmpty) {
      return KeywordBlockResult.empty;
    }
    if (value.runes.length > maxLength) {
      return KeywordBlockResult.tooLong;
    }
    final list = await load(ownerUid);
    if (list.contains(value)) {
      return KeywordBlockResult.duplicate;
    }
    if (list.keywords.length >= maxCount) {
      return KeywordBlockResult.limitReached;
    }
    await _save(
      KeywordBlockList(
        ownerUid: ownerUid,
        keywords: [
          BlockedKeyword(keyword: value, appliesToPosts: appliesToPosts, createdAt: now ?? DateTime.now()),
          ...list.keywords,
        ],
        unreadableEntries: list.unreadableEntries,
      ),
    );
    return KeywordBlockResult.ok;
  });

  /// Remove [keyword] (compared as [foldKeywordText] does) from the list of [ownerUid].
  Future<KeywordBlockResult> remove({required int? ownerUid, required String keyword}) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return KeywordBlockResult.invalid;
    }
    final key = foldKeywordText(normalizeBlockedKeyword(keyword));
    final list = await load(ownerUid);
    if (!list.contains(key)) {
      return KeywordBlockResult.notFound;
    }
    await _save(
      KeywordBlockList(
        ownerUid: ownerUid,
        keywords: list.keywords.where((e) => e.key != key).toList(),
        unreadableEntries: list.unreadableEntries,
      ),
    );
    return KeywordBlockResult.ok;
  });

  /// Set whether [keyword] of [ownerUid] also hides floors.
  Future<KeywordBlockResult> setAppliesToPosts({
    required int? ownerUid,
    required String keyword,
    required bool value,
  }) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return KeywordBlockResult.invalid;
    }
    final key = foldKeywordText(normalizeBlockedKeyword(keyword));
    final list = await load(ownerUid);
    if (!list.contains(key)) {
      return KeywordBlockResult.notFound;
    }
    await _save(
      KeywordBlockList(
        ownerUid: ownerUid,
        keywords: [for (final e in list.keywords) e.key == key ? e.withAppliesToPosts(value: value) : e],
        unreadableEntries: list.unreadableEntries,
      ),
    );
    return KeywordBlockResult.ok;
  });

  /// Dispose.
  Future<void> dispose() async {
    await _changes.close();
  }
}
