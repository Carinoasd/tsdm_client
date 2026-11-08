import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_backend.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_queue.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What the player does.
enum AudioPlayerStatus {
  /// Nothing to play: the mini player is not shown.
  idle,

  /// Fetching or loading the current track.
  loading,

  /// Playing.
  playing,

  /// Paused.
  paused,

  /// The last track of the queue played to the end.
  completed,

  /// The current track could not be played ([AudioPlayerState.failure]).
  failed,
}

/// The state of [AudioPlayerController].
final class AudioPlayerState extends Equatable {
  /// Constructor.
  const AudioPlayerState({
    this.queue,
    this.status = AudioPlayerStatus.idle,
    this.progress,
    this.duration,
    this.failure,
  });

  /// What is played, null when nothing.
  final AudioQueue? queue;

  /// What the player does.
  final AudioPlayerStatus status;

  /// The part of the current track fetched while [AudioPlayerStatus.loading], null when unknown.
  final double? progress;

  /// The length of the current track once loaded.
  final Duration? duration;

  /// Why the current track could not be played; null for an error of the player.
  final AudioFetchFailure? failure;

  /// The track played now.
  AudioTrack? get current => queue?.current;

  /// Whether [track] is the one played now.
  bool isCurrent(AudioTrack track) => queue?.isCurrent(track) ?? false;

  @override
  List<Object?> get props => [queue?.tracks, queue?.index, status, progress, duration, failure];
}

/// The app's one sound player: a queue of tracks played one after another, kept across pages until closed.
///
/// A track is fetched to a file ([AudioFetcher]) and played from there ([AudioBackend]). A track that cannot be
/// played stops the queue there: the next one is not fetched for nothing.
final class AudioPlayerController extends Cubit<AudioPlayerState> with LoggerMixin {
  /// Constructor.
  AudioPlayerController({required AudioBackend backend, required AudioFetcher fetcher})
    : _backend = backend,
      _fetcher = fetcher,
      super(const AudioPlayerState());

  /// The one of the app, made the first time it is asked for.
  // A getter of the one in the service locator, not a new one each time.
  // ignore: prefer_constructors_over_static_methods
  static AudioPlayerController get instance {
    if (!getIt.isRegistered<AudioPlayerController>()) {
      getIt.registerSingleton(AudioPlayerController(backend: JustAudioBackend(), fetcher: NetAudioFetcher()));
    }
    return getIt.get<AudioPlayerController>();
  }

  final AudioBackend _backend;
  final AudioFetcher _fetcher;

  /// Bumped for each track started and at close: what a former one finishes later is dropped.
  int _generation = 0;

  CancelToken? _cancelToken;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Where the player is in the current track. just_audio's stream gives a new listener the position at once (a card
  /// built again while paused shows where it is).
  Stream<Duration> get positionStream => _subscriptions.isEmpty ? const Stream.empty() : _backend.positionStream;

  void _listen() {
    if (_subscriptions.isNotEmpty) {
      return;
    }
    _subscriptions
      ..add(_backend.playingStream.listen(_onPlaying))
      ..add(_backend.stateStream.listen(_onBackendState));
  }

  void _onPlaying(bool playing) {
    switch (state.status) {
      case AudioPlayerStatus.playing when !playing:
        emit(_copy(status: AudioPlayerStatus.paused));
      case AudioPlayerStatus.paused || AudioPlayerStatus.completed when playing:
        // From the system's media controls.
        emit(_copy(status: AudioPlayerStatus.playing));
      case _:
        break;
    }
  }

  Future<void> _onBackendState(AudioBackendState backendState) async {
    switch (backendState) {
      case AudioBackendState.completed when state.status == AudioPlayerStatus.playing:
        final next = state.queue?.next;
        if (next == null) {
          emit(_copy(status: AudioPlayerStatus.completed));
        } else {
          await _start(next);
        }
      case AudioBackendState.idle
          when state.status == AudioPlayerStatus.playing || state.status == AudioPlayerStatus.paused:
        // Stopped from the system's media controls: closed as from the mini player.
        await dismiss();
      case _:
        break;
    }
  }

