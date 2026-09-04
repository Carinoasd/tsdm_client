import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'profile_bloc.mapper.dart';
part 'profile_event.dart';
part 'profile_state.dart';

/// Emitter
typedef _Emitter = Emitter<ProfileState>;

/// Bloc of user profile page.
///
/// This profile page is for current logged user.
///
/// Actually other user's profile page should have a similar bloc but
/// without [ProfileStatus.needLogin] status.
class ProfileBloc extends Bloc<ProfileEvent, ProfileState> with LoggerMixin {
  /// Constructor.
  ProfileBloc({
    required ProfileRepository profileRepository,
    required AuthenticationRepository authenticationRepository,
  }) : _profileRepository = profileRepository,
       _authenticationRepository = authenticationRepository,
       super(const ProfileState()) {
    on<ProfileEvent>(
      (event, emit) => switch (event) {
        ProfileLoadRequested(:final username, :final uid) => _onLoadRequested(emit, username: username, uid: uid),
        ProfileRefreshRequested(:final uid, :final username) => _onRefreshRequested(emit, uid: uid, username: username),
        ProfileLogoutRequested() => _onLogoutRequested(emit),
      },
    );
  }

  final ProfileRepository _profileRepository;
  final AuthenticationRepository _authenticationRepository;

  Future<void> _onLoadRequested(_Emitter emit, {String? username, String? uid}) async {
    if (username == null && uid == null && _profileRepository.hasCache()) {
      (await buildProfile(_profileRepository.getCache()!).run()).match(
        (e) {
          emit(state.copyWith(status: ProfileStatus.failure, failedToLogoutReason: e));
        },
        (v) {
          final (unreadNoticeCount, hasUnreadMessage) = buildUnreadInfoStatus(_profileRepository.getCache()!);
          emit(
            state.copyWith(
              status: ProfileStatus.success,
              userProfile: v,
              unreadNoticeCount: unreadNoticeCount,
              hasUnreadMessage: hasUnreadMessage,
            ),
          );
        },
      );
      return;
    }
    emit(state.copyWith(status: ProfileStatus.loading));
    final documentEither = await _profileRepository.fetchProfile(username: username, uid: uid).run();
    if (documentEither.isLeft()) {
      final err = documentEither.unwrapErr();
      handle(err);
      if (err case ProfileNeedLoginException()) {
        emit(state.copyWith(status: ProfileStatus.needLogin));
        return;
      }
      emit(state.copyWith(status: ProfileStatus.failure));
      return;
    }
    final document = documentEither.unwrap();

    (await buildProfile(document).run()).match(
      (e) {
        error('failed to parse user profile: $e');
        emit(state.copyWith(status: ProfileStatus.failure, failedToLogoutReason: e));
      },
      (v) {
        final (unreadNoticeCount, hasUnreadMessage) = buildUnreadInfoStatus(document);
        emit(
          state.copyWith(
            status: ProfileStatus.success,
            userProfile: v,
            unreadNoticeCount: unreadNoticeCount,
            hasUnreadMessage: hasUnreadMessage,
          ),
        );
      },
    );
  }

  Future<void> _onRefreshRequested(_Emitter emit, {required String? uid, required String? username}) async {
    emit(state.copyWith(status: ProfileStatus.loading));
    final documentEither = await _profileRepository.fetchProfile(uid: uid, username: username, force: true).run();
    if (documentEither.isLeft()) {
      final err = documentEither.unwrapErr();
      handle(err);
      if (err case ProfileNeedLoginException()) {
        emit(state.copyWith(status: ProfileStatus.needLogin));
        return;
      }
      emit(state.copyWith(status: ProfileStatus.failure));
      return;
    }
    final document = documentEither.unwrap();
    (await buildProfile(document).run()).match(
      (e) {
        error('failed to parse user profile: $e');
        emit(state.copyWith(status: ProfileStatus.failure, failedToLogoutReason: e));
        return;
      },
      (v) {
        final (unreadNoticeCount, hasUnreadMessage) = buildUnreadInfoStatus(document);
        emit(
          state.copyWith(
            status: ProfileStatus.success,
            userProfile: v,
            unreadNoticeCount: unreadNoticeCount,
            hasUnreadMessage: hasUnreadMessage,
          ),
        );
      },
    );
  }

  Future<void> _onLogoutRequested(_Emitter emit) async {
    emit(state.copyWith(status: ProfileStatus.loggingOut));
    await _authenticationRepository.logout().match((e) {
      handle(e);
      emit(state.copyWith(status: ProfileStatus.success, failedToLogoutReason: e));
    }, (_) => emit(state.copyWith(status: ProfileStatus.needLogin))).run();
  }
}
