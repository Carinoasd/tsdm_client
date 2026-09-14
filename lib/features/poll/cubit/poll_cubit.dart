import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';

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
}

/// Serializes voting and discards completions from obsolete accounts/pages.
class PollCubit extends Cubit<PollState> {
  /// Constructor.
  PollCubit({required this.url, required this.currentUid, required this.repository}) : super(const PollState());

  /// Original post URL, resolved by the forum to its thread.
  final String url;

  /// Active account, rechecked around every asynchronous operation.
  final int? Function() currentUid;

  /// Creates an identity-bound transport for each new fetch.
  final PollRepository Function() repository;
  int _generation = 0;
  PollRepository? _loadedRepository;

  /// Hide old-account data immediately, including during a login transition.
  void invalidate() {
    _generation++;
    _loadedRepository = null;
    emit(const PollState(busy: true));
  }

  bool _current(int generation, int? uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Reload by GET only. Never repeat a failed/ambiguous submission here.
  Future<void> load() async {
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
    try {
      await repo.vote(poll, snapshot.choices);
    } on Exception {
      // A failed response can still mean the server accepted the vote. Only GET next.
    }
    if (!_current(generation, snapshot.uid)) return;
    try {
      final refreshed = await repo.fetch(url, snapshot.uid);
      if (!_current(generation, snapshot.uid)) return;
      emit(
        PollState(
          poll: refreshed,
          uid: snapshot.uid,
          submissionUnconfirmed: refreshed.availability != PollAvailability.voted,
        ),
      );
    } on Exception {
      if (_current(generation, snapshot.uid)) {
        _loadedRepository = null;
        emit(PollState(uid: snapshot.uid, failed: true, submissionUnconfirmed: true));
      }
    }
  }
}
