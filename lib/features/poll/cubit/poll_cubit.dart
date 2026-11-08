import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/models/poll_voters.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/special_thread/repository/special_thread_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

/// Ephemeral poll UI state; never saved to disk.
final class PollState {
  /// Constructor.
  const PollState({
    this.poll,
    this.uid,
    this.busy = false,
    this.failed = false,
    this.submissionUnconfirmed = false,
    this.choices = const {},
    this.refusal,
  });

  /// Latest server snapshot.
  final ForumPoll? poll;

  /// Account the snapshot belongs to.
  final int? uid;

  /// A load or submission is in progress.
  final bool busy;

  /// Loading failed; only a GET retry is available.
  final bool failed;

  /// The refreshed server state did not confirm the submission.
  final bool submissionUnconfirmed;

  /// Explicitly selected option identifiers.
  final Set<String> choices;

  /// The forum refused the latest vote, with this message (the forum's app API's result, plugin 2.6.0).
  final String? refusal;
}

/// Serializes voting and discards completions from obsolete accounts/pages.
class PollCubit extends Cubit<PollState> {
  /// Constructor.
  PollCubit({required this.url, required this.currentUid, required this.repository, this.onVoted})
    : super(const PollState());

  /// Original post URL, resolved by the forum to its thread.
  final String url;

  /// Active account, rechecked around every asynchronous operation.
  final int? Function() currentUid;

  /// Creates an identity-bound transport for each new fetch.
  final PollRepository Function() repository;

  /// Called instead of the GET for the results when the forum took a vote (its app API's result, plugin 2.6.0): the
  /// thread page holding the card reloads, and builds the card again with the poll as the forum now has it. Null
  /// where nothing reloads (the post of a notice): the card asks for the results itself.
  final void Function()? onVoted;
  int _generation = 0;
  PollRepository? _loadedRepository;

  /// A vote was taken and [onVoted] asked the thread page to reload; the card waits for it (busy).
  bool _awaitsReload = false;

  /// Whether the card waits for the reload of its thread page after a vote ([onVoted]): a reload that failed at once
  /// leaves the card on screen, which then asks for the poll itself.
  bool get awaitsReload => _awaitsReload;

  /// The polls a vote was sent for since the app started, as (account, [url]); in memory only.
  ///
  /// A vote is final, and a page read before it still shows the poll open: the floors a failed reload of the thread
  /// page puts back on screen (see ThreadBloc) build their cards again from that page, which showed the poll open for
  /// a second vote the forum refuses. Recorded when the vote is sent: the forum may count it although its answer never
  /// arrives (a failed request, or the card closed meanwhile).
  static final _votesSent = <(int, String)>{};

  /// The options an account is known to have voted for, as (account, [url]) to option ids; in memory only. The forum's
  /// poll answer does not say which options the viewer chose: they are known from the vote sent from here and from
  /// the voters lists of a public vote that name the account.
  static final _mine = <(int, String), Set<String>>{};

  /// Forget the votes sent and the choices known, for tests.
  @visibleForTesting
  static void forgetVotesSent() {
    _votesSent.clear();
    _mine.clear();
  }

  /// The options this account is known to have voted for in this poll.
  Set<String> get mine {
    final uid = currentUid();
    return uid == null ? const {} : Set.unmodifiable(_mine[(uid, url)] ?? const <String>{});
  }

  void _remember(int uid, Set<String> ids) {
    if (ids.isEmpty) return;
    _mine[(uid, url)] = {...?_mine[(uid, url)], ...ids};
  }

  /// Page [page] of the voters of the option [optionId], for the account the poll was read for. Throws when the
  /// account changed meanwhile or the forum does not answer a voters list. An account named in the list is known to
  /// have voted for the option ([mine]).
  Future<PollVotersPage> loadVoters(String optionId, {int page = 1}) async {
    final votersUrl = state.poll?.votersUrl;
    final uid = state.uid;
    if (votersUrl == null || uid == null || uid != currentUid()) {
      throw const FormatException('Voters are not available');
    }
    final result = await repository().fetchVoters(votersUrl, optionId, page: page);
    if (uid != currentUid()) {
      throw const FormatException('Poll identity changed');
    }
    if (!isClosed && result.voters.any((e) => e.uid == uid) && !mine.contains(optionId)) {
      _remember(uid, {optionId});
      // Same snapshot, new instance: the card draws the option as the account's.
      final current = state;
      emit(
        PollState(
          poll: current.poll,
          uid: current.uid,
          busy: current.busy,
          failed: current.failed,
          submissionUnconfirmed: current.submissionUnconfirmed,
          choices: current.choices,
          refusal: current.refusal,
        ),
      );
    }
    return result;
  }

  /// Hide old-account data immediately, including during a login transition.
  void invalidate() {
    _awaitsReload = false;
    _generation++;
    _loadedRepository = null;
    emit(const PollState(busy: true));
  }

