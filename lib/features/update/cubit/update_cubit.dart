import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'update_cubit.mapper.dart';

/// Url checking for updates.
///
/// Version info used to be a JSON blob inside a forum post owned by the upstream author; the official Discuz! X5
/// edition reads `version.json` from its own repository instead so that releases and the in-app check stay in sync.
const String updateInfoUrl = upgradeVersionInfoUrl;

/// State of update cubit.
@MappableClass()
final class UpdateCubitState with UpdateCubitStateMappable {
  /// Constructor.
  const UpdateCubitState({this.loading = false, this.notice = false, this.latestVersionInfo});

  /// Loading or not.
  final bool loading;

  /// Trigger notice when failed or not.
  final bool notice;

  /// Data.
  final LatestVersionInfo? latestVersionInfo;
}

/// Checking cubit.
final class UpdateCubit extends Cubit<UpdateCubitState> with LoggerMixin {
  /// Constructor.
  UpdateCubit() : super(const UpdateCubitState());

  /// Check app update.
  ///
  /// Set [notice] to false if do not want the snackbar notice when failed to do check update.
  Future<void> checkUpdate({Duration? delay, bool notice = true}) async {
    emit(state.copyWith(loading: true, latestVersionInfo: null));
    if (delay != null) {
      await Future<void>.delayed(delay);
    }

    await getIt
        .get<NetClientProvider>()
        .get(updateInfoUrl)
        .map((v) => v.data as Object?)
        .handle(
          (e) {
            error('failed to check latest version: $e');
            emit(state.copyWith(loading: false, latestVersionInfo: null, notice: notice));
          },
          (v) {
            try {
              final latestVersionInfo = parseLatestVersionInfo(v);
              emit(state.copyWith(loading: false, latestVersionInfo: latestVersionInfo, notice: false));
            } on Exception catch (e) {
              error('failed to deserialize latest version info: $e');
              emit(state.copyWith(loading: false, latestVersionInfo: null, notice: notice));
            }
          },
        );
  }
}
