import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Play the song [songId] of NetEase Cloud Music named [title] (when known), from its public outer url; a song it does
/// not let everyone play stays a link to it.
Future<void> playNeteaseSong(BuildContext context, String songId, {String? title}) async {
  final thread = context.readOrNull<ThreadBloc>()?.state;
  final name = title?.trim();
  await AudioPlayerController.instance.playTrack(
    AudioTrack.netease(
      songId,
      title: name == null || name.isEmpty ? null : name,
      tid: thread?.tid,
      threadTitle: thread?.title,
    ),
  );
}

/// The mark before a link to a song of NetEase Cloud Music, in the size of the text: plays it ([playNeteaseSong]),
/// shows the player's state for it.
class NeteasePlayMark extends StatelessWidget {
  /// Constructor.
  const NeteasePlayMark({required this.songId, required this.size, this.title, super.key});

  /// The song.
  final String songId;

  /// The name the link gives it.
  final String? title;

  /// The size of the text.
  final double size;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.audioPlayer;
    final track = AudioTrack.netease(songId);
    final colorScheme = Theme.of(context).colorScheme;
    return BlocBuilder<AudioPlayerController, AudioPlayerState>(
      bloc: AudioPlayerController.instance,
      buildWhen: (prev, curr) => prev.isCurrent(track) || curr.isCurrent(track),
      builder: (context, state) {
        final status = state.isCurrent(track) ? state.status : AudioPlayerStatus.idle;
        final icon = switch (status) {
          AudioPlayerStatus.loading => SizedBox.square(
            dimension: size * 0.8,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
          AudioPlayerStatus.playing => Icon(Icons.pause_circle_outline, size: size, color: colorScheme.primary),
          AudioPlayerStatus.failed => Icon(Icons.music_off_outlined, size: size, color: colorScheme.error),
          _ => Icon(Icons.play_circle_outline, size: size, color: colorScheme.primary),
        };
        return Semantics(
          button: true,
          label: status == AudioPlayerStatus.playing ? tr.pause : tr.play,
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () async => playNeteaseSong(context, songId, title: title),
              child: Padding(padding: const EdgeInsets.only(right: 2), child: icon),
            ),
          ),
        );
      },
    );
  }
}