  bool _current(int generation, int? uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Show the poll [form] of the page the post was read from, a page served to [servedUid], without asking the forum:
  /// the thread page already loaded it for the account in use.
  ///
  /// False when it cannot be shown, the caller then loads instead:
  ///
  /// * The page belongs to another account than the current one (the account changed since).
  /// * The page was served as to a guest, or does not say to whom, while an account is in use. The forum does that when
  ///   the session of the account expired (issue #25), and the account may have logged in again since; or the page was
  ///   read before a login: the floors a failed reload of the thread page puts back after a login or a switch are
  ///   those of the page before (see ThreadBloc). Shown, the card asked an account logged in to log in, and asked the
  ///   forum nothing. Only such a page costs a request, mostly while the session is expired; a guest gets the page of
  ///   a guest.
  /// * The page shows the poll open although this account sent a vote for it since (the page was read before the vote,
  ///   see [_votesSent]).
  ///
  /// The form is checked the way [PollRepository.fetch] checks a page.
  bool adopt(String form, {required int? servedUid}) {
    final uid = currentUid();
    if (servedUid == null && uid != null) {
      return false;
    }
    final ForumPoll poll;
    try {
      poll = PollRepository.pollOfPage(parseHtmlDocument(form), servedUid: servedUid, uid: uid);
    } on FormatException {
      return false;
    }
    if (poll.availability == PollAvailability.available && uid != null && _votesSent.contains((uid, url))) {
      return false;
    }
    _generation++;
    // Votes go out through a client bound to the account the form belongs to, as after a load.
    _loadedRepository = repository();
    emit(PollState(poll: poll, uid: uid));
    return true;
  }

  /// Show the poll [special] of the thread page the card is in (the forum's app API, plugin 2.8.0), without asking the
  /// forum, as [adopt] shows a page's form, under the same conditions: the page belongs to the account in use, and it
  /// does not show the poll open although this account sent a vote for it since. False when it cannot be shown, the
  /// caller then loads instead.
  bool adoptSpecial(PollSpecial special) {
    final uid = currentUid();
    final servedUid = special.viewerUid;
    if ((servedUid == null && uid != null) || (servedUid != null && servedUid != uid)) {
      return false;
    }
    final poll = forumPollFromSpecial(special, loggedIn: uid != null && servedUid == uid);
    if (poll.availability == PollAvailability.available && uid != null && _votesSent.contains((uid, url))) {
      return false;
    }
    _generation++;
    _loadedRepository = repository();
    emit(PollState(poll: poll, uid: uid));
    return true;
  }

  /// Reload by GET only. Never repeat a failed/ambiguous submission here.
  Future<void> load() async {
    _awaitsReload = false;
    final generation = ++_generation;
    final uid = currentUid();
    final repo = repository();
    _loadedRepository = null;
    emit(PollState(uid: uid, busy: true));
    try {
      final poll = await repo.fetch(url, uid);
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(PollState(poll: poll, uid: uid));
    } on Exception {
      if (_current(generation, uid)) emit(PollState(uid: uid, failed: true));
    }
  }

  /// Change a choice while enforcing the server's selection limit.
  void select(String id, {required bool selected}) {
    final poll = state.poll;
    if (state.busy || state.uid != currentUid() || poll?.availability != PollAvailability.available) return;
    if (!poll!.options.any((option) => option.id == id)) return;
    final choices = {...state.choices};
    if (!selected) {
      choices.remove(id);
    } else if (poll.maxChoices == 1) {
      choices
        ..clear()
        ..add(id);
    } else if (choices.length < (poll.maxChoices ?? 0)) {
      choices.add(id);
    }
    emit(PollState(poll: poll, uid: state.uid, choices: Set.unmodifiable(choices)));
  }

  /// One explicit POST, followed by a mandatory authoritative GET.
  Future<void> submit() async {
    final snapshot = state;
    final repo = _loadedRepository;
    final poll = snapshot.poll;
    if (snapshot.busy ||
        snapshot.uid == null ||
        snapshot.uid != currentUid() ||
        repo == null ||
        poll == null ||
        !poll.accepts(snapshot.choices)) {
      return;
    }
    final generation = ++_generation;
    emit(PollState(poll: poll, uid: snapshot.uid, busy: true, choices: snapshot.choices));
    _votesSent.add((snapshot.uid!, url));
    _remember(snapshot.uid!, snapshot.choices);
    TsdmAppWriteResult? result;
    try {
      result = await repo.vote(poll, snapshot.choices);
    } on Exception {
      // A failed response can still mean the server accepted the vote. Only GET next.
    }
    if (!_current(generation, snapshot.uid)) return;
    // The forum's verdict when its app API gave one (a `page` tells nothing by itself): a vote taken reloads the
    // thread page where there is one, a refusal is shown with the forum's words and the poll read again.
    String? refusal;
    if (result != null && result.kind != TsdmAppWriteKind.page) {
      switch (specialOutcomeOfResult(result, doneKeys: const {'thread_poll_succeed'})) {
        case SpecialActionDone() when onVoted != null:
          _awaitsReload = true;
          onVoted!();
          return;
        case SpecialActionRefused(:final message):
          refusal = message;
          // The forum said no: the vote was not counted.
          _votesSent.remove((snapshot.uid!, url));
          _mine.remove((snapshot.uid!, url));
        case SpecialActionDone() || SpecialActionUnknown():
          break;
      }
    }
    try {
      final refreshed = await repo.fetch(url, snapshot.uid);
      if (!_current(generation, snapshot.uid)) return;
      emit(
        PollState(
          poll: refreshed,
          uid: snapshot.uid,
          submissionUnconfirmed: refusal == null && refreshed.availability != PollAvailability.voted,
          refusal: refusal,
        ),
      );
    } on Exception {
      if (_current(generation, snapshot.uid)) {
        _loadedRepository = null;
        emit(PollState(uid: snapshot.uid, failed: true, submissionUnconfirmed: refusal == null, refusal: refusal));
      }
    }
  }
}
