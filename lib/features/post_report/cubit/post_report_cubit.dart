import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/post_report/repository/post_report_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Phases of one report dialog.
enum PostReportPhase {
  /// Reading the fresh page and form.
  loading,

  /// The form can not be used in the app, see [PostReportState.problem]. Nothing was sent.
  unavailable,

  /// Choosing a reason.
  ready,

  /// Checking again and sending.
  submitting,

  /// Checks before sending failed, see [PostReportState.problem]; nothing was sent, the input is kept.
  notSent,

  /// The forum refused the report, see [PostReportState.message]; the input is kept.
  rejected,

  /// The forum said the report succeeded.
  succeeded,

  /// Sent, result unknown. Never sent again from this dialog.
  unknown,

  /// The account changed or the dialog was closed; nothing more happens.
  closed,
}

/// State of [PostReportCubit]. Never holds the typed reason.
final class PostReportState {
  /// Constructor.
  const PostReportState(this.phase, {this.form, this.problem, this.message, this.formChanged = false});

  /// Phase.
  final PostReportPhase phase;

  /// The last form read, for its reason choices.
  final PostReportForm? form;

  /// Why nothing was sent.
  final PostReportProblem? problem;

  /// Plain forum text of a refusal, success or forum message.
  final String? message;

  /// The forum changed the reason choices before sending: nothing was sent, choose again.
  final bool formChanged;
}

/// One report of [target] for the account that saw it (#127).
///
/// The generation changes on [invalidate] (account change, dialog closed): an answer or a confirmation of an older
/// generation is dropped, also when the same account comes back (A → B → A). A report is sent at most once per
/// confirmed [submit], never automatically again, and never after an unknown result.
class PostReportCubit extends Cubit<PostReportState> {
  /// Constructor.
  PostReportCubit({required this.target, required this.currentUid, required this.repository})
    : super(const PostReportState(PostReportPhase.loading));

  /// The floor, bound to the account that was offered its report.
  final PostReportTarget target;

  /// The account in use now.
  final int? Function() currentUid;

  /// Builds a repository whose client is bound to the account in use now.
  final PostReportRepository Function() repository;

  int _generation = 0;
  bool _busy = false;
  bool _done = false;

  /// Current generation, taken by a confirmation when it opens.
  int get generation => _generation;

  bool _current(int generation) => !isClosed && !_done && generation == _generation && currentUid() == target.viewerUid;

  /// Whether a confirmation taken at [generation] may still send.
  bool canConfirm(int generation) =>
      _current(generation) &&
      !_busy &&
      state.form != null &&
      (state.phase == PostReportPhase.ready ||
          state.phase == PostReportPhase.notSent ||
          state.phase == PostReportPhase.rejected);

  /// Drop everything pending: no later answer is shown, no later confirmation or pending check sends.
  ///
  /// With [silent] the last state stays on screen (the dialog is closing and animates out as it was).
  void invalidate({bool silent = false}) {
    _generation++;
    _done = true;
    _busy = false;
    if (!silent && !isClosed) {
      emit(const PostReportState(PostReportPhase.closed));
    }
  }

  /// Read the form. Only reads; the account must be the one [target] was offered to.
  Future<void> load() async {
    if (_busy || _done || isClosed) {
      return;
    }
    final generation = ++_generation;
    final uid = currentUid();
    if (uid == null || uid != target.viewerUid) {
      emit(const PostReportState(PostReportPhase.unavailable, problem: PostReportProblem.accountChanged));
      return;
    }
    _busy = true;
    emit(const PostReportState(PostReportPhase.loading));
    try {
      final form = await repository().prepare(target, uid: uid);
      if (_current(generation)) {
        emit(PostReportState(PostReportPhase.ready, form: form));
      }
    } on PostReportFailure catch (e) {
      if (_current(generation)) {
        emit(PostReportState(PostReportPhase.unavailable, problem: e.problem, message: e.message));
      }
    } finally {
      if (generation == _generation) {
        _busy = false;
      }
    }
  }

  /// Send the reason [reasonIndex] ([custom] for the last choice) confirmed at [generation].
  ///
  /// Reads a fresh form first (account, floor and choices checked again); sends only when all still match.
  Future<void> submit({required int generation, required int reasonIndex, required String custom}) async {
    if (!canConfirm(generation)) {
      return;
    }
    final shown = state.form!;
    final message = shown.messageFor(reasonIndex, custom);
    if (message == null) {
      return;
    }
    final uid = currentUid()!;
    _busy = true;
    emit(PostReportState(PostReportPhase.submitting, form: shown));
    final repo = repository();
    final PostReportForm fresh;
    try {
      fresh = await repo.prepare(target, uid: uid);
    } on PostReportFailure catch (e) {
      if (_current(generation)) {
        _busy = false;
        emit(PostReportState(PostReportPhase.notSent, form: shown, problem: e.problem, message: e.message));
      }
      return;
    }
    if (!_current(generation)) {
      return;
    }
    if (!fresh.sameChoices(shown) || fresh.messageFor(reasonIndex, custom) != message) {
      _busy = false;
      emit(PostReportState(PostReportPhase.ready, form: fresh, formChanged: true));
      return;
    }
    // Last check with no await before the request.
    if (!_current(generation)) {
      return;
    }
    final outcome = await repo.submit(fresh, message);
    if (!_current(generation)) {
      // The account changed or the dialog closed meanwhile: nothing is shown to anybody, nothing is resent.
      return;
    }
    switch (outcome) {
      case PostReportSucceeded(message: final text):
        _done = true;
        emit(PostReportState(PostReportPhase.succeeded, message: text));
      case PostReportRejected(message: final text, :final notLoggedIn):
        _busy = false;
        emit(
          PostReportState(
            PostReportPhase.rejected,
            form: fresh,
            message: text,
            problem: notLoggedIn ? PostReportProblem.notLoggedIn : null,
          ),
        );
      case PostReportUnknown():
        _done = true;
        emit(const PostReportState(PostReportPhase.unknown));
    }
  }
}
