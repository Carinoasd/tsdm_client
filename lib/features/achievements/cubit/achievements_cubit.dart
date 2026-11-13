import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/achievements/models/achievement_page_data.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:universal_html/parsing.dart';

/// Current-account achievement state, with no persistent/cross-account cache.
final class AchievementsState {
  /// Constructor.
  const AchievementsState({this.data, this.loading = false, this.failed = false, this.needLogin = false});

  /// Server-supplied data.
  final AchievementPageData? data;

  /// An in-flight GET.
  final bool loading;

  /// Retryable network/identity error.
  final bool failed;

  /// Not signed in, or the session expired.
  final bool needLogin;
}

/// Loads only the current account's achievement landing page.
class AchievementsCubit extends Cubit<AchievementsState> {
  /// [fetchPage] must use the app's identity-bound network client.
  AchievementsCubit({required this.fetchPage, required this.currentUid, this.fetchApi, this.ensureStatus})
    : super(const AchievementsState());

  /// A read-only GET transport; takes no user-supplied URL or action parameters.
  final Future<String> Function() fetchPage;

  /// The same page asked of the forum's app API as fields (plugin 4.0.0, `tsdmv=4`), its answer as it came; used once
  /// `status` says the forum runs the achievements (`achievement: 1`).
  final Future<Object?> Function()? fetchApi;

  /// Asks the plugin's `status` when this run has none yet.
  final Future<void> Function()? ensureStatus;

  /// Current effective account.
  final int? Function() currentUid;
  int _generation = 0;

  /// Hide account data immediately when authentication starts changing.
  void invalidate() {
    _generation++;
    emit(const AchievementsState(loading: true));
  }

  /// Fetch and confirm the forum rendered this page for the expected account.
  Future<void> load() async {
    final generation = ++_generation;
    final uid = currentUid();
    if (uid == null) {
      emit(const AchievementsState(needLogin: true));
      return;
    }
    emit(const AchievementsState(loading: true));
    try {
      if (fetchApi != null) {
        await ensureStatus?.call();
        if (isClosed || generation != _generation || currentUid() != uid) return;
        if (TsdmAppV4.achievement) {
          final answer = tsdmAppV4AnswerOf(await fetchApi!(), type: 'achievement', schema: 68);
          if (isClosed || generation != _generation || currentUid() != uid) return;
          switch (answer) {
            case _? when answer.uid == 0 && (answer is! TsdmAppV4Message || answer.login):
              emit(const AchievementsState(needLogin: true));
              return;
            case _? when answer.uid != uid:
              emit(const AchievementsState(failed: true));
              return;
            case TsdmAppV4Page(:final json):
              emit(AchievementsState(data: achievementPageFromApi(json)));
              return;
            case TsdmAppV4Message(:final message) when message.trim().isNotEmpty:
              emit(AchievementsState(data: AchievementPageData(recognized: false, message: message.trim())));
              return;
            case TsdmAppV4Message() || TsdmAppV4Refused() || null:
              break;
          }
        }
      }
      final document = parseHtmlDocument(await fetchPage());
      if (isClosed || generation != _generation || currentUid() != uid) return;
      final servedUid = parseLoggedUidFromDocument(document);
      if (servedUid == null) {
        emit(const AchievementsState(needLogin: true));
      } else if (servedUid != uid) {
        emit(const AchievementsState(failed: true));
      } else {
        emit(AchievementsState(data: parseAchievementPage(document)));
      }
    } on Exception {
      if (!isClosed && generation == _generation && currentUid() == uid) {
        emit(const AchievementsState(failed: true));
      }
    }
  }
}
