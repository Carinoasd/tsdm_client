import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/utils/guide_index_api.dart';
import 'package:tsdm_client/features/latest_thread/utils/guide_page_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/saved_answer_store.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The account the global cookie names and the session of it it holds ([CookieProvider.generation]); null fields
/// without a cookie provider (tests).
typedef _Session = ({int? uid, int? generation});

_Session _sessionNow() {
  final cookie = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>() : null;
  return (uid: cookie?.userLoginInfo.uid, generation: cookie?.generation);
}

/// Key of the account [uid] in the saved modules: 0 for a guest.
int _accountKey(int? uid) => uid != null && uid > 0 ? uid : 0;

/// A request of the guide index asked ahead by [GuideFeed.prefetch], with the session it was asked with.
typedef _Prefetch = ({_Session session, DateTime askedAt, Future<Either<AppException, List<GuideModule>>> answer});

/// The guide index of the homepage, one for the whole app.
///
/// The homepage asks for it as soon as it starts loading ([prefetch]), instead of once its own page had arrived and
/// built the guide card: the two requests went one after the other. The card takes that request ([fetch]) instead of
/// asking again; a request is only ever taken for the session it was asked with (the account the global cookie names
/// and its generation), once, and while it is fresh ([freshFor]).
///
/// Every structured answer is saved for the account it was served to ([SavedAnswerStore]); the homepage reads the
/// account's before the card is built ([loadSaved]), so the card shows them at once ([savedModules]) while the guide is
/// asked again.
final class GuideFeed with LoggerMixin {
  /// Constructor.
  ///
  /// [savedAnswers] keeps the answers for the next start, the app's store by default (none in tests that register
  /// none).
  GuideFeed({
    GuideIndexRepository repository = const GuideIndexRepository(),
    SavedAnswerStore? savedAnswers,
    this.freshFor = const Duration(seconds: 30),
  }) : _repository = repository,
       _savedAnswers = savedAnswers ?? SavedAnswerStore.app;

  final GuideIndexRepository _repository;
  final SavedAnswerStore? _savedAnswers;

  /// How long a request asked ahead may wait for the card to take it.
  final Duration freshFor;

  _Prefetch? _prefetch;

  /// Modules saved for each account (0 for the guest), read by [loadSaved], with when they were saved and the
  /// [SavedAnswerStore.forgetCountOf] of the account then.
  final _saved = <int, ({List<GuideModule> modules, DateTime savedAt, int forgotten})>{};

  /// Ask for the guide of the session in use now, unless a fresh request of it is waiting already.
  void prefetch() {
    final session = _sessionNow();
    final waiting = _prefetch;
    if (waiting != null && waiting.session == session && DateTime.now().difference(waiting.askedAt) < freshFor) {
      return;
    }
    _prefetch = (session: session, askedAt: DateTime.now(), answer: _ask(session));
  }

  /// The guide of the session in use now: the request [prefetch] asked for it when it is fresh (taken once), a new one
  /// otherwise.
  AsyncEither<List<GuideModule>> fetch() => AsyncEither(() async {
    final session = _sessionNow();
    final waiting = _prefetch;
    if (waiting != null && waiting.session == session && DateTime.now().difference(waiting.askedAt) < freshFor) {
      _prefetch = null;
      debug('take the guide index asked with the homepage');
      return waiting.answer;
    }
    return _ask(session);
  });

  Future<Either<AppException, List<GuideModule>>> _ask(_Session session) async {
    debug('fetch guide index');
    final answer = await _repository.fetchGuideIndexAnswer().run();
    return answer.map((value) {
      final json = value.json;
      // Saved under the account the answer names; not an answer that arrived after the session changed.
      if (json != null && json['ok'] == 1 && _sessionNow() == session) {
        _savedAnswers?.save(SavedAnswerKind.guide, json);
      }
      return value.modules;
    });
  }

  /// Read the modules saved for the account [uid] (null for the guest), for [savedModules]; none when nothing is saved,
  /// it is older than a day or of another format ([SavedAnswerStore]).
  Future<void> loadSaved(int? uid) async {
    final key = _accountKey(uid);
    final forgotten = _savedAnswers?.forgetCountOf(uid) ?? 0;
    final saved = await _savedAnswers?.load(SavedAnswerKind.guide, uid: uid);
    final json = saved == null ? null : guideApiAnswerOf(saved.answer);
    final modules = json == null || json['ok'] != 1 ? null : guideModulesFromApi(json);
    if (modules == null || modules.isEmpty || saved == null) {
      _saved.remove(key);
    } else {
      _saved[key] = (modules: modules, savedAt: saved.savedAt, forgotten: forgotten);
    }
  }

  /// The modules [loadSaved] read for the account in use now, null when none, when they are too old by now, or the
  /// account's answers were forgotten since (logged out, removed, its session dead).
  List<GuideModule>? get savedModules {
    final key = _accountKey(_sessionNow().uid);
    final saved = _saved[key];
    final store = _savedAnswers;
    if (saved == null || store == null) {
      return null;
    }
    if (store.forgetCountOf(key) != saved.forgotten || store.now().difference(saved.savedAt) > store.maxAge) {
      _saved.remove(key);
      return null;
    }
    return saved.modules;
  }
}
