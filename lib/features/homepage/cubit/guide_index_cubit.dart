import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_feed.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'guide_index_cubit.mapper.dart';

/// Status of the guide index section.
enum GuideIndexStatus {
  /// Nothing requested yet.
  initial,

  /// Fetching the guide index page.
  loading,

  /// Modules are ready (possibly empty).
  success,

  /// Fetching failed, the user may retry.
  failure,
}

/// State of the guide index section on the homepage.
@MappableClass()
final class GuideIndexState with GuideIndexStateMappable {
  /// Constructor.
  const GuideIndexState({this.status = GuideIndexStatus.initial, this.modules = const []});

  /// Status.
  final GuideIndexStatus status;

  /// Modules of the guide index page, in page order.
  final List<GuideModule> modules;
}

/// Loads the guide index page for the homepage guide section (GitHub #12).
final class GuideIndexCubit extends Cubit<GuideIndexState> with LoggerMixin {
  /// Constructor.
  ///
  /// With [feed] the guide is taken from it ([GuideFeed.fetch]: the request the homepage asked together with its own
  /// page) instead of [_repository]. [saved] are the modules saved for the account at the last start, shown while
  /// the guide is asked again.
  GuideIndexCubit(this._repository, {GuideFeed? feed, List<GuideModule>? saved})
    : _feed = feed,
      super(
        saved == null || saved.isEmpty
            ? const GuideIndexState()
            : GuideIndexState(status: GuideIndexStatus.success, modules: saved),
      );

  final GuideIndexRepository _repository;
  final GuideFeed? _feed;

  /// Fetch the guide index page; previous modules stay visible while loading.
  Future<void> load() async {
    emit(state.copyWith(status: GuideIndexStatus.loading));
    await (_feed?.fetch() ?? _repository.fetchGuideIndex())
        .match(
          (e) {
            handle(e);
            error('failed to load guide index: $e');
            if (!isClosed) {
              emit(state.copyWith(status: GuideIndexStatus.failure));
            }
          },
          (v) {
            if (!isClosed) {
              emit(GuideIndexState(status: GuideIndexStatus.success, modules: v));
            }
          },
        )
        .run();
  }
}
