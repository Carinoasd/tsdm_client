import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/models/update_channel.dart';
import 'package:tsdm_client/features/update/repository/cloudreve_mirror.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'update_cubit.mapper.dart';

/// Url checking for updates.
///
/// Version info used to be a JSON blob inside a forum post owned by the upstream author; the official Discuz! X5
/// edition reads `version.json` from its own repository instead so that releases and the in-app check stay in sync.
/// The Cloudreve mirror's copy ([CloudreveMirror]) is used only when this one cannot be read.
const String updateInfoUrl = upgradeVersionInfoUrl;

/// State of update cubit.
@MappableClass()
final class UpdateCubitState with UpdateCubitStateMappable {
  /// Constructor.
  const UpdateCubitState({
    this.loading = false,
    this.notice = false,
    this.latestVersionInfo,
    this.channel = UpdateChannel.auto,
  });

  /// Loading or not.
  final bool loading;

  /// Trigger notice when failed or not.
  final bool notice;

  /// Data.
  final LatestVersionInfo? latestVersionInfo;

  /// Where the check asks and the download takes its bytes.
  final UpdateChannel channel;
}

/// Checking cubit.
final class UpdateCubit extends Cubit<UpdateCubitState> with LoggerMixin {
  /// Constructor.
  ///
  /// [mirror] and [githubVersionInfo] replace the network sources in tests. [channel] is the one the user chose
  /// before and [saveChannel] keeps a new choice.
  UpdateCubit({
    UpdateDownloadCubit? download,
    CloudreveMirror? mirror,
    AsyncEither<Object?> Function()? githubVersionInfo,
    UpdateChannel channel = UpdateChannel.auto,
    Future<void> Function(UpdateChannel channel)? saveChannel,
  }) : download = download ?? UpdateDownloadCubit(),
       _mirror = mirror ?? CloudreveMirror(),
       _githubVersionInfo = githubVersionInfo,
       _saveChannel = saveChannel,
       super(UpdateCubitState(channel: channel)) {
    this.download.channel = channel;
  }

  final CloudreveMirror _mirror;
  final AsyncEither<Object?> Function()? _githubVersionInfo;
  final Future<void> Function(UpdateChannel channel)? _saveChannel;

  /// Download state belongs to the app-scoped update service, so navigation does not interrupt it.
  final UpdateDownloadCubit download;

  @override
  Future<void> close() async {
    await download.close();
    _mirror.dispose();
    await super.close();
  }

  /// Check app update.
  ///
  /// Set [notice] to false if do not want the snackbar notice when failed to do check update.
  Future<void> checkUpdate({Duration? delay, bool notice = true}) async {
    emit(state.copyWith(loading: true, latestVersionInfo: null));
    if (delay != null) {
      await Future<void>.delayed(delay);
    }

    final LatestVersionInfo? latest;
    switch (state.channel) {
      case UpdateChannel.auto:
        // Both at once: GitHub's copy is the authority whenever it can be read (the mirror may lag behind, or name a
        // version of its own); the mirror's answers only where GitHub cannot be reached.
        // Both start at once, but an answer from GitHub never waits for the mirror.
        final mirrored = _fromMirror();
        latest = await _fromGithub() ?? await mirrored;
      case UpdateChannel.mirror:
        latest = await _fromMirror();
      case UpdateChannel.github:
        latest = await _fromGithub();
    }
    if (isClosed) return;
    if (latest == null) {
      emit(state.copyWith(loading: false, latestVersionInfo: null, notice: notice));
      return;
    }
    emit(state.copyWith(loading: false, latestVersionInfo: latest, notice: false));
    // Android may kill the process when installation permission changes. Revalidate an existing APK after version
    // discovery, then let the user explicitly request installation again.
    await download.restore(latest);
  }

  /// Use [channel] from now on, for the checks and the downloads started after this, and keep the choice. The result
  /// of the last check is dropped: it is another channel's answer.
  Future<void> setChannel(UpdateChannel channel) async {
    if (channel == state.channel) return;
    download.channel = channel;
    emit(state.copyWith(channel: channel, latestVersionInfo: null, notice: false));
    await _saveChannel?.call(channel);
  }

  Future<LatestVersionInfo?> _fromMirror() async {
    try {
      return parseLatestVersionInfo(await _mirror.versionInfo());
    } on Exception catch (e) {
      warning('mirror version info unavailable: $e');
      return null;
    }
  }

  Future<LatestVersionInfo?> _fromGithub() async {
    LatestVersionInfo? result;
    try {
      await (_githubVersionInfo ?? _readGithub)().handle((e) => error('failed to check latest version: $e'), (v) {
        try {
          result = parseLatestVersionInfo(v);
        } on Exception catch (e) {
          error('failed to deserialize latest version info: $e');
        }
      });
    } on Exception catch (e) {
      error('failed to check latest version: $e');
    }
    return result;
  }

  static AsyncEither<Object?> _readGithub() =>
      getIt.get<NetClientProvider>().get(updateInfoUrl).map((v) => v.data as Object?);
}
