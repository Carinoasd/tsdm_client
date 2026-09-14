import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/achievements/models/achievement_page_data.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
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
  AchievementsCubit({required this.fetchPage, required this.currentUid}) : super(const AchievementsState());

  /// A read-only GET transport; takes no user-supplied URL or action parameters.
  final Future<String> Function() fetchPage;

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
