import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';

/// What the player does with what it loaded.
enum AudioBackendState {
  /// Nothing loaded, or stopped (from the system's media controls too).
  idle,

  /// Loading or buffering.
  loading,

  /// Ready to play, playing or paused ([AudioBackend.playingStream]).
  ready,

  /// Played to the end.
  completed,
}

/// The sound player under the app's player controller: one file at a time. Tests give a fake one.
abstract interface class AudioBackend {
  /// Whether it plays (else paused), each time it changes.
  Stream<bool> get playingStream;

  /// Its state, each time it changes.
  Stream<AudioBackendState> get stateStream;

  /// Where it is in what it plays.
  Stream<Duration> get positionStream;

  /// Load the local file [path] of [track], told to the system's media controls as [track]; the length of the sound
  /// when known.
  Future<Duration?> load(String path, AudioTrack track);

  /// Play what was loaded; returns once it started.
  Future<void> play();

  /// Pause.
  Future<void> pause();

  /// Go to [position].
  Future<void> seek(Duration position);

  /// Stop and unload.
  Future<void> stop();
}

/// [AudioBackend] of `just_audio`: the platform's player on Android, iOS and macOS (with `just_audio_background` for
/// the media notification and playing in the background), libmpv through `just_audio_media_kit` on Windows and Linux.
///
/// The player is made the first time something is loaded: building a floor with an audio attachment touches no
/// platform code.
final class JustAudioBackend implements AudioBackend {
  AudioPlayer? _player;

  AudioPlayer get _p => _player ??= AudioPlayer();

  @override
  Stream<bool> get playingStream => _p.playingStream;

  @override
  Stream<AudioBackendState> get stateStream => _p.processingStateStream.map(
    (e) => switch (e) {
      ProcessingState.idle => AudioBackendState.idle,
      ProcessingState.loading || ProcessingState.buffering => AudioBackendState.loading,
      ProcessingState.ready => AudioBackendState.ready,
      ProcessingState.completed => AudioBackendState.completed,
    },
  );

  @override
  Stream<Duration> get positionStream => _p.positionStream;

  @override
  Future<Duration?> load(String path, AudioTrack track) => _p.setAudioSource(
    AudioSource.file(
      path,
      tag: MediaItem(id: track.id, title: track.title, album: track.threadTitle),
    ),
  );

  @override
  Future<void> play() async {
    // The future of `play()` completes when playing stops again.
    unawaited(_p.play());
  }

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> seek(Duration position) => _p.seek(position);

  @override
  Future<void> stop() async => _player?.stop();
}
