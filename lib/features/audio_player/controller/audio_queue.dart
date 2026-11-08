import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';

/// The tracks played one after another and the one played now.
@immutable
final class AudioQueue {
  /// Constructor.
  const AudioQueue(this.tracks, this.index) : assert(index >= 0 && index < tracks.length, 'index out of range');

  /// [tracks] from [track]: [tracks] when [track] is one of them, else [track] alone.
  factory AudioQueue.from(List<AudioTrack> tracks, AudioTrack track) {
    final index = tracks.indexOf(track);
    return index < 0 ? AudioQueue(List.unmodifiable([track]), 0) : AudioQueue(List.unmodifiable(tracks), index);
  }

  /// In the order played.
  final List<AudioTrack> tracks;

  /// Which is played now.
  final int index;

  /// The track played now.
  AudioTrack get current => tracks[index];

  /// Whether a track follows the current one.
  bool get hasNext => index + 1 < tracks.length;

  /// The queue at the next track, null at the last one.
  AudioQueue? get next => hasNext ? AudioQueue(tracks, index + 1) : null;

  /// Whether [track] is the one played now.
  bool isCurrent(AudioTrack track) => current == track;
}