  /// Play [track], or pause or resume it when it is the one played now. [queue] is what it is played in (the audio
  /// attachments of its thread), the tracks after it played after it; [track] alone when it is not one of them.
  Future<void> playTrack(AudioTrack track, {List<AudioTrack>? queue}) async {
    if (state.isCurrent(track) && state.status != AudioPlayerStatus.failed) {
      return toggle();
    }
    await _start(AudioQueue.from(queue ?? [track], track));
  }

  Future<void> _start(AudioQueue queue) async {
    final generation = ++_generation;
    _cancelToken?.cancel();
    final cancelToken = _cancelToken = CancelToken();
    emit(AudioPlayerState(queue: queue, status: AudioPlayerStatus.loading));
    final track = queue.current;
    try {
      // The track played before is silent while this one loads, and stays so when this one fails.
      if (_subscriptions.isNotEmpty) {
        await _backend.pause();
      }
      final file = await _fetcher.fetch(
        track,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (generation == _generation && state.status == AudioPlayerStatus.loading) {
            emit(_copy(progress: progress));
          }
        },
      );
      if (generation != _generation) {
        return;
      }
      _listen();
      final duration = await _backend.load(file, track);
      if (generation != _generation) {
        return;
      }
      emit(AudioPlayerState(queue: queue, status: AudioPlayerStatus.playing, duration: duration));
      await _backend.play();
    } on AudioFetchException catch (e) {
      if (generation == _generation) {
        emit(AudioPlayerState(queue: queue, status: AudioPlayerStatus.failed, failure: e.failure));
      }
    } on DioException {
      // Cancelled for a former generation (another track started, or closed): dropped. Anything else, cancelled or
      // not, is this track failing.
      if (generation == _generation) {
        emit(AudioPlayerState(queue: queue, status: AudioPlayerStatus.failed, failure: AudioFetchFailure.network));
      }
    } on Object catch (e, st) {
      error('failed to play ${track.id}', e, st);
      if (generation == _generation) {
        emit(AudioPlayerState(queue: queue, status: AudioPlayerStatus.failed));
      }
    }
  }

  /// Pause when playing, play when paused; play again from the start when played to the end; try again when failed.
  Future<void> toggle() async {
    switch (state.status) {
      case AudioPlayerStatus.playing:
        emit(_copy(status: AudioPlayerStatus.paused));
        await _backend.pause();
      case AudioPlayerStatus.paused:
        emit(_copy(status: AudioPlayerStatus.playing));
        await _backend.play();
      case AudioPlayerStatus.completed:
        emit(_copy(status: AudioPlayerStatus.playing));
        await _backend.seek(Duration.zero);
        await _backend.play();
      case AudioPlayerStatus.failed:
        if (state.queue case final queue?) {
          await _start(queue);
        }
      case AudioPlayerStatus.idle || AudioPlayerStatus.loading:
        break;
    }
  }

  /// Go to [position] of the current track.
  Future<void> seek(Duration position) async {
    if (state.status == AudioPlayerStatus.completed) {
      // At the end the player still says it plays: it would play on from where it is sought to.
      emit(_copy(status: AudioPlayerStatus.paused));
      await _backend.pause();
    }
    if (const {AudioPlayerStatus.playing, AudioPlayerStatus.paused}.contains(state.status)) {
      await _backend.seek(position);
    }
  }

  /// Stop and forget the queue: the mini player goes away.
  Future<void> dismiss() async {
    _generation++;
    _cancelToken?.cancel();
    _cancelToken = null;
    emit(const AudioPlayerState());
    try {
      await _backend.stop();
    } on Object catch (e, st) {
      error('failed to stop the player', e, st);
    }
  }

  AudioPlayerState _copy({AudioPlayerStatus? status, double? progress}) => AudioPlayerState(
    queue: state.queue,
    status: status ?? state.status,
    progress: progress ?? state.progress,
    duration: state.duration,
    failure: state.failure,
  );
}
