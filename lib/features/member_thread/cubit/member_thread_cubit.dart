import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_api.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_parser.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// Status of one list of a member's page.
enum MemberThreadStatus {
  /// Not asked yet.
  initial,

  /// Loading the first page, nothing to show yet.
  loading,

  /// The list (maybe empty) is shown.
  success,

  /// The forum asked to log in (a guest: the forum shows the space lists to members only).
  needLogin,

  /// The forum answered a message instead of the list (no such member, the forum closed).
  notice,

  /// The first page failed to load.
  failed,
}

/// One list (threads or replies) of a member's page.
final class MemberThreadListState {
  /// Constructor.
  const MemberThreadListState({
    this.status = MemberThreadStatus.initial,
    this.items = const [],
    this.nextPageUrl,
    this.pageNumber = 1,
    this.refreshing = false,
    this.loadingMore = false,
    this.message,
    this.failureCount = 0,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// Status.
  final MemberThreadStatus status;

  /// The rows loaded, in the forum's order.
  final List<MyThread> items;

  /// The next page, null when the forum has none.
  final String? nextPageUrl;

  /// The last page loaded.
  final int pageNumber;

  /// Reloading the first page while the rows loaded stay shown.
  final bool refreshing;

  /// Loading the next page.
  final bool loadingMore;

  /// The forum's message ([MemberThreadStatus.notice]).
  final String? message;

  /// Counts the failed loads of a next page.
  final int failureCount;

  /// The next page failed: the rows loaded before stay, the end of the list retries.
  final bool loadMoreFailed;

  /// Why the last load failed: the first page ([MemberThreadStatus.failed]), the next page ([loadMoreFailed]), or a
  /// refresh that kept the rows shown. Null once a load succeeded.
  final LoadFailure? failure;

  /// A copy with the given fields replaced; [nextPageUrl], [message] and [failure] are replaced as given (null clears
  /// them).
  MemberThreadListState copyWith({
    MemberThreadStatus? status,
    List<MyThread>? items,
    String? Function()? nextPageUrl,
    int? pageNumber,
    bool? refreshing,
    bool? loadingMore,
    String? Function()? message,
    int? failureCount,
    bool? loadMoreFailed,
    LoadFailure? Function()? failure,
  }) => MemberThreadListState(
    status: status ?? this.status,
    items: items ?? this.items,
    nextPageUrl: nextPageUrl != null ? nextPageUrl() : this.nextPageUrl,
    pageNumber: pageNumber ?? this.pageNumber,
    refreshing: refreshing ?? this.refreshing,
    loadingMore: loadingMore ?? this.loadingMore,
    message: message != null ? message() : this.message,
    failureCount: failureCount ?? this.failureCount,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    failure: failure != null ? failure() : this.failure,
  );
}

/// State of a member's page: their threads and their replies, and who they are as the forum named them.
final class MemberThreadState {
  /// Constructor.
  const MemberThreadState({
    this.thread = const MemberThreadListState(),
    this.reply = const MemberThreadListState(),
    this.ownerUid,
    this.ownerName,
    this.viewerUid,
  });

  /// The threads.
  final MemberThreadListState thread;

  /// The replies, one row per reply.
  final MemberThreadListState reply;

  /// The member whose lists these are, as the answer named them (`owner` of a structured answer), else as the route
  /// did.
  final int? ownerUid;

  /// The member's name, as [ownerUid].
  final String? ownerName;

  /// The account the lists were asked for (the uid of the session in use when they were asked), null for a guest.
  final int? viewerUid;

  /// The list [tab].
  MemberThreadListState of(MemberThreadTab tab) => switch (tab) {
    MemberThreadTab.thread => thread,
    MemberThreadTab.reply => reply,
  };

  MemberThreadState _with(
    MemberThreadTab tab,
    MemberThreadListState list, {
    int? ownerUid,
    String? ownerName,
    int? Function()? viewerUid,
  }) => MemberThreadState(
    thread: tab == MemberThreadTab.thread ? list : thread,
    reply: tab == MemberThreadTab.reply ? list : reply,
    ownerUid: ownerUid ?? this.ownerUid,
    ownerName: ownerName ?? this.ownerName,
    viewerUid: viewerUid != null ? viewerUid() : this.viewerUid,
  );
}

/// The session a list is asked with: the account the global cookie names and the session of it it holds
/// (`CookieProvider.generation`), as the requests of `NetClientProvider.build` are bound to; null fields without a
/// cookie provider (tests).
typedef MemberThreadSession = ({int? uid, int? generation});

MemberThreadSession _sessionNow() {
  final cookie = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>() : null;
  return (uid: cookie?.userLoginInfo.uid, generation: cookie?.generation);
}

/// Loads the threads and the replies of another member ("TA的主题", `home.php?mod=space&uid=N&do=thread&view=me`).
///
/// The forum lists another member's threads and replies with the template of the account's own list, so the pages are
/// asked and read as the "my threads" page reads them ([MyThreadRepository], [myThreadPageOf]): the structured answer
/// of the forum's app API (plugin 2.4.0, `schema: 9`, asked lean) built from its fields, the web page or an older
/// plugin's answer parsed as before. What the forum hides from the viewer (anonymous posts, posts in forums the
/// viewer can not see, all of it when the forum closed the lists to others) it hides here too.
///
/// What the forum lets a member see of another member's lists depends on the viewer, so each list is bound to the
/// session it was asked with: an answer that comes back after another account (or another session of the account)
/// came into use is dropped and the list asked again, and an answer served to another account than the one asked
/// with is a failure. The requests themselves are dropped by the net client once the account changed.
final class MemberThreadCubit extends Cubit<MemberThreadState> with LoggerMixin {
  /// Constructor.
  ///
  /// The member is [uid] and/or [username], as the link named them ([memberThreadUrl]).
  MemberThreadCubit({
    required MyThreadRepository repository,
    this.uid,
    this.username,
    MemberThreadSession Function()? session,
  }) : _repository = repository,
       _session = session ?? _sessionNow,
       super(MemberThreadState(ownerUid: int.tryParse(uid ?? ''), ownerName: username));

  /// Uid of the member, as the route named it.
  final String? uid;

  /// Name of the member, as the route named it.
  final String? username;

  final MyThreadRepository _repository;
  final MemberThreadSession Function() _session;

  /// Bumped by every load of a list: an answer to an older one is dropped.
  final List<int> _generations = List.filled(MemberThreadTab.values.length, 0);

  bool _isCurrent(MemberThreadTab tab, int generation) => !isClosed && _generations[tab.index] == generation;

  /// The account the latest load was asked as (the uid of the session then), null before the first and for a guest.
  int? get askedUid => _askedUid;
  int? _askedUid;

  /// The session the rows of each list were asked with: a next page is only appended to rows of the same session.
  final List<MemberThreadSession?> _loadedSessions = List.filled(MemberThreadTab.values.length, null);

  /// Load the first page of the list [tab]: the first time, on a pull to refresh, to retry.
  Future<void> load(MemberThreadTab tab) async {
    if (isClosed) {
      return;
    }
    final generation = ++_generations[tab.index];
    final session = _session();
    _askedUid = session.uid;
    final list = state.of(tab);
    final shown = list.status == MemberThreadStatus.success;
    emit(
      state._with(
        tab,
        shown
            ? list.copyWith(refreshing: true, loadingMore: false, loadMoreFailed: false, failure: () => null)
            : const MemberThreadListState(status: MemberThreadStatus.loading),
      ),
    );
    final url = memberThreadUrl(tab, uid: uid, username: username);
    final result = await _repository.fetchPage(url).run();
    if (!_isCurrent(tab, generation)) {
      return;
    }
    if (_session() != session) {
      warning('member thread: the account changed while loading the $tab list, ask it again');
      unawaited(load(tab));
      return;
    }
    switch (result) {
      case Left(:final value):
        handle(value);
        // A refresh keeps the rows shown (the page says it failed), a first page tells why it failed.
        emit(
          state._with(
            tab,
            state.of(tab).copyWith(status: _failedStatus(tab), refreshing: false, failure: () => LoadFailure.of(value)),
          ),
        );
      case Right(:final value):
        _onFirstPage(tab, value, url, session);
    }
  }

  /// The first page [answer] of the list [tab], asked from [url] with [session].
  void _onFirstPage(MemberThreadTab tab, TsdmAppPageAnswer answer, String url, MemberThreadSession session) {
    // The forum's message instead of the list: the login prompt of a guest, or a refusal.
    final message = _messageOf(answer);
    if (message != null) {
      emit(
        state._with(
          tab,
          MemberThreadListState(
            status: message.login ? MemberThreadStatus.needLogin : MemberThreadStatus.notice,
            message: message.text,
          ),
          viewerUid: () => session.uid,
        ),
      );
      return;
    }
    if (_servedToAnother(answer, session)) {
      error('member thread: the $tab list was served to another account than ${session.uid}');
      emit(
        state._with(
          tab,
          state
              .of(tab)
              .copyWith(
                status: _failedStatus(tab),
                refreshing: false,
                failure: () => LoadFailure(LoadFailureKind.accountChanged),
              ),
        ),
      );
      return;
    }
    // Not the list either: the forum printed another page instead (the profile of a banned member, see the plugin
    // README), which has nothing of the list. Told as such, not as an empty list.
    if (answer case TsdmAppWebPage(:final document) when document.querySelector('form#delform') == null) {
      warning('member thread: the forum answered the $tab list with another page');
      emit(
        state._with(tab, const MemberThreadListState(status: MemberThreadStatus.notice), viewerUid: () => session.uid),
      );
      return;
    }
    final (items, nextPageUrl) = myThreadPageOf(answer, url, reply: tab == MemberThreadTab.reply);
    final owner = switch (answer) {
      TsdmAppStructuredPage(:final json) => tsdmAppMap(json['owner']),
      TsdmAppWebPage() => const <String, dynamic>{},
    };
    final ownerName = tsdmAppText(owner['username']);
    _loadedSessions[tab.index] = session;
    emit(
      state._with(
        tab,
        MemberThreadListState(status: MemberThreadStatus.success, items: items, nextPageUrl: nextPageUrl),
        ownerUid: switch (answer) {
          TsdmAppStructuredPage(:final json) => myThreadApiOwnerUid(json),
          TsdmAppWebPage(:final document) => _webOwnerUid(document),
        },
        ownerName: ownerName.isEmpty ? null : ownerName,
        viewerUid: () => session.uid,
      ),
    );
  }

  /// Load the next page of the list [tab].
  Future<void> loadMore(MemberThreadTab tab) async {
    final list = state.of(tab);
    final url = list.nextPageUrl;
    if (isClosed || url == null || list.loadingMore || list.refreshing || list.status != MemberThreadStatus.success) {
      return;
    }
    final session = _session();
    if (session != _loadedSessions[tab.index]) {
      // The rows shown were asked as another account or session: start over rather than mix the two.
      warning('member thread: the account changed since the $tab list was loaded, ask it again');
      await load(tab);
      return;
    }
    final generation = ++_generations[tab.index];
    emit(state._with(tab, list.copyWith(loadingMore: true, loadMoreFailed: false)));
    final result = await _repository.fetchPage(url).run();
    if (!_isCurrent(tab, generation)) {
      return;
    }
    if (_session() != session) {
      // The rows loaded were asked as another account: start over.
      warning('member thread: the account changed while loading more of the $tab list, ask it again');
      unawaited(load(tab));
      return;
    }
    final current = state.of(tab);
    // The rows loaded before stay, the end of the list tells why the next page failed and retries.
    MemberThreadListState failed(LoadFailure failure) => current.copyWith(
      loadingMore: false,
      failureCount: current.failureCount + 1,
      loadMoreFailed: true,
      failure: () => failure,
    );
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(state._with(tab, failed(LoadFailure.of(value))));
      case Right(:final value):
        if (_messageOf(value) case final message?) {
          emit(
            state._with(
              tab,
              failed(
                message.login ? LoadFailure(LoadFailureKind.needLogin) : LoadFailure.fromMessage(message.text),
              ),
            ),
          );
          return;
        }
        if (_servedToAnother(value, session) ||
            (value is TsdmAppWebPage && value.document.querySelector('form#delform') == null)) {
          error('member thread: a next page of the $tab list was served to another account, or is no list');
          emit(state._with(tab, failed(LoadFailure(LoadFailureKind.unknown))));
          return;
        }
        final (items, nextPageUrl) = myThreadPageOf(value, url, reply: tab == MemberThreadTab.reply);
        emit(
          state._with(
            tab,
            current.copyWith(
              items: [...current.items, ...items],
              nextPageUrl: () => nextPageUrl,
              pageNumber: current.pageNumber + 1,
              loadingMore: false,
              loadMoreFailed: false,
              failure: () => null,
            ),
          ),
        );
    }
  }

  /// Load both lists again from their first page, the rows of the previous account dropped at once: another account
  /// came into use, and what the forum shows of the member depends on who asks.
  Future<void> reloadAll() async {
    if (isClosed) {
      return;
    }
    emit(MemberThreadState(ownerUid: state.ownerUid, ownerName: state.ownerName));
    await Future.wait(MemberThreadTab.values.map(load));
  }

  /// A failed first page keeps the rows shown by a failed refresh.
  MemberThreadStatus _failedStatus(MemberThreadTab tab) =>
      state.of(tab).status == MemberThreadStatus.success ? MemberThreadStatus.success : MemberThreadStatus.failed;
}

/// Whether a list page [answer] asked with [session] was served to another account: the viewer of the structured
/// answer (its `uid`), or of the web page (its `discuz_uid`, when the page names it), is not the account asked as.
/// Not checked without an account (a guest gets the login prompt) or when the page names none.
bool _servedToAnother(TsdmAppPageAnswer answer, MemberThreadSession session) {
  final asked = session.uid;
  if (asked == null || asked <= 0) {
    return false;
  }
  return switch (answer) {
    TsdmAppStructuredPage(:final json) => myThreadApiViewerUid(json) != asked,
    TsdmAppWebPage(:final document) => switch (_webViewerUid(document)) {
      final int served => served != asked,
      null => false,
    },
  };
}

final _discuzUidRe = RegExp(r"discuz_uid\s*=\s*'(\d+)'");

/// The account the web page [document] was served to (its `discuz_uid`, 0 for a guest), null when it names none (an
/// older plugin's answer without its head).
int? _webViewerUid(uh.Document document) {
  for (final script in document.querySelectorAll('script')) {
    final match = _discuzUidRe.firstMatch(script.text ?? '');
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
  }
  return null;
}

final _webOwnerRe = RegExp(r'mod=space&(?:amp;)?uid=(\d+)&(?:amp;)?do=thread');

/// The member whose list the web page [document] is: the uid its own links to the list carry (the pagination, the
/// forum filter's script: `home.php?mod=space&uid=N&do=thread`), null when it has none (one page, no filter).
int? _webOwnerUid(uh.Document document) {
  final match = _webOwnerRe.firstMatch(document.documentElement?.outerHtml ?? '');
  final uid = match == null ? null : int.tryParse(match.group(1)!);
  return uid != null && uid > 0 ? uid : null;
}

/// The forum's message in a list page [answer] instead of the list, null for a list: the structured answer of the
/// forum's message (`ok` 0, `error: message`; `login` 1 for a guest), or the 提示信息 page of the web page
/// (`div#messagetext`, the login form `div#messagelogin` for a guest).
({String text, bool login})? _messageOf(TsdmAppPageAnswer answer) {
  switch (answer) {
    case TsdmAppStructuredPage(:final json) when json['ok'] != 1:
      return (text: tsdmAppText(json['message']), login: tsdmAppMessageAsksLogin(json));
    case TsdmAppStructuredPage():
      return null;
    case TsdmAppWebPage(:final document):
      return _webMessageOf(document);
  }
}

({String text, bool login})? _webMessageOf(uh.Document document) {
  if (document.querySelector('form#delform') != null) {
    return null;
  }
  final node = document.querySelector('div#messagetext > p') ?? document.querySelector('div#messagetext');
  if (node == null) {
    return null;
  }
  return (text: node.innerText.trim(), login: document.querySelector('div#messagelogin') != null);
}
