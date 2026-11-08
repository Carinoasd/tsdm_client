import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread_link_card/models/thread_link_card_info.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Fetches the first page of the thread [tid].
typedef ThreadLinkPageFetcher = Future<Either<AppException, ThreadPageInfo>> Function(int tid);

/// The cards of the links to threads in the posts ([ThreadLinkCardInfo]), kept for the run of the app.
///
/// A card is the first page of its thread, asked the way the thread page asks it (the forum's app API in the JSON
/// mode, `nodoc=1`; the web page without the plugin: [ThreadRepository.fetchThreadFirstPage]). Each thread is asked
/// once for each account: a link appearing again (in the same floor, another floor, another thread) shares the answer
/// or the request still going. An answer is kept, also one the account can not read (null: the card is the link
/// again); a failed request is not, the card asks again the next time it is shown.
///
/// An answer that comes back after the account in use changed is dropped: it was served to the other account.
final class ThreadLinkCardRepository with LoggerMixin {
  /// Constructor.
  ThreadLinkCardRepository({ThreadLinkPageFetcher? fetchPage, int? Function()? currentUid})
    : _fetchPage = fetchPage ?? _fetchFirstPage,
      _currentUid = currentUid ?? _cookieUid;

  /// The one used by the cards, replaced in tests.
  static ThreadLinkCardRepository instance = ThreadLinkCardRepository();

  final ThreadLinkPageFetcher _fetchPage;
  final int? Function() _currentUid;

  /// Answers kept, by account and thread.
  final _answers = <(int, int), ThreadLinkCardInfo?>{};

  /// Requests going, by account and thread.
  final _pending = <(int, int), Future<ThreadLinkCardInfo?>>{};

  static Future<Either<AppException, ThreadPageInfo>> _fetchFirstPage(int tid) async =>
      (await ThreadRepository().fetchThreadFirstPage(tid: '$tid').run()).map((e) => e.page);

  static int? _cookieUid() =>
      getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null;

  (int, int) _key(int tid) => (_currentUid() ?? 0, tid);

  /// Whether the thread [tid] was answered for the account in use ([cached] then is the card, or null).
  bool isCached(int tid) => _answers.containsKey(_key(tid));

  /// The card of [tid] answered for the account in use, null when not answered or not readable.
  ThreadLinkCardInfo? cached(int tid) => _answers[_key(tid)];

  /// The card of [tid] for the account in use: the answer kept, the request going, or a new request. Null when the
  /// account can not read the thread, the request failed or the account changed meanwhile.
  Future<ThreadLinkCardInfo?> load(int tid) async {
    final key = _key(tid);
    if (_answers.containsKey(key)) {
      return _answers[key];
    }
    return _pending[key] ??= _requestOnce(key);
  }

  Future<ThreadLinkCardInfo?> _requestOnce((int, int) key) async {
    try {
      return await _request(key);
    } finally {
      // The future removed is this one, awaited by its callers.
      unawaited(_pending.remove(key));
    }
  }

  Future<ThreadLinkCardInfo?> _request((int, int) key) async {
    final (uid, tid) = key;
    final Either<AppException, ThreadPageInfo> answer;
    try {
      answer = await _fetchPage(tid);
    } on Object catch (e, st) {
      error('failed to load the card of thread $tid', e, st);
      return null;
    }
    if ((_currentUid() ?? 0) != uid) {
      return null;
    }
    switch (answer) {
      case Left(:final value):
        debug('card of thread $tid not loaded: $value');
        return null;
      case Right(:final value):
        final info = ThreadLinkCardInfo.ofPage(tid, value);
        _answers[key] = info;
        return info;
    }
  }

  /// Forget every card (for tests).
  @visibleForTesting
  void clear() {
    _answers.clear();
    _pending.clear();
  }
}
