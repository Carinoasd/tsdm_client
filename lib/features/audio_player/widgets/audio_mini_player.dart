import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/widgets/audio_controls.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The app's pages ([child]) with the mini player below them while something is played: the track's name, where it
/// is, play or pause, close. It stays from page to page until closed; it steps aside while the keyboard is up.
///
/// Above the app's navigator: nothing in it may ask for an overlay (no tooltips).
class AudioMiniPlayerHost extends StatelessWidget {
  /// Constructor.
  const AudioMiniPlayerHost({required this.child, super.key});

  /// The app's pages.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    return BlocBuilder<AudioPlayerController, AudioPlayerState>(
      bloc: AudioPlayerController.instance,
      buildWhen: (prev, curr) => (prev.queue == null) != (curr.queue == null),
      builder: (context, state) {
        final shown = state.queue != null && data.viewInsets.bottom <= 0;
        // The same tree either way: the pages keep their state when the bar comes and goes.
        return Column(
          children: [
            Expanded(
              child: MediaQuery(data: shown ? data.removePadding(removeBottom: true) : data, child: child),
            ),
            if (shown) const _MiniPlayerBar(),
          ],
        );
      },
    );
  }
}

class _MiniPlayerBar extends StatelessWidget {
  const _MiniPlayerBar();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.audioPlayer;
    final controller = AudioPlayerController.instance;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: colorScheme.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: BlocBuilder<AudioPlayerController, AudioPlayerState>(
          bloc: controller,
          builder: (context, state) {
            final track = state.current;
            if (track == null) {
              return const SizedBox.shrink();
            }
            final duration = state.duration;
            final failed = state.status == AudioPlayerStatus.failed;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 2,
                  child: switch (state.status) {
                    AudioPlayerStatus.loading => LinearProgressIndicator(value: state.progress),
                    _ when duration != null && duration > Duration.zero => StreamBuilder<Duration>(
                      stream: controller.positionStream,
                      builder: (context, snapshot) => LinearProgressIndicator(
                        value: ((snapshot.data ?? Duration.zero).inMilliseconds / duration.inMilliseconds).clamp(0, 1),
                      ),
                    ),
                    _ => null,
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(
                        failed ? Icons.music_off_outlined : Icons.music_note_outlined,
                        color: failed ? colorScheme.error : colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          failed ? '${track.title}  ${audioFailureText(context, state.failure)}' : track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium,
                        ),
                      ),
                      if (state.status == AudioPlayerStatus.loading)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                        )
                      else
                        Semantics(
                          button: true,
                          label: state.status == AudioPlayerStatus.playing ? tr.pause : tr.play,
                          excludeSemantics: true,
                          child: IconButton(
                            icon: Icon(switch (state.status) {
                              AudioPlayerStatus.playing => Icons.pause,
                              AudioPlayerStatus.failed => Icons.refresh,
                              _ => Icons.play_arrow,
                            }),
                            onPressed: controller.toggle,
                          ),
                        ),
                      Semantics(
                        button: true,
                        label: tr.close,
                        excludeSemantics: true,
                        child: IconButton(icon: const Icon(Icons.close), onPressed: controller.dismiss),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
